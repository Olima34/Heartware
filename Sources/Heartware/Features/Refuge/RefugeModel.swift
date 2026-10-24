import SwiftUI

/// A moment shown in the middle of the window: its birth, a mue (stage or scarf), the path it chose.
enum RefugeCeremony: Equatable {
    case birth
    case mue(RefugeRules.Mue)
    case path(RefugePath)
}

/// The Refuge: the chamois that lives in the Mac. It is born in a blueberry bush, the user adopts it (or not, for now),
/// feeds it the blueberries picked by taking care of the Mac, dresses it at the shop, and it grows, writes its notebook
/// and shows how the Mac is doing on its face. Everything stays on this Mac (refuge.json).
@Observable
@MainActor
final class RefugeModel: AppModule {
    private(set) var state: RefugeState
    /// `--snapshot --tab naissance`, `mue`, `humeur-…`, `hiver`…: a ceremony, a mood or a day shown whatever the state.
    /// The Labo's « Revoir la naissance » uses `previewCeremony` too: nothing it does is kept.
    var previewCeremony: RefugeCeremony?
    var previewMood: RefugeMood?
    var previewDate: Date?
    /// The step `--snapshot` opens the birth on.
    var previewBirthStep: RefugeBirthStep?
    /// The last reaction to a caress, shown in its bubble.
    var reaction: String?
    /// The birth stays on screen until its last step, even once adopted.
    private(set) var birthOpen = false
    private(set) var feedingUntil: Date?
    private(set) var danceUntil: Date?

    @ObservationIgnored private let store = JSONStore<RefugeState>("refuge", default: RefugeState())
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var started = false
    @ObservationIgnored private(set) var returningUser = false
    @ObservationIgnored private var pets: [Date] = []
    @ObservationIgnored let companion = RefugeCompanion()

    init() {
        state = store.value
        publishLook()
    }

    /// Saves a new state, after the consequences of what changed: its mue noted, its path chosen at the Beau Chamois,
    /// the daily round paid once complete, the badges it now deserves.
    private func update(_ new: RefugeState, now: Date = Date()) {
        var s = new
        var news: [(String, Bool)] = []
        if s.welcomed, state.welcomed {
            if s.stage > state.stage {
                RefugeRules.note(&s, kind: "mue", text: "J'ai mué : me voilà \(s.stage.title) ! \(s.stage.line)", now: now)
            } else if s.level > state.level, let scarf = RefugeRules.scarf(forLevel: s.level) {
                RefugeRules.note(&s, kind: "mue", text: "Nouvelle écharpe : \(scarf.title.lowercased()) ! Elle me va bien, non ?", now: now)
            }
        }
        if s.welcomed, s.stage >= .beau, s.path == nil {
            let path = RefugeStyle.suggestedPath(days: recentDays(now: now))
            s.path = path.rawValue
            s.pathSeason = RefugeSeason.key(now)
            RefugeRules.note(&s, kind: "path", text: "J'ai trouvé ma voie : \(path.title). \(path.line)", now: now)
        }
        let roundPaid = RefugeStyle.payRound(&s, now: now)
        if roundPaid > 0 {
            RefugeRules.note(&s, kind: "round", text: "La tournée du jour est finie ! Une petite danse pour fêter ça.", amount: roundPaid, now: now)
            news.append(("+\(roundPaid) myrtilles · tournée du jour finie", true))
            danceUntil = now.addingTimeInterval(3)
        }
        for b in RefugeRules.award(&s, now: now) { news.append(("Nouvel insigne : \(b.title)", false)) }
        state = s
        store.value = s
        publishLook()
        for (text, berry) in news { tell(text, berry: berry) }
    }

    /// The waiting scenes and the mascot at rest, all over the app, show the user's own chamois.
    func publishLook() {
        MascotStyle.look = state.welcomed && playful ? RefugeLook.of(state, on: clock) : nil
    }

    /// The days each page was opened these last 30 days (its path follows the tools used most).
    private func recentDays(now: Date) -> [Page: Int] {
        guard let app else { return [:] }
        let since = RefugeRules.dayKey(Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now)
        var out: [Page: Int] = [:]
        for (key, days) in app.profile.usageLog.days {
            if let page = Page(rawValue: key) { out[page] = days.filter { $0 >= since }.count }
        }
        return out
    }

    // MARK: Reading

    var name: String { state.name }
    var stage: RefugeStage { state.stage }
    var isAdopted: Bool { state.welcomed }
    /// The date the Refuge lives at: today, or the one a snapshot asks for.
    var clock: Date { previewDate ?? Date() }
    var day: Int { RefugeRules.dayNumber(state, now: clock) }

    func look(now: Date = Date()) -> RefugeLook { RefugeLook.of(state, on: previewDate ?? now) }
    func events(now: Date = Date()) -> [RefugeEvent] { RefugeStyle.events(on: previewDate ?? now, born: state.born) }
    /// How its room is decorated with what was bought at the shop.
    var decor: RefugeDecor {
        let used = RefugeStyle.items.filter { state.worn.contains($0.id) && state.owned.contains($0.id) }
        func one(_ slot: RefugeSlot) -> String? { used.first { $0.slot == slot }?.id }
        return RefugeDecor(wall: one(.wall), floor: one(.floor), window: one(.window), lamp: one(.lamp),
                           objects: Set(used.filter { $0.slot == .room }.map(\.id)))
    }

    /// What the moods read from the Mac now.
    func signals(now: Date = Date()) -> RefugeSignals {
        let hour = Calendar.current.component(.hour, from: now)
        let hungry = RefugeRules.hungry(state, now: now)
        guard let app else { return RefugeSignals(hour: hour, hungry: hungry) }
        let recent = app.monitor.recentCPU.suffix(5)
        let busy = recent.count >= 3 && recent.reduce(0, +) / Double(recent.count) >= 0.8
        return RefugeSignals(hour: hour,
                             junk: app.cleanup.hasResults ? app.cleanup.recommendedSize : 0,
                             hot: app.monitor.thermal == .serious || app.monitor.thermal == .critical || busy,
                             boost: app.performance.boost.mode == .performance,
                             threats: app.protection.malware.count,
                             hungry: hungry)
    }

    func mood(now: Date = Date()) -> RefugeMood {
        previewMood ?? RefugeRules.mood(signals(now: now))
    }

    /// What its room shows now; a mood forced for a snapshot brings its own setting.
    func scene(now: Date = Date()) -> (mood: RefugeMood, night: Bool, dust: Int, moths: Int) {
        let s = signals(now: now)
        guard let forced = previewMood else {
            return (RefugeRules.mood(s), RefugeRules.isNight(s.hour), RefugeRules.dust(s.junk), min(3, s.threats))
        }
        return (forced, forced == .sleepy, forced == .sneezy ? 4 : 1, forced == .worried ? 2 : 0)
    }

    /// The badges won, in the order of the list: the trophies on its shelves.
    var trophies: [RefugeMetal] { RefugeRules.badges.filter { state.badges[$0.id] != nil }.map(\.metal) }

    /// What it says in its bubble: its reaction to a caress, else how it feels (or the day's meeting when all is well).
    func line(now: Date = Date()) -> String {
        if let reaction { return reaction }
        let s = signals(now: now)
        let mood = previewMood ?? RefugeRules.mood(s)
        if mood == .happy, let event = events(now: now).first { return event.line }
        if mood == .happy, state.lastFed == nil, state.basket > 0 { return "Tu me donnes mes premières myrtilles ? Je grandis en les mangeant." }
        return RefugeRules.moodLine(mood, signals: s)
    }

    /// The step of a meal's animation, nil when it is not eating.
    func feedingStep(now: Date) -> Int? {
        guard let until = feedingUntil, until > now else { return nil }
        return Int(now.timeIntervalSinceReferenceDate * 4) % 9
    }

    func dancing(now: Date) -> Bool { danceUntil.map { $0 > now } ?? false }

    /// The moment waiting to be shown: its birth, its last mue, the path it chose.
    var ceremony: RefugeCeremony? {
        if let previewCeremony { return previewCeremony }
        if birthOpen { return .birth }
        guard started else { return nil }
        if state.awaitingAdoption { return .birth }
        guard state.welcomed else { return nil }
        if let mue = RefugeRules.pendingMue(state) { return .mue(mue) }
        if state.stage >= .beau, let path = state.path.flatMap(RefugePath.init(rawValue:)), !state.claimed.contains("seen:voie") {
            return .path(path)
        }
        return nil
    }

    /// The game shows itself: not in sober mode, not in the themes without the mascot.
    var playful: Bool { !state.sober && Theme.current.spec.mascot }

    /// The ceremony in the middle of the window: only on the dashboard or the Refuge, never in the middle of a task.
    var showsOverlay: Bool {
        guard let app, ceremony != nil, playful || birthOpen || previewCeremony != nil else { return false }
        return (app.page == .dashboard || app.page == .refuge)
            && !app.smartScanRunning && !app.cleanup.isCleaning && !app.cleanup.isScanning
    }

    /// Its head in the menu bar follows the moods that matter (nil: the usual head).
    var menuMood: RefugeMood? {
        guard state.welcomed, playful else { return nil }
        let m = mood()
        return [.sleepy, .boosted, .sneezy, .worried].contains(m) ? m : nil
    }

    // MARK: Birth

    /// Adopted, with the name chosen at its birth and the ten blueberries picked from its bush. The birth stays on
    /// screen for its last step (its first meal).
    func adopt(name raw: String) {
        guard previewCeremony == nil, !state.welcomed else { return }
        let now = Date()
        let log = app?.profile.usageLog ?? ToolUsageLog()
        let known = Page.allCases.filter { $0 != .refuge && !(log.days[$0.rawValue] ?? []).isEmpty }
        var s = state
        RefugeRules.adopt(&s, name: raw, known: known, returning: returningUser, now: now)
        birthOpen = true
        update(s, now: now)
        app?.profile.setFeatured(.refuge, true)
        ensureRound()
    }

    /// The end of the birth.
    func finishBirth() {
        if previewCeremony != nil { previewCeremony = nil; return }
        birthOpen = false
    }

    /// Not now: it goes back into its bush and waits in the Refuge (in « Autres outils »).
    func decline() {
        if previewCeremony != nil { previewCeremony = nil; return }
        var s = state
        s.declined = true
        update(s)
        app?.profile.setFeatured(.refuge, false)
    }

    /// The user changed their mind: its birth starts again.
    func reconsider() {
        var s = state
        s.declined = false
        update(s)
        app?.profile.setFeatured(.refuge, true)
        if let app, app.page != .dashboard { app.page = .refuge }
    }

    /// The Labo can replay its birth, without changing anything.
    func replayBirth() {
        previewCeremony = .birth
    }

    func rename(_ raw: String) {
        let clean = RefugeRules.cleanName(raw)
        guard clean != state.name, state.welcomed else { return }
        var s = state
        s.name = clean
        RefugeRules.note(&s, kind: "name", text: "Je m'appelle désormais \(clean). Ça me plaît !", merge: true, now: Date())
        update(s)
    }

    /// A mue or its path was seen.
    func acknowledge() {
        if previewCeremony != nil { previewCeremony = nil; return }
        var s = state
        if case .path = ceremony { s.claimed.insert("seen:voie") } else { s.shownLevel = s.level }
        update(s)
    }

    func setSober(_ on: Bool) {
        var s = state
        s.sober = on
        update(s)
        // The Refuge leaves the sidebar with the game, and comes back with it.
        app?.profile.setFeatured(.refuge, !on)
    }

    // MARK: Feeding

    /// Gives it blueberries from the basket: it eats them and grows. Returns how many it ate.
    @discardableResult
    func feed(_ amount: Int) -> Int {
        guard state.welcomed, !DemoData.isEnabled else { return 0 }
        let now = Date()
        var s = state
        let fed = RefugeRules.feed(&s, amount, now: now)
        guard fed > 0 else {
            if state.basket > 0, RefugeRules.appetiteLeft(state, now: now) == 0 {
                reaction = "J'ai bien mangé pour aujourd'hui ! Garde les autres pour demain."
            }
            return 0
        }
        feedingUntil = now.addingTimeInterval(min(4, 1.2 + Double(fed) * 0.1))
        reaction = fed >= 20 ? "Miam ! Quel festin, merci !" : "Miam ! Merci, je me sens grandir."
        update(s, now: now)
        companion.react("Miam !")
        return fed
    }

    // MARK: Shop and wardrobe

    /// Buys a thing (put on or in its room right away) or a coat. Returns false if the basket is too light.
    @discardableResult
    func buy(_ id: String, price: Int) -> Bool {
        guard !DemoData.isEnabled else { return false }
        var s = state
        guard RefugeStyle.buy(&s, id: id, price: price, now: Date()) else { return false }
        if RefugeStyle.item(id) != nil { RefugeStyle.toggleWorn(&s, id: id) }
        if id.hasPrefix("coat:") { s.coat = String(id.dropFirst(5)) }
        reaction = "Merci ! Je l'adore."
        update(s)
        return true
    }

    func toggleWorn(_ id: String) {
        var s = state
        RefugeStyle.toggleWorn(&s, id: id)
        update(s)
    }

    /// Wears a coat it owns, or its own (nil).
    func wearCoat(_ coat: RefugeCoat?) {
        var s = state
        s.coat = coat.flatMap { s.owned.contains($0.shopID) ? $0.rawValue : nil }
        update(s)
    }

    func setSeasons(_ on: Bool) {
        var s = state
        s.seasons = on
        update(s)
    }

    /// The Chamois d'or picks its scarf among those it won.
    func chooseScarf(_ scarf: RefugeScarf) {
        guard RefugeScarf.won(level: state.level).contains(scarf) else { return }
        var s = state
        s.scarf = scarf.rawValue
        update(s)
    }

    /// Changes path, once per season.
    func changePath(_ path: RefugePath) {
        guard state.stage >= .beau, RefugeStyle.canChangePath(state, on: clock), path.rawValue != state.path else { return }
        var s = state
        s.path = path.rawValue
        s.pathSeason = RefugeSeason.key(clock)
        RefugeRules.note(&s, kind: "path", text: "Nouvelle voie : \(path.title). \(path.line)", now: Date())
        update(s)
    }

    // MARK: The daily round

    /// Today's round, drawn on the first visit of the day from what really makes sense on this Mac.
    /// A round saved before a page went away has its mission swapped for another.
    func ensureRound() {
        guard state.welcomed, !DemoData.isEnabled else { return }
        let now = Date()
        let today = RefugeRules.dayKey(now)
        var s = state
        if let r = state.round, r.day == today {
            guard r.tasks.contains(where: { RefugeStyle.task($0).page == nil }) else { return }
            s.round = RefugeStyle.repairRound(r, state, candidates: roundCandidates(), now: now)
            guard s.round != r else { return }
        } else {
            s.round = RefugeStyle.makeRound(day: today, candidates: roundCandidates())
        }
        update(s, now: now)
    }

    private func roundCandidates() -> [String] {
        guard let app else { return ["scan", "tool"] }
        var c = ["scan", "tool"]
        if app.cleanup.hasResults && app.cleanup.recommendedSize > 500_000_000 { c.append("clean") }
        if app.updates.hasChecked && app.updates.totalAvailable > 0 { c.append("update") }
        if app.protection.issues.contains(where: { $0.fix != nil }) { c.append("fix") }
        let lit = Set(RefugeRules.discovered(state).map(\.page))
        let order = app.profile.ranking + RefugeRules.rooms.map(\.page)
        if let next = order.first(where: { RefugeRules.room($0) != nil && !lit.contains($0) }) { c.append("discover:" + next.rawValue) }
        return c
    }

    /// Today's missions and whether each one is done.
    var roundTasks: [(task: RefugeTask, done: Bool)] {
        guard let r = state.round, r.day == RefugeRules.dayKey(clock) else { return [] }
        return r.tasks.map { (RefugeStyle.task($0), RefugeStyle.done($0, state, now: clock)) }
    }

    // MARK: Earning

    /// Pays `source`, writes `text` in its notebook (nil: counted without a line).
    @discardableResult
    private func earn(_ source: RefugeSource, key: String? = nil, text: String?, merge: Bool = false, announce: String? = nil) -> Int {
        // The demo's chamois is invented and stays as it is.
        guard state.welcomed, !DemoData.isEnabled else { return 0 }
        let now = Date()
        var s = state
        let paid = RefugeRules.earn(&s, source, key: key, now: now)
        guard paid > 0 else { return 0 }
        if let text { RefugeRules.note(&s, kind: source.rawValue, text: text, amount: paid, merge: merge, now: now) }
        update(s, now: now)
        if let announce { tell("+\(paid) myrtilles · \(announce)", berry: true) }
        companion.react("+\(paid)")
        return paid
    }

    /// A discreet word, only while the user is in the app and wants the game: a blueberry for blueberries.
    private func tell(_ text: String, berry: Bool) {
        guard playful, state.welcomed, NSApp?.isActive == true else { return }
        if berry {
            HUD.show(text, icon: RefugeBerry(size: 20))
        } else {
            HUD.show(text, symbol: "rosette")
        }
    }

    /// Something only seen once (a badge condition).
    private func see(_ key: String) {
        guard state.welcomed, !DemoData.isEnabled, !state.claimed.contains(key) else { return }
        var s = state
        s.claimed.insert(key)
        update(s)
    }

    /// The app opened or came back to the front: the first visit of the day, the week's reward, its birthday, the round.
    func arrived() {
        guard state.welcomed else { return }
        earn(.visit, text: nil)
        let now = Date()
        if RefugeRules.weekDue(state, now: now) {
            earn(.week, key: "week:" + RefugeRules.weekKey(now), text: "Quatre jours sur sept ensemble cette semaine. On fait une belle équipe.",
                 announce: "semaine d'entretien")
        }
        let year = Calendar.current.component(.year, from: now)
        if events(now: now).contains(.anniversaire), !state.claimed.contains("anniv:\(year)"), !DemoData.isEnabled {
            var s = state
            s.claimed.insert("anniv:\(year)")
            s.claimed.insert("seen:anniversaire")
            RefugeRules.note(&s, kind: "birthday", text: RefugeEvent.anniversaire.line, now: now)
            update(s, now: now)
        }
        ensureRound()
        observe()
    }

    /// A page opened: a room of the house lights up the first time.
    func visited(_ page: Page) {
        guard state.welcomed else { return }
        if let room = RefugeRules.room(page) {
            if RefugeRules.isDiscovered(page, state), !state.claimed.contains("page:" + page.rawValue) {
                // Lit under its former name: noted under the new one, without a second reward.
                var s = state
                s.claimed.insert("page:" + page.rawValue)
                update(s)
            } else {
                earn(.discovery, key: "page:" + page.rawValue, text: "J'ai découvert une nouvelle pièce : \(room.name).", announce: room.name)
            }
        }
        observe()
    }

    /// What it notices on its own: the automations switched on, a strong security score.
    func observe() {
        guard let app, state.welcomed else { return }
        for k in AutomationKind.allCases where app.automation.isEnabled(k) {
            earn(.automation, key: "auto:" + k.rawValue, text: "Le jardin pousse tout seul : une automatisation de plus.", announce: "automatisation")
        }
        if app.protection.hasAudit && app.protection.securityScore >= 90 { see("seen:forteresse") }
    }

    func scanned() {
        if Calendar.current.component(.hour, from: Date()) < 5 { see("seen:noctambule") }
        earn(.scan, text: "On a fait le tour du Mac ensemble. Rien ne m'échappe !", announce: "analyse intelligente")
    }

    func cleaned() {
        earn(.cleaning, text: "Hop, des myrtilles de plus dans mon panier. Merci pour le ménage !", announce: "ménage")
    }

    func fixed(_ id: String, title: String) {
        earn(.fix, key: "fix:" + id, text: "« \(title) » : la porte du Mac ferme mieux maintenant.", announce: "point de sécurité corrigé")
    }

    func neutralized(_ ids: [String]) {
        for id in ids {
            earn(.threat, key: "threat:" + id, text: "J'ai chassé une mite. Elle est dans la Corbeille, tu peux la récupérer si c'était une erreur.",
                 announce: "une mite chassée")
        }
    }

    func upgraded(_ count: Int) {
        for _ in 0..<max(0, count) { earn(.update, text: "Le courrier est arrivé : des apps toutes neuves.", merge: true) }
    }

    func usedTool(_ id: String) {
        guard !id.hasPrefix("refuge_") else { return }
        earn(.tool, text: nil)
    }

    /// A dust bunny caught during an analysis. Returns what it paid (nothing past three a day).
    @discardableResult
    func caughtBunny() -> Int {
        earn(.chase, text: "J'ai attrapé des moutons de poussière pendant l'analyse !", merge: true)
    }

    /// A souvenir photo was copied or saved.
    func photoTaken() { see("seen:photo") }

    /// A caress: it laughs, and ten very fast make it sneeze.
    func pet() {
        let now = Date()
        pets = pets.filter { now.timeIntervalSince($0) < 4 } + [now]
        if pets.count >= 10 {
            pets = []
            reaction = "Atchoum ! Ça chatouille !"
            see("seen:atchoum")
        } else {
            reaction = ["Hi hi !", "Encore !", "Ça chatouille.", "Merci, ça fait du bien.", "Tu prends bien soin de moi."][pets.count % 5]
        }
    }

    // MARK: Desktop companion

    /// It left the screen (three quick caresses): the menu bar panel can call it back.
    func companionLeft() {
        var s = state
        s.companion = false
        update(s)
    }

    func setCompanion(_ on: Bool) {
        var s = state
        s.companion = on
        update(s)
        if on, state.welcomed, !DemoData.isEnabled, !Snapshot.isActive { companion.start(self) } else { companion.stop() }
    }

    // MARK: AppModule

    /// In the menu bar panel: bring it back on the desktop, or put it away.
    var quickToggles: [QuickToggle] {
        guard state.welcomed, playful, !DemoData.isEnabled else { return [] }
        return [QuickToggle(id: "refuge-compagnon", title: "\(state.name) sur le bureau", symbol: "figure.walk", isOn: state.companion) { [weak self] in
            guard let self else { return }
            self.setCompanion(!self.state.companion)
        }]
    }

    var sidebarBadge: String? {
        guard playful else { return nil }
        if ceremony != nil { return "Nouveau" }
        return RefugeRules.hungry(state, now: Date()) ? "Faim" : nil
    }

    func start(app: AppModel) {
        self.app = app
        started = true
        returningUser = app.history.runs > 0 || app.profile.usageLog.active.count > 1
        arrived()
        if state.companion, state.welcomed { companion.start(self) }
    }

    /// Without `start` (demo, snapshots, self-tests), the moods still read the app.
    func attach(_ app: AppModel) {
        if self.app == nil { self.app = app }
    }

    func stop() {
        companion.stop()
        store.flush()
    }

    func loadDemo() {
        let now = Date()
        func ago(_ days: Int, _ hour: Int = 10) -> Date {
            let d = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
            return Calendar.current.date(bySettingHour: hour, minute: 12, second: 0, of: d) ?? d
        }
        var s = RefugeState()
        s.name = "Pompon"
        s.born = ago(63)
        s.welcomed = true
        s.harvested = 2620
        s.eaten = 2140
        s.basket = 380
        s.lastFed = ago(0, 9)
        s.shownLevel = RefugeRules.level(2140)
        s.daysTogether = 41
        s.day = RefugeRules.dayKey(now)
        s.paidToday = ["visit": 1, "cleaning": 1, "tool": 4, "scan": 1]
        s.recentDays = (0..<7).filter { $0 != 2 && $0 != 5 }.map { RefugeRules.dayKey(ago($0)) }
        s.totals = ["visit": 41, "scan": 22, "cleaning": 34, "fix": 3, "threat": 1, "update": 46, "tool": 182, "discovery": 14,
                    "automation": 1, "round": 5, "fed": 38, "welcome": 10]
        let visited: [Page] = [.dashboard, .cleanup, .protection, .performance, .updates, .apps, .storage, .wheel, .media,
                               .hotkeys, .automation]
        s.claimed = Set(visited.map { "page:" + $0.rawValue } + ["fix:firewall", "fix:filevault", "fix:gatekeeper", "auto:trash", "seen:voie"])
        s.owned = ["confiture", "plante", "tableau", "bonnet", "lanterne", RefugeCoat.chocolat.shopID]
        s.worn = ["confiture", "plante", "tableau", "lanterne"]
        s.path = RefugePath.fee.rawValue
        s.pathSeason = RefugeSeason.key(ago(9))
        s.round = RefugeRound(day: RefugeRules.dayKey(now), tasks: ["feed", "scan", "discover:media"])
        let badges = ["repas", "chiffon", "lynx", "explorateur", "mainverte", "coquet", "moutons", "mites", "ajour", "gourmand", "fidele"]
        for (i, b) in badges.enumerated() { s.badges[b] = ago(62 - i * 5) }
        s.journal = [
            RefugeEntry(date: ago(63, 9), kind: "birth", text: RefugeStage.cabri.line),
            RefugeEntry(date: ago(63, 9), kind: "welcome", text: "Un cadeau de bienvenue : on les a cueillies ensemble dans mon buisson.", amount: 10),
            RefugeEntry(date: ago(63, 9), kind: "name", text: "Je m'appelle Pompon. Enchanté !"),
            RefugeEntry(date: ago(61), kind: "mue", text: "J'ai mué : me voilà Éterlou ! \(RefugeStage.eterlou.line)"),
            RefugeEntry(date: ago(49), kind: "mue", text: "J'ai mué : me voilà Chamois ! \(RefugeStage.chamois.line)"),
            RefugeEntry(date: ago(23, 16), kind: "threat", text: "J'ai chassé une mite cachée dans les Téléchargements. Elle est dans la Corbeille, tu peux la récupérer si c'était une erreur.", amount: 20),
            RefugeEntry(date: ago(9), kind: "mue", text: "J'ai mué : me voilà Beau Chamois ! \(RefugeStage.beau.line)"),
            RefugeEntry(date: ago(9), kind: "path", text: "J'ai trouvé ma voie : Fée du logis. \(RefugePath.fee.line)"),
            RefugeEntry(date: ago(4, 18), kind: "shop", text: "Merci pour « Tableau de montagne » ! Je l'adore."),
            RefugeEntry(date: ago(2, 11), kind: "week", text: "Quatre jours sur sept ensemble cette semaine. On fait une belle équipe.", amount: 20),
            RefugeEntry(date: ago(1, 20), kind: "update", text: "Le courrier est arrivé : des apps toutes neuves.", amount: 6, count: 3),
            RefugeEntry(date: ago(0, 9), kind: "feed", text: "Miam ! Merci pour les myrtilles, je me sens grandir.", amount: 25, count: 2),
            RefugeEntry(date: ago(0, 9), kind: "cleaning", text: "Hop, des myrtilles de plus dans mon panier. Merci pour le ménage !", amount: 5),
        ]
        state = s
        previewMood = .happy
        publishLook()
    }

    func applySnapshotTab(_ tab: String) {
        defer { publishLook() }
        switch tab {
        case "naissance": previewCeremony = .birth; previewBirthStep = .pick
        case "naissance-nom": previewCeremony = .birth; previewBirthStep = .name
        case "naissance-repas": previewCeremony = .birth; previewBirthStep = .feed
        case "refus": previewCeremony = .birth; previewBirthStep = .decline
        case "mue": previewCeremony = .mue(.stage(.beau))
        case "echarpe": previewCeremony = .mue(.scarf(.or))
        case "voie": previewCeremony = .path(.fee)
        case "hiver": previewDate = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 24, hour: 15))
        case "ete": previewDate = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 15))
        case "anniversaire":
            previewDate = state.born.flatMap { Calendar.current.date(byAdding: .year, value: 1, to: $0) }
        case "sobre":
            var s = state
            s.sober = true
            state = s
        case "refuse":
            // Said no at its birth: it waits in its bush.
            var s = RefugeState()
            s.declined = true
            state = s
        case "deco", "halloween":
            // A decorated room: for Christmas, or for Halloween.
            var s = state
            let christmas = ["fleuri", "tomettes", "arche", "lustre", "sapin", "chaussettes", "guirlande", "tapis", "cadre", "poele"]
            let halloween = ["pierre", "dallage", "vitrail", "lanterne", "citrouille", "toile", "chauves-souris", "fantome", "tapis"]
            let set = tab == "deco" ? christmas : halloween
            s.owned.formUnion(set)
            s.worn = Set(set)
            state = s
        case "faim":
            var s = state
            s.lastFed = Calendar.current.date(byAdding: .day, value: -2, to: Date())
            state = s
            previewMood = .hungry
        case "tournee-0", "tournee-1", "tournee-2":
            // The round with nothing done, then only its last mission, then all but the first: the trail counts them,
            // whatever their order (the demo's own round is all done).
            var s = state
            s.lastFed = Calendar.current.date(byAdding: .day, value: -1, to: Date())
            s.paidToday["cleaning"] = nil
            let tasks = ["tournee-0": ["feed", "clean", "discover:toolbox"], "tournee-1": ["feed", "clean", "discover:media"],
                         "tournee-2": ["feed", "tool", "discover:media"]][tab] ?? []
            s.round = RefugeRound(day: RefugeRules.dayKey(Date()), tasks: tasks)
            state = s
        case "nouveau":
            // The first day: a cabri, ten blueberries waiting to be eaten.
            var s = RefugeState()
            RefugeRules.adopt(&s, name: RefugeRules.defaultName, known: [.dashboard], returning: false, now: Date())
            state = s
            previewMood = nil
        default:
            if tab.hasPrefix("humeur-"), let mood = RefugeMood.allCases.first(where: { "humeur-" + $0.rawValue == tab }) {
                previewMood = mood
            } else if tab.hasPrefix("stade-"), let stage = RefugeStage.allCases.first(where: { "stade-" + String(describing: $0) == tab }) {
                var s = state
                s.eaten = stage.threshold + 40
                s.peakLevel = RefugeRules.level(s.eaten)
                s.shownLevel = s.level
                if stage == .gold { s.scarf = RefugeScarf.rubis.rawValue }
                state = s
            }
        }
    }

    func commands(app: AppModel) -> [AppCommand] {
        let tint = Theme.warn
        func open(_ ctx: CommandContext) {
            ctx.app.page = .refuge
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
        guard state.welcomed else {
            return [AppCommand(id: "refuge_adopt", title: "Adopter \(RefugeRules.defaultName)",
                               subtitle: state.declined ? "Il t'attend dans son buisson de myrtilles" : "Le petit chamois du Refuge",
                               keywords: ["adopter", "chamois", "refuge", "mascotte", "myrtilles"], icon: .symbol(Page.refuge.symbol, tint),
                               group: .actions, assistantSafe: true, urlSafe: true, hint: "Ouvrir") { [weak self] ctx in
                self?.reconsider()
                open(ctx)
                return .done
            }]
        }
        let n = state.name
        return [
            AppCommand(id: "refuge_open", title: "Le Refuge de \(n)",
                       subtitle: "\(state.stage.title) · \(Fmt.int(state.basket)) myrtilles dans le panier",
                       keywords: ["refuge", "chamois", "mascotte", "myrtilles", "insignes", "carnet", "maison", "boutique", n],
                       icon: .symbol(Page.refuge.symbol, tint), group: .actions, assistantSafe: true, urlSafe: true, hint: "Ouvrir") { ctx in
                open(ctx)
                return .done
            },
            AppCommand(id: "refuge_feed", title: "Nourrir \(n)", subtitle: "Lui donner 10 myrtilles du panier (il y en a \(Fmt.int(state.basket)))",
                       keywords: ["nourrir", "manger", "myrtilles", "chamois", n], icon: .symbol("fork.knife", tint), group: .actions,
                       assistantSafe: true, hint: "Donner") { [weak self] ctx in
                guard let self else { return .done }
                let fed = self.feed(10)
                open(ctx)
                if fed > 0 { return .message("Miam ! \(n) a mangé \(fed) myrtilles") }
                return .message(self.state.basket == 0 ? "Le panier est vide : prends soin du Mac pour en cueillir" : "\(n) a bien mangé pour aujourd'hui")
            },
            AppCommand(id: "refuge_hug", title: "Un câlin à \(n)", subtitle: "Une caresse au chamois du Refuge",
                       keywords: ["câlin", "calin", "caresse", "chamois", n], icon: .symbol("heart", tint), group: .actions,
                       assistantSafe: true, hint: "Câlin") { [weak self] _ in
                self?.pet()
                return .message(self?.reaction ?? "Hi hi !")
            },
            AppCommand(id: "refuge_companion", title: state.companion ? "Ranger \(n) dans le Refuge" : "\(n) sur le bureau",
                       subtitle: "Le compagnon de bureau : il se promène au bord de l'écran",
                       keywords: ["compagnon", "bureau", "promener", "chamois", n], icon: .symbol("figure.walk", tint), group: .actions,
                       hint: state.companion ? "Ranger" : "Sortir") { [weak self] _ in
                guard let self else { return .done }
                self.setCompanion(!self.state.companion)
                return .done
            },
        ]
    }

    func selfTest() -> [String] { RefugeRules.selfTest() + RefugeFigure.selfTest() + RefugeCompanion.selfTest() }

    func dump() -> [String] {
        let s = state
        guard s.welcomed else {
            return [s.declined ? "Pas adopté pour l'instant : il attend dans son buisson" : "Pas encore né (naissance à la fin de l'accueil)"]
        }
        var lines = ["Prénom : \(s.name) · né le \(s.born.map(Fmt.day) ?? "?") · jour \(day) · \(s.daysTogether) jours ensemble",
                     "Stade : \(s.stage.title) (niveau \(s.level)) · \(Fmt.int(s.eaten)) mangées · panier \(Fmt.int(s.basket)) · \(Fmt.int(s.harvested)) récoltées"]
        let p = RefugeRules.progress(s)
        if let next = p.next { lines.append("Prochain niveau : \(next) dans \(Fmt.int(p.left)) myrtilles à manger") }
        let look = look()
        lines.append("Allure : pelage \(look.coat.title), écharpe \(look.scarf?.title ?? "aucune"), tête \(look.head ?? "rien"), voie \(look.path?.title ?? "aucune")")
        let sig = signals()
        lines.append("Humeur : \(mood().title) (heure \(sig.hour), moutons \(RefugeRules.dust(sig.junk)), chaud \(sig.hot), Boost \(sig.boost), mites \(sig.threats), faim \(sig.hungry))")
        lines.append("Tournée : " + roundTasks.map { "\($0.task.title)\($0.done ? " ✓" : "")" }.joined(separator: " · "))
        lines.append("Pièces : \(RefugeRules.discovered(s).count) sur \(RefugeRules.rooms.count) · insignes : \(s.badges.count) sur \(RefugeRules.badges.count)")
        lines.append("Boutique : " + (s.owned.isEmpty ? "rien" : s.owned.sorted().joined(separator: ", ")))
        lines.append("Aujourd'hui : " + RefugeSource.allCases.compactMap { src in s.paidToday[src.rawValue].map { "\(src.rawValue) \($0)" } }.joined(separator: ", "))
        for e in s.journal.suffix(6) { lines.append("  \(Fmt.day(e.date)) · \(e.text)\(e.amount > 0 ? " (\(e.amount))" : "")") }
        return lines
    }
}
