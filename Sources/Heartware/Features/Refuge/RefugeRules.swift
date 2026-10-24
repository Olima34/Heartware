import Foundation

// The game of the Refuge, as pure functions: the blueberries and what they are for (feeding it, the shop), the stages
// and scarves, the badges, the rooms, the moods, the daily round. `--selftest` checks them; the model only calls them
// and saves the result.

/// The six stages of the chamois. At each one it really changes: its size, its horns, what it wears.
enum RefugeStage: Int, CaseIterable, Codable, Comparable {
    case cabri, eterlou, chamois, beau, grand, gold

    static func < (a: RefugeStage, b: RefugeStage) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .cabri: return "Cabri"
        case .eterlou: return "Éterlou"
        case .chamois: return "Chamois"
        case .beau: return "Beau Chamois"
        case .grand: return "Grand Chamois"
        case .gold: return "Chamois d'or"
        }
    }

    /// The blueberries it must have eaten.
    var threshold: Int {
        switch self {
        case .cabri: return 0
        case .eterlou: return 100
        case .chamois: return 400
        case .beau: return 1500
        case .grand: return 4500
        case .gold: return 15000
        }
    }

    /// What is new, in a few words (the stage strip).
    var change: String {
        switch self {
        case .cabri: return "pas encore de cornes"
        case .eterlou: return "ses premières cornes"
        case .chamois: return "les cornes en crochet"
        case .beau: return "sa clochette et sa voie"
        case .grand: return "sa première écharpe"
        case .gold: return "le pelage doré"
        }
    }

    /// What it says at its mue (or at its birth, for the first stage).
    var line: String {
        switch self {
        case .cabri: return "Je suis né dans ce buisson de myrtilles. Je grandis en les mangeant !"
        case .eterlou: return "Deux petites cornes ont poussé. Je me sens déjà plus grand !"
        case .chamois: return "Mes cornes font le crochet, comme celles des grands. Me voilà un vrai chamois."
        case .beau: return "Une clochette à mon cou ! Tu m'entendras arriver de loin."
        case .grand: return "Ma première écharpe, en bronze. Elle changera de matière à chaque palier."
        case .gold: return "Mon pelage est devenu doré. Je n'en reviens pas : choisis-moi l'écharpe que tu préfères."
        }
    }

    var next: RefugeStage? { RefugeStage(rawValue: rawValue + 1) }

    static func at(_ eaten: Int) -> RefugeStage {
        allCases.last { eaten >= $0.threshold } ?? .cabri
    }
}

/// What earns blueberries. Never the amount deleted: nobody should erase files to make it grow.
enum RefugeSource: String, CaseIterable, Codable {
    case visit, scan, cleaning, fix, threat, update, tool, discovery, automation, week, round, chase, welcome

    var amount: Int {
        switch self {
        case .visit: return 2
        case .scan, .cleaning, .discovery: return 5
        case .fix, .threat, .automation, .round: return 10
        case .week: return 15
        case .update, .tool, .chase: return 1
        case .welcome: return 0
        }
    }

    /// How many times a day it pays, nil without a daily limit.
    var perDay: Int? {
        switch self {
        case .visit, .scan, .round: return 1
        case .cleaning: return 2
        case .chase, .discovery: return 3
        case .tool: return 5
        case .update, .threat: return 10
        case .fix, .automation, .week, .welcome: return nil
        }
    }

    /// Paid once for each thing (a security point, a tool, an automation, a week, a day's round): the call gives its key.
    var needsKey: Bool { [.fix, .threat, .discovery, .automation, .week, .round].contains(self) }

    /// The table of the page: what to do, and its limit.
    var what: String {
        switch self {
        case .visit: return "Premier passage de la journée"
        case .scan: return "Lancer l'analyse intelligente"
        case .cleaning: return "Faire un nettoyage, quelle que soit sa taille"
        case .fix: return "Corriger un point du bilan de sécurité"
        case .threat: return "Neutraliser une menace (chasser une mite)"
        case .update: return "Mettre une app à jour"
        case .tool: return "Utiliser un outil depuis le lanceur"
        case .discovery: return "Découvrir une pièce de la maison"
        case .automation: return "Activer une automatisation"
        case .week: return "Semaine d'entretien : 4 jours sur 7"
        case .round: return "Finir la tournée du jour"
        case .chase: return "Attraper un mouton pendant une analyse"
        case .welcome: return "Le buisson de sa naissance"
        }
    }

    var limit: String {
        switch self {
        case .visit, .scan, .round: return "1 par jour"
        case .cleaning: return "2 par jour"
        case .chase: return "3 par jour"
        case .update: return "10 par jour"
        case .tool: return "5 par jour"
        case .threat: return "chaque menace"
        case .fix: return "une fois par point"
        case .discovery: return "3 pièces par jour"
        case .automation: return "une fois chacune"
        case .week: return "1 par semaine"
        case .welcome: return "à sa naissance"
        }
    }

    var symbol: String {
        switch self {
        case .visit: return "sun.max"
        case .scan: return "sparkle.magnifyingglass"
        case .cleaning: return "sparkles"
        case .fix: return "lock.shield"
        case .threat: return "ant"
        case .update: return "arrow.down.circle"
        case .tool: return "command"
        case .discovery: return "door.left.hand.open"
        case .automation: return "leaf"
        case .week: return "calendar"
        case .round: return "checklist"
        case .chase: return "hand.tap"
        case .welcome: return "gift"
        }
    }
}

/// A line of its notebook, written in its own voice.
struct RefugeEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var date: Date
    var kind: String
    var text: String
    var amount = 0
    /// Events of the same kind on the same day, merged into one line.
    var count = 1
}

/// Today's round: three little missions drawn from the real state of the Mac.
struct RefugeRound: Codable, Equatable {
    var day: String
    var tasks: [String]
    var paid = false
}

/// Everything the Refuge keeps (refuge.json). Every field may be missing from an older file.
struct RefugeState: Codable, Equatable {
    var name = RefugeRules.defaultName
    /// The day it was adopted, nil before.
    var born: Date?
    /// Adopted: the user took care of it at its birth.
    var welcomed = false
    /// The user said no at its birth, for now: it waits in its bush until they change their mind.
    var declined = false
    /// Every blueberry picked since its birth (a statistic: it never goes down).
    var harvested = 0
    /// The blueberries picked and not used yet: to feed it, or for the shop.
    var basket = 0
    /// Every blueberry it ate: never goes down, sets its stage and its scarf.
    var eaten = 0
    var lastFed: Date?
    /// The level the user last saw (stage, then scarf): a higher one waits for its mue.
    var shownLevel = 0
    /// The highest level it reached: it never goes back, even if the thresholds change.
    var peakLevel = 0
    /// Rewards paid once (`fix:…`, `page:…`, `auto:…`, `threat:…`, `week:…`, `round:…`) and things seen once (`seen:…`).
    var claimed: Set<String> = []
    /// Today, and what paid today, per source.
    var day = ""
    var paidToday: [String: Int] = [:]
    /// The days the app was used lately (the last 28), and how many since its birth.
    var recentDays: [String] = []
    var daysTogether = 0
    /// Everything paid since its birth, per source, plus `fed` (meals) (the badges count them).
    var totals: [String: Int] = [:]
    var badges: [String: Date] = [:]
    var journal: [RefugeEntry] = []
    /// The app without the game: no ceremony, no message, the Refuge out of the sidebar.
    var sober = false
    /// Its coat follows the seasons (tawny in summer, dark brown in winter).
    var seasons = true
    /// A coat of the shop it wears, nil for its own.
    var coat: String?
    /// What was bought (coats and things), and what it wears or has put in its room.
    var owned: Set<String> = []
    var worn: Set<String> = []
    /// The scarf chosen by the Chamois d'or (raw value of `RefugeScarf`), nil for the last one won.
    var scarf: Int?
    /// Its path (from the Beau Chamois on), and the season it was last chosen.
    var path: String?
    var pathSeason: String?
    var round: RefugeRound?
    /// It walks along the bottom of the screen.
    var companion = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? RefugeRules.defaultName
        born = try c.decodeIfPresent(Date.self, forKey: .born)
        welcomed = try c.decodeIfPresent(Bool.self, forKey: .welcomed) ?? false
        declined = try c.decodeIfPresent(Bool.self, forKey: .declined) ?? false
        harvested = max(0, try c.decodeIfPresent(Int.self, forKey: .harvested) ?? 0)
        basket = max(0, try c.decodeIfPresent(Int.self, forKey: .basket) ?? 0)
        // Before feeding existed, what it picked made it grow.
        eaten = max(0, try c.decodeIfPresent(Int.self, forKey: .eaten) ?? (welcomed ? harvested : 0))
        lastFed = try c.decodeIfPresent(Date.self, forKey: .lastFed)
        shownLevel = try c.decodeIfPresent(Int.self, forKey: .shownLevel) ?? RefugeRules.level(eaten)
        peakLevel = try c.decodeIfPresent(Int.self, forKey: .peakLevel) ?? max(shownLevel, RefugeRules.level(eaten))
        claimed = try c.decodeIfPresent(Set<String>.self, forKey: .claimed) ?? []
        day = try c.decodeIfPresent(String.self, forKey: .day) ?? ""
        paidToday = try c.decodeIfPresent([String: Int].self, forKey: .paidToday) ?? [:]
        recentDays = try c.decodeIfPresent([String].self, forKey: .recentDays) ?? []
        daysTogether = try c.decodeIfPresent(Int.self, forKey: .daysTogether) ?? 0
        totals = try c.decodeIfPresent([String: Int].self, forKey: .totals) ?? [:]
        badges = try c.decodeIfPresent([String: Date].self, forKey: .badges) ?? [:]
        journal = try c.decodeIfPresent([RefugeEntry].self, forKey: .journal) ?? []
        sober = try c.decodeIfPresent(Bool.self, forKey: .sober) ?? false
        seasons = try c.decodeIfPresent(Bool.self, forKey: .seasons) ?? true
        coat = try c.decodeIfPresent(String.self, forKey: .coat)
        owned = try c.decodeIfPresent(Set<String>.self, forKey: .owned) ?? []
        worn = try c.decodeIfPresent(Set<String>.self, forKey: .worn) ?? []
        scarf = try c.decodeIfPresent(Int.self, forKey: .scarf)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        pathSeason = try c.decodeIfPresent(String.self, forKey: .pathSeason)
        round = try c.decodeIfPresent(RefugeRound.self, forKey: .round)
        companion = try c.decodeIfPresent(Bool.self, forKey: .companion) ?? false
    }

    /// Its level and stage: what it ate, or the highest it reached.
    var level: Int { max(RefugeRules.level(eaten), peakLevel) }
    var stage: RefugeStage { RefugeRules.stage(forLevel: level) }
    func total(_ source: RefugeSource) -> Int { totals[source.rawValue] ?? 0 }
    /// Waiting for an answer at its birth.
    var awaitingAdoption: Bool { !welcomed && !declined }
}

/// The badges: good habits, regularity and curiosity, in bronze, silver and gold. Two are secret.
enum RefugeMetal { case bronze, silver, gold }

struct RefugeBadge: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let metal: RefugeMetal
    var secret = false
}

/// A room of its house: every tool of the app. It lights up the first time the user goes in.
struct RefugeRoom: Identifiable {
    let page: Page
    let name: String
    var id: String { page.rawValue }
}

/// How it feels: a glance at its face says how the Mac is doing. `sad` is only for the moment the user says no.
enum RefugeMood: String, CaseIterable {
    case happy, sleepy, sneezy, hot, boosted, worried, hungry, sad

    var title: String {
        switch self {
        case .happy: return "Content"
        case .sleepy: return "Il dort"
        case .sneezy: return "Atchoum !"
        case .hot: return "Il a chaud"
        case .boosted: return "Boosté"
        case .worried: return "Une mite rôde"
        case .hungry: return "Un petit creux"
        case .sad: return "Triste"
        }
    }
}

/// What the moods read from the Mac (and from its basket).
struct RefugeSignals: Equatable {
    var hour = 12
    /// Junk found by the last cleanup scan, in bytes.
    var junk: Int64 = 0
    var hot = false
    var boost = false
    var threats = 0
    var hungry = false
}

enum RefugeRules {
    static let defaultName = "Chamois"
    static let nameLimit = 24
    static let journalLimit = 80
    /// The blueberries picked from its bush at its birth: a welcome gift, or what the user already earned with the app.
    static let welcomeGift = 10

    // MARK: Days

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func weekKey(_ date: Date, calendar: Calendar = .current) -> String {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let c = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    /// Its day number since its birth, 1 on the first day.
    static func dayNumber(_ s: RefugeState, now: Date, calendar: Calendar = .current) -> Int {
        guard let born = s.born else { return 0 }
        let d = calendar.dateComponents([.day], from: calendar.startOfDay(for: born), to: calendar.startOfDay(for: now)).day ?? 0
        return max(1, d + 1)
    }

    // MARK: Birth

    /// Adopted: a fresh start, the tools already known lit, and the ten blueberries picked from its bush.
    /// `returning`: the user already used the app before it was born.
    static func adopt(_ s: inout RefugeState, name: String, known: [Page], returning: Bool, now: Date, calendar: Calendar = .current) {
        guard !s.welcomed else { return }
        var n = RefugeState()
        n.sober = s.sober
        n.seasons = s.seasons
        n.companion = s.companion
        n.name = cleanName(name)
        n.welcomed = true
        n.born = now
        for p in known where rooms.contains(where: { $0.page == p }) { n.claimed.insert("page:" + p.rawValue) }
        roll(&n, now: now, calendar: calendar)
        n.harvested = welcomeGift
        n.basket = welcomeGift
        n.totals[RefugeSource.welcome.rawValue] = welcomeGift
        note(&n, kind: "birth", text: RefugeStage.cabri.line, now: now, calendar: calendar)
        note(&n, kind: "welcome", text: returning
             ? "Tu en avais déjà gagné quelques-unes en utilisant l'app : on les a cueillies ensemble dans mon buisson."
             : "Un cadeau de bienvenue : on les a cueillies ensemble dans mon buisson.",
             amount: welcomeGift, now: now, calendar: calendar)
        note(&n, kind: "name", text: "Je m'appelle \(n.name). Enchanté !", now: now, calendar: calendar)
        s = n
    }

    /// The name the user typed, tidied: no line break, not too long, never empty.
    static func cleanName(_ raw: String) -> String {
        let one = raw.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let short = String(one.prefix(nameLimit)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? defaultName : short
    }

    // MARK: Earning

    /// A new day: today's limits start again, and the day counts as one more together.
    static func roll(_ s: inout RefugeState, now: Date, calendar: Calendar = .current) {
        let today = dayKey(now, calendar: calendar)
        guard s.day != today else { return }
        s.day = today
        s.paidToday = [:]
        if !s.recentDays.contains(today) {
            s.recentDays.append(today)
            if s.recentDays.count > 28 { s.recentDays.removeFirst(s.recentDays.count - 28) }
            s.daysTogether += 1
        }
    }

    /// Pays `source` if its limits allow it; the blueberries fall into its basket. Returns what was paid.
    @discardableResult
    static func earn(_ s: inout RefugeState, _ source: RefugeSource, key: String? = nil, now: Date,
                     calendar: Calendar = .current) -> Int {
        guard s.welcomed, source != .welcome else { return 0 }
        roll(&s, now: now, calendar: calendar)
        if source.needsKey {
            // Claimed even past the day's limit: a room visited lights up, it just pays nothing more today.
            guard let key, !key.isEmpty, !s.claimed.contains(key) else { return 0 }
            s.claimed.insert(key)
        }
        if let cap = source.perDay, s.paidToday[source.rawValue, default: 0] >= cap { return 0 }
        s.paidToday[source.rawValue, default: 0] += 1
        s.totals[source.rawValue, default: 0] += 1
        s.harvested += source.amount
        s.basket += source.amount
        return source.amount
    }

    /// The week's reward is due: the app opened on 4 of the last 7 days, and not yet paid this week.
    static func weekDue(_ s: RefugeState, now: Date, calendar: Calendar = .current) -> Bool {
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }.map { dayKey($0, calendar: calendar) }
        return days.filter(s.recentDays.contains).count >= 4 && !s.claimed.contains("week:" + weekKey(now, calendar: calendar))
    }

    // MARK: Feeding

    /// How many blueberries it can eat in a day: a baby's appetite, which grows with it. However many the user picks,
    /// it takes days to grow.
    static func appetite(_ stage: RefugeStage) -> Int {
        switch stage {
        case .cabri: return 20
        case .eterlou: return 25
        case .chamois: return 30
        case .beau: return 35
        case .grand, .gold: return 40
        }
    }

    /// What it can still eat today.
    static func appetiteLeft(_ s: RefugeState, now: Date, calendar: Calendar = .current) -> Int {
        let ateToday = s.day == dayKey(now, calendar: calendar) ? (s.paidToday["eaten"] ?? 0) : 0
        return max(0, appetite(s.stage) - ateToday)
    }

    /// Gives it up to `amount` blueberries from the basket, within its appetite: it eats them and grows.
    /// Returns how many it ate.
    @discardableResult
    static func feed(_ s: inout RefugeState, _ amount: Int, now: Date, calendar: Calendar = .current) -> Int {
        guard s.welcomed else { return 0 }
        roll(&s, now: now, calendar: calendar)
        let n = min(max(0, amount), s.basket, appetiteLeft(s, now: now, calendar: calendar))
        guard n > 0 else { return 0 }
        s.basket -= n
        s.eaten += n
        s.paidToday["eaten", default: 0] += n
        s.peakLevel = max(s.peakLevel, level(s.eaten))
        s.lastFed = now
        s.totals["fed", default: 0] += 1
        note(&s, kind: "feed", text: "Miam ! Merci pour les myrtilles, je me sens grandir.", amount: n, merge: true, now: now, calendar: calendar)
        return n
    }

    /// A little hunger: blueberries wait in the basket and it has not eaten for most of a day. Never more than that.
    static func hungry(_ s: RefugeState, now: Date) -> Bool {
        guard s.welcomed, s.basket >= 5, appetiteLeft(s, now: now) > 0 else { return false }
        return s.lastFed.map { now.timeIntervalSince($0) > 20 * 3600 } ?? true
    }

    // MARK: Levels and mues

    /// Its level: the stage, then from the Grand Chamois on the scarf (13 levels, each with its mue).
    static func level(_ eaten: Int) -> Int {
        switch RefugeStage.at(eaten) {
        case .gold: return 12
        case .grand: return 4 + (RefugeScarf.at(eaten)?.rawValue ?? 0)
        case let stage: return stage.rawValue
        }
    }

    static func stage(forLevel level: Int) -> RefugeStage {
        switch level {
        case ..<4: return RefugeStage(rawValue: max(0, level)) ?? .cabri
        case 4...11: return .grand
        default: return .gold
        }
    }

    /// The scarf of a level, from the Grand Chamois on.
    static func scarf(forLevel level: Int) -> RefugeScarf? {
        level >= 12 ? .laine : RefugeScarf(rawValue: level - 4)
    }

    static func levelTitle(_ level: Int) -> String {
        switch level {
        case 0...3: return RefugeStage(rawValue: level)?.title ?? ""
        case 4: return "Grand Chamois"
        case 5...11: return "Écharpe \(RefugeScarf(rawValue: level - 4)?.title.lowercased() ?? "")"
        default: return "Chamois d'or"
        }
    }

    /// What waits for the user's eyes: the stage it reached, or its new scarf.
    enum Mue: Equatable {
        case stage(RefugeStage)
        case scarf(RefugeScarf)
    }

    static func pendingMue(_ s: RefugeState) -> Mue? {
        guard s.welcomed, s.level > s.shownLevel else { return nil }
        let l = s.level
        if (5...11).contains(l), let scarf = RefugeScarf(rawValue: l - 4) { return .scarf(scarf) }
        return .stage(s.stage)
    }

    /// The blueberries to have eaten for each level.
    static let levelThresholds: [Int] = RefugeStage.allCases.filter { $0 != .grand && $0 != .gold }.map(\.threshold)
        + RefugeScarf.allCases.map(\.threshold) + [RefugeStage.gold.threshold]

    /// Where it stands: the next level, how far along, how many blueberries are left to eat.
    static func progress(_ s: RefugeState) -> (next: String?, fraction: Double, left: Int) {
        let level = s.level
        guard level < 12 else { return (nil, 1, 0) }
        let start = levelThresholds[level], end = levelThresholds[level + 1]
        return (levelTitle(level + 1), min(1, max(0, Double(s.eaten - start) / Double(end - start))), max(0, end - s.eaten))
    }

    // MARK: Notebook

    /// Writes a line of its notebook. `merge`: the same kind on the same day adds up on one line.
    static func note(_ s: inout RefugeState, kind: String, text: String, amount: Int = 0, merge: Bool = false, now: Date,
                     calendar: Calendar = .current) {
        if merge, let last = s.journal.last, last.kind == kind, calendar.isDate(last.date, inSameDayAs: now) {
            s.journal[s.journal.count - 1].count += 1
            s.journal[s.journal.count - 1].amount += amount
            s.journal[s.journal.count - 1].text = text
            s.journal[s.journal.count - 1].date = now
            return
        }
        s.journal.append(RefugeEntry(date: now, kind: kind, text: text, amount: amount))
        if s.journal.count > journalLimit { s.journal.removeFirst(s.journal.count - journalLimit) }
    }

    // MARK: Badges

    static let badges: [RefugeBadge] = [
        RefugeBadge(id: "repas", title: "Premier repas", detail: "Tes premières myrtilles données", symbol: "fork.knife", metal: .bronze),
        RefugeBadge(id: "chiffon", title: "Premier coup de chiffon", detail: "Ton premier nettoyage avec lui", symbol: "sparkles", metal: .bronze),
        RefugeBadge(id: "lynx", title: "Œil de lynx", detail: "Ta première analyse intelligente", symbol: "eye", metal: .bronze),
        RefugeBadge(id: "explorateur", title: "Explorateur", detail: "5 pièces de la maison découvertes", symbol: "map", metal: .bronze),
        RefugeBadge(id: "mainverte", title: "Main verte", detail: "Ta première automatisation", symbol: "leaf", metal: .bronze),
        RefugeBadge(id: "coquet", title: "Coquet", detail: "Un premier achat à la boutique", symbol: "bag", metal: .bronze),
        RefugeBadge(id: "photographe", title: "Photographe", detail: "Une photo souvenir", symbol: "camera", metal: .bronze),
        RefugeBadge(id: "moutons", title: "Chasseur de moutons", detail: "20 nettoyages", symbol: "wind", metal: .silver),
        RefugeBadge(id: "mites", title: "Chasseur de mites", detail: "Une menace neutralisée", symbol: "ant", metal: .silver),
        RefugeBadge(id: "ajour", title: "Toujours à jour", detail: "10 mises à jour d'apps", symbol: "arrow.down.circle", metal: .silver),
        RefugeBadge(id: "gourmand", title: "Gourmand", detail: "1 000 myrtilles mangées", symbol: "heart.circle", metal: .silver),
        RefugeBadge(id: "forteresse", title: "Forteresse", detail: "Une note de sécurité d'au moins 90", symbol: "shield.lefthalf.filled", metal: .gold),
        RefugeBadge(id: "proprietaire", title: "Tour du propriétaire", detail: "Toutes les pièces découvertes", symbol: "house", metal: .gold),
        RefugeBadge(id: "fidele", title: "Fidèle", detail: "30 jours ensemble", symbol: "heart", metal: .gold),
        RefugeBadge(id: "tournee", title: "Tournée parfaite", detail: "7 tournées du jour finies", symbol: "checklist", metal: .gold),
        RefugeBadge(id: "anniversaire", title: "Joyeux anniversaire", detail: "Un an ensemble", symbol: "birthday.cake", metal: .gold),
        RefugeBadge(id: "noctambule", title: "Noctambule", detail: "Une analyse entre minuit et 5 h", symbol: "moon.stars", metal: .silver, secret: true),
        RefugeBadge(id: "atchoum", title: "Atchoum !", detail: "Dix caresses très vite", symbol: "nose", metal: .bronze, secret: true),
    ]

    /// The badges the state now deserves.
    static func deserved(_ s: RefugeState) -> [String] {
        let rooms = discovered(s).count
        var out: [String] = []
        if (s.totals["fed"] ?? 0) >= 1 { out.append("repas") }
        if s.total(.cleaning) >= 1 { out.append("chiffon") }
        if s.total(.scan) >= 1 { out.append("lynx") }
        if rooms >= 5 { out.append("explorateur") }
        if s.total(.automation) >= 1 { out.append("mainverte") }
        if !s.owned.isEmpty { out.append("coquet") }
        if s.claimed.contains("seen:photo") { out.append("photographe") }
        if s.total(.cleaning) >= 20 { out.append("moutons") }
        if s.total(.threat) >= 1 { out.append("mites") }
        if s.total(.update) >= 10 { out.append("ajour") }
        if s.eaten >= 1000 { out.append("gourmand") }
        if s.claimed.contains("seen:forteresse") { out.append("forteresse") }
        if rooms >= self.rooms.count { out.append("proprietaire") }
        if s.daysTogether >= 30 { out.append("fidele") }
        if s.total(.round) >= 7 { out.append("tournee") }
        if s.claimed.contains("seen:anniversaire") { out.append("anniversaire") }
        if s.claimed.contains("seen:noctambule") { out.append("noctambule") }
        if s.claimed.contains("seen:atchoum") { out.append("atchoum") }
        return out
    }

    /// Gives the badges newly deserved, writes them in the notebook, and returns them.
    @discardableResult
    static func award(_ s: inout RefugeState, now: Date) -> [RefugeBadge] {
        guard s.welcomed else { return [] }
        let fresh = deserved(s).filter { s.badges[$0] == nil }
        var out: [RefugeBadge] = []
        for id in fresh {
            guard let b = badges.first(where: { $0.id == id }) else { continue }
            s.badges[id] = now
            note(&s, kind: "badge", text: "Nouvel insigne : « \(b.title) ». Je le pose sur l'étagère.", now: now)
            out.append(b)
        }
        return out
    }

    // MARK: The house

    static let rooms: [RefugeRoom] = [
        RefugeRoom(page: .dashboard, name: "La Grande salle"),
        RefugeRoom(page: .cleanup, name: "La Buanderie"),
        RefugeRoom(page: .protection, name: "La Salle de garde"),
        RefugeRoom(page: .performance, name: "La Salle de sport"),
        RefugeRoom(page: .battery, name: "La Chaufferie"),
        RefugeRoom(page: .updates, name: "La Boîte aux lettres"),
        RefugeRoom(page: .apps, name: "La Cave"),
        RefugeRoom(page: .storage, name: "Le Grenier"),
        RefugeRoom(page: .phone, name: "La Cabine"),
        RefugeRoom(page: .wheel, name: "Le Moulin"),
        RefugeRoom(page: .media, name: "Le Ciné-club"),
        RefugeRoom(page: .toolbox, name: "L'Établi"),
        RefugeRoom(page: .hotkeys, name: "Le Tableau des clés"),
        RefugeRoom(page: .automation, name: "Le Jardin"),
        RefugeRoom(page: .assistant, name: "Le Salon"),
        RefugeRoom(page: .menubar, name: "La Lucarne"),
    ]

    static func room(_ page: Page) -> RefugeRoom? { rooms.first { $0.page == page } }

    static func discovered(_ s: RefugeState) -> [RefugeRoom] {
        rooms.filter { isDiscovered($0.page, s) }
    }

    /// A room lit before the refonte under one of the pages its page took in (the Ciné-club opened as Films et séries)
    /// stays lit, and is not paid again.
    static func isDiscovered(_ page: Page, _ s: RefugeState) -> Bool {
        ([page.rawValue] + (ToolProfileRules.formerKeys[page] ?? [])).contains { s.claimed.contains("page:" + $0) }
    }

    // MARK: Moods

    /// The dust bunnies under the furniture: the junk on a gentle scale, never more than five.
    static func dust(_ junk: Int64) -> Int {
        let gb = Double(max(0, junk)) / 1_000_000_000
        switch gb {
        case ..<0.5: return 0
        case ..<2: return 1
        case ..<5: return 2
        case ..<10: return 3
        case ..<20: return 4
        default: return 5
        }
    }

    static func isNight(_ hour: Int) -> Bool { hour >= 23 || hour < 6 }

    /// One mood at a time, the most useful first: a threat, heat, hunger, the Boost, the dust, then the night.
    static func mood(_ s: RefugeSignals) -> RefugeMood {
        if s.threats > 0 { return .worried }
        if s.hot { return .hot }
        if s.hungry { return .hungry }
        if s.boost { return .boosted }
        if dust(s.junk) >= 3 { return .sneezy }
        if isNight(s.hour) { return .sleepy }
        return .happy
    }

    /// What it says about it, in its own voice.
    static func moodLine(_ mood: RefugeMood, signals: RefugeSignals) -> String {
        switch mood {
        case .happy: return "Ton Mac va bien. Je profite de la vue."
        case .sleepy: return "Il est tard, je fais un somme. Ton Mac veille."
        case .sneezy: return "Atchoum ! Il y a \(Fmt.bytes(signals.junk)) de moutons sous les meubles. On fait le ménage ?"
        case .hot: return "Ton processeur chauffe un peu. J'ai chaud, moi aussi."
        case .boosted: return "Boost activé : j'ai mis mes lunettes de course."
        case .worried:
            return signals.threats > 1 ? "\(signals.threats) mites rôdent dans ton Mac. On les chasse ensemble ?"
                : "Une mite rôde dans ton Mac. On la chasse ensemble ?"
        case .hungry: return "J'ai un petit creux… Il reste des myrtilles dans le panier ?"
        case .sad: return "Oh… Tu es sûr de toi ?"
        }
    }

    // MARK: Self-test

    static func selfTest() -> [String] {
        var f: [String] = []
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 10)) ?? Date()
        func day(_ n: Int, hour: Int = 10) -> Date {
            cal.date(byAdding: DateComponents(day: n, hour: hour - 10), to: start) ?? start
        }

        // Stages and levels.
        let stages = RefugeStage.allCases
        if zip(stages, stages.dropFirst()).contains(where: { $0.threshold >= $1.threshold }) { f.append("Refuge : seuils des stades dans le désordre") }
        if RefugeStage.at(0) != .cabri || RefugeStage.at(99) != .cabri || RefugeStage.at(100) != .eterlou
            || RefugeStage.at(14_999) != .grand || RefugeStage.at(50_000) != .gold {
            f.append("Refuge : stade mal calculé aux seuils")
        }
        if level(0) != 0 || level(1500) != 3 || level(4500) != 4 || level(5700) != 5 || level(12_900) != 11 || level(15_000) != 12 {
            f.append("Refuge : niveaux (stades puis écharpes) mal comptés")
        }
        if levelThresholds.count != 13 || zip(levelThresholds, levelThresholds.dropFirst()).contains(where: { $0 >= $1 }) {
            f.append("Refuge : seuils des niveaux dans le désordre")
        }
        var pr = RefugeState()
        pr.eaten = 50
        if progress(pr).next != "Éterlou" || abs(progress(pr).fraction - 0.5) > 0.001 || progress(pr).left != 50 { f.append("Refuge : progression fausse") }
        pr.eaten = 5000
        if progress(pr).next != "Écharpe argent" || progress(pr).left != 700 { f.append("Refuge : progression vers l'écharpe fausse") }
        pr.eaten = 15_000
        if progress(pr).next != nil { f.append("Refuge : un niveau après le Chamois d'or") }
        // A level reached stays, even if the thresholds rise.
        var kept = RefugeState()
        kept.eaten = 307
        kept.peakLevel = 2
        if kept.stage != .chamois || progress(kept).next != "Beau Chamois" || progress(kept).fraction != 0 { f.append("Refuge : un stade atteint s'est perdu") }

        // Nothing is paid before the adoption; adopting is a fresh start with ten blueberries.
        var s = RefugeState()
        if earn(&s, .cleaning, now: start) != 0 { f.append("Refuge : des myrtilles avant l'adoption") }
        s.harvested = 24
        s.basket = 24
        s.declined = true
        if s.awaitingAdoption { f.append("Refuge : un refus attend encore une réponse") }
        s.declined = false
        adopt(&s, name: "  Pom\npon ", known: [.wheel, .refuge], returning: true, now: start, calendar: cal)
        if !s.welcomed || s.born == nil || s.name != "Pom pon" { f.append("Refuge : adoption mal enregistrée") }
        if s.basket != welcomeGift || s.harvested != welcomeGift || s.eaten != 0 { f.append("Refuge : le buisson ne donne pas 10 myrtilles (\(s.basket))") }
        if !s.claimed.contains("page:wheel") || s.claimed.contains("page:refuge") { f.append("Refuge : pièces déjà connues mal allumées") }
        if s.daysTogether != 1 || s.journal.count != 3 { f.append("Refuge : naissance mal notée") }

        // Daily limits.
        _ = earn(&s, .visit, now: start, calendar: cal)
        _ = earn(&s, .visit, now: day(0, hour: 18), calendar: cal)
        if s.basket != welcomeGift + 2 { f.append("Refuge : premier passage payé \(s.basket - welcomeGift) au lieu de 2") }
        for _ in 0..<3 { _ = earn(&s, .cleaning, now: start, calendar: cal) }
        if s.total(.cleaning) != 2 { f.append("Refuge : plus de 2 nettoyages payés par jour") }
        _ = earn(&s, .visit, now: day(1), calendar: cal)
        if s.total(.visit) != 2 || s.daysTogether != 2 { f.append("Refuge : le lendemain ne repart pas de zéro") }
        if earn(&s, .fix, now: start, calendar: cal) != 0 { f.append("Refuge : un point de sécurité payé sans clé") }
        _ = earn(&s, .fix, key: "fix:firewall", now: day(1), calendar: cal)
        if earn(&s, .fix, key: "fix:firewall", now: day(2), calendar: cal) != 0 { f.append("Refuge : un point de sécurité payé deux fois") }
        if earn(&s, .discovery, key: "page:wheel", now: day(1), calendar: cal) != 0 { f.append("Refuge : une pièce déjà connue repayée") }
        if earn(&s, .discovery, key: "page:toolbox", now: day(1), calendar: cal) != 5 { f.append("Refuge : découverte non payée") }
        for p in ["page:cinema", "page:network", "page:windows"] { _ = earn(&s, .discovery, key: p, now: day(1), calendar: cal) }
        if s.total(.discovery) != 3 || !s.claimed.contains("page:windows") { f.append("Refuge : plus de 3 découvertes payées par jour, ou une pièce pas allumée") }
        for _ in 0..<12 { _ = earn(&s, .tool, now: day(1), calendar: cal) }
        if s.total(.tool) != 5 { f.append("Refuge : plus de 5 outils payés par jour") }
        for _ in 0..<5 { _ = earn(&s, .chase, now: day(1), calendar: cal) }
        if s.total(.chase) != 3 { f.append("Refuge : plus de 3 moutons attrapés payés par jour") }

        // Earning fills the basket; only eating makes it grow, within its appetite of the day.
        if s.eaten != 0 || s.stage != .cabri { f.append("Refuge : il grandit sans manger") }
        s.basket = 100
        if feed(&s, 5, now: day(1), calendar: cal) != 5 || s.basket != 95 || s.eaten != 5 { f.append("Refuge : repas mal compté") }
        if feed(&s, 10_000, now: day(1), calendar: cal) != appetite(.cabri) - 5 || s.basket != 100 - appetite(.cabri) { f.append("Refuge : il mange plus que son appétit") }
        if feed(&s, 3, now: day(1, hour: 20), calendar: cal) != 0 || appetiteLeft(s, now: day(1, hour: 20), calendar: cal) != 0 { f.append("Refuge : il mange encore, l'appétit fini") }
        if appetiteLeft(s, now: day(2), calendar: cal) != appetite(.cabri) { f.append("Refuge : l'appétit ne revient pas le lendemain") }
        s.basket = 2
        if feed(&s, 10, now: day(2), calendar: cal) != 2 || s.basket != 0 { f.append("Refuge : il mange plus que le panier") }
        if feed(&s, 3, now: day(2), calendar: cal) != 0 { f.append("Refuge : il mange un panier vide") }
        if s.journal.filter({ $0.kind == "feed" }).count != 2 { f.append("Refuge : les repas d'un jour ne tiennent pas sur une ligne") }
        // However much is picked, growing takes days: at least 5 to the Éterlou, about 17 to the Chamois.
        var fast = RefugeState()
        adopt(&fast, name: "", known: [], returning: false, now: start, calendar: cal)
        fast.basket = 100_000
        var days = 0
        while fast.stage < .chamois, days < 400 { days += 1; _ = feed(&fast, 1_000, now: day(days), calendar: cal) }
        if days < 15 { f.append("Refuge : le Chamois en \(days) jours, trop vite") }
        var h = RefugeState()
        adopt(&h, name: "", known: [], returning: false, now: start, calendar: cal)
        if !hungry(h, now: start) { f.append("Refuge : jamais nourri, il devrait avoir un petit creux") }
        _ = feed(&h, 2, now: start, calendar: cal)
        if hungry(h, now: day(0, hour: 20)) || hungry(RefugeState(), now: start) { f.append("Refuge : faim mal calculée") }

        // The week: 4 days out of 7.
        var w = RefugeState()
        adopt(&w, name: "", known: [], returning: false, now: day(0), calendar: cal)
        for n in 1...2 { roll(&w, now: day(n), calendar: cal) }
        if weekDue(w, now: day(2), calendar: cal) { f.append("Refuge : semaine payée après 3 jours") }
        roll(&w, now: day(4), calendar: cal)
        if !weekDue(w, now: day(4), calendar: cal) { f.append("Refuge : semaine non payée après 4 jours sur 7") }
        _ = earn(&w, .week, key: "week:" + weekKey(day(4), calendar: cal), now: day(4), calendar: cal)
        if weekDue(w, now: day(4), calendar: cal) { f.append("Refuge : semaine payée deux fois") }

        // The mue waits for the adoption, then for the user's eyes; the scarves have theirs.
        var m = RefugeState()
        m.eaten = 400
        if pendingMue(m) != nil { f.append("Refuge : mue avant l'adoption") }
        m.welcomed = true
        if pendingMue(m) != .stage(.chamois) { f.append("Refuge : mue attendue non signalée") }
        m.shownLevel = m.level
        if pendingMue(m) != nil { f.append("Refuge : mue déjà vue reproposée") }
        m.eaten = 7000
        if pendingMue(m) != .scarf(.or) { f.append("Refuge : écharpe en or non signalée") }

        // Names.
        if cleanName("  \n ") != defaultName || cleanName(String(repeating: "a", count: 60)).count != nameLimit { f.append("Refuge : prénom mal nettoyé") }

        // The notebook merges and stays short.
        var j = RefugeState()
        note(&j, kind: "update", text: "1", amount: 2, merge: true, now: start, calendar: cal)
        note(&j, kind: "update", text: "2", amount: 2, merge: true, now: day(0, hour: 15), calendar: cal)
        note(&j, kind: "update", text: "3", amount: 2, merge: true, now: day(1), calendar: cal)
        if j.journal.count != 2 || j.journal[0].count != 2 || j.journal[0].amount != 4 { f.append("Refuge : carnet mal regroupé") }
        for i in 0..<100 { note(&j, kind: "x\(i)", text: "", now: start, calendar: cal) }
        if j.journal.count != journalLimit { f.append("Refuge : carnet trop long") }

        // Badges.
        var b = RefugeState()
        adopt(&b, name: "", known: Array(rooms.prefix(4).map(\.page)), returning: false, now: start, calendar: cal)
        if !award(&b, now: start).isEmpty { f.append("Refuge : insigne sans raison") }
        b.totals["cleaning"] = 1
        b.claimed.insert("page:" + rooms[10].page.rawValue)
        _ = feed(&b, 1, now: start, calendar: cal)
        let got = award(&b, now: start).map(\.id)
        if Set(got) != ["chiffon", "explorateur", "repas"] { f.append("Refuge : insignes attendus chiffon, explorateur et repas, obtenus \(got)") }
        if !award(&b, now: start).isEmpty { f.append("Refuge : insigne donné deux fois") }
        for room in rooms { b.claimed.insert("page:" + room.page.rawValue) }
        if award(&b, now: start).map(\.id) != ["proprietaire"] { f.append("Refuge : tour du propriétaire non donné") }
        if Set(badges.map(\.id)).count != badges.count || badges.count != 18 { f.append("Refuge : 18 insignes distincts attendus") }

        // A room lit under a page folded into another stays lit.
        var former = RefugeState()
        former.claimed = ["page:cinema", "page:launcher"]
        if !isDiscovered(.media, former) || !isDiscovered(.hotkeys, former) || isDiscovered(.wheel, former) {
            f.append("Refuge : une pièce découverte sous son ancien nom s'éteint")
        }

        // Every page but the Refuge is a room, once.
        let roomPages = rooms.map(\.page)
        if Set(roomPages).count != roomPages.count { f.append("Refuge : une pièce en double") }
        for p in Page.allCases where p != .refuge && !roomPages.contains(p) { f.append("Refuge : \(p.title) n'a pas de pièce") }

        // Moods.
        if mood(RefugeSignals(hour: 2, junk: 30_000_000_000, hot: true, boost: true, threats: 1, hungry: true)) != .worried { f.append("Refuge : la mite doit passer avant tout") }
        if mood(RefugeSignals(hour: 2, junk: 30_000_000_000, hot: true, boost: true, hungry: true)) != .hot { f.append("Refuge : la chaleur avant la faim") }
        if mood(RefugeSignals(hour: 2, junk: 30_000_000_000, boost: true, hungry: true)) != .hungry { f.append("Refuge : la faim avant le Boost") }
        if mood(RefugeSignals(hour: 2, junk: 30_000_000_000, boost: true)) != .boosted { f.append("Refuge : le Boost avant la poussière") }
        if mood(RefugeSignals(hour: 2, junk: 6_000_000_000)) != .sneezy { f.append("Refuge : la poussière avant la nuit") }
        if mood(RefugeSignals(hour: 23)) != .sleepy || mood(RefugeSignals(hour: 6)) != .happy { f.append("Refuge : nuit mal bornée") }
        if dust(0) != 0 || dust(1_000_000_000) != 1 || dust(500_000_000_000) != 5 { f.append("Refuge : moutons mal comptés") }

        // An older or partial file still opens.
        if let old = try? JSONDecoder.store.decode(RefugeState.self, from: Data(#"{"name":"Pompon","harvested":120,"welcomed":true}"#.utf8)) {
            if old.name != "Pompon" || old.eaten != 120 || old.basket != 0 || !old.seasons || old.shownLevel != level(120) || old.peakLevel != level(120) {
                f.append("Refuge : fichier ancien mal relu")
            }
        } else {
            f.append("Refuge : un fichier partiel ne s'ouvre pas")
        }
        if let data = try? JSONEncoder.store.encode(s), let back = try? JSONDecoder.store.decode(RefugeState.self, from: data) {
            if back.basket != s.basket || back.eaten != s.eaten || back.claimed != s.claimed || back.journal.count != s.journal.count {
                f.append("Refuge : l'état ne se relit pas à l'identique")
            }
        } else {
            f.append("Refuge : l'état ne s'enregistre pas")
        }
        return f + RefugeStyle.selfTest()
    }
}
