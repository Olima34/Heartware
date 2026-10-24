import Foundation
import SystemConfiguration
import AppKit
import WebKit

/// Asks resolvers about the canary domains: this Mac's own resolver (`getaddrinfo`, the call every app makes, through
/// /etc/hosts and the DNS profile), or a level's resolver directly over HTTPS (to preview a level).
/// Only after a click: nothing is asked in the background.
enum AdBlockProbes {
    /// This Mac: blocked, reachable, or no answer at all (unknown until a useful site shows the network works).
    /// Blocks the calling thread for the lookup: never call it on the main thread.
    static func systemVerdict(_ domain: String) -> AdBlockVerdict {
        guard !DemoData.isEnabled else { return .unknown }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let error = getaddrinfo(domain, nil, &hints, &list)
        defer { if let list { freeaddrinfo(list) } }
        // No such name: a dead domain, or a blocker answering NXDOMAIN; anything else is "no answer".
        guard error == 0 else { return error == EAI_NONAME ? .missing : .unknown }
        var addresses: [String] = []
        var node = list
        while let n = node {
            if let address = n.pointee.ai_addr {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, n.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append(String(cString: host))
                }
            }
            node = n.pointee.ai_next
        }
        return AdBlockDNS.verdict(rcode: 0, addresses: addresses)
    }

    /// Several lookups at once, on threads of their own (each one waits for the network).
    static func systemVerdicts(_ domains: [String]) -> [AdBlockVerdict] {
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var values: [AdBlockVerdict]
            init(_ n: Int) { values = Array(repeating: .unknown, count: n) }
        }
        let results = Results(domains.count)
        DispatchQueue.concurrentPerform(iterations: domains.count) { i in
            let v = systemVerdict(domains[i])
            results.lock.lock()
            results.values[i] = v
            results.lock.unlock()
        }
        return results.values
    }

    /// The level's resolver, over DNS-over-HTTPS (RFC 8484, GET).
    static func resolverVerdict(_ domain: String, level: AdBlockLevel) async -> AdBlockVerdict {
        guard let q = AdBlockDNS.query(domain), let url = URL(string: level.serverURL + "?dns=" + AdBlockDNS.base64url(q)),
              let (data, _) = try? await HTTP.get(url, headers: ["Accept": "application/dns-message"]),
              let r = AdBlockDNS.parse(data) else { return .unknown }
        return AdBlockDNS.verdict(rcode: r.rcode, addresses: r.addresses)
    }

    /// What this Mac's resolver does now, from three canaries (three short lookups at once).
    static func state() -> AdBlockState {
        let v = systemVerdicts([AdBlockCanary.both, AdBlockCanary.maximalOnly, AdBlockCanary.reachable])
        return AdBlockState.from(both: v[0], maximalOnly: v[1], reachable: v[2])
    }

    /// All the canaries: on this Mac (`level` nil) or through a level's resolver.
    static func measure(level: AdBlockLevel?) async -> AdBlockMeasure {
        let domains = AdBlockCanary.ads.map { ($0, true) } + AdBlockCanary.useful.map { ($0, false) }
        var verdicts: [String: AdBlockVerdict] = [:]
        if let level {
            await withTaskGroup(of: (String, AdBlockVerdict).self) { group in
                for (domain, _) in domains { group.addTask { (domain, await resolverVerdict(domain, level: level)) } }
                for await (domain, verdict) in group { verdicts[domain] = verdict }
            }
        } else {
            let found = systemVerdicts(domains.map(\.0))
            for (i, d) in domains.enumerated() { verdicts[d.0] = found[i] }
        }
        let probes = domains.map { AdBlockProbe(domain: $0.0, shouldBlock: $0.1, verdict: verdicts[$0.0] ?? .unknown) }
        return AdBlockMeasure(date: Date(), level: level, probes: probes)
    }

    /// The DNS servers the network gives this Mac (the box, most of the time).
    static func networkResolvers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "Heartware.adblock" as CFString, nil, nil),
              let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] else { return [] }
        return dns["ServerAddresses"] as? [String] ?? []
    }
}

/// `Heartware --adblock …`: the ad blocker from the command line, to measure it and check the profile it writes.
///   --adblock mesure [mac|equilibre|maximal]   what is blocked, on this Mac or through a level's resolver
///   --adblock etat                              what this Mac's resolver does now
///   --adblock extensions                        Safari's ad-blocking extensions
///   --adblock compteur [minutes]                the ads stopped in the last minutes, from macOS' log
///   --adblock verifier <domaine>                one domain, on this Mac and through both levels
///   --adblock profil <fichier.mobileconfig>     writes the profile (Maximal) for inspection, never over a file
///   --adblock video <lien> [image.png]          « Vidéo seule » on a real page (`AdBlockVideoBench`), muted
///   --adblock detecteur <lien> [app|regles|nu] [image.png]   a site's anti-adblock check (`AdBlockDetectorBench`)
///   --adblock pip [page.html|lien|menu:<pid>|croix:<pid>]  the picture-in-picture script of « Détacher la vidéo » in a WebKit view of the app
enum AdBlockCLI {
    static func run(_ args: [String]) async {
        switch args.first ?? "" {
        case "mesure":
            let which = args.dropFirst().first ?? "mac"
            let level: AdBlockLevel? = which == "equilibre" ? .balanced : which == "maximal" ? .maximal : nil
            let start = Date()
            let m = await AdBlockProbes.measure(level: level)
            print("Mesure \(level.map { "du niveau \($0.title) (\($0.list))" } ?? "de ce Mac") en \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
            print("Pubs et pisteurs bloqués : \(m.blockedAds)/\(m.ads.count) (\(Int(m.share * 100)) %) · sites utiles bloqués : \(m.brokenUseful)/\(m.useful.count)\(m.offline ? " · pas de réseau ?" : "")")
            for p in m.probes where !p.good { print("  \(p.shouldBlock ? "passe" : "bloqué à tort") : \(p.domain) (\(p.verdict.rawValue))") }
        case "suivre":
            // The live counter, as the app runs it, for N seconds (60 by default): what it hands over and what it costs.
            let seconds = Double(args.dropFirst().first ?? "60") ?? 60
            final class Got: @unchecked Sendable { var events: [AdBlockLog.Event] = []; var error: String? }
            let got = Got()
            let stream = AdBlockLogStream(onEvents: { got.events += $0 }, onError: { got.error = $0 })
            var usage = rusage()
            getrusage(RUSAGE_CHILDREN, &usage)
            stream.start()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            stream.stop()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var after = rusage()
            getrusage(RUSAGE_CHILDREN, &after)
            let child = Double(after.ru_utime.tv_sec - usage.ru_utime.tv_sec + after.ru_stime.tv_sec - usage.ru_stime.tv_sec)
                + Double(after.ru_utime.tv_usec - usage.ru_utime.tv_usec + after.ru_stime.tv_usec - usage.ru_stime.tv_usec) / 1e6
            print("\(got.events.count) pubs et pisteurs arrêtés en \(Int(seconds)) s · processeur de log stream : \(String(format: "%.2f", child)) s"
                  + (got.error.map { " · \($0)" } ?? ""))
            for (app, n) in Dictionary(grouping: got.events, by: \.app).mapValues(\.count).sorted(by: { $0.value > $1.value }) { print("  \(app) : \(n)") }
        case "compteur":
            // The last N minutes of macOS' log (60 by default), as the counter reads them.
            let minutes = Double(args.dropFirst().first ?? "60") ?? 60
            let start = Date()
            switch AdBlockLog.read(from: Date().addingTimeInterval(-minutes * 60), to: Date()) {
            case .success(let events):
                var t = AdBlockTally()
                t.add(events, readUntil: Date())
                print("\(Fmt.int(t.total)) pubs et pisteurs arrêtés en \(Int(minutes)) min (lu en \(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
                for (app, n) in t.apps.sorted(by: { $0.value > $1.value }) { print("  \(app) : \(n)") }
                for e in AdBlockFun.equivalences(t.total) { print("  \(e.value) \(e.text)") }
            case .failure(.unreadable(let why)):
                print("Journal illisible : \(why)")
            }
        case "extensions":
            let found = AdBlockBrowser.installed()
            print(found.isEmpty ? "Aucune extension anti-pub dans Safari" : found.map { "\($0.name) (\($0.identifier))\($0.youtube ? " · pubs YouTube" : "")" }.joined(separator: "\n"))
        case "etat":
            print("État : \(describe(AdBlockProbes.state())) · DNS du réseau : \(AdBlockProbes.networkResolvers().joined(separator: ", "))")
        case "verifier":
            guard let d = args.dropFirst().first.flatMap({ AdBlockDomain.normalize($0, keepWWW: true) }) else { print("Domaine invalide"); return }
            print("\(d) sur ce Mac : \(AdBlockProbes.systemVerdict(d).rawValue)")
            for level in AdBlockLevel.allCases { print("\(d) avec \(level.title) : \(await AdBlockProbes.resolverVerdict(d, level: level).rawValue)") }
        case "profil":
            guard let path = args.dropFirst().first, let data = AdBlockProfile.data(level: .maximal, exceptions: []) else {
                print("Indique le fichier à écrire.")
                return
            }
            do { print("Écrit : \(try FileOps.write(data, to: URL(fileURLWithPath: path)).path)") } catch { print("Échec : \(error.localizedDescription)") }
        case "video":
            let raw = args.dropFirst().first ?? ""
            guard let url = await MainActor.run(body: { AdBlockPlayer.playable(raw) }) else {
                print("Indique un lien YouTube, Twitch, France.tv, M6+, Arte ou Pluto TV.")
                return
            }
            let png = args.dropFirst(2).first
            await AdBlockVideoBench.run(url, png: png)
        case "detecteur":
            let rest = Array(args.dropFirst())
            guard let url = await MainActor.run(body: { rest.first.flatMap(AdBlockPlayer.playable) }) else {
                print("Indique un lien YouTube, Twitch, France.tv, M6+, Arte ou Pluto TV.")
                return
            }
            let mode = rest.dropFirst().first { AdBlockDetectorBench.modes.contains($0) } ?? "app"
            await AdBlockDetectorBench.run(url, mode: mode, png: rest.dropFirst().first { $0.hasSuffix(".png") })
        case "bascule":
            await MainActor.run { AdBlockHandoff.bench(Array(args.dropFirst())) }
        case "pip":
            // The picture-in-picture scripts in a WebKit view of the app, on a page of its own or the one given.
            await AdBlockPiPBench.run(args.dropFirst().first)
        default:
            print("Usage : --adblock mesure [mac|equilibre|maximal] | etat | extensions | compteur [minutes] | suivre [secondes] | verifier <domaine> | profil <fichier> | video <lien> [image.png] | detecteur <lien> [app|regles|nu] [image.png] | pip [page.html|lien|menu:<pid>|croix:<pid>] | bascule [lien…]")
        }
    }

    static func describe(_ s: AdBlockState) -> String {
        switch s {
        case .unknown, .checking: return "inconnu"
        case .off: return "pubs non bloquées"
        case .offline: return "pas de réseau"
        case .on(let level): return "pubs bloquées" + (level.map { " (niveau \($0.title))" } ?? "")
        }
    }
}

/// `--adblock detecteur <lien> [app|regles|nu] [image.png]` : a page in the player's WebKit view, as the app shows it
/// (`app`), with the blocking rules alone (`regles`: what the player did before a site got a script of its own) or with
/// nothing (`nu`, still behind this Mac's DNS), on screen, muted, its cookies refused, for about 30 s. Lists the requests
/// to ad servers and what came back, whether the page shows an anti-adblock message, which of the player's scripts run
/// and whether a video plays; on France.tv, also asks the player's own check (`magnetoscope.isAdserverReachable`, loaded
/// by the bench when the page holds it back for a sign-in).
@MainActor
enum AdBlockDetectorBench {
    nonisolated static let modes = ["app", "regles", "nu"]

    private final class Listener: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { messages.append(body) }
        }
    }

    /// Notes the requests to ad servers (fetch, XHR, script, image) and their outcome, as the page sees them (installed
    /// after the player's scripts, so it wraps them); the bench never plays a sound.
    private static let recorder = #"""
    (() => {
      if (window.__cmcBench) return;
      const log = window.__cmcBench = [];
      const ads = /fwmrm|freewheel|stickyadstv|smartadserver|outbrain|doubleclick|googlesyndication|imasdk|amazon-adsystem|scorecardresearch/i;
      const note = (kind, url) => { const e = { kind, url: String(url).slice(0, 150) }; if (ads.test(e.url)) log.push(e); return e; };
      const f = window.fetch;
      window.fetch = function (input) {
        const e = note('fetch', input instanceof Request ? input.url : input);
        const p = f.apply(this, arguments);
        p.then(r => { e.result = 'HTTP ' + r.status; }, x => { e.result = 'échec (' + (x && x.name) + ')'; });
        return p;
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, u) {
        const e = note('xhr', u);
        this.addEventListener('loadend', () => { e.result = this.status ? 'HTTP ' + this.status : 'échec'; });
        return open.apply(this, arguments);
      };
      for (const t of ['error', 'load']) addEventListener(t, ev => {
        const el = ev.target, u = el && (el.src || el.href);
        if (u && el.tagName && ads.test(u)) note(el.tagName.toLowerCase(), u).result = t === 'load' ? 'chargé' : 'échec';
      }, true);
      const p = HTMLMediaElement.prototype, play = p.play;
      p.play = function () { this.muted = true; return play.apply(this, arguments); };
      document.addEventListener('volumechange', e => { if (e.target.muted === false) e.target.muted = true; }, true);
    })();
    """#

    private static let state = #"""
    (() => {
      const text = document.body ? document.body.innerText : '';
      const wall = text.split('\n').find(l => /bloqueur de pub/i.test(l)) || null;
      const videos = [...document.querySelectorAll('video')].filter(v => v.videoWidth > 0)
        .map(v => v.videoWidth + '×' + v.videoHeight + ' à ' + Math.round(v.currentTime) + ' s' + (v.paused ? ', en pause' : ', en lecture'));
      const scripts = ['__cmcAdFree', '__cmcTwitch', '__cmcFranceTV'].filter(k => window[k]);
      return JSON.stringify({ page: location.href, title: document.title, wall, videos, scripts, ads: window.__cmcBench || [] });
    })()
    """#

    /// The cookie banner refused (« Continuer sans accepter », « Tout refuser », « Je refuse », « Rejeter »), for a picture of the page itself.
    private static let refuseCookies = #"""
    (() => {
      const b = [...document.querySelectorAll('button, a, span')].find(e => /^(continuer sans accepter|tout refuser|je refuse|rejeter)/i.test((e.innerText || '').trim()));
      if (b) b.click();
      return !!b;
    })()
    """#

    /// France.tv's player answers whether its ad server is reachable: false is the wall « Un bloqueur de publicités ».
    private static let francetvCheck = #"""
    if (!/(^|\.)france\.tv$/.test(location.hostname)) return null;
    let loaded = false;
    if (!window.magnetoscope) {
      const m = document.documentElement.innerHTML.match(/https:\/\/static\.francetv\.fr\/magnetoscope\/[\w.\/-]+\.js(\?\w*)?/);
      if (!m) return 'lecteur introuvable dans la page';
      await new Promise((ok, ko) => {
        const s = document.createElement('script');
        s.src = m[0]; s.onload = ok; s.onerror = () => ko(new Error('script du lecteur refusé'));
        document.head.appendChild(s);
      });
      loaded = true;
    }
    const t0 = performance.now();
    const reachable = await window.magnetoscope.isAdserverReachable();
    return JSON.stringify({ reachable, ms: Math.round(performance.now() - t0), loadedByBench: loaded });
    """#

    static func run(_ url: URL, mode: String, png: String?) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let listener = Listener()
        let config: WKWebViewConfiguration
        if mode == "nu" {
            config = WKWebViewConfiguration()
            config.applicationNameForUserAgent = "Version/\(AdBlockPlayer.safariVersion) Safari/605.1.15"
            config.mediaTypesRequiringUserActionForPlayback = []
            config.userContentController.add(listener, name: "hw")
        } else {
            config = AdBlockPlayer.configuration(handler: listener, journal: false, videoOnly: false)
            if mode == "regles" { config.userContentController.removeAllUserScripts() }
        }
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: recorder, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        // The rules are compiled while the window comes up (they are in place before the page asks for anything).
        await AdBlockVideoBench.pump(1)
        let size = NSSize(width: 960, height: 540)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        window.level = .floating
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        window.contentView = web
        window.orderFrontRegardless()
        let start = Date()
        web.load(URLRequest(url: url))
        print("Détecteur (\(mode)) : \(url.absoluteString)")
        await AdBlockVideoBench.pump(8)
        if (try? await web.evaluateJavaScript(refuseCookies) as? Bool) == true { print("  cookies refusés") }
        await AdBlockVideoBench.pump(6)
        if let check = try? await web.callAsyncJavaScript(francetvCheck, contentWorld: .page) as? String {
            print("  France.tv, isAdserverReachable : \(check)")
        }
        await AdBlockVideoBench.pump(12)
        print(String(format: "Attendu %.0f s", Date().timeIntervalSince(start)))
        for m in listener.messages { print("  message : " + m.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")) }
        if let info = try? await web.evaluateJavaScript(state) as? String,
           let json = try? JSONSerialization.jsonObject(with: Data(info.utf8)) as? [String: Any] {
            print("  page : \(json["title"] ?? "") · \(json["page"] ?? "")")
            print("  message anti-bloqueur : \(json["wall"] as? String ?? "aucun")")
            print("  scripts du lecteur actifs : \((json["scripts"] as? [String]).map { $0.isEmpty ? "aucun" : $0.joined(separator: ", ") } ?? "?")")
            let videos = json["videos"] as? [String] ?? []
            print("  vidéos : \(videos.isEmpty ? "aucune" : videos.joined(separator: " · "))")
            for a in json["ads"] as? [[String: Any]] ?? [] {
                print("  pub \(a["kind"] ?? "") \(a["url"] ?? "") → \(a["result"] ?? "sans réponse")")
            }
        }
        if let png, let image = try? await web.takeSnapshot(configuration: nil),
           let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            do { print("  image : \(try FileOps.write(data, to: URL(fileURLWithPath: png)).path)") } catch { print("  image : échec, \(error.localizedDescription)") }
        }
        window.close()
    }
}
