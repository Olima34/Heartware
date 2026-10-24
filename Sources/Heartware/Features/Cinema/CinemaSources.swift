import Foundation
import ImageIO

/// The Movie Database: search, a title's card and where it can be watched (TMDB's availability data comes from JustWatch).
/// Free for personal use with the user's own key; a sold version needs TMDB's commercial agreement.
enum CinemaTMDB {
    static let keyAccount = "tmdb"
    static let signupURL = "https://www.themoviedb.org/settings/api"
    private static let base = "https://api.themoviedb.org/3"

    enum KeyKind: Equatable { case v3, v4 }

    /// A v3 key (32 hexadecimal characters) goes in the address, a v4 read token (a JWT) in a header.
    static func keyKind(_ raw: String) -> KeyKind? {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.count == 32, k.allSatisfy(\.isHexDigit) { return .v3 }
        if k.hasPrefix("eyJ"), k.count > 100, k.split(separator: ".").count == 3,
           k.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) { return .v4 }
        return nil
    }

    enum Failure: LocalizedError {
        case noKey, badKey, network(String)

        var errorDescription: String? {
            switch self {
            case .noKey: return "Ajoute ta clé TMDB pour chercher des films."
            case .badKey: return "TMDB refuse la clé : vérifie-la dans Films et séries."
            case .network(let m): return m
            }
        }
    }

    private static func request(_ path: String, _ items: [URLQueryItem], key: String) async throws -> [String: Any] {
        guard let kind = keyKind(key) else { throw Failure.badKey }
        var comps = URLComponents(string: base + path)!
        comps.queryItems = items + (kind == .v3 ? [URLQueryItem(name: "api_key", value: key)] : [])
        guard let url = comps.url else { throw Failure.network("Adresse invalide.") }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if kind == .v4 { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await HTTP.sendKeepingErrors(req) } catch { throw Failure.network("TMDB ne répond pas : \(error.localizedDescription)") }
        if response.statusCode == 401 { throw Failure.badKey }
        guard (200..<300).contains(response.statusCode) else { throw Failure.network("TMDB a répondu avec le code \(response.statusCode).") }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.network("Réponse illisible de TMDB.") }
        return json
    }

    /// The key works (a v3 key or a v4 token).
    static func check(key: String) async throws {
        _ = try await request("/authentication", [], key: key)
    }

    static func search(_ title: String, kind: CinemaKind?, key: String, language: String) async throws -> [CinemaHit] {
        let path = kind.map { "/search/\($0.rawValue)" } ?? "/search/multi"
        let json = try await request(path, [URLQueryItem(name: "query", value: title), URLQueryItem(name: "language", value: language),
                                            URLQueryItem(name: "include_adult", value: "false")], key: key)
        return parseSearch(json, kind: kind)
    }

    static func details(_ hit: CinemaHit, key: String, language: String, region: String) async throws -> CinemaTitle {
        let json = try await request("/\(hit.kind.rawValue)/\(hit.tmdbID)",
                                     [URLQueryItem(name: "language", value: language),
                                      URLQueryItem(name: "append_to_response", value: "credits,videos,watch/providers"),
                                      URLQueryItem(name: "include_video_language", value: "fr,en,null")], key: key)
        return parseDetails(json, hit: hit, region: region)
    }

    // MARK: Pictures

    static func imageURL(_ path: String, width: Int) -> URL? {
        guard path.hasPrefix("/"), path.count < 120, !path.contains("..") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w\(width)\(path)")
    }

    static func image(_ path: String, width: Int) async -> CGImage? {
        guard let url = imageURL(path, width: width), let (data, _) = try? await HTTP.get(url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Parsing (pure, checked by the self-tests)

    static func parseSearch(_ json: [String: Any], kind: CinemaKind?) -> [CinemaHit] {
        let results = json["results"] as? [[String: Any]] ?? []
        return results.compactMap { r in
            let k: CinemaKind
            if let kind { k = kind } else {
                guard let type = r["media_type"] as? String, let parsed = CinemaKind(rawValue: type) else { return nil }
                k = parsed
            }
            return parseHit(r, kind: k)
        }
    }

    static func parseHit(_ r: [String: Any], kind: CinemaKind) -> CinemaHit? {
        guard let id = r["id"] as? Int else { return nil }
        let title = (r[kind == .movie ? "title" : "name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !title.isEmpty else { return nil }
        let original = (r[kind == .movie ? "original_title" : "original_name"] as? String).flatMap { $0 == title || $0.isEmpty ? nil : $0 }
        let date = r[kind == .movie ? "release_date" : "first_air_date"] as? String ?? ""
        let year = date.count >= 4 ? Int(date.prefix(4)) : nil
        let rating = (r["vote_average"] as? Double) ?? (r["vote_average"] as? Int).map(Double.init)
        return CinemaHit(kind: kind, tmdbID: id, title: title, originalTitle: original, year: year,
                         overview: (r["overview"] as? String) ?? "", posterPath: r["poster_path"] as? String,
                         rating: rating.flatMap { $0 > 0 ? $0 : nil }, votes: r["vote_count"] as? Int ?? 0)
    }

    static func parseDetails(_ json: [String: Any], hit fallback: CinemaHit, region: String) -> CinemaTitle {
        var hit = parseHit(json, kind: fallback.kind) ?? fallback
        if hit.overview.isEmpty { hit.overview = fallback.overview }
        var t = CinemaTitle(hit: hit)
        t.region = region
        t.tagline = (json["tagline"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        t.genres = (json["genres"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        if fallback.kind == .movie {
            t.runtime = (json["runtime"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        } else {
            t.runtime = (json["episode_run_time"] as? [Int])?.first
            t.seasons = json["number_of_seasons"] as? Int
            t.episodes = json["number_of_episodes"] as? Int
        }
        let credits = json["credits"] as? [String: Any] ?? [:]
        if fallback.kind == .movie {
            t.makers = (credits["crew"] as? [[String: Any]] ?? []).filter { $0["job"] as? String == "Director" }.compactMap { $0["name"] as? String }
        } else {
            t.makers = (json["created_by"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        t.makers = Array(unique(t.makers).prefix(3))
        t.cast = Array((credits["cast"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.prefix(5))
        t.trailer = trailer(json["videos"] as? [String: Any])
        let providers = (json["watch/providers"] as? [String: Any])?["results"] as? [String: Any]
        let local = providers?[region] as? [String: Any] ?? [:]
        t.watchPage = local["link"] as? String
        var offers: [CinemaOffer] = []
        for kind in CinemaOfferKind.allCases {
            for p in local[kind.tmdbKey] as? [[String: Any]] ?? [] {
                guard let id = p["provider_id"] as? Int, let name = p["provider_name"] as? String else { continue }
                offers.append(CinemaOffer(kind: kind, providerID: id, name: name, logoPath: p["logo_path"] as? String,
                                          priority: p["display_priority"] as? Int ?? 999))
            }
        }
        t.offers = CinemaOffers.merged(CinemaOffers.sorted(offers))
        return t
    }

    /// The official trailer on YouTube, in French when there is one.
    static func trailer(_ videos: [String: Any]?) -> String? {
        let list = (videos?["results"] as? [[String: Any]] ?? []).filter {
            $0["site"] as? String == "YouTube" && ($0["key"] as? String).map(YouTubeLink.isVideoID) == true
        }
        func rank(_ v: [String: Any]) -> Int {
            var r = 0
            if v["type"] as? String == "Trailer" { r += 4 } else if v["type"] as? String == "Teaser" { r += 2 }
            if v["iso_639_1"] as? String == "fr" { r += 3 }
            if v["official"] as? Bool == true { r += 1 }
            return r
        }
        return list.max { rank($0) < rank($1) }?["key"] as? String
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

/// Wikidata (free, no key): the title's own page on Netflix, Disney+, Apple TV or Crunchyroll,
/// found from its TMDB number. Asked only when one of these platforms has the title.
enum CinemaWikidata {
    private static let api = "https://www.wikidata.org/w/api.php"

    static func direct(for title: CinemaTitle) async -> [String: String] {
        let wanted = wantedPlatforms(title)
        guard !wanted.isEmpty else { return [:] }
        let tmdbProperty = title.hit.kind == .movie ? "P4947" : "P4983"
        var search = URLComponents(string: api)!
        search.queryItems = [URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
                             URLQueryItem(name: "srsearch", value: "haswbstatement:\(tmdbProperty)=\(title.hit.tmdbID)"),
                             URLQueryItem(name: "srlimit", value: "1"), URLQueryItem(name: "format", value: "json")]
        guard let url = search.url, let (data, _) = try? await HTTP.get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = ((json["query"] as? [String: Any])?["search"] as? [[String: Any]])?.first?["title"] as? String,
              item.range(of: #"^Q\d+$"#, options: .regularExpression) != nil else { return [:] }
        var entity = URLComponents(string: api)!
        entity.queryItems = [URLQueryItem(name: "action", value: "wbgetentities"), URLQueryItem(name: "ids", value: item),
                             URLQueryItem(name: "props", value: "claims"), URLQueryItem(name: "format", value: "json")]
        guard let url2 = entity.url, let (data2, _) = try? await HTTP.get(url2),
              let json2 = try? JSONSerialization.jsonObject(with: data2) as? [String: Any] else { return [:] }
        return parseLinks(json2, item: item, kind: title.hit.kind, region: title.region, platforms: wanted)
    }

    static func wantedPlatforms(_ title: CinemaTitle) -> [CinemaPlatform] {
        var out: [CinemaPlatform] = []
        for o in title.offers {
            guard CinemaPlatform.channel(o.name) == nil, let p = o.platform, p.wikidataProperty(title.hit.kind) != nil, !out.contains(p) else { continue }
            out.append(p)
        }
        return out
    }

    static func parseLinks(_ json: [String: Any], item: String, kind: CinemaKind, region: String, platforms: [CinemaPlatform]) -> [String: String] {
        let claims = ((json["entities"] as? [String: Any])?[item] as? [String: Any])?["claims"] as? [String: Any] ?? [:]
        var out: [String: String] = [:]
        for p in platforms {
            guard let property = p.wikidataProperty(kind),
                  let statements = claims[property] as? [[String: Any]] else { continue }
            // The preferred statement first, never a deprecated one.
            let usable = statements.filter { $0["rank"] as? String != "deprecated" }
                .sorted { ($0["rank"] as? String == "preferred" ? 0 : 1) < ($1["rank"] as? String == "preferred" ? 0 : 1) }
            for s in usable {
                guard let value = ((s["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] as? String,
                      !value.isEmpty, value.count < 120, !value.contains(" "),
                      let url = p.directURL(value, kind: kind, region: region), url.hasPrefix("https://") else { continue }
                out[p.key] = url
                break
            }
        }
        return out
    }
}
