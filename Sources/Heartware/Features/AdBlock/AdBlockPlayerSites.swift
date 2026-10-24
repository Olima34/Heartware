import Foundation

/// A site the ad-free player shows itself: the domains it browses (pages, sign-in, video), the ad servers its player
/// calls, blocked on top of the common list (`AdBlockPlayerScripts.blockedPatterns`), and the script its pages get.
/// Checked in a WebKit bench (20 Oct. 2026): Arte plays without account nor ads; Pluto TV plays, its ads sewn into the
/// stream itself (same server as the programme: they cannot be blocked as requests); France.tv and M6+ ask for a free
/// account before any video, their ad servers read from their public code; M6+'s player gets FairPlay from WebKit.
/// France.tv walls a video with ads when a dummy request to its ad server fails (22 Oct. 2026, `--adblock detecteur`):
/// its script answers that request in the page (`AdBlockPlayerScripts.francetv`).
/// TF1+ is left out: it refuses to play as soon as one of its ad servers does not answer (« Un bloqueur de publicité
/// empêche la lecture »), and getting past that wall would be circumventing its access protection, not blocking ads.
struct AdBlockPlayerSite: Identifiable, Equatable {
    var key: String
    var name: String
    var home: URL
    var domains: [String]
    var adHosts: [String] = []
    /// Put in its pages from their start (each script checks the page's host itself).
    var script: String?
    /// What the player cannot do there (shown on the page).
    var limit: String?

    var id: String { key }

    static let youtube = AdBlockPlayerSite(key: "youtube", name: "YouTube", home: URL(string: "https://www.youtube.com/")!,
                                           domains: ["youtube.com", "youtu.be", "youtube-nocookie.com", "ytimg.com", "googlevideo.com",
                                                     "accounts.google.com", "google.com", "gstatic.com", "googleusercontent.com",
                                                     // Google's sign-in may pass through the user's country.
                                                     "google.fr", "google.be", "google.ch", "google.ca", "google.lu"],
                                           script: AdBlockPlayerScripts.youtube)
    static let twitch = AdBlockPlayerSite(key: "twitch", name: "Twitch", home: URL(string: "https://www.twitch.tv/")!,
                                          domains: ["twitch.tv", "twitchcdn.net", "ttvnw.net", "jtvnw.net"],
                                          script: AdBlockPlayerScripts.twitch)
    static let francetv = AdBlockPlayerSite(key: "francetv", name: "France.tv", home: URL(string: "https://www.france.tv/")!,
                                            domains: ["france.tv", "francetv.fr", "ftven.fr", "francetelevisions.fr"],
                                            adHosts: ["fwmrm.net", "stickyadstv.com", "outbrain.com", "smartadserver.com"],
                                            script: AdBlockPlayerScripts.francetv,
                                            limit: "Compte gratuit France.tv demandé avant toute vidéo")
    static let m6 = AdBlockPlayerSite(key: "m6", name: "M6+", home: URL(string: "https://www.m6.fr/")!,
                                      domains: ["m6.fr", "6play.fr", "6cloud.fr", "m6web.fr", "bedrock.tech", "gigya.com"],
                                      adHosts: ["stickyadstv.com", "fwmrm.net", "outbrain.com", "smartadserver.com"],
                                      limit: "Compte gratuit M6+ demandé avant toute vidéo")
    static let arte = AdBlockPlayerSite(key: "arte", name: "Arte", home: URL(string: "https://www.arte.tv/fr/")!,
                                        domains: ["arte.tv"])
    static let pluto = AdBlockPlayerSite(key: "pluto", name: "Pluto TV", home: URL(string: "https://pluto.tv/fr/")!,
                                         domains: ["pluto.tv", "plutostatic.tv"],
                                         adHosts: ["imasdk.googleapis.com"],
                                         limit: "Pub cousue dans le flux : elle ne peut pas être coupée")

    static let all: [AdBlockPlayerSite] = [youtube, twitch, francetv, m6, arte, pluto]
    /// Offered in the player's menu and on the page, after YouTube and Twitch.
    static let others: [AdBlockPlayerSite] = [francetv, m6, arte, pluto]

    static func named(_ key: String) -> AdBlockPlayerSite? { all.first { $0.key == key } }

    func owns(_ host: String) -> Bool {
        let h = host.lowercased()
        return domains.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// The site of a page shown in the player.
    static func site(of url: URL) -> AdBlockPlayerSite? {
        guard let host = url.host else { return nil }
        // Sign-in pages shared by several sites (Google, Gigya) are no site of their own.
        let h = host.lowercased()
        return all.first { $0.owns(h) && !(h.hasSuffix("gigya.com") || h.split(separator: ".").contains("google")) }
    }

    /// Every ad server of the sites, without duplicates.
    static var adHosts: [String] {
        var seen = Set<String>()
        return all.flatMap(\.adHosts).filter { seen.insert($0).inserted }
    }
}

/// In the Labo only: the player notes, page by page, which servers each site calls (names only, no address), whether a
/// video plays, the DRM asked for and any anti-adblock message. Kept on this Mac (`player-journal.json`), so that the
/// rules of a site that needs an account can be written from a real viewing.
struct AdBlockPlayerJournal: Codable {
    struct Site: Codable {
        var hosts: [String: Int] = [:]
        var drm: [String] = []
        var played = false
        var notes: [String] = []
        var seen = Date()
    }

    var sites: [String: Site] = [:]

    mutating func add(_ body: [String: Any], site: String) {
        var s = sites[site] ?? Site()
        s.seen = Date()
        if let hosts = body["hosts"] as? [String] {
            for h in hosts where h.count < 120 && !h.contains("/") { s.hosts[h.lowercased(), default: 0] += 1 }
        }
        if let drm = body["drm"] as? [String] {
            for d in drm where d.count < 80 && !s.drm.contains(d) { s.drm.append(d) }
        }
        if body["played"] as? Bool == true { s.played = true }
        if let notes = body["notes"] as? [String] {
            for n in notes where n.count < 60 && !s.notes.contains(n) { s.notes.append(n) }
        }
        sites[site] = s
    }

    /// Reports what a page calls (in every frame), once a new server shows up and every 20 s.
    static let script = #"""
    (() => {
      if (window.__cmcJournal) return;
      window.__cmcJournal = true;
      const hosts = new Set(), sent = new Set(), drm = [];
      let played = false, dirty = false;
      const note = (u) => { try { const h = new URL(u, location.href).hostname; if (h && !sent.has(h)) { hosts.add(h); dirty = true; } } catch (e) {} };
      try { new PerformanceObserver(l => { for (const e of l.getEntries()) note(e.name); }).observe({ type: 'resource', buffered: true }); } catch (e) {}
      const f = window.fetch;
      window.fetch = function (input) { try { note(String(input && input.url || input)); } catch (e) {} return f.apply(this, arguments); };
      const o = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, u) { try { note(String(u)); } catch (e) {} return o.apply(this, arguments); };
      if (navigator.requestMediaKeySystemAccess) {
        const r = navigator.requestMediaKeySystemAccess.bind(navigator);
        navigator.requestMediaKeySystemAccess = function (ks, cfg) {
          return r(ks, cfg).then(a => { drm.push(ks + ' ok'); dirty = true; return a; }, e => { drm.push(ks + ' refusé'); dirty = true; throw e; });
        };
      }
      document.addEventListener('playing', () => { if (!played) { played = true; dirty = true; } }, true);
      const words = ['bloqueur de pub', 'bloqueur de publicité', 'adblock', 'ad blocker', 'désactivez votre bloqueur', 'désactive ton bloqueur'];
      const send = () => {
        const text = window === window.top && document.body ? (document.body.innerText || '').toLowerCase() : '';
        const notes = words.filter(w => text.includes(w));
        if (!dirty && !notes.length) return;
        const list = [...hosts]; list.forEach(h => sent.add(h)); hosts.clear(); dirty = false;
        try { window.webkit.messageHandlers.hw.postMessage({ type: 'journal', hosts: list, drm: drm.splice(0), played, notes }); } catch (e) {}
      };
      setInterval(send, 20000);
      addEventListener('pagehide', send);
      setTimeout(send, 5000);
    })();
    """#
}
