import Foundation

/// `--selftest`: the pure parts (prefixes, keys, TMDB and Wikidata answers, platforms, links).
enum CinemaChecks {
    static func run() -> [String] {
        var f: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { f.append(what) } }

        // The launcher's prefixes.
        expect(CinemaQuery.parse("film Dune")?.title == "Dune" && CinemaQuery.parse("film Dune")?.kind == .movie, "préfixe : film")
        expect(CinemaQuery.parse("Série  The Office")?.kind == .tv && CinemaQuery.parse("Série  The Office")?.title == "The Office", "préfixe : série")
        expect(CinemaQuery.parse("où regarder la haine")?.title == "la haine" && CinemaQuery.parse("où regarder la haine")?.kind == nil, "préfixe : où regarder")
        expect(CinemaQuery.parse("filmographie") == nil && CinemaQuery.parse("film a") == nil && CinemaQuery.parse("dune") == nil, "préfixe : faux positifs")
        expect(CinemaQuery.looksLikeTitle("le comte de monte cristo") && !CinemaQuery.looksLikeTitle("12*7") && !CinemaQuery.looksLikeTitle("~/Documents")
               && !CinemaQuery.looksLikeTitle("https://exemple.fr") && !CinemaQuery.looksLikeTitle("ab"), "texte à chercher")
        expect(CinemaQuery.key("Amélie", kind: nil) == CinemaQuery.key("amelie ", kind: nil), "clé de recherche sans accents")

        // Keys.
        expect(CinemaTMDB.keyKind("0123456789abcdef0123456789ABCDEF") == .v3, "clé v3")
        expect(CinemaTMDB.keyKind("eyJ" + String(repeating: "a", count: 60) + "." + String(repeating: "b", count: 60) + ".c-_d") == .v4, "jeton v4")
        expect(CinemaTMDB.keyKind("sk-ant-123") == nil && CinemaTMDB.keyKind("0123456789abcdef0123456789abcdeg") == nil, "clé refusée")
        expect(CinemaTMDB.imageURL("/abc.jpg", width: 185)?.absoluteString == "https://image.tmdb.org/t/p/w185/abc.jpg"
               && CinemaTMDB.imageURL("../etc", width: 92) == nil && CinemaTMDB.imageURL("/a/../b.jpg", width: 92) == nil, "adresse d'image")

        // A search: people are left out, the year is read, the original title only when it differs.
        let hits = CinemaTMDB.parseSearch(json(searchSample), kind: nil)
        expect(hits.count == 2, "recherche : \(hits.count) titres au lieu de 2")
        expect(hits.first?.kind == .movie && hits.first?.year == 2001 && hits.first?.originalTitle == "Original" && hits.first?.rating == 7.5,
               "recherche : film mal lu")
        expect(hits.last?.kind == .tv && hits.last?.title == "Une série" && hits.last?.originalTitle == nil && hits.last?.rating == nil, "recherche : série mal lue")

        // A card: genres, director, cast, French trailer, offers of the region only, merged and ordered.
        let t = CinemaTMDB.parseDetails(json(detailsSample), hit: hits[0], region: "FR")
        expect(t.genres == ["Drame", "Comédie"] && t.runtime == 104 && t.makers == ["Réa Lisatrice"] && t.cast.count == 2, "fiche : infos")
        expect(t.trailer == "frTrailer01", "fiche : bande-annonce française")
        expect(t.watchPage == "https://www.themoviedb.org/movie/1/watch?locale=FR", "fiche : page des plateformes")
        expect(t.offers.map(\.name) == ["Netflix", "France TV", "Apple TV", "Apple TV"], "fiche : offres \(t.offers.map(\.name))")
        expect(t.offers.map(\.kind) == [.subscription, .free, .rent, .buy], "fiche : types d'offres")

        // Platforms behind TMDB's names.
        let names: [(String, String?)] = [("Netflix", "netflix"), ("Netflix Standard with Ads", "netflix"), ("Amazon Prime Video", "prime"),
                                          ("Amazon Video", "prime"), ("Disney Plus", "disney"), ("Canal+", "canal"), ("Apple TV", "apple"),
                                          ("Apple TV Plus", "apple"), ("HBO Max", "max"), ("Max", "max"), ("France TV", "francetv"),
                                          ("Arte", "arte"), ("TF1+", "tf1"), ("M6+", "m6"), ("YouTube", "youtube"), ("Maxdome", nil),
                                          ("Artesia", nil), ("Universciné", nil),
                                          // Names TMDB really gives in France (October 2026).
                                          ("Apple TV Store", "apple"), ("Canal VOD", "canal"), ("Canal+ Séries", "canal"), ("ARTE VOD", "artevod"),
                                          ("Amazon Prime Video with Ads", "prime"), ("YouTube Premium", "youtube"), ("Paramount Plus Premium", "paramount"),
                                          ("Animation Digital Network", "adn"), ("France TV Amazon Channel", "prime"), ("MUBI Amazon Channel", "prime"),
                                          ("Cine+ OCS Amazon Channel ", "prime"), ("HBO Max Amazon Channel", "prime"),
                                          ("Paramount Plus Apple TV channel", "apple"), ("Orange VOD", nil), ("SFR Play", nil), ("JustWatch TV", nil)]
        for (name, key) in names where CinemaPlatform.match(name)?.key != key {
            f.append("plateforme : « \(name) » → \(CinemaPlatform.match(name)?.key ?? "aucune") au lieu de \(key ?? "aucune")")
        }

        // Channels: shown by their own name, watched in the platform that sells them, never merged with each other.
        let channels = [CinemaOffer(kind: .subscription, providerID: 2535, name: "France TV Amazon Channel"),
                        CinemaOffer(kind: .subscription, providerID: 2173, name: "Anime Digital Network Amazon Channel"),
                        CinemaOffer(kind: .subscription, providerID: 119, name: "Amazon Prime Video")]
        expect(channels.map(\.displayName) == ["France TV via Prime Video", "Anime Digital Network via Prime Video", "Prime Video"]
               && CinemaOffers.merged(channels).count == 3, "chaînes : \(channels.map(\.displayName))")
        expect(CinemaOffersView.groups(t.offers, compact: true).map(\.label) == ["Abonnement", "Gratuit", "Location ou achat"]
               && CinemaOffersView.groups(t.offers, compact: true).last?.offers.count == 1
               && CinemaOffersView.groups(t.offers, compact: false).map(\.label) == ["Abonnement", "Gratuit", "Location", "Achat"], "groupes d'offres")

        // Where a click goes: the title's own page, else the platform's search, else TMDB.
        var linked = t
        linked.direct = ["netflix": "https://www.netflix.com/title/123"]
        let byName = Dictionary(linked.offers.map { ($0.name + $0.kind.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
        if let n = byName["Netflixsubscription"], let fr = byName["France TVfree"] {
            expect(CinemaOffers.destination(n, in: linked) == CinemaDestination(url: "https://www.netflix.com/title/123", via: .direct), "lien direct")
            expect(CinemaOffers.destination(fr, in: linked).url == "https://www.france.tv/recherche/?q=Un%20film%20%26%20moi", "lien de recherche encodé")
        } else {
            f.append("fiche : offres introuvables")
        }
        let unknown = CinemaOffer(kind: .rent, providerID: 999, name: "Vidéoclub Lumière")
        expect(CinemaOffers.destination(unknown, in: linked).via == .tmdb, "plateforme inconnue : page TMDB")
        let youtube = CinemaOffer(kind: .ads, providerID: 192, name: "YouTube")
        expect(CinemaOffers.destination(youtube, in: linked).adFreePlayer, "YouTube : lecteur sans pub")
        let freeFrance = CinemaOffer(kind: .free, providerID: 236, name: "France TV")
        let paidFrance = CinemaOffer(kind: .subscription, providerID: 2535, name: "France TV Amazon Channel")
        let freeTF1 = CinemaOffer(kind: .ads, providerID: 1754, name: "TF1+")
        expect(CinemaOffers.destination(freeFrance, in: linked).adFreePlayer && !CinemaOffers.destination(paidFrance, in: linked).adFreePlayer
               && !CinemaOffers.destination(freeTF1, in: linked).adFreePlayer
               && !CinemaOffers.destination(linked.offers[0], in: linked).adFreePlayer, "offres gratuites dans le lecteur sans pub")
        for p in CinemaPlatform.all where p.freeInPlayer || p.adFreePlayer {
            if let host = p.searchURL("x").flatMap(URL.init(string:))?.host, !AdBlockPlayerSite.all.contains(where: { $0.owns(host) }) {
                f.append("lecteur : \(p.name) n'est pas un site du lecteur")
            }
        }
        expect(CinemaPlatform.named("disney")?.directURL("abc", kind: .tv) == "https://www.disneyplus.com/series/wp/abc"
               && CinemaPlatform.named("apple")?.directURL("umc.cmc.1", kind: .movie) == "https://tv.apple.com/fr/movie/umc.cmc.1"
               && CinemaPlatform.named("prime")?.wikidataMovie == nil, "liens Disney+, Apple TV et Prime Video")

        // The user's platforms come first, and ↩ opens them.
        let mine = CinemaOffers.sorted(t.offers, mine: ["apple"])
        expect(mine.first?.name == "Apple TV" && mine.first?.kind == .rent, "tes plateformes en tête")
        expect(CinemaOffers.best(t, mine: [])?.name == "Netflix", "meilleure offre sans abonnement choisi")
        expect(CinemaOffers.merged([CinemaOffer(kind: .subscription, providerID: 8, name: "Netflix"),
                                    CinemaOffer(kind: .subscription, providerID: 1796, name: "Netflix basic with Ads")]).count == 1, "offres en double")

        // Wikidata: the preferred statement, never a deprecated one, only the platforms asked for.
        let links = CinemaWikidata.parseLinks(json(wikidataSample), item: "Q42", kind: .movie, region: "BE",
                                              platforms: [CinemaPlatform.named("netflix")!, CinemaPlatform.named("disney")!, CinemaPlatform.named("apple")!])
        expect(links == ["netflix": "https://www.netflix.com/title/222", "disney": "https://www.disneyplus.com/movies/wd/d1s",
                         "apple": "https://tv.apple.com/be/movie/umc.cmc.zzz"], "Wikidata : \(links)")
        expect(CinemaWikidata.wantedPlatforms(t).map(\.key) == ["netflix", "apple"], "Wikidata : plateformes à demander")

        expect(CinemaFormat.runtime(104) == "1 h 44" && CinemaFormat.runtime(45) == "45 min" && CinemaFormat.rating(7.46) == "7,5", "formats")
        expect(CinemaRegion.inName("FR") == "en France" && CinemaRegion.inName("CA") == "au Canada", "pays")
        return f
    }

    private static func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    static let searchSample = """
    {"page":1,"results":[
     {"media_type":"movie","id":1,"title":"Un film & moi","original_title":"Original","release_date":"2001-04-25","overview":"Résumé.","poster_path":"/p1.jpg","vote_average":7.5,"vote_count":900},
     {"media_type":"person","id":2,"name":"Une personne"},
     {"media_type":"tv","id":3,"name":"Une série","original_name":"Une série","first_air_date":"","vote_average":0,"vote_count":0},
     {"media_type":"movie","id":4,"title":"","release_date":"1999"}
    ]}
    """

    static let detailsSample = """
    {"id":1,"title":"Un film & moi","original_title":"Original","release_date":"2001-04-25","runtime":104,"tagline":"",
     "genres":[{"id":18,"name":"Drame"},{"id":35,"name":"Comédie"}],
     "credits":{"cast":[{"name":"Act Eur"},{"name":"Act Rice"}],"crew":[{"job":"Director","name":"Réa Lisatrice"},{"job":"Writer","name":"Scé Nariste"}]},
     "videos":{"results":[{"site":"YouTube","key":"enTrailer01","type":"Trailer","iso_639_1":"en","official":true},
                          {"site":"YouTube","key":"frTrailer01","type":"Trailer","iso_639_1":"fr","official":false},
                          {"site":"Vimeo","key":"123","type":"Trailer","iso_639_1":"fr"}]},
     "watch/providers":{"results":{
       "FR":{"link":"https://www.themoviedb.org/movie/1/watch?locale=FR",
             "buy":[{"provider_id":2,"provider_name":"Apple TV","logo_path":"/a.jpg","display_priority":4}],
             "rent":[{"provider_id":2,"provider_name":"Apple TV","logo_path":"/a.jpg","display_priority":4}],
             "flatrate":[{"provider_id":8,"provider_name":"Netflix","logo_path":"/n.jpg","display_priority":1},
                         {"provider_id":1796,"provider_name":"Netflix basic with Ads","logo_path":"/n2.jpg","display_priority":9}],
             "free":[{"provider_id":236,"provider_name":"France TV","logo_path":"/f.jpg","display_priority":2}]},
       "US":{"link":"x","flatrate":[{"provider_id":15,"provider_name":"Hulu","display_priority":1}]}}}}
    """

    static let wikidataSample = """
    {"entities":{"Q42":{"claims":{
      "P1874":[{"rank":"deprecated","mainsnak":{"datavalue":{"value":"111"}}},
               {"rank":"normal","mainsnak":{"datavalue":{"value":"333"}}},
               {"rank":"preferred","mainsnak":{"datavalue":{"value":"222"}}}],
      "P7595":[{"rank":"normal","mainsnak":{"datavalue":{"value":"d1s"}}}],
      "P9586":[{"rank":"normal","mainsnak":{"datavalue":{"value":"umc.cmc.zzz"}}}]}}}}
    """
}
