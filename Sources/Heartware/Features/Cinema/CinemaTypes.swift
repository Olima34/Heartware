import Foundation

// Films et séries: a title typed in the launcher or on the page, its card (TMDB) and the platforms where it can be watched
// in the user's country (TMDB's availability data, by JustWatch). Only legal offers are listed: nothing is played or
// downloaded by the app, a click opens the platform.

enum CinemaKind: String, Codable, CaseIterable {
    case movie, tv

    var label: String { self == .movie ? "Film" : "Série" }
    var symbol: String { self == .movie ? "film" : "tv" }
}

/// One title found by a search.
struct CinemaHit: Codable, Equatable, Hashable, Identifiable {
    var kind: CinemaKind
    var tmdbID: Int
    var title: String
    var originalTitle: String?
    var year: Int?
    var overview: String = ""
    var posterPath: String?
    /// TMDB users' mark out of 10, and how many gave one.
    var rating: Double?
    var votes = 0

    var id: String { "\(kind.rawValue)-\(tmdbID)" }

    /// "Film · 2024 · ★ 8,1"
    var line: String {
        var parts = [kind.label]
        if let year { parts.append(String(year)) }
        if let r = rating, votes >= 20 { parts.append("★ " + CinemaFormat.rating(r)) }
        return parts.joined(separator: " · ")
    }

    var tmdbURL: String { "https://www.themoviedb.org/\(kind.rawValue)/\(tmdbID)" }
}

/// How a platform offers the title.
enum CinemaOfferKind: String, Codable, CaseIterable {
    case subscription, free, ads, rent, buy

    var label: String {
        switch self {
        case .subscription: return "Abonnement"
        case .free: return "Gratuit"
        case .ads: return "Gratuit avec pub"
        case .rent: return "Location"
        case .buy: return "Achat"
        }
    }

    /// TMDB's key in `watch/providers`.
    var tmdbKey: String {
        switch self {
        case .subscription: return "flatrate"
        case .free: return "free"
        case .ads: return "ads"
        case .rent: return "rent"
        case .buy: return "buy"
        }
    }
}

/// A platform that has the title, and how.
struct CinemaOffer: Codable, Equatable, Hashable, Identifiable {
    var kind: CinemaOfferKind
    var providerID: Int
    var name: String
    var logoPath: String?
    /// TMDB's order among the platforms of the country (lower first).
    var priority = 999

    var id: String { "\(kind.rawValue)-\(providerID)" }
    var platform: CinemaPlatform? { CinemaPlatform.match(name) }

    /// « Netflix », or for a channel sold inside another platform « France TV via Prime Video ».
    var displayName: String {
        if let c = CinemaPlatform.channel(name) { return "\(c.label) via \(c.host.name)" }
        return platform?.name ?? name.trimmingCharacters(in: .whitespaces)
    }

    /// Two offers are the same when they are the same platform (or the same channel) and kind.
    var mergeKey: String {
        let who = CinemaPlatform.channel(name).map { "channel:" + Fuzzy.fold($0.label) } ?? platform?.key ?? "id\(providerID)"
        return kind.rawValue + "|" + who
    }
}

/// Everything shown about a title.
struct CinemaTitle: Codable, Equatable {
    var hit: CinemaHit
    var tagline: String?
    var genres: [String] = []
    /// Minutes (a film, or an episode of a series).
    var runtime: Int?
    var seasons: Int?
    var episodes: Int?
    /// Director(s) of a film, creator(s) of a series.
    var makers: [String] = []
    var cast: [String] = []
    /// A YouTube video id.
    var trailer: String?
    /// Offers in `region`, best first (see `CinemaOffers.sorted`).
    var offers: [CinemaOffer] = []
    var region = "FR"
    /// TMDB's page of the platforms for this title in `region`: each one links to the title itself (JustWatch).
    var watchPage: String?
    /// Direct addresses of the title on some platforms (platform key → URL), from Wikidata.
    var direct: [String: String] = [:]

    var wikidataChecked = false
}

/// A platform the app knows: how to reach a title on it.
struct CinemaPlatform: Equatable, Hashable, Identifiable {
    var key: String
    var name: String
    /// TMDB provider names that are this platform, folded ("netflix basic with ads" starts with "netflix").
    var prefixes: [String]
    /// Its search page, `%@` for the title (only addresses checked to answer); nil: TMDB's page leads there.
    var search: String?
    /// Wikidata properties giving the title's own page (film, series) and the address they make (`$1`).
    var wikidataMovie: String?
    var wikidataTV: String?
    var directTemplate: String?
    /// Opened in the app's ad-free player (YouTube) instead of the browser.
    var adFreePlayer = false
    /// Its free offers (with or without ads) open in the ad-free player, which knows the site (`AdBlockPlayerSite`).
    var freeInPlayer = false
    /// Proposed in « Tes plateformes ».
    var common = true

    var id: String { key }

    static let all: [CinemaPlatform] = [
        CinemaPlatform(key: "netflix", name: "Netflix", prefixes: ["netflix"], search: "https://www.netflix.com/search?q=%@",
                       wikidataMovie: "P1874", wikidataTV: "P1874", directTemplate: "https://www.netflix.com/title/$1"),
        // Wikidata's Prime Video numbers are those of amazon.com (United States): the search finds the title of the user's country.
        CinemaPlatform(key: "prime", name: "Prime Video", prefixes: ["amazon prime video", "prime video", "amazon video"],
                       search: "https://www.primevideo.com/search?phrase=%@"),
        CinemaPlatform(key: "disney", name: "Disney+", prefixes: ["disney plus", "disney+"], search: nil,
                       wikidataMovie: "P7595", wikidataTV: "P7596", directTemplate: nil),
        // « Canal+ », « Canal+ Séries », « Canal VOD » (its rental store).
        CinemaPlatform(key: "canal", name: "Canal+", prefixes: ["canal", "mycanal", "ocs"], search: nil),
        CinemaPlatform(key: "apple", name: "Apple TV", prefixes: ["apple tv"], search: "https://tv.apple.com/fr/search?term=%@",
                       wikidataMovie: "P9586", wikidataTV: "P9751", directTemplate: nil),
        CinemaPlatform(key: "max", name: "HBO Max", prefixes: ["hbo max", "max"], search: "https://play.hbomax.com/search?q=%@"),
        CinemaPlatform(key: "paramount", name: "Paramount+", prefixes: ["paramount"], search: nil),
        CinemaPlatform(key: "francetv", name: "France.tv", prefixes: ["france tv", "france.tv", "francetv"],
                       search: "https://www.france.tv/recherche/?q=%@", freeInPlayer: true),
        // ARTE's paid store before arte.tv, whose search only finds what is free to watch.
        CinemaPlatform(key: "artevod", name: "ARTE VOD", prefixes: ["arte vod"], search: nil, common: false),
        CinemaPlatform(key: "arte", name: "Arte", prefixes: ["arte"], search: "https://www.arte.tv/fr/search/?q=%@", freeInPlayer: true),
        // TF1+ refuses to play while its ads are blocked: its offers open in the browser.
        CinemaPlatform(key: "tf1", name: "TF1+", prefixes: ["tf1", "tf1+"], search: nil),
        CinemaPlatform(key: "m6", name: "M6+", prefixes: ["m6", "m6+", "6play"], search: "https://www.m6.fr/recherche?q=%@", freeInPlayer: true),
        CinemaPlatform(key: "youtube", name: "YouTube", prefixes: ["youtube"], search: "https://www.youtube.com/results?search_query=%@",
                       adFreePlayer: true),
        CinemaPlatform(key: "googleplay", name: "Google Play", prefixes: ["google play"],
                       search: "https://play.google.com/store/search?q=%@&c=movies", common: false),
        CinemaPlatform(key: "rakuten", name: "Rakuten TV", prefixes: ["rakuten"], search: "https://www.rakuten.tv/fr/search?q=%@", common: false),
        CinemaPlatform(key: "pluto", name: "Pluto TV", prefixes: ["pluto"], search: "https://pluto.tv/fr/search/details/?query=%@",
                       freeInPlayer: true, common: false),
        CinemaPlatform(key: "mubi", name: "MUBI", prefixes: ["mubi"], search: "https://mubi.com/fr/search/films?query=%@"),
        CinemaPlatform(key: "adn", name: "ADN", prefixes: ["animation digital network", "anime digital network", "adn"], search: nil),
        CinemaPlatform(key: "crunchyroll", name: "Crunchyroll", prefixes: ["crunchyroll"], search: "https://www.crunchyroll.com/fr/search?q=%@",
                       wikidataMovie: nil, wikidataTV: "P11330", directTemplate: "https://www.crunchyroll.com/series/$1")
    ]

    static func named(_ key: String) -> CinemaPlatform? { all.first { $0.key == key } }

    /// The platform behind a TMDB provider name, or nil for one the app does not know (it still links through TMDB).
    /// A channel (« MUBI Amazon Channel ») is watched in the platform that sells it.
    static func match(_ providerName: String) -> CinemaPlatform? {
        if let c = channel(providerName) { return c.host }
        let n = Fuzzy.fold(providerName).trimmingCharacters(in: .whitespaces)
        return all.first { p in
            p.prefixes.contains { pre in n == pre || n.hasPrefix(pre + " ") || (pre.count > 4 && n.hasPrefix(pre)) }
        }
    }

    /// « France TV Amazon Channel » → France TV inside Prime Video; « Paramount Plus Apple TV channel » → inside Apple TV.
    static func channel(_ providerName: String) -> (label: String, host: CinemaPlatform)? {
        let n = providerName.trimmingCharacters(in: .whitespaces)
        for (suffix, key) in [(" amazon channel", "prime"), (" apple tv channel", "apple")] where n.lowercased().hasSuffix(suffix) {
            let label = String(n.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if !label.isEmpty, let host = named(key) { return (label, host) }
        }
        return nil
    }

    func wikidataProperty(_ kind: CinemaKind) -> String? { kind == .movie ? wikidataMovie : wikidataTV }

    /// The title's own page from its Wikidata identifier. Disney+ and Apple TV need the kind in the address, Apple TV the
    /// country too (without it, the American store opens).
    func directURL(_ value: String, kind: CinemaKind, region: String = "FR") -> String? {
        let id = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? value
        switch key {
        case "disney": return kind == .movie ? "https://www.disneyplus.com/movies/wd/\(id)" : "https://www.disneyplus.com/series/wp/\(id)"
        case "apple":
            let country = region.count == 2 && region.allSatisfy(\.isLetter) ? region.lowercased() : "fr"
            return "https://tv.apple.com/\(country)/\(kind == .movie ? "movie" : "show")/\(id)"
        default: return directTemplate.map { $0.replacingOccurrences(of: "$1", with: id) }
        }
    }

    /// What may stay as is in a query value (no « & », « + », « = », « # »).
    static let queryValue = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))

    func searchURL(_ title: String) -> String? {
        guard let search, let q = title.addingPercentEncoding(withAllowedCharacters: Self.queryValue) else { return nil }
        return search.replacingOccurrences(of: "%@", with: q)
    }
}

/// Where a click on an offer goes.
struct CinemaDestination: Equatable {
    enum Via: Equatable {
        /// The title's own page on the platform.
        case direct
        /// The platform's search, on the title.
        case search
        /// TMDB's page of the platforms, which links to the title on each one.
        case tmdb
    }

    var url: String
    var via: Via
    var adFreePlayer = false
}

enum CinemaOffers {
    /// What the user can watch first: their own platforms, then included in a subscription, free, with ads, rental, purchase.
    static func sorted(_ offers: [CinemaOffer], mine: Set<String> = []) -> [CinemaOffer] {
        let order: [CinemaOfferKind: Int] = [.subscription: 0, .free: 1, .ads: 2, .rent: 3, .buy: 4]
        return offers.sorted { a, b in
            let ma = a.platform.map { mine.contains($0.key) } ?? false
            let mb = b.platform.map { mine.contains($0.key) } ?? false
            if ma != mb { return ma }
            if a.kind != b.kind { return order[a.kind, default: 9] < order[b.kind, default: 9] }
            return a.priority < b.priority
        }
    }

    /// One offer per platform (or channel) and kind: TMDB lists « Netflix » and « Netflix Standard with Ads » apart.
    static func merged(_ offers: [CinemaOffer]) -> [CinemaOffer] {
        var seen = Set<String>()
        return offers.filter { seen.insert($0.mergeKey).inserted }
    }

    /// The offer ↩ opens: on one of the user's platforms when possible, else the first one listed.
    static func best(_ title: CinemaTitle, mine: Set<String>) -> CinemaOffer? {
        sorted(title.offers, mine: mine).first
    }

    /// TMDB's page always opens in the browser; a platform's own page or search opens in the ad-free player when it is
    /// YouTube, or a free offer of a site the player knows (France.tv, M6+, Arte, Pluto TV; not TF1+).
    static func destination(_ offer: CinemaOffer, in title: CinemaTitle) -> CinemaDestination {
        let p = offer.platform
        let player = p.map { $0.adFreePlayer || ($0.freeInPlayer && (offer.kind == .free || offer.kind == .ads)) } ?? false
        if let p, let url = title.direct[p.key] { return CinemaDestination(url: url, via: .direct, adFreePlayer: player) }
        if let p, let url = p.searchURL(title.hit.title) { return CinemaDestination(url: url, via: .search, adFreePlayer: player) }
        return CinemaDestination(url: title.watchPage ?? title.hit.tmdbURL + "/watch", via: .tmdb)
    }
}

enum CinemaFormat {
    static func rating(_ r: Double) -> String {
        String(format: "%.1f", r).replacingOccurrences(of: ".", with: ",")
    }

    static func runtime(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }

    /// "Film · 2024 · 2 h 46 · Science-fiction, Aventure"
    static func facts(_ t: CinemaTitle) -> String {
        var parts = [t.hit.kind.label]
        if let y = t.hit.year { parts.append(String(y)) }
        if t.hit.kind == .movie, let r = t.runtime, r > 0 { parts.append(runtime(r)) }
        if t.hit.kind == .tv, let s = t.seasons, s > 0 { parts.append(Fmt.plural(s, "saison", "saisons")) }
        if !t.genres.isEmpty { parts.append(t.genres.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// What the launcher hands to the module: « film dune », « série the office », « où regarder la haine ».
enum CinemaQuery {
    static let prefixes = ["ou regarder", "regarder", "films", "film", "series", "serie", "cine", "cinema"]

    /// The title asked for after a prefix, or nil when the text is not for this module.
    static func parse(_ text: String) -> (title: String, kind: CinemaKind?)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let folded = Fuzzy.fold(trimmed)
        for p in prefixes where folded.hasPrefix(p + " ") {
            let title = String(trimmed.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            guard title.count >= 2 else { return nil }
            let kind: CinemaKind? = p.hasPrefix("serie") ? .tv : (p.hasPrefix("film") ? .movie : nil)
            return (title, kind)
        }
        return nil
    }

    /// Worth a « Films et séries » row without prefix: words, not a calculation, an address or a path.
    static func looksLikeTitle(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3, t.count <= 80, t.contains(where: \.isLetter) else { return false }
        if t.hasPrefix("/") || t.hasPrefix("~") || t.hasPrefix(":") || t.contains("://") || t.contains("@") { return false }
        if t.range(of: #"^[\d\s+\-*/×÷^().,%=]+$"#, options: .regularExpression) != nil { return false }
        return true
    }

    /// The key of a search: same text, any case or accent.
    static func key(_ title: String, kind: CinemaKind?) -> String {
        (kind?.rawValue ?? "all") + "|" + Fuzzy.fold(title).trimmingCharacters(in: .whitespaces)
    }
}
