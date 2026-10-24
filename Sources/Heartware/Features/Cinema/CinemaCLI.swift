import Foundation

/// `--cinema-check "<titre>" [--kind film|serie] [--region FR] [--pick N]`: the module against the real TMDB and Wikidata
/// (search, card, platforms and where each click goes), with the key of the TMDB_KEY variable, never printed.
enum CinemaCLI {
    static func run() async {
        guard !DemoData.isEnabled else {
            print(HTTP.Failure.demo.localizedDescription)
            return
        }
        guard let title = Entry.value(after: "--cinema-check"), title.count >= 2 else {
            print("Usage : --cinema-check \"titre\" [--kind film|serie] [--region FR] [--pick N]")
            return
        }
        guard let key = ProcessInfo.processInfo.environment["TMDB_KEY"], CinemaTMDB.keyKind(key) != nil else {
            print("✗ Mets une clé TMDB (clé d'API ou jeton) dans la variable TMDB_KEY.")
            return
        }
        let kindArg = Entry.value(after: "--kind").map(Fuzzy.fold)
        let kind: CinemaKind? = kindArg?.hasPrefix("film") == true ? .movie : (kindArg?.hasPrefix("serie") == true ? .tv : nil)
        let region = Entry.value(after: "--region")?.uppercased() ?? "FR"
        do {
            let hits = try await CinemaTMDB.search(title, kind: kind, key: key, language: "fr-FR")
            print("Recherche « \(title) » : \(hits.count) titre(s)")
            for (i, h) in hits.prefix(8).enumerated() {
                print("  \(i). \(h.title) · \(h.line)" + (h.originalTitle.map { " · \($0)" } ?? "") + (h.posterPath == nil ? " · sans affiche" : ""))
            }
            let pick = Int(Entry.value(after: "--pick") ?? "0") ?? 0
            guard hits.indices.contains(pick) else { return }
            var t = try await CinemaTMDB.details(hits[pick], key: key, language: "fr-FR", region: region)
            t.direct = await CinemaWikidata.direct(for: t)
            print("Fiche : \(t.hit.title) · \(CinemaFormat.facts(t))")
            print("  \(t.hit.kind == .movie ? "de" : "créée par") : \(t.makers.joined(separator: ", ")) · avec : \(t.cast.prefix(3).joined(separator: ", "))")
            print("  résumé : \(t.hit.overview.count) caractères · bande-annonce : \(t.trailer.map { "youtube \($0)" } ?? "aucune")")
            print("Où regarder \(CinemaRegion.inName(region)) :")
            if t.offers.isEmpty { print("  aucune offre · page TMDB \(t.watchPage ?? "-")") }
            for o in t.offers {
                let d = CinemaOffers.destination(o, in: t)
                print("  \(o.kind.label) · \(o.name) → \(o.displayName) · \(d.via) \(d.url)" + (d.adFreePlayer ? " · lecteur sans pub" : ""))
            }
            print("Wikidata : " + (t.direct.isEmpty ? "aucun lien direct" : t.direct.map { "\($0.key) \($0.value)" }.sorted().joined(separator: " · ")))
        } catch {
            print("✗ \(error.localizedDescription)")
        }
    }
}
