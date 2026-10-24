import SwiftUI

/// What the ad blocker gives the launcher: install, measure, remove, and "pub <domaine>" to check a domain.
@MainActor
enum AdBlockCommands {
    static let keywords = ["pub", "pubs", "publicité", "publicités", "bloqueur", "adblock", "pisteurs", "trackers", "dns", "bloquer"]

    static func list(_ m: AdBlockModel) -> [AppCommand] {
        let tint = AdBlockStyle.tint
        return [
            AppCommand(id: "adblock_open", title: "Bloqueur de pub", subtitle: "Les pubs et les pisteurs bloqués pour tout le Mac",
                       keywords: keywords + ["ouvrir"], icon: .symbol("hand.raised", tint), group: .tools,
                       assistantSafe: true, urlSafe: true, hint: "Ouvrir") { _ in
                m.openPage(.blocker)
                return .done
            },
            AppCommand(id: "adblock_player_open", title: "Lecteur sans pub",
                       subtitle: "YouTube, Twitch et les plateformes gratuites sans pub, Vidéo seule et tes comptes",
                       keywords: ["lecteur", "sans pub", "youtube", "twitch", "vidéo seule", "comptes", "signet", "ouvrir"],
                       icon: .symbol("play.tv", tint), group: .tools, assistantSafe: true, urlSafe: true, hint: "Ouvrir") { _ in
                m.openPage(.player)
                return .done
            },
            AppCommand(id: "adblock_install", title: m.installed ? "Réinstaller le bloqueur de pub" : "Installer le bloqueur de pub",
                       subtitle: "Pubs et pisteurs bloqués pour tout le Mac · niveau \(m.settings.level.title)",
                       keywords: keywords + ["installer", "activer"], icon: .symbol("hand.raised", tint), group: .actions,
                       assistantSafe: true, hint: "Installer") { _ in
                m.openPage()
                m.install()
                return .done
            },
            AppCommand(id: "adblock_measure", title: "Mesurer le bloqueur de pub", subtitle: "Combien de pubs et de pisteurs ton Mac bloque vraiment",
                       keywords: keywords + ["mesurer", "tester", "vérifier"], icon: .symbol("gauge.with.needle", tint), group: .actions,
                       assistantSafe: true, urlSafe: true, hint: "Mesurer") { _ in
                m.openPage()
                m.runMeasure()
                return .done
            },
            AppCommand(id: "adblock_player_youtube", title: "YouTube sans pub", subtitle: "YouTube dans une fenêtre de Heartware, sans ses pubs vidéo",
                       keywords: ["youtube", "vidéo", "vidéos", "sans pub", "lecteur", "regarder"], icon: .symbol("play.rectangle.fill", tint),
                       group: .actions, assistantSafe: true, urlSafe: true, hint: "Ouvrir") { _ in
                m.player.open(AdBlockPlayer.youtube)
                return .done
            },
            AppCommand(id: "adblock_player_twitch", title: "Twitch sans pub", subtitle: "Les directs Twitch dans une fenêtre de Heartware, sans coupures pub",
                       keywords: ["twitch", "stream", "direct", "live", "sans pub", "lecteur", "regarder"], icon: .symbol("tv", tint),
                       group: .actions, assistantSafe: true, urlSafe: true, hint: "Ouvrir") { _ in
                m.player.open(AdBlockPlayer.twitch)
                return .done
            },
            AppCommand(id: AdBlockHandoff.commandID,
                       title: m.handoff.enabled ? "Laisser YouTube et Twitch dans le navigateur" : "YouTube et Twitch toujours sans pub",
                       subtitle: m.handoff.enabled ? "Éteint la bascule automatique dans le lecteur sans pub"
                                                   : "Ouverts dans ton navigateur, ils passent d'eux-mêmes dans le lecteur sans pub",
                       keywords: ["youtube", "twitch", "sans pub", "bascule", "basculer", "automatique", "toujours", "navigateur", "safari", "chrome", "lecteur"],
                       icon: .symbol("arrow.triangle.swap", tint), group: .actions,
                       risk: m.handoff.enabled ? .safe : .confirm("YouTube et Twitch ouverts dans ton navigateur passeront dans le lecteur sans pub, et leur onglet se fermera dans le navigateur."),
                       hint: m.handoff.enabled ? "Éteindre" : "Allumer") { _ in
                m.handoff.setEnabled(!m.handoff.enabled)
                m.openPage(.player)
                return .done
            }
        ] + AdBlockAccount.all.map { account in
            let signedIn = m.accounts[account.key]?.isSignedIn == true
            return AppCommand(id: "adblock_account_\(account.key)",
                              title: signedIn ? "Se déconnecter de \(account.name) dans le lecteur" : "Se connecter à \(account.name) dans le lecteur sans pub",
                              subtitle: signedIn ? "Le lecteur sans pub oublie ce compte (ton navigateur garde le sien)" : account.serves,
                              keywords: ["compte", "comptes", "connexion", "connecter", "se connecter", "déconnecter", account.name.lowercased(), "lecteur", "sans pub"],
                              icon: .symbol(account.symbol, tint), group: .actions,
                              risk: signedIn ? .confirm("Le lecteur sans pub oubliera ton compte \(account.name) : il faudra te reconnecter.") : .safe,
                              hint: signedIn ? "Déconnecter" : "Se connecter") { _ in
                if signedIn { m.signOut(account) } else { m.signIn(account) }
                return .done
            }
        } + [
            AppCommand(id: AdBlockVideoOnly.commandID, title: "Vidéo seule",
                       subtitle: "La vidéo de Safari dans une petite fenêtre au-dessus des autres, sans pub sur YouTube et Twitch",
                       keywords: ["vidéo", "video", "seule", "mini", "lecteur", "fenêtre", "flottante", "détacher", "pip", "image dans l'image",
                                  "direct", "live", "stream", "twitch", "youtube", "regarder", "coin", "netflix", "prime video", "disney",
                                  "film", "série"],
                       icon: .symbol("pip.enter", tint), group: .actions, assistantSafe: true, hint: "Détacher") { _ in
                Task { await m.player.detach() }
                return .done
            },
            AppCommand(id: "adblock_youtube", title: "Bloquer les pubs YouTube dans Safari", subtitle: "L'extension de Safari qui coupe les pubs des vidéos",
                       keywords: keywords + ["youtube", "vidéo", "vidéos", "safari", "extension", "ublock"], icon: .symbol("play.rectangle", tint),
                       group: .actions, assistantSafe: true, hint: "Ouvrir") { _ in
                m.openPage(.player)
                m.refreshExtensions()
                return .done
            },
            AppCommand(id: "adblock_remove", title: "Désactiver le bloqueur de pub", subtitle: "Retire le profil DNS : tout redevient comme avant",
                       keywords: keywords + ["désactiver", "retirer", "supprimer"], icon: .symbol("hand.raised.slash", Theme.bad), group: .actions,
                       risk: .confirm("Le profil DNS du bloqueur sera retiré de ton Mac (mot de passe administrateur) : les pubs reviendront.")) { _ in
                m.remove()
                return .done
            }
        ]
    }

    /// A pasted YouTube or Twitch link, "yt …" or "twitch …": opened in the ad-free player.
    static func playerResults(_ q: String, _ m: AdBlockModel) -> [AppCommand] {
        let tint = AdBlockStyle.tint
        if q.contains("."), !q.contains(" "), let url = AdBlockPlayer.playable(q) {
            return [AppCommand(id: "adblock_player_link", title: "Regarder sans pub dans Heartware", subtitle: url.absoluteString,
                               icon: .symbol("play.tv", tint), group: .actions, hint: "Regarder", boost: 1925) { _ in
                m.player.open(url)
                return .done
            }]
        }
        let lower = q.lowercased()
        if lower.hasPrefix("yt "), case let term = String(q.dropFirst(3)).trimmingCharacters(in: .whitespaces), !term.isEmpty,
           var c = URLComponents(string: "https://www.youtube.com/results") {
            c.queryItems = [URLQueryItem(name: "search_query", value: term)]
            guard let url = c.url else { return [] }
            return [AppCommand(id: "adblock_player_search", title: "Chercher « \(term) » sur YouTube sans pub", subtitle: "Dans le lecteur sans pub de Heartware",
                               icon: .symbol("play.rectangle.fill", tint), group: .actions, hint: "Regarder", boost: 1550) { _ in
                m.player.open(url)
                return .done
            }]
        }
        if lower.hasPrefix("twitch "), case let login = String(q.dropFirst(7)).trimmingCharacters(in: .whitespaces),
           !login.isEmpty, login.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
           let url = URL(string: "https://www.twitch.tv/" + login.lowercased()) {
            return [AppCommand(id: "adblock_player_channel", title: "Regarder « \(login) » sur Twitch sans pub", subtitle: "Dans le lecteur sans pub de Heartware",
                               icon: .symbol("tv", tint), group: .actions, hint: "Regarder", boost: 1550) { _ in
                m.player.open(url)
                return .done
            }]
        }
        return []
    }

    /// "pub exemple.fr", "adblock exemple.fr": checks the domain on the page.
    static func results(_ raw: String, _ m: AdBlockModel) -> [AppCommand] {
        let q = raw.trimmingCharacters(in: .whitespaces)
        let player = playerResults(q, m)
        if !player.isEmpty { return player }
        guard let space = q.firstIndex(of: " "), ["pub", "adblock", "bloqué", "bloque"].contains(Fuzzy.fold(String(q[..<space]))),
              let domain = AdBlockDomain.normalize(String(q[space...]), keepWWW: true) else { return [] }
        return [AppCommand(id: "adblock_check", title: "Vérifier « \(domain) » dans le bloqueur de pub",
                           subtitle: m.isExcepted(domain) ? "Dans tes exceptions" : "Bloqué sur ce Mac ? Dans la liste \(m.settings.level.list) ?",
                           icon: .symbol("magnifyingglass", AdBlockStyle.tint), group: .actions, hint: "Vérifier", boost: 1500) { _ in
            m.checkText = domain
            m.openPage()
            m.checkDomain()
            return .done
        }]
    }
}

/// Pure checks for `--selftest`: domains, the profile, DNS messages and the reading of answers.
@MainActor
enum AdBlockChecks {
    static func run(_ m: AdBlockModel) -> [String] {
        var f: [String] = []
        func expect(_ ok: Bool, _ message: String) { if !ok { f.append(message) } }

        // Domains typed or pasted.
        let names: [(String, String?)] = [
            ("https://www.Exemple.fr/page?x=1", "exemple.fr"), ("boutique.fr", "boutique.fr"), ("*.pub.exemple.com.", "pub.exemple.com"),
            ("sous.domaine.exemple.co.uk:443", "sous.domaine.exemple.co.uk"), ("192.168.1.1", nil), ("bonjour", nil), ("exa mple.fr", nil),
            ("-moins.fr", nil), ("a..b.fr", nil), ("www.fr", "www.fr"), ("", nil)
        ]
        for (raw, want) in names where AdBlockDomain.normalize(raw) != want {
            f.append("domaine « \(raw) » lu « \(AdBlockDomain.normalize(raw) ?? "rien") » au lieu de « \(want ?? "rien") »")
        }
        expect(AdBlockDomain.normalize("www.lemonde.fr", keepWWW: true) == "www.lemonde.fr", "vérifier un domaine garde www.")

        // The profile: an XML property list macOS can read, with the level's resolver and the exceptions.
        for level in AdBlockLevel.allCases {
            guard let data = AdBlockProfile.data(level: level, exceptions: ["boutique.fr"]),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let payload = (plist["PayloadContent"] as? [[String: Any]])?.first,
                  let dns = payload["DNSSettings"] as? [String: Any] else {
                f.append("profil \(level.title) illisible")
                continue
            }
            expect(plist["PayloadIdentifier"] as? String == AdBlockProfile.identifier, "profil : identifiant (sinon une réinstallation s'ajoute au lieu de remplacer)")
            expect(plist["PayloadType"] as? String == "Configuration" && payload["PayloadType"] as? String == "com.apple.dnsSettings.managed", "profil : types")
            expect(dns["DNSProtocol"] as? String == "HTTPS" && (dns["ServerURL"] as? String)?.hasPrefix("https://") == true, "profil : DNS chiffré en HTTPS")
            let rules = payload["OnDemandRules"] as? [[String: Any]] ?? []
            let domains = ((rules.first?["ActionParameters"] as? [[String: Any]])?.first?["Domains"] as? [String]) ?? []
            expect(domains.contains("boutique.fr") && domains.contains("*.boutique.fr"), "profil : exception et ses sous-domaines")
            expect(domains.contains("captive.apple.com") && domains.contains("home"), "profil : portails Wi-Fi et réseau local hors filtre")
            expect(rules.last?["Action"] as? String == "Connect", "profil : le filtre doit s'appliquer à tout le reste")
        }
        expect(AdBlockLevel.balanced.serverURL != AdBlockLevel.maximal.serverURL, "niveaux : même résolveur")

        // A DNS query, and answers as resolvers give them.
        guard let q = AdBlockDNS.query("pub.exemple.fr", type: 1, id: 0x1234) else { return f + ["requête DNS"] }
        expect(q.count == 12 + 16 + 4 && q[0] == 0x12 && q[1] == 0x34 && q[12] == 3, "requête DNS : en-tête ou nom")
        expect(AdBlockDNS.query(String(repeating: "a", count: 64) + ".fr") == nil, "requête DNS : étiquette trop longue acceptée")
        expect(!AdBlockDNS.base64url(Data([0xFB, 0xFF])).contains(where: { "+/=".contains($0) }), "requête DNS : base64url")
        func answer(_ rcode: UInt8, _ records: [(UInt16, [UInt8])]) -> Data {
            var d = Data(q)
            d[2] = 0x81; d[3] = 0x80 | rcode
            d[6] = 0; d[7] = UInt8(records.count)
            for (type, rdata) in records {
                d.append(contentsOf: [0xC0, 0x0C, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1, 0, 0, 0, 60, 0, UInt8(rdata.count)])
                d.append(contentsOf: rdata)
            }
            return d
        }
        let sinkhole = AdBlockDNS.parse(answer(0, [(1, [0, 0, 0, 0])]))
        expect(sinkhole?.addresses == ["0.0.0.0"] && AdBlockDNS.verdict(rcode: 0, addresses: sinkhole?.addresses ?? []) == .blocked, "réponse 0.0.0.0 = bloqué")
        let real = AdBlockDNS.parse(answer(0, [(1, [93, 184, 216, 34]), (28, [0x26, 0x06] + Array(repeating: 0, count: 13) + [1])]))
        expect(real?.addresses == ["93.184.216.34", "2606:0:0:0:0:0:0:1"], "réponse : adresses lues \(real?.addresses ?? [])")
        expect(AdBlockDNS.verdict(rcode: 0, addresses: real?.addresses ?? []) == .open, "vraie adresse = ouvert")
        expect(AdBlockDNS.verdict(rcode: 3, addresses: []) == .missing && AdBlockDNS.verdict(rcode: 2, addresses: []) == .unknown
               && AdBlockDNS.verdict(rcode: 5, addresses: []) == .blocked, "NXDOMAIN / SERVFAIL / REFUSED")
        expect(AdBlockProbe(domain: "x.fr", shouldBlock: true, verdict: .missing).good, "une pub introuvable est bien bloquée")
        expect(AdBlockDNS.parse(Data([1, 2, 3])) == nil, "réponse tronquée acceptée")

        // Safari's extensions as pluginkit lists them: only the ad blockers are kept.
        let listing = """
             net.raymondhill.uBlock-Origin-Lite.Extension(2026.1012.1545)
        	            Path = /Applications/uBlock Origin Lite.app/Contents/PlugIns/uBlock Origin Lite Extension.appex
        	   Parent Bundle = /Applications/uBlock Origin Lite.app
        	     Parent Name = uBlock Origin Lite
        +    com.exemple.Notes.Extension(1.0)
        	     Parent Name = Notes rapides
        -    com.exemple.wipr.blocker(2.1)
        	     Parent Name = Wipr

         (3 plug-ins)
        """
        let found = AdBlockBrowser.parse(listing)
        expect(found.map(\.name) == ["uBlock Origin Lite", "Wipr"], "extensions Safari : \(found.map(\.name))")
        expect(found.first?.youtube == true && found.last?.youtube == false && found.first?.appPath == "/Applications/uBlock Origin Lite.app",
               "extensions Safari : YouTube et app")
        expect(found.last?.identifier == "com.exemple.wipr.blocker", "extensions Safari : marque de pluginkit retirée")

        // The counter: one event per blocked lookup, with its app; real answers and other lines ignored.
        let log = """
        2026-10-20 01:03:41.542 Df mDNSResponder[688:3678] [com.apple.mdns:dnssd_server] [R100] getaddrinfo start -- flags: 0xC000D000, ifindex: 0, protocols: 0, hostname: <private> <dn:5+xG0g>, options: 0x0 {}, client pid: 988 (com.apple.WebKi), delegator uuid: 32C7
        2026-10-20 01:03:41.543 Df mDNSResponder[688:3678] [com.apple.mdns:dnssd_server] [R100->Q1] getaddrinfo result -- event: add, ifindex: 0, name: <dn:Yb9gFA>, type: A, rdata: 0.0.0.0, expired: yes
        2026-10-20 01:03:41.544 Df mDNSResponder[688:3678] [com.apple.mdns:dnssd_server] [R100->Q2] getaddrinfo result -- event: add, ifindex: 0, name: <dn:Yb9gFA>, type: A, rdata: 0.0.0.0, expired: no
        2026-10-20 01:03:41.545 Df mDNSResponder[688:3678] [com.apple.mdns:dnssd_server] [R101] getaddrinfo start -- flags: 0x0, client pid: 77 (cloudd), delegator uuid: 1
        2026-10-20 01:03:41.546 Df mDNSResponder[688:3678] [com.apple.mdns:dnssd_server] [R101->Q3] getaddrinfo result -- event: add, ifindex: 0, name: <dn:X>, type: A, rdata: <ipv4:u5oziw>, expired: no
        2026-10-20 01:03:42.000 Df mDNSResponder[688:3678] [com.apple.mdns:dnssd_server] [R102->Q4] getaddrinfo result -- event: add, ifindex: 0, name: <dn:Z>, type: A, rdata: 0.0.0.0, expired: no
        """
        let events = AdBlockLog.parse(log)
        expect(events.map(\.app) == ["Safari et pages web", "Autres apps"], "compteur : \(events.map(\.app))")
        var tally = AdBlockTally()
        tally.add(events, readUntil: Date())
        expect(tally.total == 2 && tally.days.values.reduce(0, +) == 2, "compteur : total")
        expect(AdBlockLog.appName("cloudtelemetryd") == "Services de macOS" && AdBlockLog.appName("Google Chrome H") == "Google Chrome", "compteur : noms d'apps")
        let fun = AdBlockFun.equivalences(1_000)
        expect(fun.first { $0.id == "tv" }?.value == "8 h 20", "équivalences : 1 000 spots de 30 s = 8 h 20 (\(fun.first?.value ?? ""))")
        expect(fun.first { $0.id == "paper" }?.text.contains("le poids de 1,2 chat") == false, "équivalences : accord")
        expect(AdBlockFun.compare(5, lead: "le poids", to: AdBlockFun.weights) == "le poids d'un chat"
               && AdBlockFun.compare(330, lead: "la hauteur", to: AdBlockFun.heights) == "la hauteur de la tour Eiffel"
               && AdBlockFun.compare(9_000, lead: "la hauteur", to: AdBlockFun.heights) == "la hauteur de l'Everest"
               && AdBlockFun.compare(12, lead: "le poids", to: AdBlockFun.weights) == "le poids de 3 chats",
               "équivalences : \(AdBlockFun.compare(12, lead: "le poids", to: AdBlockFun.weights))")
        let step = AdBlockFun.milestone(1_500)
        expect(step.reached?.0 == 1_000 && step.next?.0 == 5_000 && abs(step.progress - 0.125) < 0.001, "paliers")

        // The ad-free player: the links it opens, the pages it keeps, its scripts and rules.
        let links: [(String, String?)] = [
            ("https://youtu.be/kJQP7kiw5Fk?t=30", "https://www.youtube.com/watch?v=kJQP7kiw5Fk&t=30"),
            ("youtube.com/watch?v=abc", "https://www.youtube.com/watch?v=abc"), ("m.youtube.com/shorts/xyz", "https://www.youtube.com/shorts/xyz"),
            ("https://www.twitch.tv/zackrawrr", "https://www.twitch.tv/zackrawrr"), ("twitch.tv/videos/123", "https://www.twitch.tv/videos/123"),
            ("https://exemple.fr/video", nil), ("https://youtu.be/", nil), ("javascript:alert(1)", nil), ("bonjour", nil),
            ("http://www.france.tv/films/123-un-film.html", "https://www.france.tv/films/123-un-film.html"),
            ("pluto.tv/fr/search/details/?query=dune", "https://pluto.tv/fr/search/details/?query=dune"),
            ("www.m6.fr/recherche?q=x", "https://www.m6.fr/recherche?q=x"), ("https://faux-france.tv.exemple.fr/", nil),
            ("https://www.tf1.fr/tf1/x.html", nil)
        ]
        for (raw, want) in links where AdBlockPlayer.playable(raw)?.absoluteString != want {
            f.append("lecteur : « \(raw) » → \(AdBlockPlayer.playable(raw)?.absoluteString ?? "rien") au lieu de \(want ?? "rien")")
        }
        expect(AdBlockPlayer.belongs(URL(string: "https://rr3---sn-x.googlevideo.com/videoplayback")!)
               && AdBlockPlayer.belongs(URL(string: "https://video-weaver.fra05.hls.ttvnw.net/v1/playlist/x.m3u8")!)
               && !AdBlockPlayer.belongs(URL(string: "https://www.tf1.fr/")!)
               && AdBlockPlayer.belongs(URL(string: "https://login-gigya.m6.fr/")!)
               && !AdBlockPlayer.belongs(URL(string: "https://exemple.fr/")!) && !AdBlockPlayer.belongs(URL(string: "https://notfrance.tv/")!),
               "lecteur : sites gardés dans la fenêtre")
        expect(AdBlockPlayerSite.site(of: URL(string: "https://www.france.tv/x.html")!)?.key == "francetv"
               && AdBlockPlayerSite.site(of: URL(string: "https://accounts.google.com/")!) == nil
               && AdBlockPlayerSite.site(of: URL(string: "https://www.youtube.com/watch?v=a")!)?.key == "youtube", "lecteur : site d'une page")
        let rules = (try? JSONSerialization.jsonObject(with: Data(AdBlockPlayerScripts.rules.utf8))) as? [[String: Any]] ?? []
        let filters = rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        expect(filters.count == rules.count && rules.allSatisfy { $0["action"] != nil } && Set(filters).count == filters.count
               && filters.count >= AdBlockPlayerScripts.blockedPatterns.count + 4, "lecteur : règles de blocage illisibles")
        let fw = filters.first { $0.contains("fwmrm") }.flatMap { try? NSRegularExpression(pattern: $0) }
        func hits(_ s: String) -> Bool { fw?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        expect(hits("https://mssl.fwmrm.net/ad/g/1") && !hits("https://exemple.fr/fwmrm.net")
               && filters.contains { $0.contains("stickyadstv") } && !filters.contains { $0.contains("|") }, "lecteur : règles des plateformes")
        var journal = AdBlockPlayerJournal()
        journal.add(["hosts": ["mssl.fwmrm.net", "WWW.France.tv", "a/b"], "drm": ["com.apple.fps ok"], "played": true, "notes": ["adblock"]], site: "francetv")
        journal.add(["hosts": ["mssl.fwmrm.net"]], site: "francetv")
        expect(journal.sites["francetv"]?.hosts == ["mssl.fwmrm.net": 2, "www.france.tv": 1] && journal.sites["francetv"]?.played == true
               && journal.sites["francetv"]?.drm == ["com.apple.fps ok"], "lecteur : journal du Labo")
        expect(!AdBlockPlayerScripts.blockedPatterns.contains { $0.contains("|") }, "lecteur : WebKit refuse « | » dans une règle")
        expect(AdBlockPlayerScripts.youtube.contains("adPlacements") && AdBlockPlayerScripts.youtube.contains("location.hostname")
               && AdBlockPlayerScripts.twitch.contains("usher") && AdBlockPlayerScripts.twitch.contains("location.hostname"), "lecteur : scripts")
        expect(AdBlockPlayer.bookmarklet.hasPrefix("javascript:") && AdBlockPlayer.bookmarklet.contains("heartware://regarder"), "lecteur : signet")
        let search = AdBlockCommands.playerResults("yt lofi girl", m)
        expect(search.first?.id == "adblock_player_search", "lecteur : « yt … » dans le lanceur")
        expect(AdBlockCommands.playerResults("twitch zackrawrr", m).first?.id == "adblock_player_channel"
               && AdBlockCommands.playerResults("twitch ../x", m).isEmpty, "lecteur : « twitch … » dans le lanceur")

        // The state from the three canaries.
        expect(AdBlockState.from(both: .blocked, maximalOnly: .blocked, reachable: .open) == .on(.maximal), "état : Maximal")
        expect(AdBlockState.from(both: .blocked, maximalOnly: .open, reachable: .open) == .on(.balanced), "état : Équilibré")
        expect(AdBlockState.from(both: .open, maximalOnly: .open, reachable: .open) == .off, "état : inactif")
        expect(AdBlockState.from(both: .unknown, maximalOnly: .unknown, reachable: .unknown) == .offline, "état : sans réseau")
        expect(Set(AdBlockCanary.ads).count == AdBlockCanary.ads.count && AdBlockCanary.ads.contains(AdBlockCanary.both)
               && AdBlockCanary.ads.contains(AdBlockCanary.maximalOnly) && AdBlockCanary.useful.contains(AdBlockCanary.reachable), "témoins")
        return f
    }
}
