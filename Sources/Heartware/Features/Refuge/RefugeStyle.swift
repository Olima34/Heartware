import Foundation

// What it wears and how it lives: its scarves, its coats, the shop, its path, the seasons and the daily round.
// Pure data and rules, checked by `--selftest`.

/// The scarves of the Grand Chamois: a new material at each level, like the ranks of a video game.
enum RefugeScarf: Int, CaseIterable, Codable, Comparable {
    case bronze, argent, or, platine, diamant, emeraude, rubis, laine

    static func < (a: RefugeScarf, b: RefugeScarf) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .bronze: return "Bronze"
        case .argent: return "Argent"
        case .or: return "Or"
        case .platine: return "Platine"
        case .diamant: return "Diamant"
        case .emeraude: return "Émeraude"
        case .rubis: return "Rubis"
        case .laine: return "Laine sacrée"
        }
    }

    var threshold: Int { 4500 + rawValue * 1200 }
    /// The precious ones sparkle.
    var sparkle: Bool { self >= .platine }

    /// The last scarf won, nil before the Grand Chamois.
    static func at(_ eaten: Int) -> RefugeScarf? { allCases.last { eaten >= $0.threshold } }
    /// The scarves won at a level (all of them for the Chamois d'or).
    static func won(level: Int) -> [RefugeScarf] { allCases.filter { level >= 12 || $0.rawValue <= level - 4 } }
}

/// Its coats: its own (caramel), the winter one, and those of the shop.
enum RefugeCoat: String, CaseIterable, Codable {
    case caramel, hiver, chocolat, roux, grisPerle = "gris-perle", neige, nuit

    var title: String {
        switch self {
        case .caramel: return "Caramel"
        case .hiver: return "Pelage d'hiver"
        case .chocolat: return "Chocolat"
        case .roux: return "Roux"
        case .grisPerle: return "Gris perle"
        case .neige: return "Neige"
        case .nuit: return "Nuit étoilée"
        }
    }

    /// Its price at the shop, nil for the coats it has on its own.
    var price: Int? {
        switch self {
        case .caramel, .hiver: return nil
        case .chocolat, .roux: return 600
        case .grisPerle: return 800
        case .neige: return 1000
        case .nuit: return 2000
        }
    }

    var shopID: String { "coat:" + rawValue }
}

/// Where a thing of the shop goes: on its head or face, or in its room (one wall, one floor, one window, one lamp,
/// and any number of things).
enum RefugeSlot: String {
    case head, face, wall, floor, window, lamp, room
}

/// The seasons, and the shop's stall that follows them.
enum RefugeSeason: String, CaseIterable {
    case printemps, ete, automne, hiver

    var title: String {
        switch self {
        case .printemps: return "printemps"
        case .ete: return "été"
        case .automne: return "automne"
        case .hiver: return "hiver"
        }
    }

    static func of(_ date: Date, calendar: Calendar = .current) -> RefugeSeason {
        let c = calendar.dateComponents([.month, .day], from: date)
        let md = (c.month ?? 1) * 100 + (c.day ?? 1)
        switch md {
        case 320..<621: return .printemps
        case 621..<923: return .ete
        case 923..<1221: return .automne
        default: return .hiver
        }
    }

    /// The season and its year, to allow one change of path per season ("2026-hiver" runs into 2027).
    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let season = of(date, calendar: calendar)
        let c = calendar.dateComponents([.year, .month], from: date)
        let year = (c.year ?? 0) - (season == .hiver && (c.month ?? 1) <= 3 ? 1 : 0)
        return "\(year)-\(season.rawValue)"
    }
}

/// The yearly meetings.
enum RefugeEvent: String, CaseIterable {
    case menage, vacances, fantomes, finAnnee = "fin-annee", anniversaire

    var title: String {
        switch self {
        case .menage: return "Le grand ménage de printemps"
        case .vacances: return "Chamois en vacances"
        case .fantomes: return "La nuit des fantômes"
        case .finAnnee: return "Ton année avec lui"
        case .anniversaire: return "Son anniversaire"
        }
    }

    var line: String {
        switch self {
        case .menage: return "C'est le printemps : on fait le grand ménage ? Une couronne de fleurs t'attend à la boutique."
        case .vacances: return "Je suis en vacances ! Chapeau de paille à la boutique, et pense à la batterie en voyage."
        case .fantomes: return "Halloween : des fantômes d'apps supprimées traînent peut-être encore. On va voir dans Applications ?"
        case .finAnnee: return "L'année se termine : regarde notre photo souvenir de l'année, et la guirlande à la boutique."
        case .anniversaire: return "C'est mon anniversaire ! Un gâteau est arrivé au Refuge. Merci pour cette année."
        }
    }

    var symbol: String {
        switch self {
        case .menage: return "leaf"
        case .vacances: return "sun.max"
        case .fantomes: return "moon.haze"
        case .finAnnee: return "sparkles"
        case .anniversaire: return "birthday.cake"
        }
    }
}

/// A thing of the shop: worn on its head or face, or put in its room. Some appear only in their season and come back
/// every year; what is bought stays for good.
struct RefugeItem: Identifiable {
    let id: String
    let title: String
    let price: Int
    let slot: RefugeSlot
    var season: RefugeSeason? = nil
    let detail: String
}

/// Its path, chosen at the Beau Chamois from the tools the user uses most, and its accessory.
enum RefugePath: String, CaseIterable, Codable {
    case gardien, artiste, guide, fee

    var title: String {
        switch self {
        case .gardien: return "Gardien"
        case .artiste: return "Artiste"
        case .guide: return "Guide"
        case .fee: return "Fée du logis"
        }
    }

    var pages: [Page] {
        switch self {
        case .gardien: return [.protection, .updates]
        case .artiste: return [.wheel, .media]
        case .guide: return [.hotkeys, .toolbox]
        case .fee: return [.cleanup, .storage, .apps, .phone, .automation, .performance, .battery]
        }
    }

    var accessory: String {
        switch self {
        case .gardien: return "un bouclier"
        case .artiste: return "un béret et un pinceau"
        case .guide: return "des lunettes d'aviateur"
        case .fee: return "de petites ailes et une baguette"
        }
    }

    var who: String {
        switch self {
        case .gardien: return "Pour ceux qui soignent la sécurité : bilan, protection, menaces."
        case .artiste: return "Convertisseur et Multimédia."
        case .guide: return "Lanceur, raccourcis, fenêtres, presse-papiers."
        case .fee: return "Nettoyage, stockage, apps, automatisations."
        }
    }

    var line: String {
        switch self {
        case .gardien: return "Je crois que je suis fait pour garder la maison. Gardien, à ton service !"
        case .artiste: return "Je crois que j'ai l'âme d'un artiste. Où sont mes pinceaux ?"
        case .guide: return "Je connais tous les raccourcis du Mac. Suis le guide !"
        case .fee: return "Je crois que je suis une vraie fée du logis. Tout brille avec moi."
        }
    }
}

/// A mission of the daily round.
struct RefugeTask: Identifiable, Equatable {
    let id: String
    let title: String
    let page: Page?
}

/// Where it stands on the trail of the round: one step per mission done, in whatever order they were done. The flags
/// along the trail are steps, not missions.
struct RefugeRoundProgress: Equatable {
    var steps: Int
    var count: Int

    init(_ done: [Bool]) {
        steps = done.filter { $0 }.count
        count = done.count
    }

    var finished: Bool { count > 0 && steps >= count }
    /// The flag of step `index` (0 for the first) is planted once it is reached.
    func planted(_ index: Int) -> Bool { index < steps }
}

enum RefugeStyle {
    // MARK: The shop

    static let items: [RefugeItem] = [
        RefugeItem(id: "confiture", title: "Confiture de myrtilles", price: 80, slot: .room, detail: "Un pot sur le rebord de la fenêtre"),
        RefugeItem(id: "plante", title: "Plante verte", price: 120, slot: .room, detail: "Dans le coin de la pièce"),
        RefugeItem(id: "tapis", title: "Tapis tressé", price: 180, slot: .room, detail: "Sous ses sabots"),
        RefugeItem(id: "lunettes", title: "Lunettes rondes", price: 200, slot: .face, detail: "Pour lire son carnet"),
        RefugeItem(id: "tableau", title: "Tableau de montagne", price: 220, slot: .room, detail: "Au-dessus de sa tête"),
        RefugeItem(id: "bonnet", title: "Bonnet à pompon", price: 250, slot: .head, detail: "Bien au chaud"),
        RefugeItem(id: "coucou", title: "Coucou suisse", price: 350, slot: .room, detail: "Il sonne les heures, en silence"),
        RefugeItem(id: "poele", title: "Poêle à bois", price: 600, slot: .room, detail: "Une flamme qui danse"),
        RefugeItem(id: "fleurs", title: "Couronne de fleurs", price: 200, slot: .head, season: .printemps, detail: "Le grand ménage de printemps"),
        RefugeItem(id: "paille", title: "Chapeau de paille", price: 250, slot: .head, season: .ete, detail: "Chamois en vacances"),
        RefugeItem(id: "citrouille", title: "Citrouille", price: 150, slot: .room, season: .automne, detail: "La nuit des fantômes"),
        RefugeItem(id: "luge", title: "Luge", price: 300, slot: .room, season: .hiver, detail: "Pour les pentes enneigées"),
        RefugeItem(id: "guirlande", title: "Guirlande", price: 200, slot: .room, season: .hiver, detail: "Pour finir l'année"),
        RefugeItem(id: "raye", title: "Papier peint rayé", price: 200, slot: .wall, detail: "Des rayures douces"),
        RefugeItem(id: "fleuri", title: "Papier peint fleuri", price: 250, slot: .wall, detail: "Des fleurs partout"),
        RefugeItem(id: "rondins", title: "Mur en rondins", price: 300, slot: .wall, detail: "Comme un vrai chalet"),
        RefugeItem(id: "pierre", title: "Mur de pierre", price: 350, slot: .wall, detail: "Solide et frais"),
        RefugeItem(id: "moquette", title: "Moquette moelleuse", price: 200, slot: .floor, detail: "Douce sous les sabots"),
        RefugeItem(id: "tomettes", title: "Tomettes", price: 250, slot: .floor, detail: "En terre cuite"),
        RefugeItem(id: "dallage", title: "Dallage de pierre", price: 300, slot: .floor, detail: "Pour les grands froids"),
        RefugeItem(id: "hublot", title: "Fenêtre ronde", price: 200, slot: .window, detail: "Comme un hublot"),
        RefugeItem(id: "arche", title: "Fenêtre en arche", price: 250, slot: .window, detail: "Le haut arrondi"),
        RefugeItem(id: "vitrail", title: "Vitrail", price: 400, slot: .window, detail: "Des carreaux de couleur"),
        RefugeItem(id: "lanterne", title: "Lanterne", price: 150, slot: .lamp, detail: "Une flamme dans sa cage"),
        RefugeItem(id: "lampion", title: "Lampion", price: 180, slot: .lamp, detail: "En papier rose"),
        RefugeItem(id: "lustre", title: "Lustre à bougies", price: 300, slot: .lamp, detail: "Trois petites flammes"),
        RefugeItem(id: "cadre", title: "Portrait encadré", price: 120, slot: .room, detail: "Son portrait au mur"),
        RefugeItem(id: "bouquet", title: "Bouquet de printemps", price: 120, slot: .room, season: .printemps, detail: "Le grand ménage de printemps"),
        RefugeItem(id: "toile", title: "Toile d'araignée", price: 80, slot: .room, season: .automne, detail: "Dans un coin, pour Halloween"),
        RefugeItem(id: "chauves-souris", title: "Chauves-souris", price: 120, slot: .room, season: .automne, detail: "Elles volent sous le plafond"),
        RefugeItem(id: "fantome", title: "Petit fantôme", price: 180, slot: .room, season: .automne, detail: "Il flotte, gentiment"),
        RefugeItem(id: "sapin", title: "Sapin de Noël", price: 400, slot: .room, season: .hiver, detail: "Ses boules et son étoile"),
        RefugeItem(id: "chaussettes", title: "Chaussettes de Noël", price: 100, slot: .room, season: .hiver, detail: "Pendues à l'étagère"),
    ]

    static func item(_ id: String) -> RefugeItem? { items.first { $0.id == id } }

    /// On the stall now: everything but the things of other seasons (unless already bought).
    static func available(_ item: RefugeItem, on date: Date, owned: Set<String>, calendar: Calendar = .current) -> Bool {
        owned.contains(item.id) || item.season == nil || item.season == RefugeSeason.of(date, calendar: calendar)
    }

    /// Buys a thing or a coat with the blueberries of the basket. Returns false if it is too dear or already owned.
    @discardableResult
    static func buy(_ s: inout RefugeState, id: String, price: Int, now: Date) -> Bool {
        guard s.welcomed, price > 0, !s.owned.contains(id), s.basket >= price else { return false }
        s.basket -= price
        s.owned.insert(id)
        let name = item(id)?.title ?? RefugeCoat(rawValue: String(id.dropFirst(5)))?.title ?? id
        RefugeRules.note(&s, kind: "shop", text: "Merci pour « \(name) » ! Je l'adore.", now: now)
        return true
    }

    /// Puts on (or takes off) a thing it owns: one on its head, one on its face, any number in its room.
    static func toggleWorn(_ s: inout RefugeState, id: String) {
        guard s.owned.contains(id), let item = item(id) else { return }
        if s.worn.contains(id) {
            s.worn.remove(id)
            return
        }
        if item.slot != .room {
            for other in items where other.slot == item.slot { s.worn.remove(other.id) }
        }
        s.worn.insert(id)
    }

    // MARK: Coats and seasons

    /// Its winter coat, like a real chamois: from mid-November to the end of March.
    static func winterCoat(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.month, .day], from: date)
        let md = (c.month ?? 1) * 100 + (c.day ?? 1)
        return md >= 1115 || md <= 331
    }

    /// The coat it wears now: the chosen one, else the season's (the Chamois d'or keeps its gold).
    static func coat(_ s: RefugeState, on date: Date, calendar: Calendar = .current) -> RefugeCoat {
        if let chosen = s.coat.flatMap(RefugeCoat.init(rawValue:)), s.owned.contains(chosen.shopID) { return chosen }
        if s.stage == .gold { return .caramel }
        return s.seasons && winterCoat(date, calendar: calendar) ? .hiver : .caramel
    }

    /// The meetings of the day.
    static func events(on date: Date, born: Date?, calendar: Calendar = .current) -> [RefugeEvent] {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let md = (c.month ?? 1) * 100 + (c.day ?? 1)
        var out: [RefugeEvent] = []
        if (320...430).contains(md) { out.append(.menage) }
        if (701...831).contains(md) { out.append(.vacances) }
        if md >= 1025 && md <= 1102 { out.append(.fantomes) }
        if md >= 1215 { out.append(.finAnnee) }
        if let born {
            let b = calendar.dateComponents([.year, .month, .day], from: born)
            if b.month == c.month, b.day == c.day, (c.year ?? 0) > (b.year ?? 0) { out.append(.anniversaire) }
        }
        return out
    }

    // MARK: Path

    /// The path of the tools used most these last 30 days (days each page was opened); the Fée du logis on a tie.
    static func suggestedPath(days: [Page: Int]) -> RefugePath {
        let order: [RefugePath] = [.fee, .gardien, .guide, .artiste]
        return order.max { a, b in
            let sa = a.pages.reduce(0) { $0 + (days[$1] ?? 0) }, sb = b.pages.reduce(0) { $0 + (days[$1] ?? 0) }
            // On a tie, the earlier one of `order` wins.
            return sa < sb || (sa == sb && order.firstIndex(of: a)! > order.firstIndex(of: b)!)
        } ?? .fee
    }

    /// It may change path once per season.
    static func canChangePath(_ s: RefugeState, on date: Date, calendar: Calendar = .current) -> Bool {
        s.path != nil && s.pathSeason != RefugeSeason.key(date, calendar: calendar)
    }

    // MARK: The daily round

    static func task(_ id: String) -> RefugeTask {
        switch id {
        case "feed": return RefugeTask(id: id, title: "Lui donner des myrtilles", page: .refuge)
        case "scan": return RefugeTask(id: id, title: "Lancer l'analyse intelligente", page: .dashboard)
        case "clean": return RefugeTask(id: id, title: "Faire un nettoyage", page: .cleanup)
        case "update": return RefugeTask(id: id, title: "Mettre une app à jour", page: .updates)
        case "fix": return RefugeTask(id: id, title: "Corriger un point de sécurité", page: .protection)
        case "tool": return RefugeTask(id: id, title: "Lancer une commande depuis le lanceur", page: .hotkeys)
        default:
            if let page = discoveryPage(id) {
                return RefugeTask(id: id, title: "Découvrir \(RefugeRules.room(page)?.name ?? page.title) (\(page.title))", page: page)
            }
            // A mission saved before its page went away: `repairRound` swaps it unless it was already done.
            return RefugeTask(id: id, title: id.hasPrefix("discover:") ? "Découvrir une nouvelle pièce" : "Une petite mission", page: nil)
        }
    }

    /// The page a `discover:` mission leads to: a page folded into another (cinema into Multimédia, the launcher into
    /// Raccourcis…) leads to the one that took it in; a page gone for good (YouTube, the translator…), nowhere.
    private static func discoveryPage(_ id: String) -> Page? {
        guard id.hasPrefix("discover:") else { return nil }
        let key = String(id.dropFirst(9))
        return Page(rawValue: key) ?? ToolProfileRules.formerKeys.first { $0.value.contains(key) }?.key
    }

    private static func roundSeed(_ day: String) -> UInt64 {
        day.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
    }

    private static func draw(_ pool: inout [String], _ seed: inout UInt64) -> String {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return pool.remove(at: Int(seed >> 33) % pool.count)
    }

    /// Today's three missions: feeding it, then two drawn (the same all day) from what really makes sense on this Mac.
    static func makeRound(day: String, candidates: [String]) -> RefugeRound {
        var seed = roundSeed(day)
        var pool = Array(Set(candidates.filter { $0 != "feed" })).sorted()
        var picked: [String] = ["feed"]
        while picked.count < 3, !pool.isEmpty { picked.append(draw(&pool, &seed)) }
        return RefugeRound(day: day, tasks: picked)
    }

    /// A round saved before a page went away: each mission that leads nowhere and is not done yet gives way to another of
    /// today's candidates (or leaves the round if there is none), so the round can still be finished. Done ones stay.
    static func repairRound(_ r: RefugeRound, _ s: RefugeState, candidates: [String], now: Date,
                            calendar: Calendar = .current) -> RefugeRound {
        let stale = r.tasks.indices.filter { task(r.tasks[$0]).page == nil && !done(r.tasks[$0], s, now: now, calendar: calendar) }
        guard !r.paid, !stale.isEmpty else { return r }
        var pool = Array(Set(candidates.filter { $0 != "feed" && task($0).page != nil && !r.tasks.contains($0) })).sorted()
        var seed = roundSeed(r.day + ":repair")
        var out = r
        var dropped: [Int] = []
        for i in stale {
            if pool.isEmpty { dropped.append(i) } else { out.tasks[i] = draw(&pool, &seed) }
        }
        for i in dropped.reversed() { out.tasks.remove(at: i) }
        return out
    }

    /// Whether a mission is done today.
    static func done(_ id: String, _ s: RefugeState, now: Date, calendar: Calendar = .current) -> Bool {
        let today = s.day == RefugeRules.dayKey(now, calendar: calendar)
        func paid(_ source: RefugeSource) -> Bool { today && (s.paidToday[source.rawValue] ?? 0) > 0 }
        switch id {
        case "feed": return s.lastFed.map { calendar.isDate($0, inSameDayAs: now) } ?? false
        case "scan": return paid(.scan)
        case "clean": return paid(.cleaning)
        case "update": return paid(.update)
        case "fix": return paid(.fix)
        case "tool": return paid(.tool)
        default:
            guard id.hasPrefix("discover:") else { return false }
            // Its own room lit, or the room of the page that took it in.
            return s.claimed.contains("page:" + id.dropFirst(9)) || discoveryPage(id).map { s.claimed.contains("page:" + $0.rawValue) } ?? false
        }
    }

    /// How far along the trail it is.
    static func progress(_ r: RefugeRound, _ s: RefugeState, now: Date, calendar: Calendar = .current) -> RefugeRoundProgress {
        RefugeRoundProgress(r.tasks.map { done($0, s, now: now, calendar: calendar) })
    }

    /// Pays today's round once all its missions are done, whatever their order: once a day, never twice.
    static func payRound(_ s: inout RefugeState, now: Date, calendar: Calendar = .current) -> Int {
        guard s.welcomed, let r = s.round, r.day == RefugeRules.dayKey(now, calendar: calendar), !r.paid,
              progress(r, s, now: now, calendar: calendar).finished else { return 0 }
        s.round?.paid = true
        return RefugeRules.earn(&s, .round, key: "round:" + r.day, now: now, calendar: calendar)
    }

    // MARK: Self-test

    static func selfTest() -> [String] {
        var f: [String] = []
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? Date() }

        // Scarves: one per thousand from 3 500.
        if RefugeScarf.at(4499) != nil || RefugeScarf.at(4500) != .bronze || RefugeScarf.at(12_899) != .rubis || RefugeScarf.at(99_999) != .laine {
            f.append("Refuge : paliers d'écharpe mal calculés")
        }
        if RefugeScarf.won(level: 6) != [.bronze, .argent, .or] || RefugeScarf.won(level: 12).count != 8 || !RefugeScarf.won(level: 3).isEmpty {
            f.append("Refuge : écharpes gagnées mal listées")
        }

        // Seasons and meetings.
        if RefugeSeason.of(date(2026, 3, 19), calendar: cal) != .hiver || RefugeSeason.of(date(2026, 3, 20), calendar: cal) != .printemps
            || RefugeSeason.of(date(2026, 10, 20), calendar: cal) != .automne || RefugeSeason.of(date(2026, 12, 25), calendar: cal) != .hiver {
            f.append("Refuge : saisons mal bornées")
        }
        if RefugeSeason.key(date(2027, 2, 1), calendar: cal) != "2026-hiver" || RefugeSeason.key(date(2026, 12, 22), calendar: cal) != "2026-hiver" {
            f.append("Refuge : l'hiver ne court pas sur deux années")
        }
        if !winterCoat(date(2026, 1, 10), calendar: cal) || winterCoat(date(2026, 10, 20), calendar: cal) || !winterCoat(date(2026, 11, 20), calendar: cal) {
            f.append("Refuge : pelage d'hiver mal daté")
        }
        if events(on: date(2026, 10, 31), born: nil, calendar: cal) != [.fantomes] { f.append("Refuge : Halloween manquant") }
        if !events(on: date(2027, 10, 20), born: date(2026, 10, 20), calendar: cal).contains(.anniversaire)
            || events(on: date(2026, 10, 20), born: date(2026, 10, 20), calendar: cal).contains(.anniversaire) {
            f.append("Refuge : anniversaire mal fêté")
        }

        // Coats.
        var s = RefugeState()
        RefugeRules.adopt(&s, name: "", known: [], returning: false, now: date(2026, 10, 20), calendar: cal)
        if coat(s, on: date(2026, 12, 1), calendar: cal) != .hiver || coat(s, on: date(2026, 7, 1), calendar: cal) != .caramel { f.append("Refuge : pelage des saisons faux") }
        s.seasons = false
        if coat(s, on: date(2026, 12, 1), calendar: cal) != .caramel { f.append("Refuge : saisons désactivées ignorées") }
        s.coat = "neige"
        if coat(s, on: date(2026, 7, 1), calendar: cal) != .caramel { f.append("Refuge : un pelage pas acheté se porte") }

        // The shop.
        s.basket = 700
        if buy(&s, id: RefugeCoat.neige.shopID, price: 1000, now: Date()) { f.append("Refuge : achat plus cher que le panier") }
        if !buy(&s, id: RefugeCoat.chocolat.shopID, price: 600, now: Date()) || s.basket != 100 { f.append("Refuge : achat mal payé") }
        if buy(&s, id: RefugeCoat.chocolat.shopID, price: 600, now: Date()) { f.append("Refuge : objet acheté deux fois") }
        s.coat = "chocolat"
        if coat(s, on: date(2026, 12, 1), calendar: cal) != .chocolat { f.append("Refuge : le pelage acheté ne se porte pas") }
        s.owned.formUnion(["bonnet", "paille", "poele", "coucou"])
        toggleWorn(&s, id: "bonnet")
        toggleWorn(&s, id: "paille")
        toggleWorn(&s, id: "poele")
        toggleWorn(&s, id: "coucou")
        if s.worn != ["paille", "poele", "coucou"] { f.append("Refuge : deux chapeaux à la fois (\(s.worn.sorted()))") }
        s.owned.formUnion(["raye", "pierre"])
        toggleWorn(&s, id: "raye")
        toggleWorn(&s, id: "pierre")
        if s.worn.contains("raye") || !s.worn.contains("pierre") { f.append("Refuge : deux murs à la fois") }
        toggleWorn(&s, id: "lunettes")
        if s.worn.contains("lunettes") { f.append("Refuge : un objet pas acheté se porte") }
        let luge = item("luge")!
        if available(luge, on: date(2026, 7, 1), owned: [], calendar: cal) || !available(luge, on: date(2026, 12, 25), owned: [], calendar: cal)
            || !available(luge, on: date(2026, 7, 1), owned: ["luge"], calendar: cal) {
            f.append("Refuge : étal de saison faux")
        }
        if Set(items.map(\.id)).count != items.count { f.append("Refuge : deux objets du même nom") }

        // Path.
        if suggestedPath(days: [.protection: 5, .wheel: 3]) != .gardien || suggestedPath(days: [:]) != .fee
            || suggestedPath(days: [.hotkeys: 2, .cleanup: 2]) != .fee || suggestedPath(days: [.media: 9]) != .artiste {
            f.append("Refuge : voie mal choisie")
        }
        let all = RefugePath.allCases.flatMap(\.pages)
        if Set(all).count != all.count { f.append("Refuge : une page dans deux voies") }
        s.path = "fee"
        s.pathSeason = RefugeSeason.key(date(2026, 10, 20), calendar: cal)
        if canChangePath(s, on: date(2026, 11, 1), calendar: cal) || !canChangePath(s, on: date(2027, 1, 5), calendar: cal) { f.append("Refuge : changement de voie mal limité") }

        // The round.
        let r = makeRound(day: "2026-10-20", candidates: ["scan", "update", "clean", "discover:media", "feed"])
        if r.tasks.count != 3 || r.tasks.first != "feed" || Set(r.tasks).count != 3 { f.append("Refuge : tournée mal tirée \(r.tasks)") }
        if makeRound(day: "2026-10-20", candidates: ["scan", "update", "clean", "discover:media"]) != r { f.append("Refuge : la tournée change dans la journée") }
        if makeRound(day: "2026-10-20", candidates: []).tasks != ["feed"] { f.append("Refuge : tournée vide mal tirée") }
        var t = RefugeState()
        let now = date(2026, 10, 20)
        RefugeRules.adopt(&t, name: "", known: [], returning: false, now: now, calendar: cal)
        if done("feed", t, now: now, calendar: cal) || done("scan", t, now: now, calendar: cal) { f.append("Refuge : mission faite sans rien faire") }
        _ = RefugeRules.feed(&t, 1, now: now, calendar: cal)
        _ = RefugeRules.earn(&t, .scan, now: now, calendar: cal)
        if !done("feed", t, now: now, calendar: cal) || !done("scan", t, now: now, calendar: cal) { f.append("Refuge : mission faite non reconnue") }
        if done("feed", t, now: date(2026, 10, 21), calendar: cal) { f.append("Refuge : la mission d'hier compte aujourd'hui") }
        for id in ["feed", "scan", "clean", "update", "fix", "tool", "discover:media"] where task(id).page == nil {
            f.append("Refuge : mission \(id) sans page")
        }

        // The trail moves one step per mission done, whatever their order.
        var o = RefugeState()
        RefugeRules.adopt(&o, name: "", known: [.dashboard], returning: false, now: now, calendar: cal)
        o.round = RefugeRound(day: RefugeRules.dayKey(now, calendar: cal), tasks: ["feed", "scan", "discover:media"])
        func at(_ s: RefugeState) -> RefugeRoundProgress { progress(s.round!, s, now: now, calendar: cal) }
        if at(o).steps != 0 || at(o).planted(0) || at(o).finished { f.append("Refuge : la tournée avance sans rien faire") }
        _ = RefugeRules.earn(&o, .discovery, key: "page:media", now: now, calendar: cal)
        if at(o).steps != 1 || !at(o).planted(0) || at(o).planted(1) || at(o).planted(2) {
            f.append("Refuge : la dernière mission faite d'abord n'avance pas d'une étape (\(at(o).steps))")
        }
        if payRound(&o, now: now, calendar: cal) != 0 || o.round?.paid == true { f.append("Refuge : tournée payée avant la fin") }
        _ = RefugeRules.earn(&o, .scan, now: now, calendar: cal)
        if at(o).steps != 2 || !at(o).planted(1) || at(o).planted(2) || at(o).finished {
            f.append("Refuge : deux missions faites dans le désordre ne font pas deux étapes")
        }
        _ = RefugeRules.feed(&o, 1, now: now, calendar: cal)
        let basket = o.basket
        if !at(o).finished || at(o).steps != 3 { f.append("Refuge : tournée finie dans le désordre non reconnue") }
        if payRound(&o, now: now, calendar: cal) != RefugeSource.round.amount || o.basket != basket + RefugeSource.round.amount || o.round?.paid != true {
            f.append("Refuge : tournée finie dans le désordre non payée")
        }
        if payRound(&o, now: now, calendar: cal) != 0 { f.append("Refuge : tournée payée deux fois") }
        o.round?.paid = false
        if payRound(&o, now: now, calendar: cal) != 0 || o.basket != basket + RefugeSource.round.amount { f.append("Refuge : tournée repayée après coup") }
        if RefugeRoundProgress([]).finished { f.append("Refuge : une tournée vide est finie") }

        // A round saved before the redesign: a page folded into another still leads somewhere; a page gone for good
        // gives way to another mission, unless it was done.
        for key in ["cinema", "adblock", "launcher", "clipboard", "windows", "converter", "fillsign"] where task("discover:" + key).page == nil {
            f.append("Refuge : l'ancienne pièce \(key) ne mène plus nulle part")
        }
        var old = RefugeState()
        RefugeRules.adopt(&old, name: "", known: [.dashboard], returning: false, now: now, calendar: cal)
        if done("discover:cinema", old, now: now, calendar: cal) { f.append("Refuge : ancienne pièce faite sans y aller") }
        _ = RefugeRules.earn(&old, .discovery, key: "page:media", now: now, calendar: cal)
        if !done("discover:cinema", old, now: now, calendar: cal) || task("discover:cinema").page != .media {
            f.append("Refuge : Multimédia ne fait pas la mission du Ciné-club d'avant")
        }
        let day = RefugeRules.dayKey(now, calendar: cal)
        let stale = RefugeRound(day: day, tasks: ["feed", "discover:youtube", "scan"])
        let fixed = repairRound(stale, old, candidates: ["scan", "tool", "discover:toolbox"], now: now, calendar: cal)
        if fixed.tasks.count != 3 || fixed.tasks[0] != "feed" || fixed.tasks[2] != "scan" || Set(fixed.tasks).count != 3
            || fixed.tasks.contains(where: { task($0).page == nil }) {
            f.append("Refuge : mission d'une page disparue mal remplacée \(fixed.tasks)")
        }
        if repairRound(fixed, old, candidates: ["tool"], now: now, calendar: cal) != fixed { f.append("Refuge : une tournée saine réparée") }
        if repairRound(stale, old, candidates: ["scan"], now: now, calendar: cal).tasks != ["feed", "scan"] {
            f.append("Refuge : mission disparue sans remplaçante gardée")
        }
        old.claimed.insert("page:youtube")
        if repairRound(stale, old, candidates: ["tool"], now: now, calendar: cal) != stale { f.append("Refuge : mission disparue mais faite remplacée") }
        if task("discover:youtube").title.contains("youtube") || task("bidule").title == "bidule" { f.append("Refuge : identifiant brut montré") }
        return f
    }
}
