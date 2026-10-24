import SwiftUI
import Observation

/// What the user does with their Mac. Each profile puts forward the tools it needs; the upkeep pages are for everyone,
/// and the rest waits in « Autres outils » at the bottom of the sidebar (and in the launcher, which finds everything).
enum ToolProfileKind: String, Codable, CaseIterable, Identifiable {
    case essentials, studies, work, creation, leisure, everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .essentials: return "L'essentiel"
        case .studies: return "Études"
        case .work: return "Travail"
        case .creation: return "Création"
        case .leisure: return "Loisirs"
        case .everything: return "Touche-à-tout"
        }
    }

    var blurb: String {
        switch self {
        case .essentials: return "Un Mac propre, sûr et à jour."
        case .studies: return "Signer, convertir, vidéos, langues."
        case .work: return "Documents, raccourcis, fenêtres."
        case .creation: return "Photo, vidéo, son, place disque."
        case .leisure: return "Films, séries et vidéos sans pub."
        case .everything: return "Tous les outils, sans exception."
        }
    }

    var symbol: String {
        switch self {
        case .essentials: return "leaf"
        case .studies: return "graduationcap"
        case .work: return "briefcase"
        case .creation: return "paintbrush.pointed"
        case .leisure: return "play.tv"
        case .everything: return "square.grid.3x3"
        }
    }

    /// `--snapshot --profile etudes,loisirs`.
    var slug: String {
        switch self {
        case .essentials: return "essentiel"
        case .studies: return "etudes"
        case .work: return "travail"
        case .creation: return "creation"
        case .leisure: return "loisirs"
        case .everything: return "tout"
        }
    }

    /// The tools it puts forward, on top of the upkeep pages.
    var pages: Set<Page> {
        switch self {
        case .essentials: return [.storage, .apps, .phone, .media]
        case .studies: return [.wheel, .media, .hotkeys]
        case .work: return [.wheel, .hotkeys, .toolbox]
        case .creation: return [.storage, .apps, .phone, .wheel, .toolbox, .hotkeys]
        case .leisure: return [.media, .phone, .storage]
        case .everything: return Set(Page.allCases)
        }
    }

    /// Upkeep, for every profile (the battery only on a Mac that has one).
    static let upkeep: Set<Page> = [.cleanup, .protection, .performance, .battery, .updates]
}

/// Why a tool is in the sidebar, or in « Autres outils ».
enum ToolReason: Equatable {
    case home, companion, upkeep, everything, profile(ToolProfileKind), used, active, pinned
    case removed, faded, notInProfile, noBattery

    var featured: Bool {
        switch self {
        case .home, .companion, .upkeep, .everything, .profile, .used, .active, .pinned: return true
        case .removed, .faded, .notInProfile, .noBattery: return false
        }
    }

    var label: String {
        switch self {
        case .home: return "Accueil"
        case .companion: return "Ton chamois"
        case .upkeep: return "Pour tous"
        case .everything: return "Tous les outils"
        case .profile(let k): return k.title
        case .used: return "Tu t'en sers"
        case .active: return "Activé"
        case .pinned: return "Ajouté par toi"
        case .removed: return "Rangé par toi"
        case .faded: return "Pas ouvert depuis \(ToolProfileRules.fadeDays) j"
        case .notInProfile: return "Hors profil"
        case .noBattery: return "Pas de batterie"
        }
    }

    var detail: String {
        switch self {
        case .home: return "Le tableau de bord est toujours là."
        case .companion: return "La maison de ton chamois. Le mode sobre la range avec le jeu."
        case .upkeep: return "L'entretien du Mac, pour tous les profils."
        case .everything: return "Pas encore de profil : je montre tout."
        case .profile(let k): return "Mis en avant par ton profil \(k.title)."
        case .used: return "Tu l'as ouvert plusieurs jours ces dernières semaines : il reste à portée de main."
        case .active: return "Tu as allumé une de ses fonctions : il reste à portée de main."
        case .pinned: return "Tu l'as ajouté à ta barre latérale."
        case .removed: return "Tu l'as rangé dans « Autres outils »."
        case .faded: return "De ton profil, mais pas ouvert depuis \(ToolProfileRules.fadeDays) jours : je l'ai rangé. Coche-le pour le garder."
        case .notInProfile: return "Hors de ton profil : il t'attend dans « Autres outils »."
        case .noBattery: return "Ce Mac n'a pas de batterie."
        }
    }
}

/// Saved choices (profile.json).
struct ToolProfileSettings: Codable, Equatable {
    var kinds: Set<ToolProfileKind> = []
    /// When the profile last changed: no tool fades during the weeks that follow.
    var chosen: Date?
    /// Pages the user added to the sidebar, and pages they put away (raw values).
    var pinned: Set<String> = []
    var removed: Set<String> = []
    /// The dashboard's invitation to pick a profile was closed.
    var inviteDismissed = false
}

/// Which days each tool was opened, kept on this Mac only (tool-usage.json).
struct ToolUsageLog: Codable, Equatable {
    /// Page → the days it was opened ("2026-10-20"), oldest first, the last 90 days.
    var days: [String: [String]] = [:]
    /// The days the app was used at all.
    var active: [String] = []
}

/// What the app knows about the tools besides the sidebar: switched-on features, launcher commands, the hardware.
struct ToolSignals {
    var hasBattery = true
    /// Something the user switched on keeps working in the background (clipboard history, automations…).
    var active: Set<Page> = []
    /// The launcher commands of each tool: how many times, and the last one.
    var commands: [Page: CommandRunner.Usage] = [:]
}

/// The rules, as pure functions (`--selftest` checks them).
enum ToolProfileRules {
    /// A tool opened on this many different days over the last `usedWindow` days joins the sidebar.
    static let usedDays = 3
    static let usedWindow = 30
    /// A tool of the profile left unopened this long, while the app is in use, goes to « Autres outils »…
    static let fadeDays = 45
    /// …once the app was used on this many days meanwhile, and never in the weeks after choosing the profile.
    static let fadeActiveDays = 10
    static let fadeGrace = 30

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func day(_ date: Date) -> String { dayFormat.string(from: date) }

    static func day(_ days: Int, before now: Date) -> String {
        day(now.addingTimeInterval(-Double(days) * 86400))
    }

    /// Days in `list` on or after `since`.
    static func count(_ list: [String], since: String) -> Int {
        list.reduce(0) { $0 + ($1 >= since ? 1 : 0) }
    }

    /// Adds today to a list of days, once, and forgets what is older than 90 days.
    static func adding(_ today: String, to list: [String], now: Date) -> [String] {
        let oldest = day(90, before: now)
        var out = list.filter { $0 >= oldest }
        if out.last != today { out.append(today) }
        return out
    }

    /// The pages that were folded into another (cinema and adblock into Multimédia…): their days and the user's choices
    /// still count for the page that took them in.
    static let formerKeys: [Page: [String]] = [.media: ["cinema", "adblock"], .hotkeys: ["windows", "launcher", "clipboard"],
                                                  .wheel: ["converter", "fillsign"]]

    static func days(_ page: Page, in log: ToolUsageLog) -> [String] {
        let keys = [page.rawValue] + (formerKeys[page] ?? [])
        return keys.count == 1 ? log.days[page.rawValue] ?? [] : Array(Set(keys.flatMap { log.days[$0] ?? [] })).sorted()
    }

    static func resolve(_ s: ToolProfileSettings, log: ToolUsageLog, signals: ToolSignals, now: Date) -> [Page: ToolReason] {
        let usedSince = day(usedWindow, before: now)
        let fadeSince = day(fadeDays, before: now)
        let recent = now.addingTimeInterval(-Double(usedWindow) * 86400)
        let fadeRecent = now.addingTimeInterval(-Double(fadeDays) * 86400)
        let settled = s.chosen.map { now.timeIntervalSince($0) >= Double(fadeGrace) * 86400 } ?? false
        let busy = count(log.active, since: fadeSince) >= fadeActiveDays
        var out: [Page: ToolReason] = [:]
        for page in Page.allCases {
            let key = page.rawValue
            let keys = [key] + (formerKeys[page] ?? [])
            let days = days(page, in: log)
            let command = signals.commands[page]
            let used = count(days, since: usedSince) >= usedDays || (command.map { $0.count >= usedDays && $0.last >= recent } ?? false)
            let forgotten = count(days, since: fadeSince) == 0 && !(command.map { $0.last >= fadeRecent } ?? false)
            let kind = ToolProfileKind.allCases.first { s.kinds.contains($0) && $0.pages.contains(page) }
            let reason: ToolReason
            if page == .dashboard {
                reason = .home
            } else if !s.removed.isDisjoint(with: keys) {
                reason = .removed
            } else if page == .refuge {
                reason = .companion
            } else if !s.pinned.isDisjoint(with: keys) {
                reason = .pinned
            } else if ToolProfileKind.upkeep.contains(page) && (page != .battery || signals.hasBattery) {
                reason = .upkeep
            } else if signals.active.contains(page) {
                reason = .active
            } else if used {
                reason = .used
            } else if s.kinds.isEmpty {
                reason = .everything
            } else if let kind {
                // « Touche-à-tout » asked for everything: nothing of it fades.
                reason = kind != .everything && settled && busy && forgotten ? .faded : .profile(kind)
            } else {
                reason = page == .battery ? .noBattery : .notInProfile
            }
            out[page] = reason
        }
        return out
    }

    /// How much a tool is used, to put the most used first on the dashboard.
    static func weight(_ page: Page, log: ToolUsageLog, signals: ToolSignals, now: Date) -> Int {
        let days = count(days(page, in: log), since: day(usedWindow, before: now))
        let recent = now.addingTimeInterval(-Double(usedWindow) * 86400)
        let commands = signals.commands[page].map { $0.last >= recent ? min($0.count, 10) : 0 } ?? 0
        return days * 2 + commands
    }

    // MARK: Self-test

    static func selfTest() -> [String] {
        var f: [String] = []
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func days(_ list: [Int]) -> [String] { list.sorted(by: >).map { day($0, before: now) } }
        let tools = Page.allCases.filter { $0 != .dashboard }

        // The catalogue.
        for p in tools where !ToolProfileKind.allCases.contains(where: { $0 != .everything && $0.pages.contains(p) })
            && !ToolProfileKind.upkeep.contains(p) && ![.automation, .assistant, .menubar, .refuge].contains(p) {
            f.append("Profils : \(p.title) n'est mis en avant par aucun profil")
        }
        for k in ToolProfileKind.allCases where k != .everything {
            let n = k.pages.subtracting(ToolProfileKind.upkeep).count
            if n < 3 || n > 9 { f.append("Profil \(k.title) : \(n) outils mis en avant (de 3 à 9 attendus)") }
            if k.pages.contains(.dashboard) { f.append("Profil \(k.title) : le tableau de bord n'a pas à y figurer") }
        }
        if !ToolProfileKind.leisure.pages.contains(.media) { f.append("Profils : Multimédia manque aux Loisirs") }
        for p: Page in [.wheel, .media] where !ToolProfileKind.studies.pages.contains(p) {
            f.append("Profils : \(p.title) manque aux Études")
        }
        if Set(ToolProfileKind.allCases.map(\.slug)).count != ToolProfileKind.allCases.count { f.append("Profils : deux slugs identiques") }

        let signals = ToolSignals()
        // No profile yet: the sidebar of before, everything in it.
        let none = resolve(ToolProfileSettings(), log: ToolUsageLog(), signals: signals, now: now)
        if let p = tools.first(where: { none[$0]?.featured != true }) { f.append("Sans profil, \(p.title) quitte la barre latérale") }

        // A profile: its tools and the upkeep stay, the others go.
        var s = ToolProfileSettings(kinds: [.essentials], chosen: now.addingTimeInterval(-86400))
        var r = resolve(s, log: ToolUsageLog(), signals: signals, now: now)
        if r[.hotkeys] != .notInProfile { f.append("L'essentiel : Raccourcis devrait être rangé (\(r[.hotkeys]?.label ?? "?"))") }
        if r[.phone] != .profile(.essentials) { f.append("L'essentiel : iPhone devrait être mis en avant") }
        if r[.cleanup] != .upkeep || r[.updates] != .upkeep { f.append("L'entretien doit rester pour tous") }
        if r[.dashboard] != .home { f.append("Le tableau de bord doit toujours rester") }
        // Two profiles add up.
        s.kinds = [.essentials, .work]
        r = resolve(s, log: ToolUsageLog(), signals: signals, now: now)
        if r[.toolbox]?.featured != true || r[.storage]?.featured != true { f.append("Deux profils ne s'additionnent pas") }

        // A tool opened on three different days joins; on two, not yet; months ago, no longer.
        s.kinds = [.essentials]
        var log = ToolUsageLog(days: ["toolbox": days([1, 5, 9])], active: [])
        if resolve(s, log: log, signals: signals, now: now)[.toolbox] != .used { f.append("Un outil ouvert trois jours ne rejoint pas la barre") }
        log.days["toolbox"] = days([1, 5])
        if resolve(s, log: log, signals: signals, now: now)[.toolbox]?.featured != false { f.append("Un outil ouvert deux jours rejoint déjà la barre") }
        log.days["toolbox"] = days([40, 50, 60])
        if resolve(s, log: log, signals: signals, now: now)[.toolbox]?.featured != false { f.append("Un usage vieux de deux mois compte encore") }
        // The days of a page folded into another count for it.
        log = ToolUsageLog(days: ["windows": days([1, 5]), "hotkeys": days([9])], active: [])
        if resolve(s, log: log, signals: signals, now: now)[.hotkeys] != .used { f.append("Les jours de Fenêtres ne comptent pas pour Raccourcis") }
        // The launcher counts too.
        var withCommands = signals
        withCommands.commands[.toolbox] = CommandRunner.Usage(count: 4, last: now.addingTimeInterval(-3 * 86400))
        if resolve(s, log: ToolUsageLog(), signals: withCommands, now: now)[.toolbox] != .used { f.append("Le lanceur ne compte pas dans l'usage") }
        // A feature switched on keeps its page.
        var withActive = signals
        withActive.active = [.hotkeys]
        if resolve(s, log: ToolUsageLog(), signals: withActive, now: now)[.hotkeys] != .active { f.append("Un outil allumé quitte la barre") }

        // A tool of the profile fades only after weeks without it, while the app is in use, and not right after choosing.
        let busy = ToolUsageLog(days: ["cleanup": days(Array(1...12))], active: days(Array(1...12)))
        s.chosen = now.addingTimeInterval(-60 * 86400)
        r = resolve(s, log: busy, signals: signals, now: now)
        if r[.phone] != .faded { f.append("Un outil du profil oublié depuis des semaines ne se range pas (\(r[.phone]?.label ?? "?"))") }
        if r[.cleanup] != .upkeep { f.append("L'entretien ne doit jamais se ranger seul") }
        if resolve(s, log: ToolUsageLog(), signals: signals, now: now)[.phone] != .profile(.essentials) {
            f.append("Un outil se range alors que l'app n'a presque pas servi")
        }
        var fresh = s
        fresh.chosen = now.addingTimeInterval(-5 * 86400)
        if resolve(fresh, log: busy, signals: signals, now: now)[.phone] != .profile(.essentials) { f.append("Un outil se range juste après le choix du profil") }
        var all = s
        all.kinds = [.everything]
        if resolve(all, log: busy, signals: signals, now: now)[.phone] != .profile(.everything) { f.append("Touche-à-tout range des outils") }

        // The user's own choices win.
        s.pinned = ["phone", "automation"]
        s.removed = ["cleanup", "launcher", "adblock"]
        s.kinds = [.leisure]
        r = resolve(s, log: busy, signals: signals, now: now)
        if r[.phone] != .pinned || r[.automation] != .pinned { f.append("Un outil ajouté par l'utilisateur ne reste pas") }
        if r[.cleanup] != .removed { f.append("Un outil rangé par l'utilisateur revient") }
        if r[.hotkeys] != .removed { f.append("Le Lanceur rangé ne range pas Raccourcis") }
        if r[.media] != .removed { f.append("Le Bloqueur de pub rangé ne range pas Multimédia") }

        // A Mac without a battery has no battery page in its sidebar, unless the user wants it.
        var desktop = signals
        desktop.hasBattery = false
        if resolve(ToolProfileSettings(kinds: [.work]), log: ToolUsageLog(), signals: desktop, now: now)[.battery] != .noBattery {
            f.append("La page Batterie reste sur un Mac sans batterie")
        }

        // The log keeps one entry a day, 90 days at most.
        let today = day(now)
        let kept = adding(today, to: adding(today, to: days([200, 89, 2]), now: now), now: now)
        if kept != days([89, 2, 0]) { f.append("Journal d'usage mal tenu : \(kept)") }
        if weight(.toolbox, log: ToolUsageLog(days: ["toolbox": days([1, 2])]), signals: withCommands, now: now) <= 0 {
            f.append("Le poids d'usage d'un outil reste nul")
        }
        return f
    }
}

/// The profile, the tools it puts forward and what the user actually uses.
@Observable
@MainActor
final class ToolProfileModel {
    private(set) var settings: ToolProfileSettings
    /// Why each page is in the sidebar or in « Autres outils », recomputed at launch, when the main window comes back
    /// and when the user changes something: never while they look at the sidebar.
    private(set) var reasons: [Page: ToolReason] = [:]
    /// The tools of the sidebar, most used first (the dashboard's order).
    private(set) var ranking: [Page] = []

    @ObservationIgnored private let settingsStore = JSONStore<ToolProfileSettings>("profile", default: ToolProfileSettings())
    @ObservationIgnored private let logStore = JSONStore<ToolUsageLog>("tool-usage", default: ToolUsageLog())
    /// The days each tool was opened (the Refuge lights the rooms already known at its birth).
    var usageLog: ToolUsageLog { logStore.value }
    @ObservationIgnored private var signals = ToolSignals()
    /// Launcher command → the page it belongs to, and the id prefixes only one page uses ("yt_…" for a result
    /// computed from what was typed), built once.
    @ObservationIgnored private var owners: [String: Page]?
    @ObservationIgnored private var prefixes: [String: Page] = [:]
    @ObservationIgnored private var batteryRead = false

    init() {
        settings = settingsStore.value
        resolve()
    }

    var isChosen: Bool { !settings.kinds.isEmpty }
    var kinds: [ToolProfileKind] { ToolProfileKind.allCases.filter(settings.kinds.contains) }
    var isCustomised: Bool { !settings.pinned.isEmpty || !settings.removed.isEmpty }

    var summary: String {
        isChosen ? kinds.map(\.title).joined(separator: ", ") : "Tous les outils"
    }

    var symbol: String { kinds.count == 1 ? kinds[0].symbol : (isChosen ? "person.2" : "square.grid.3x3") }

    func reason(_ page: Page) -> ToolReason { reasons[page] ?? .everything }
    func isFeatured(_ page: Page) -> Bool { reason(page).featured }

    /// The sidebar's groups with only their featured tools.
    var sections: [(String, [Page])] {
        Page.groups.map { ($0.0, $0.1.filter(isFeatured)) }.filter { !$0.1.isEmpty }
    }

    /// « Autres outils », in the sidebar's order.
    var others: [Page] { Page.groups.flatMap(\.1).filter { !isFeatured($0) } }

    /// The « Aller à » menu: the sidebar from top to bottom.
    var menuOrder: [Page] { sections.flatMap(\.1) + others }

    /// A tool of the profile the user has not opened yet: the dashboard suggests it.
    var discovery: Page? {
        guard isChosen else { return nil }
        let log = logStore.value
        return ranking.first { p in
            guard case .profile = reason(p) else { return false }
            return ToolProfileRules.days(p, in: log).isEmpty && signals.commands[p] == nil
        }
    }

    // MARK: Changes

    func toggle(_ kind: ToolProfileKind) {
        var s = settings
        if s.kinds.contains(kind) { s.kinds.remove(kind) } else { s.kinds.insert(kind) }
        s.chosen = s.kinds.isEmpty ? nil : Date()
        save(s)
    }

    /// Keeps a tool in the sidebar, or puts it away in « Autres outils ».
    func setFeatured(_ page: Page, _ on: Bool) {
        guard page != .dashboard else { return }
        let key = page.rawValue
        let former = ToolProfileRules.formerKeys[page] ?? []
        var s = settings
        if on {
            s.removed.subtract([key] + former)
            // Back to what the profile says; pinned only when the profile would not keep it.
            if !(ToolProfileRules.resolve(s, log: logStore.value, signals: signals, now: Date())[page]?.featured ?? false) { s.pinned.insert(key) }
        } else {
            s.pinned.subtract([key] + former)
            if ToolProfileRules.resolve(s, log: logStore.value, signals: signals, now: Date())[page]?.featured ?? false { s.removed.insert(key) }
        }
        save(s)
    }

    /// Forgets the tools added and put away by hand.
    func resetChoices() {
        var s = settings
        s.pinned = []
        s.removed = []
        save(s)
    }

    func dismissInvite() {
        var s = settings
        s.inviteDismissed = true
        save(s)
    }

    /// A page was opened: today counts for it, and for the app.
    func recordVisit(_ page: Page) {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        let now = Date()
        let today = ToolProfileRules.day(now)
        var log = logStore.value
        let key = page.rawValue
        // Nothing to write when today is already there (most visits).
        guard log.days[key]?.last != today || log.active.last != today else { return }
        log.days[key] = ToolProfileRules.adding(today, to: log.days[key] ?? [], now: now)
        log.active = ToolProfileRules.adding(today, to: log.active, now: now)
        logStore.value = log
    }

    /// Reads the signals again (switched-on features, launcher commands) and places the tools.
    func refresh(_ app: AppModel) {
        var s = ToolSignals()
        if !batteryRead || DemoData.isEnabled || Snapshot.isActive {
            batteryRead = true
            signals.hasBattery = DemoData.isEnabled || Snapshot.isActive ? app.monitor.battery != nil : SystemMonitor.readBattery() != nil
        }
        s.hasBattery = signals.hasBattery
        if app.wheel.recentlyUsed { s.active.insert(.wheel) }
        if app.automation.activeCount > 0 { s.active.insert(.automation) }
        if app.hotkeys.bindings.contains(where: { $0.combo != nil }) { s.active.insert(.hotkeys) }
        if let limit = app.battery.activeLimit, limit < 100 { s.active.insert(.battery) }
        // Each module's launcher commands count for its page; « Ouvrir … » counts for the page it opens.
        // All of them count for Raccourcis too, where the launcher is set up: it is used through its shortcut.
        let usage = DemoData.isEnabled ? [:] : CommandRunner.usage.value
        if !usage.isEmpty {
            if owners == nil { mapOwners(app) }
            func add(_ u: CommandRunner.Usage, to page: Page) {
                var merged = s.commands[page] ?? CommandRunner.Usage(count: 0, last: .distantPast)
                merged.count += u.count
                merged.last = max(merged.last, u.last)
                s.commands[page] = merged
            }
            for (id, u) in usage {
                // The launcher's settings are on the Raccourcis page: using it counts for that page too.
                add(u, to: .hotkeys)
                let opened = id.hasPrefix("open_") ? Page(rawValue: String(id.dropFirst(5))) : nil
                guard let page = opened ?? owners?[id] ?? prefixes[Self.prefix(id)], page != .hotkeys else { continue }
                add(u, to: page)
            }
        }
        signals = s
        resolve()
    }

    private func mapOwners(_ app: AppModel) {
        var map: [String: Page] = [:]
        var byPrefix: [String: Page?] = [:]
        for e in ModuleRegistry.modules(app) {
            guard let page = e.page else { continue }
            for c in e.module.commands(app: app) {
                map[c.id] = page
                let p = Self.prefix(c.id)
                if let seen = byPrefix[p], seen != page { byPrefix[p] = .some(nil) } else { byPrefix[p] = page }
            }
        }
        owners = map
        prefixes = byPrefix.compactMapValues { $0 }
    }

    private static func prefix(_ id: String) -> String {
        String(id.prefix { $0 != "_" && $0 != "-" })
    }

    private func save(_ s: ToolProfileSettings) {
        settings = s
        if !Snapshot.isActive { settingsStore.value = s }
        resolve()
    }

    private func resolve() {
        let now = Date()
        let log = logStore.value
        let r = ToolProfileRules.resolve(settings, log: log, signals: signals, now: now)
        if r != reasons { reasons = r }
        let order = Dictionary(uniqueKeysWithValues: Page.allCases.enumerated().map { ($1, $0) })
        let weights = Dictionary(uniqueKeysWithValues: Page.allCases.map { ($0, ToolProfileRules.weight($0, log: log, signals: signals, now: now)) })
        let ranked = Page.allCases.filter { r[$0]?.featured ?? true }.sorted {
            weights[$0, default: 0] != weights[$1, default: 0] ? weights[$0, default: 0] > weights[$1, default: 0] : order[$0, default: 0] < order[$1, default: 0]
        }
        if ranked != ranking { ranking = ranked }
    }

    // MARK: Demo and snapshots

    /// A student who also arranges windows often: Raccourcis joined the sidebar on its own, and the tools of the profile
    /// they use stay.
    func loadDemo() {
        let now = Date()
        settings = ToolProfileSettings(kinds: [.studies], chosen: now.addingTimeInterval(-40 * 86400))
        var log = ToolUsageLog()
        let d = { (n: Int) in ToolProfileRules.day(n, before: now) }
        log.days = ["wheel": [d(12), d(6), d(3), d(2), d(0)], "fillsign": [d(8), d(5), d(1)],
                    "media": [d(2)], "hotkeys": [d(9), d(6), d(4), d(3), d(1)], "cleanup": [d(7), d(0)]]
        log.active = (0...12).reversed().map(d)
        logStore.value = log
        resolve()
    }

    /// `--snapshot --profile etudes,loisirs` (or `aucun`): shows a profile without saving it.
    func preview(_ slugs: String) {
        let wanted = Set(slugs.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        settings.kinds = Set(ToolProfileKind.allCases.filter { wanted.contains($0.slug) })
        settings.chosen = settings.kinds.isEmpty ? nil : Date()
        settings.inviteDismissed = false
        resolve()
    }
}
