import SwiftUI
import AppKit

/// What the switch does with the page the browser shows.
enum AdBlockHandoffDecision: Equatable {
    case ignore
    case switchTo(URL)
}

/// The switch's memory: the pages it already moved, the ones the user wants in the browser, and the sites it leaves to
/// the browser for a while. Pure, tested by `AdBlockHandoff.checks()`.
@MainActor
struct AdBlockHandoffMemory {
    /// Pages moved to the player, and when: one that shows up again soon after was reopened by the user (⌘⇧T).
    var switched: [String: Date] = [:]
    /// Videos, lives and channels the user wants in the browser, and since when.
    var kept: [String: Date] = [:]
    /// Sites left to the browser until its front tab shows another site.
    var suspended: Set<String> = []

    static let reopenWindow: TimeInterval = 30 * 60
    /// A page that is no single content (the home page, a feed, a search) is opened again soon by itself: only right after
    /// the switch does it mean the user brought it back.
    static let reopenWindowGeneral: TimeInterval = 2 * 60
    static let keptFor: TimeInterval = 6 * 3600

    /// The browser's front tab shows `raw`.
    mutating func decide(_ raw: String, now: Date = Date()) -> AdBlockHandoffDecision {
        guard let url = URL(string: raw), url.scheme == "https" || url.scheme == "http", let host = url.host else { return .ignore }
        guard let site = AdBlockHandoff.site(ofHost: host) else {
            // The user went to another site: the switch is back for YouTube and Twitch.
            suspended.removeAll()
            return .ignore
        }
        guard let target = AdBlockHandoff.target(url), let key = AdBlockHandoff.key(target) else { return .ignore }
        kept = kept.filter { now.timeIntervalSince($0.value) < Self.keptFor }
        if kept[key] != nil { return .ignore }
        let content = AdBlockHandoff.isContent(key)
        if suspended.contains(site) {
            if content { kept[key] = now }
            return .ignore
        }
        if let at = switched[key], now.timeIntervalSince(at) < (content ? Self.reopenWindow : Self.reopenWindowGeneral) {
            // Opened again in the browser after the switch: it stays there, and so does the site.
            if content { kept[key] = now }
            suspended.insert(site)
            return .ignore
        }
        switched = switched.filter { now.timeIntervalSince($0.value) < Self.reopenWindow }
        switched[key] = now
        return .switchTo(target)
    }

    /// The switch did not happen after all (the tab changed meanwhile): the page may switch later.
    mutating func cancel(_ key: String) {
        switched.removeValue(forKey: key)
    }

    /// The page opened in the player but its tab could not be closed: it stays in the browser as well, the site not set aside.
    mutating func leftOpen(_ key: String, now: Date = Date()) {
        switched.removeValue(forKey: key)
        kept[key] = now
    }

    /// The user sends a page of the player back to the browser: it stays there, and so does its site.
    mutating func giveBack(_ url: URL, now: Date = Date()) {
        guard let host = url.host, let site = AdBlockHandoff.site(ofHost: host) else { return }
        if let key = AdBlockHandoff.target(url).flatMap(AdBlockHandoff.key), AdBlockHandoff.isContent(key) { kept[key] = now }
        suspended.insert(site)
    }
}

/// « Toujours sans pub » : YouTube or Twitch opened in the browser in front goes on in the ad-free player, at the same
/// second when the browser lets the app run a script, and its tab is closed in the browser. While a browser is in front
/// (and only then), the address of its front tab is read every 1.5 s by an Apple event; it is never kept nor sent.
@Observable
@MainActor
final class AdBlockHandoff {
    static let enabledKey = "Heartware.Handoff.Enabled"
    static let commandID = "adblock_handoff"
    static let interval: TimeInterval = 1.5

    /// The last page moved, shown on the page.
    struct Event: Equatable {
        var site: String
        var browser: String
        var date: Date
    }

    private(set) var enabled = UserDefaults.standard.bool(forKey: AdBlockHandoff.enabledKey)
    /// Browsers that do not let the app read their address (Automation off in System Settings).
    private(set) var refused: [String] = []
    private(set) var last: Event?

    @ObservationIgnored weak var player: AdBlockPlayer?
    @ObservationIgnored private var memory = AdBlockHandoffMemory()
    @ObservationIgnored private var activation: NSObjectProtocol?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var browser: AdBlockVideoBrowser?
    @ObservationIgnored private var lastSeen = ""
    @ObservationIgnored private var reading = false

    /// Turned on by the user's click: macOS asks for each browser in front (the running ones right away).
    func setEnabled(_ on: Bool) {
        guard !DemoData.isEnabled, !Snapshot.isActive else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        ActionLog.write("BASCULE SANS PUB \(on ? "activée" : "désactivée")")
        if on {
            Task {
                for b in AdBlockVideoBrowser.all where !NSRunningApplication.runningApplications(withBundleIdentifier: b.bundleID).isEmpty {
                    note(b, await PermissionCenter.automation(b.bundleID, ask: true))
                }
                start()
            }
        } else {
            stop()
        }
    }

    func start() {
        guard enabled, !DemoData.isEnabled, !Snapshot.isActive, activation == nil else { return }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                       object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.front(id) }
        }
        front(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    func stop() {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        front(nil)
    }

    /// A page of the player sent back to the browser.
    func giveBack(_ url: URL) {
        memory.giveBack(url)
    }

    // MARK: Watching

    /// Another app came in front: the browser's tab is read while it stays there, nothing otherwise.
    private func front(_ id: String?) {
        let b = enabled ? AdBlockVideoBrowser.named(id) : nil
        guard b != browser else { return }
        browser = b
        lastSeen = ""
        timer?.invalidate()
        timer = nil
        guard let b else { return }
        Task {
            // Already answered: at once. Otherwise macOS asks now, while the user is looking at the browser.
            note(b, await PermissionCenter.automation(b.bundleID, ask: true))
            poll(b)
        }
    }

    private func poll(_ b: AdBlockVideoBrowser) {
        guard browser == b, timer == nil, !refused.contains(b.name) else { return }
        read()
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func note(_ b: AdBlockVideoBrowser, _ state: PermissionState) {
        if state == .denied {
            if !refused.contains(b.name) { refused.append(b.name) }
            if browser == b {
                timer?.invalidate()
                timer = nil
            }
        } else if state == .granted {
            refused.removeAll { $0 == b.name }
        }
    }

    /// One look at the browser's tab; a switch in progress holds the next look back until it is done.
    private func read() {
        guard !reading, let b = browser else { return }
        reading = true
        Task {
            defer { reading = false }
            let r = await Self.frontURL(b)
            guard browser == b else { return }
            if r.status == -1743 || r.status == -1744 {
                note(b, .denied)
                return
            }
            let raw = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard r.ok, raw != lastSeen else { return }
            lastSeen = raw
            if case .switchTo(let page) = memory.decide(raw), let key = Self.key(page) { await handOff(page, key: key, from: b) }
        }
    }

    private static func frontURL(_ b: AdBlockVideoBrowser) async -> Shell.Output {
        let script = b.frontURLScript
        return await Task.detached(priority: .userInitiated) { Shell.appleScript(script) }.value
    }

    /// The page in the player, the browser's tab closed (only if it still shows the same page).
    private func handOff(_ page: URL, key: String, from b: AdBlockVideoBrowser) async {
        guard let player else {
            memory.cancel(key)
            return
        }
        // The tab once more, just before acting on it: a redirect (youtu.be, youtube.com) may have changed its address,
        // or the user moved to another tab.
        let again = await Self.frontURL(b)
        let raw = again.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard again.ok, let url = URL(string: raw), Self.target(url).flatMap(Self.key) == key else {
            memory.cancel(key)
            lastSeen = ""
            return
        }
        lastSeen = raw
        let siteName = page.host?.contains("twitch") == true ? "Twitch" : "YouTube"
        var moment: AdBlockVideoMoment?
        if AdBlockVideoOnly.scriptsAllowed(b) != false {
            let paused = await Task.detached(priority: .userInitiated) { Shell.appleScript(b.pauseScript) }.value
            if paused.ok {
                AdBlockVideoOnly.remember(scripts: true, for: b)
                moment = AdBlockVideoOnly.moment(from: paused.out)
            } else if paused.err.localizedCaseInsensitiveContains("javascript") {
                AdBlockVideoOnly.remember(scripts: false, for: b)
            }
        }
        player.open(AdBlockVideoOnly.resume(page, at: moment), videoOnly: player.isOpen && player.videoOnly)
        var closed = false
        if let script = b.closeTabScript(raw) {
            let r = await Task.detached(priority: .userInitiated) { Shell.appleScript(script) }.value
            closed = r.ok && r.out == "closed"
        }
        if !closed { memory.leftOpen(key) }
        last = Event(site: siteName, browser: b.name, date: Date())
        ActionLog.write("BASCULE SANS PUB \(siteName) depuis \(b.name)\(closed ? " · onglet fermé" : "")")
        if closed || moment != nil {
            HUD.show("\(siteName) continue ici, sans pub", symbol: "play.tv.fill")
        } else {
            HUD.show("\(siteName) continue ici, sans pub : ferme l'onglet de \(b.name)", symbol: "exclamationmark.circle.fill")
        }
    }

    // MARK: Rules

    /// "youtube" or "twitch" for a host of these sites.
    static func site(ofHost raw: String) -> String? {
        let host = raw.lowercased()
        if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be" { return "youtube" }
        if host == "twitch.tv" || host.hasSuffix(".twitch.tv") { return "twitch" }
        return nil
    }

    /// YouTube's pages that are watched or browsed to watch; the others (Studio, Music, the account) stay in the browser.
    static let youtubePages = ["/watch", "/shorts/", "/live/", "/results", "/feed/", "/playlist", "/@", "/channel/", "/c/",
                                           "/user/", "/gaming", "/podcasts", "/hashtag/"]
    /// Twitch's pages that are no channel nor directory: they stay in the browser.
    static let twitchKept: Set<String> = [
        "settings", "subscriptions", "wallet", "inventory", "drops", "friends", "messages", "turbo", "prime", "store", "jobs", "p",
        "downloads", "login", "signup", "logout", "payments", "bits", "broadcast", "popout", "moderator", "embed", "products", "dashboard",
        "passport-callback", "annual-recap"
    ]

    /// The page to open in the player for a YouTube or Twitch address, or nil when it stays in the browser.
    static func target(_ url: URL) -> URL? {
        guard let page = AdBlockPlayer.playable(url.absoluteString), let host = page.host?.lowercased() else { return nil }
        let path = page.path
        if host == "www.youtube.com" {
            let lower = path.lowercased()
            guard path.isEmpty || path == "/" || youtubePages.contains(where: { lower.hasPrefix($0) }) else { return nil }
            return page
        }
        if host == "www.twitch.tv" {
            let first = path.split(separator: "/").first.map { $0.lowercased() } ?? ""
            return twitchKept.contains(first) ? nil : page
        }
        return nil
    }

    /// What makes two addresses the same page: the video, the channel or the search (not the time nor the tracking).
    static func key(_ url: URL) -> String? {
        guard let host = url.host, let site = site(ofHost: host) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        if site == "twitch" { return "twitch:" + path.lowercased() }
        if path == "/watch", let v = items.first(where: { $0.name == "v" })?.value { return "youtube:v=" + v }
        if path == "/playlist", let list = items.first(where: { $0.name == "list" })?.value { return "youtube:/playlist?list=" + list }
        if path == "/results", let q = items.first(where: { $0.name == "search_query" })?.value { return "youtube:?" + q }
        return "youtube:" + (path.hasPrefix("/@") ? path.lowercased() : path)
    }

    /// A key of one video, live, playlist or channel, rather than a page to browse (home, feeds, searches, directory).
    static func isContent(_ key: String) -> Bool {
        if key.hasPrefix("twitch:") {
            let first = key.dropFirst("twitch:".count).split(separator: "/").first.map(String.init) ?? ""
            return !["", "directory", "search"].contains(first)
        }
        let rest = key.dropFirst("youtube:".count)
        return ["v=", "/playlist?", "/shorts/", "/live/", "/@", "/channel/", "/c/", "/user/"].contains { rest.hasPrefix($0) }
    }

    /// An address the close script can compare with: no quote, backslash nor line break (it sits in an AppleScript string).
    nonisolated static func safeInScript(_ s: String) -> Bool {
        !s.isEmpty && s.count < 4000 && !s.contains { $0 == "\"" || $0 == "\\" || $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }
    }

    /// `--adblock bascule [lien…]` : what the switch does with each link, and its scripts compiled for the browsers of this
    /// Mac (nothing is sent to them).
    static func bench(_ links: [String]) {
        for raw in links {
            var memory = AdBlockHandoffMemory()
            switch memory.decide(raw) {
            case .ignore: print("\(raw) → reste dans le navigateur")
            case .switchTo(let page): print("\(raw) → lecteur sans pub : \(page.absoluteString)")
            }
        }
        for b in AdBlockVideoBrowser.all where NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.bundleID) != nil {
            for (what, source) in [("lecture de l'onglet", b.frontURLScript), ("fermeture de l'onglet", b.closeTabScript("https://www.youtube.com/watch?v=abc") ?? "")] {
                var error: NSDictionary?
                let ok = NSAppleScript(source: source)?.compileAndReturnError(&error) == true
                print("\(b.name), \(what) : " + (ok ? "compile" : "erreur, \(error?[NSAppleScript.errorMessage] as? String ?? "?")"))
            }
        }
    }

    // MARK: Checks

    static func checks() -> [String] {
        var f: [String] = []
        func expect(_ ok: Bool, _ message: String) { if !ok { f.append("bascule : " + message) } }
        func t(_ s: String) -> String? { target(URL(string: s)!)?.absoluteString }

        // What moves, and what stays in the browser.
        expect(t("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s", "une vidéo YouTube passe dans le lecteur")
        expect(t("https://m.youtube.com/watch?v=abc") == "https://www.youtube.com/watch?v=abc", "YouTube mobile passe en YouTube complet")
        expect(t("https://youtu.be/abc") == "https://www.youtube.com/watch?v=abc", "un lien court youtu.be")
        expect(t("https://www.youtube.com/") != nil && t("https://youtube.com") != nil, "l'accueil de YouTube")
        expect(t("https://www.youtube.com/@Heartware/videos") != nil && t("https://www.youtube.com/shorts/Ab_1") != nil
               && t("https://www.youtube.com/results?search_query=atome") != nil, "chaînes, shorts et recherches")
        for kept in ["https://studio.youtube.com/channel/UC1", "https://music.youtube.com/watch?v=abc", "https://www.youtube.com/account",
                     "https://www.youtube.com/premium", "https://www.youtube.com/embed/abc", "https://www.youtube.com/redirect?q=https://exemple.fr",
                     "https://accounts.google.com/", "https://www.twitch.tv/settings/profile", "https://www.twitch.tv/popout/camille/chat",
                     "https://dashboard.twitch.tv/u/camille", "https://www.twitch.tv/p/fr/legal/terms-of-service/", "https://www.france.tv/",
                     "https://exemple.fr/watch?v=abc"] {
            expect(t(kept) == nil, "\(kept) doit rester dans le navigateur")
        }
        expect(t("https://www.twitch.tv/camille") == "https://www.twitch.tv/camille" && t("https://twitch.tv/directory/category/just-chatting") != nil
               && t("https://www.twitch.tv/videos/123?t=1h2m3s") != nil && t("https://www.twitch.tv/") != nil, "les chaînes et le répertoire de Twitch")

        // Same page, whatever the time or the tracking.
        func k(_ s: String) -> String? { key(URL(string: s)!) }
        expect(k("https://www.youtube.com/watch?v=abc&t=12s&pp=xyz") == k("https://www.youtube.com/watch?v=abc"), "une vidéo reste la même page à un autre moment")
        expect(k("https://www.youtube.com/watch?v=abc") != k("https://www.youtube.com/watch?v=ABC"), "l'identifiant d'une vidéo garde sa casse")
        expect(k("https://www.twitch.tv/Camille/") == k("https://www.twitch.tv/camille"), "une chaîne Twitch, en majuscules ou non")
        expect(k("https://www.youtube.com/results?search_query=a") != k("https://www.youtube.com/results?search_query=b"), "deux recherches")
        expect(k("https://www.youtube.com/playlist?list=A") != k("https://www.youtube.com/playlist?list=B"), "deux playlists")
        expect(isContent(k("https://www.youtube.com/watch?v=a")!) && isContent(k("https://www.youtube.com/playlist?list=A")!)
               && isContent(k("https://www.youtube.com/@Heartware")!) && isContent(k("https://www.twitch.tv/camille")!)
               && isContent(k("https://www.twitch.tv/videos/1")!), "vidéos, playlists et chaînes sont des contenus")
        expect(!isContent(k("https://www.youtube.com/")!) && !isContent(k("https://www.youtube.com/feed/subscriptions")!)
               && !isContent(k("https://www.youtube.com/results?search_query=a")!) && !isContent(k("https://www.twitch.tv/")!)
               && !isContent(k("https://www.twitch.tv/directory/following")!), "accueil, flux, recherches et répertoire se parcourent")

        // The memory.
        var m = AdBlockHandoffMemory()
        let now = Date()
        let video = "https://www.youtube.com/watch?v=abc"
        expect(m.decide(video, now: now) == .switchTo(URL(string: video)!), "une vidéo ouverte dans le navigateur bascule")
        expect(m.decide(video + "&t=5s", now: now.addingTimeInterval(60)) == .ignore, "rouverte juste après (⌘⇧T), elle reste dans le navigateur")
        expect(m.decide("https://www.youtube.com/watch?v=other", now: now.addingTimeInterval(70)) == .ignore,
               "après ça, YouTube reste dans le navigateur tant qu'on y est")
        expect(m.decide("https://www.wikipedia.org/", now: now.addingTimeInterval(80)) == .ignore && m.suspended.isEmpty,
               "un autre site rend la bascule à YouTube")
        expect(m.decide(video, now: now.addingTimeInterval(90)) == .ignore, "une page gardée dans le navigateur n'en repart plus")
        expect(m.decide("https://www.youtube.com/watch?v=new", now: now.addingTimeInterval(100)) == .switchTo(URL(string: "https://www.youtube.com/watch?v=new")!),
               "une nouvelle vidéo bascule de nouveau")
        expect(m.decide("favorites://", now: now) == .ignore && m.decide("", now: now) == .ignore, "un onglet vide ne fait rien")

        var back = AdBlockHandoffMemory()
        back.giveBack(URL(string: "https://www.twitch.tv/camille")!)
        expect(back.decide("https://www.twitch.tv/camille") == .ignore && back.decide("https://www.twitch.tv/autre") == .ignore,
               "rendu au navigateur par le lecteur, Twitch y reste")
        expect(back.decide("https://www.youtube.com/watch?v=abc") == .switchTo(URL(string: "https://www.youtube.com/watch?v=abc")!),
               "rendre Twitch au navigateur ne touche pas à YouTube")
        var home = AdBlockHandoffMemory()
        expect(home.decide("https://www.youtube.com/", now: now) != .ignore, "l'accueil de YouTube bascule")
        expect(home.decide("https://www.youtube.com/", now: now.addingTimeInterval(600)) != .ignore && home.suspended.isEmpty,
               "l'accueil rouvert 10 min plus tard (un favori) bascule encore, sans mettre YouTube de côté")
        var failed = AdBlockHandoffMemory()
        _ = failed.decide(video, now: now)
        failed.leftOpen("youtube:v=abc", now: now)
        expect(failed.decide(video + "&t=1s", now: now.addingTimeInterval(5)) == .ignore && failed.suspended.isEmpty,
               "un onglet qui n'a pas pu se fermer reste où il est, sans mettre YouTube de côté")
        expect(failed.decide("https://www.youtube.com/watch?v=next", now: now.addingTimeInterval(9)) != .ignore,
               "après un onglet resté ouvert, la vidéo suivante bascule")
        var cancelled = AdBlockHandoffMemory()
        _ = cancelled.decide(video, now: now)
        cancelled.cancel("youtube:v=abc")
        expect(cancelled.decide(video, now: now.addingTimeInterval(5)) != .ignore, "une bascule annulée peut se refaire")
        var old = AdBlockHandoffMemory()
        _ = old.decide(video, now: now)
        expect(old.decide(video, now: now.addingTimeInterval(AdBlockHandoffMemory.reopenWindow + 60)) == .switchTo(URL(string: video)!),
               "la même vidéo, bien plus tard, bascule de nouveau")

        // The scripts.
        expect(safeInScript(video) && !safeInScript("https://x.fr/\"&do shell script") && !safeInScript("https://x.fr/a\\b")
               && !safeInScript("https://x.fr/\nb") && !safeInScript(""), "seules les adresses sans guillemet ni retour vont dans un script")
        for b in AdBlockVideoBrowser.all {
            expect(NSAppleScript(source: b.frontURLScript) != nil && b.frontURLScript.contains("is running"), "lecture de l'onglet de \(b.name)")
            expect(b.closeTabScript(video)?.contains("is \"\(video)\"") == true && b.closeTabScript("a\"b") == nil, "fermeture de l'onglet de \(b.name)")
        }
        return f
    }
}

extension AdBlockVideoBrowser {
    /// The front tab's address; nothing when the browser does not run (it is never launched), has no window, or shows a
    /// private window (Chrome, Brave, Edge…: Safari does not tell). Fixed text.
    var frontURLScript: String {
        let body = chromium
            ? """
                  if (count of windows) is 0 then return ""
                  try
                    if mode of front window is "incognito" then return ""
                  end try
                  return URL of active tab of front window
              """
            : """
                  if (count of windows) is 0 then return ""
                  return URL of current tab of front window
              """
        return """
        if application id "\(bundleID)" is running then
          with timeout of 3 seconds
            tell application id "\(bundleID)"
        \(body)
            end tell
          end timeout
        end if
        return ""
        """
    }

    /// Closes the front tab if it still shows `url` (an address `AdBlockHandoff.safeInScript` accepts, else nil).
    func closeTabScript(_ url: String) -> String? {
        guard AdBlockHandoff.safeInScript(url) else { return nil }
        let tab = chromium ? "active tab of front window" : "current tab of front window"
        return """
        if application id "\(bundleID)" is running then
          with timeout of 3 seconds
            tell application id "\(bundleID)"
              if (count of windows) > 0 then
                if URL of \(tab) is "\(url)" then
                  close \(tab)
                  return "closed"
                end if
              end if
            end tell
          end timeout
        end if
        return ""
        """
    }
}

// MARK: - The page's panel

/// « Toujours sans pub » on the player's tab: the switch, and the Safari bookmark that does the same on a click.
struct AdBlockHandoffPanel: View {
    @Environment(AppModel.self) private var app
    @State private var copied = false

    var body: some View {
        let h = app.adblock.handoff
        Panel(title: "YouTube et Twitch toujours sans pub",
              subtitle: "Ouverts dans ton navigateur, ils passent d'eux-mêmes dans le lecteur",
              symbol: "arrow.triangle.swap", tint: AdBlockStyle.tint) {
            HelpTipButton(tip: AdBlockTips.handoff, opensByItself: false)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { h.enabled }, set: { h.setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Basculer tout seul dans le lecteur").font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                        Text(status(h)).font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .switchToggles()
                .controlSize(.small)
                if !h.refused.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(h.refused.joined(separator: ", ")) ne laisse pas Heartware lire son onglet : autorise-le dans Automatisation.")
                            .font(.ui(11.5, .medium)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Réglages…") { Finder.open(PermissionKind.safari.settingsURL) }
                            .buttonStyle(SoftButtonStyle(small: true))
                    }
                }
                HStack(spacing: 8) {
                    Text("Plutôt d'un clic, avec un signet dans Safari").font(.ui(11.5)).foregroundStyle(Theme.text3)
                    Spacer(minLength: 0)
                    Button(copied ? "Copié" : "Copier le signet") {
                        if case .copied = CommandRunner.copy(AdBlockPlayer.bookmarklet) {
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        }
                    }
                    .buttonStyle(SoftButtonStyle(small: true))
                }
            }
        }
    }

    private func status(_ h: AdBlockHandoff) -> String {
        guard h.enabled else { return "Éteint : ils restent dans ton navigateur, avec leurs pubs" }
        if let last = h.last { return "Allumé · dernière bascule : \(last.site) depuis \(last.browser), \(Fmt.relative(last.date))" }
        return "Allumé : la prochaine page YouTube ou Twitch de ton navigateur passe ici"
    }
}
