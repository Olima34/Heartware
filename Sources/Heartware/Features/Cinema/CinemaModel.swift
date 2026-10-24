import SwiftUI
import AppKit

/// A search: running, its titles, or why it failed.
enum CinemaSearchState: Equatable {
    case loading
    case done([CinemaHit], Date)
    case failed(String)

    var hits: [CinemaHit] {
        if case .done(let h, _) = self { return h }
        return []
    }
}

/// What the module keeps between launches: the user's platforms and the titles they looked at.
struct CinemaSaved: Codable {
    var mine: [String] = []
    var recents: [CinemaHit] = []
    /// The country whose platforms are listed, when the user chose one.
    var region: String?
}

@Observable
@MainActor
final class CinemaModel: AppModule {
    /// A TMDB key is in the keychain (never read until a search needs it).
    var hasKey = false
    var keyChecking = false
    var keyError: String?

    var searches: [String: CinemaSearchState] = [:]
    var titles: [String: CinemaTitle] = [:]
    var loadingTitles: Set<String> = []
    var titleErrors: [String: String] = [:]
    /// Posters and platform logos, by TMDB path and width.
    var images: [String: CGImage] = [:]

    // The page.
    var pageQuery = ""
    var pageKind: CinemaKind?
    var selected: CinemaHit?
    var mine: Set<String> = []
    var recents: [CinemaHit] = []

    @ObservationIgnored private let store = JSONStore<CinemaSaved>("cinema", default: CinemaSaved())
    @ObservationIgnored private var launcherTask: Task<Void, Never>?
    /// The search the launcher waits for: asked once, however often the list is redrawn meanwhile.
    @ObservationIgnored private var launcherKey: String?
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var imageLoads: Set<String> = []
    /// The posters in the order they arrived, the oldest first.
    @ObservationIgnored private var imageOrder: [String] = []
    @ObservationIgnored private var cachedKey: String?

    let language = "fr-FR"
    /// The country whose platforms are listed: the user's choice, else the Mac's region (France by default).
    var region = CinemaRegion.system

    init() {
        let saved = store.value
        mine = Set(saved.mine)
        recents = saved.recents
        if let r = saved.region, CinemaRegion.isValid(r) { region = r }
        hasKey = !DemoData.isEnabled && Keychain.exists(CinemaTMDB.keyAccount)
    }

    var sidebarBadge: String? { nil }

    // MARK: Key

    /// Read off the main thread: after an update macOS may ask whether the app can read its item, and the main thread
    /// would wait for that answer (a window easily hidden behind the launcher) with the whole app frozen.
    private func key() async -> String? {
        if let cachedKey { return cachedKey }
        let account = CinemaTMDB.keyAccount
        let read = await Task.detached(priority: .userInitiated) { Keychain.get(account) }.value
        if cachedKey == nil { cachedKey = read }
        return cachedKey
    }

    /// Checks the key with TMDB, then keeps it in the keychain.
    func saveKey(_ raw: String) {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !DemoData.isEnabled else { return HUD.show(DemoData.refusal) }
        guard CinemaTMDB.keyKind(k) != nil else {
            keyError = "Ça ne ressemble pas à une clé TMDB : colle la « Clé d'API » (32 caractères) ou le « Jeton d'accès en lecture »."
            return
        }
        keyChecking = true
        keyError = nil
        Task {
            defer { keyChecking = false }
            do {
                try await CinemaTMDB.check(key: k)
                guard Keychain.set(k, for: CinemaTMDB.keyAccount) else {
                    keyError = "Impossible d'enregistrer la clé dans le Trousseau."
                    return
                }
                cachedKey = k
                hasKey = true
                searches = [:]
                HUD.show("Clé TMDB enregistrée", symbol: "checkmark.circle.fill")
            } catch {
                keyError = error.localizedDescription
            }
        }
    }

    func removeKey() {
        guard !DemoData.isEnabled else { return HUD.show(DemoData.refusal) }
        _ = Keychain.delete(CinemaTMDB.keyAccount)
        cachedKey = nil
        hasKey = false
        searches = [:]
    }

    // MARK: Searching

    func search(_ title: String, kind: CinemaKind?) -> CinemaSearchState? {
        searches[CinemaQuery.key(title, kind: kind)]
    }

    /// Starts a search unless an answer of less than ten minutes is there. `forLauncher`: the launcher's latest text
    /// replaces the previous one (typing « film du… » asks once it stays still) and the list is redrawn with the answer.
    func startSearch(_ title: String, kind: CinemaKind?, delay: Double = 0.3, forLauncher: Bool = false) {
        let k = CinemaQuery.key(title, kind: kind)
        if case .done(_, let date)? = searches[k], Date().timeIntervalSince(date) < 600 { return }
        if case .loading? = searches[k], !forLauncher { return }
        // A failure stays on screen until "↩ réessaie": each redraw of the launcher would otherwise ask TMDB again, forever.
        if case .failed? = searches[k], forLauncher { return }
        guard hasKey, !DemoData.isEnabled else { return }
        if forLauncher {
            if launcherKey == k { return }
            launcherTask?.cancel()
            launcherKey = k
        } else {
            pageTask?.cancel()
        }
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, let key = await self.key(), !Task.isCancelled else { return }
            self.searches[k] = .loading
            let state: CinemaSearchState
            do {
                state = .done(try await CinemaTMDB.search(title, kind: kind, key: key, language: self.language), Date())
            } catch {
                if case CinemaTMDB.Failure.badKey = error { self.cachedKey = nil }
                state = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled else { self.searches[k] = nil; return }
            // Every title typed in the launcher leaves its answer: past a few hundred, the oldest half goes.
            if self.searches.count >= 300 {
                let old = self.searches.compactMap { key, s -> (String, Date)? in
                    if case .done(_, let date) = s { return (key, date) } else if case .failed = s { return (key, .distantPast) } else { return nil }
                }.sorted { $0.1 < $1.1 }.prefix(150)
                for (key, _) in old { self.searches[key] = nil }
            }
            self.searches[k] = state
            if forLauncher {
                if self.launcherKey == k { self.launcherKey = nil }
                self.refreshLauncher()
            }
        }
        if forLauncher { launcherTask = task } else { pageTask = task }
    }

    /// The page's search field.
    func searchFromPage() {
        let q = pageQuery.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        startSearch(q, kind: pageKind, delay: 0)
    }

    var pageResults: CinemaSearchState? {
        let q = pageQuery.trimmingCharacters(in: .whitespaces)
        return q.count >= 2 ? search(q, kind: pageKind) : nil
    }

    // MARK: A title's card

    /// Loads the card and the platforms of a title (kept half an hour), then the direct links of Wikidata.
    func load(_ hit: CinemaHit) {
        loadPicture(hit.posterPath, width: 185)
        guard !DemoData.isEnabled, hasKey, !loadingTitles.contains(hit.id) else { return }
        if titles[hit.id] != nil, titleErrors[hit.id] == nil { return }
        loadingTitles.insert(hit.id)
        titleErrors[hit.id] = nil
        Task { [weak self] in
            guard let self else { return }
            guard let key = await self.key() else {
                self.loadingTitles.remove(hit.id)
                return
            }
            do {
                var title = try await CinemaTMDB.details(hit, key: key, language: self.language, region: self.region)
                self.titles[hit.id] = title
                self.loadingTitles.remove(hit.id)
                for o in title.offers { self.loadPicture(o.logoPath, width: 92) }
                self.refreshLauncher()
                title.direct = await CinemaWikidata.direct(for: title)
                title.wikidataChecked = true
                self.titles[hit.id] = title
                self.refreshLauncher()
            } catch {
                self.loadingTitles.remove(hit.id)
                self.titleErrors[hit.id] = error.localizedDescription
            }
        }
    }

    func title(_ hit: CinemaHit) -> CinemaTitle? { titles[hit.id] }

    func picture(_ path: String?, width: Int) -> CGImage? {
        path.flatMap { images["\(width)\($0)"] }
    }

    func loadPicture(_ path: String?, width: Int) {
        guard let path, !DemoData.isEnabled else { return }
        let k = "\(width)\(path)"
        guard images[k] == nil, !imageLoads.contains(k) else { return }
        imageLoads.insert(k)
        Task { [weak self] in
            let image = await CinemaTMDB.image(path, width: width)
            guard let self else { return }
            if let image {
                // Posters pile up while browsing (≈ 200 KB each): past three hundred, the hundred loaded longest ago go
                // (what is on screen was loaded last and stays). The small logos of the platforms are kept.
                if width > 92 { self.imageOrder.append(k) }
                if self.imageOrder.count > 300 {
                    let old = self.imageOrder.prefix(100)
                    self.imageOrder.removeFirst(100)
                    for o in old {
                        self.images[o] = nil
                        self.imageLoads.remove(o)
                    }
                }
                self.images[k] = image
            } else {
                self.imageLoads.remove(k)
            }
        }
    }

    // MARK: Watching

    func bestOffer(_ hit: CinemaHit) -> CinemaOffer? {
        titles[hit.id].flatMap { CinemaOffers.best($0, mine: mine) }
    }

    /// Opens the platform: the ad-free player for YouTube, the browser otherwise.
    func open(_ offer: CinemaOffer, in title: CinemaTitle) {
        let d = CinemaOffers.destination(offer, in: title)
        remember(title.hit)
        guard !DemoData.isEnabled else { return HUD.show(DemoData.refusal) }
        guard let url = URL(string: d.url), url.scheme == "https" else { return }
        AppContext.model?.launcher.hide()
        if d.adFreePlayer, let playable = AdBlockPlayer.playable(d.url) {
            AppContext.model?.adblock.player.open(playable)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// ↩ on a title: its best offer, or TMDB's page of the platforms while the card is not there yet.
    func watch(_ hit: CinemaHit) {
        if let t = titles[hit.id], let offer = CinemaOffers.best(t, mine: mine) {
            open(offer, in: t)
        } else {
            remember(hit)
            guard !DemoData.isEnabled else { return HUD.show(DemoData.refusal) }
            AppContext.model?.launcher.hide()
            Finder.open(titles[hit.id]?.watchPage ?? hit.tmdbURL + "/watch")
        }
    }

    func playTrailer(_ title: CinemaTitle) {
        guard let id = title.trailer, let url = URL(string: "https://www.youtube.com/watch?v=\(id)") else { return }
        remember(title.hit)
        guard !DemoData.isEnabled else { return HUD.show(DemoData.refusal) }
        AppContext.model?.launcher.hide()
        AppContext.model?.adblock.player.open(url)
    }

    /// The card on the page.
    func show(_ hit: CinemaHit, app: AppModel) {
        selected = hit
        remember(hit)
        load(hit)
        app.media.show(.watch, app: app)
    }

    func select(_ hit: CinemaHit) {
        selected = hit
        remember(hit)
        load(hit)
    }

    /// Another country: its platforms, so the cards are asked again.
    func setRegion(_ code: String) {
        guard CinemaRegion.isValid(code), code != region else { return }
        region = code
        store.value.region = code == CinemaRegion.system ? nil : code
        titles = [:]
        titleErrors = [:]
        if let s = selected { load(s) }
    }

    func toggleMine(_ key: String) {
        if mine.contains(key) { mine.remove(key) } else { mine.insert(key) }
        store.value.mine = mine.sorted()
    }

    private func remember(_ hit: CinemaHit) {
        recents.removeAll { $0.id == hit.id }
        recents.insert(hit, at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
        store.value.recents = recents
    }

    private func refreshLauncher() {
        guard let launcher = AppContext.model?.launcher, launcher.isOpen else { return }
        let q = launcher.query
        if CinemaQuery.parse(q) != nil || CinemaQuery.looksLikeTitle(q) { launcher.refreshKeepingSelection() }
    }

    // MARK: AppModule

    func stop() {
        launcherTask?.cancel()
        pageTask?.cancel()
        store.flush()
    }

    func commands(app: AppModel) -> [AppCommand] {
        [AppCommand(id: "cinema_open", title: "Films et séries", subtitle: "Cherche un film ou une série : sa fiche et où le regarder",
                    keywords: ["film", "série", "cinéma", "où regarder", "streaming", "netflix", "tmdb", "bande-annonce"],
                    icon: .symbol("popcorn", CinemaStyle.tint), group: .tools, assistantSafe: true, urlSafe: true, hint: "Ouvrir") { ctx in
            ctx.app.media.show(.watch, app: ctx.app)
            return .done
        }]
    }

    func results(for query: String, app: AppModel) -> [AppCommand] {
        if let asked = CinemaQuery.parse(query) { return launcherResults(asked.title, kind: asked.kind) }
        guard hasKey || DemoData.isEnabled, CinemaQuery.looksLikeTitle(query) else { return [] }
        let text = query.trimmingCharacters(in: .whitespaces)
        // Under everything that matches (the row of the files too): nothing is sent until the row is selected.
        return [AppCommand(id: "cinema_lookup", title: "Films et séries : « \(text) »", subtitle: "Sa fiche et où le regarder",
                           icon: .symbol("popcorn", CinemaStyle.tint), group: .cinema, hint: "Tous les résultats",
                           boost: 40, staysInLauncher: true,
                           pane: { AnyView(CinemaSearchPane(title: text, kind: nil)) }) { ctx in
            ctx.app.launcher.query = "regarder " + text
            return .done
        }]
    }

    private func launcherResults(_ title: String, kind: CinemaKind?) -> [AppCommand] {
        let tint = CinemaStyle.tint
        guard hasKey || DemoData.isEnabled else {
            return [AppCommand(id: "cinema_key", title: "Films et séries : ajoute ta clé TMDB", subtitle: "Gratuite, en deux minutes",
                               icon: .symbol("key", tint), group: .cinema, hint: "Ouvrir", boost: 2000) { ctx in
                ctx.app.media.show(.watch, app: ctx.app)
                return .done
            }]
        }
        startSearch(title, kind: kind, forLauncher: true)
        let label = kind == .tv ? "séries" : (kind == .movie ? "films" : "films et séries")
        switch search(title, kind: kind) {
        case .done(let hits, _) where !hits.isEmpty:
            return hits.prefix(6).enumerated().map { i, hit in hitCommand(hit, boost: 2000 - Double(i)) }
        case .done:
            return [AppCommand(id: "cinema_none", title: "Aucun résultat dans les \(label) pour « \(title) »",
                               subtitle: "Vérifie l'orthographe ou essaie le titre original", icon: .symbol("questionmark.circle", tint),
                               group: .cinema, boost: 2000) { _ in .done }]
        case .failed(let message):
            return [AppCommand(id: "cinema_failed", title: message, subtitle: "↩ réessaie", icon: .symbol("exclamationmark.triangle", Theme.warn),
                               group: .cinema, boost: 2000, staysInLauncher: true) { [weak self] _ in
                self?.searches[CinemaQuery.key(title, kind: kind)] = nil
                self?.refreshLauncher()
                return .done
            }]
        default:
            return [AppCommand(id: "cinema_searching", title: "Recherche dans les \(label) : « \(title) »…", subtitle: "The Movie Database",
                               icon: .symbol("popcorn", tint), group: .cinema, boost: 2000, staysInLauncher: true,
                               pane: { AnyView(CinemaSearchPane(title: title, kind: kind)) }) { _ in .done }]
        }
    }

    func hitCommand(_ hit: CinemaHit, boost: Double) -> AppCommand {
        let offer = bestOffer(hit)
        var subtitle = hit.line
        if let o = offer { subtitle += " · " + o.displayName } else if titles[hit.id] != nil { subtitle += " · pas en streaming" }
        return AppCommand(id: "cinema_\(hit.kind.rawValue)_\(hit.tmdbID)", title: hit.title, subtitle: subtitle,
                          icon: .symbol(hit.kind.symbol, CinemaStyle.tint), group: .cinema,
                          hint: offer.map { "Regarder sur \($0.displayName)" } ?? "Où regarder", boost: boost,
                          pane: { AnyView(CinemaLauncherPane(hit: hit)) }) { [weak self] ctx in
            if ctx.alternate { self?.show(hit, app: ctx.app) } else { self?.watch(hit) }
            return .done
        }
    }

    // MARK: Demo, snapshots, checks

    func loadDemo() {
        hasKey = true
        mine = ["netflix", "canal"]
        let hits = CinemaDemo.hits
        searches[CinemaQuery.key("marée", kind: nil)] = .done(hits, Date())
        searches[CinemaQuery.key("marée", kind: .movie)] = .done(hits.filter { $0.kind == .movie }, Date())
        for t in CinemaDemo.titles { titles[t.hit.id] = t }
        pageQuery = "marée"
        selected = hits.first
        recents = Array(hits.prefix(4))
    }

    func applySnapshotTab(_ tab: String) {
        switch tab {
        case "cle", "clé": hasKey = false
        case "vide": pageQuery = ""; selected = nil
        case "recherche": selected = nil
        default: break
        }
    }

    func selfTest() -> [String] { CinemaChecks.run() }

    func dump() -> [String] {
        var lines = ["Clé TMDB : \(hasKey ? "enregistrée" : "aucune") · région \(region) · langue \(language)",
                     "Tes plateformes : " + (mine.isEmpty ? "aucune" : mine.sorted().compactMap { CinemaPlatform.named($0)?.name }.joined(separator: ", ")),
                     "Recherches en mémoire : \(searches.count) · fiches : \(titles.count) · images : \(images.count)"]
        if !recents.isEmpty { lines.append("Récemment : " + recents.prefix(6).map { "\($0.title) (\($0.year.map(String.init) ?? "?"))" }.joined(separator: ", ")) }
        if let s = selected, let t = titles[s.id] {
            lines.append("Fiche : \(t.hit.title) · \(CinemaFormat.facts(t))")
            for o in t.offers {
                let d = CinemaOffers.destination(o, in: t)
                lines.append("  \(o.kind.label) · \(o.name) → \(d.via) \(d.url)")
            }
        }
        return lines
    }
}

enum CinemaStyle {
    static var tint: Color { Theme.palette[3] }
}
