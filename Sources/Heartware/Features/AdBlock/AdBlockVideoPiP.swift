import SwiftUI
import AppKit
import WebKit
import JavaScriptCore

/// Why the last « Détacher la vidéo » did not go through, under the button.
struct AdBlockDetachIssue: Equatable {
    var text: String
    /// The « ? » whose steps settle it.
    var tip: HelpTip?
    /// The permission that settles it, behind a « Réglages… » button.
    var settings: AdBlockDetachSettings?
}

/// What the « Réglages… » button next to the line opens.
enum AdBlockDetachSettings: Equatable {
    /// System Settings' Automation pane: the app may drive the browser.
    case automation
    /// macOS' Accessibility prompt: the app may use Safari's own picture-in-picture command.
    case accessibility

    @MainActor
    func open() {
        switch self {
        case .automation: Finder.open(PermissionKind.safari.settingsURL)
        case .accessibility: AppPermission.accessibility.request()
        }
    }
}

/// Where « Détacher la vidéo » takes the browser's front tab.
enum AdBlockDetachRoute: Equatable {
    /// YouTube, Twitch, France.tv…: the page goes on in the ad-free player, video only.
    case player(URL)
    /// Any other page (Netflix, Prime Video, Disney+…): the browser's own picture in picture. `site`: its name, when known.
    case browser(site: String?)
    /// No web page in that tab (Safari's start page, a blank tab…).
    case nothing
}

/// What the page answered to `AdBlockVideoPiP.request`, then to `check`.
enum AdBlockPiPAnswer: Equatable {
    /// The browser was asked; `lifted`: the page had forbidden the picture in picture on that video.
    case asked(lifted: Bool)
    case entered
    case already
    /// Still in the page; `error`: why, when the browser said it.
    case inline(error: String)
    /// It went into picture in picture, and the page brought it straight back (TF1+'s player in Safari does).
    case kicked
    /// The player is in a frame of another origin (TF1+: prod-player.tf1.fr inside www.tf1.fr): the browser runs the
    /// app's script in the page only, never in such a frame. `site`: the frame's platform, when known.
    case inFrame(site: String?)
    case noVideo
    case unsupported
    case refused(error: String)
    case unreadable
}

/// What the user is told.
struct AdBlockPiPVerdict: Equatable {
    var success: Bool
    var hud: String
    var issue: AdBlockDetachIssue?
}

/// « Détacher la vidéo » on a page the player does not show: Netflix, Prime Video, Disney+ and the other platforms whose
/// videos are protected (DRM), or any page with a video. The browser keeps playing it (its session, its licence) and puts
/// it in its own picture in picture, a window above the others on every desktop. Nothing is bypassed: the script finds the
/// video being watched and asks the browser for the mode it offers by itself (Safari's audio button does the same).
enum AdBlockVideoPiP {
    /// The platforms named in the messages (any other page with a video works the same).
    static let platforms: [(name: String, domains: [String])] = [
        ("Netflix", ["netflix.com"]),
        ("Prime Video", ["primevideo.com"]),
        ("Disney+", ["disneyplus.com"]),
        ("Canal+", ["canalplus.com", "mycanal.fr"]),
        ("HBO Max", ["hbomax.com", "max.com"]),
        ("Apple TV", ["tv.apple.com"]),
        ("Paramount+", ["paramountplus.com"]),
        ("Crunchyroll", ["crunchyroll.com"]),
        ("ADN", ["animationdigitalnetwork.fr", "animationdigitalnetwork.com"]),
        ("MUBI", ["mubi.com"]),
        ("Molotov", ["molotov.tv"]),
        ("OCS", ["ocs.fr"]),
        ("TF1+", ["tf1.fr"]),
        ("Rakuten TV", ["rakuten.tv"]),
        ("Dailymotion", ["dailymotion.com"]),
        ("Vimeo", ["vimeo.com"])
    ]

    static func site(of url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if let name = site(host: host) { return name }
        if host.split(separator: ".").contains("amazon"), url.path.hasPrefix("/gp/video") { return "Prime Video" }
        return nil
    }

    static func site(host raw: String) -> String? {
        let host = raw.lowercased()
        return platforms.first(where: { p in p.domains.contains { host == $0 || host.hasSuffix("." + $0) } })?.name
    }

    /// The player for its platforms, the browser's picture in picture for any other web page.
    @MainActor
    static func route(_ raw: String) -> AdBlockDetachRoute {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return .nothing }
        let web = scheme == "http" || scheme == "https"
        if web, let page = AdBlockPlayer.playable(text) { return .player(page) }
        guard web || scheme == "file" else { return .nothing }
        return .browser(site: site(of: url))
    }

    // MARK: The scripts

    /// `text` as an AppleScript string: quotes and backslashes escaped, line breaks written as escapes.
    static func literal(_ text: String) -> String {
        var out = "\""
        for c in text.unicodeScalars {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }

    /// Run in the browser's tab. Finds the video being watched (the largest one playing on screen, else the largest one,
    /// in the page, its open shadow roots and its frames of the same origin), lets it go into picture in picture if the
    /// page forbade it, and asks the browser for it. The answer is JSON; the browser takes a moment: `check` tells after.
    /// A player in a frame of another origin is out of reach (the browser keeps the page's script out of it): when such
    /// a frame shows more than any video the page holds, it says so ("frame", with the frame's host) instead.
    static let request = #"""
    (() => {
      const videos = [], frames = [];
      const shown = (e) => {
        const r = e.getBoundingClientRect();
        const w = (e.ownerDocument && e.ownerDocument.defaultView) || window;
        const x = Math.min(r.right, w.innerWidth) - Math.max(r.left, 0);
        const y = Math.min(r.bottom, w.innerHeight) - Math.max(r.top, 0);
        return x > 0 && y > 0 ? x * y : 0;
      };
      // A frame made for a player (an embed, a live, the right to play full screen or encrypted media): not an ad box.
      const player = (e, src) => {
        try {
          return e.hasAttribute('allowfullscreen') || e.hasAttribute('webkitallowfullscreen')
            || /autoplay|encrypted-media|fullscreen|picture-in-picture/.test(e.getAttribute('allow') || '')
            || /player|embed|video|live|stream|watch/i.test(src);
        } catch (x) { return false; }
      };
      const look = (root, depth) => {
        let all = [];
        try { all = root.querySelectorAll('*'); } catch (e) { return; }
        for (const e of all) {
          if (e.tagName === 'VIDEO') videos.push(e);
          if (depth < 4 && e.shadowRoot) look(e.shadowRoot, depth + 1);
          if (e.tagName === 'IFRAME' || e.tagName === 'FRAME') {
            let d = null;
            try { d = e.contentDocument; } catch (x) {}
            if (d) {
              if (depth < 4) look(d, depth + 1);
            } else {
              const src = String(e.src || '');
              const m = /^[a-z][a-z0-9+.-]*:\/\/([^\/?#:]+)/i.exec(src);
              let area = 0;
              try { area = shown(e); } catch (x) {}
              if (area > 0 && player(e, src)) frames.push({ host: m ? m[1].toLowerCase() : '', area: area });
            }
          }
        }
      };
      look(document, 0);
      const inPip = (v) => {
        const root = v.getRootNode ? v.getRootNode() : null;
        return v.webkitPresentationMode === 'picture-in-picture' || !!(root && root.pictureInPictureElement === v);
      };
      if (videos.some(inPip)) return JSON.stringify({ state: 'already', videos: videos.length });
      const playing = (v) => !v.paused && !v.ended && v.readyState > 2;
      let best = null, tier = -1, most = -1;
      for (const v of videos) {
        const a = shown(v);
        const t = playing(v) && a > 0 ? 2 : v.readyState > 0 ? 1 : 0;
        if (t > tier || (t === tier && a > most)) { best = v; tier = t; most = a; }
      }
      // A video playing on screen wins; otherwise a player frame larger than any video of the page (a small paused
      // preview beside it, say) is where the user watches.
      let shut = null;
      for (const f of frames) if (f.area >= 240 * 135 && (!shut || f.area > shut.area)) shut = f;
      if (shut && tier < 2 && shut.area > Math.max(most, 0)) {
        return JSON.stringify({ state: 'frame', host: shut.host, videos: videos.length, frames: frames.length });
      }
      if (!best || (tier === 0 && most === 0)) return JSON.stringify({ state: 'none', videos: videos.length, frames: frames.length });
      const lifted = best.disablePictureInPicture === true || best.hasAttribute('disablepictureinpicture');
      if (lifted) {
        best.removeAttribute('disablepictureinpicture');
        try { best.disablePictureInPicture = false; } catch (e) {}
      }
      const pip = window.__cmcPip = { video: best, error: '', seen: false };
      // Did it go into picture in picture at all? Some pages bring it straight back (TF1+'s player does): heard first,
      // in the capture phase of the video's own tree, before the page's listeners on the video. Added once per page.
      if (!window.__cmcPipSeen) {
        window.__cmcPipSeen = (ev) => {
          const p = window.__cmcPip, v = p && p.video;
          if (!v || ev.target !== v) return;
          const r = v.getRootNode ? v.getRootNode() : null;
          if (v.webkitPresentationMode === 'picture-in-picture' || (r && r.pictureInPictureElement === v)) p.seen = true;
        };
      }
      try {
        const root = best.getRootNode ? best.getRootNode() : null;
        for (const name of ['webkitpresentationmodechanged', 'enterpictureinpicture']) {
          if (root && root.addEventListener) root.addEventListener(name, window.__cmcPipSeen, true);
          best.addEventListener(name, window.__cmcPipSeen);
        }
      } catch (e) {}
      let how = 'webkit';
      try {
        if (typeof best.webkitSetPresentationMode === 'function'
            && (typeof best.webkitSupportsPresentationMode !== 'function' || best.webkitSupportsPresentationMode('picture-in-picture'))) {
          best.webkitSetPresentationMode('picture-in-picture');
        } else if (typeof best.requestPictureInPicture === 'function') {
          how = 'standard';
          const p = best.requestPictureInPicture();
          if (p && p.catch) p.catch((e) => { pip.error = String((e && e.name) || e); });
        } else {
          return JSON.stringify({ state: 'unsupported', videos: videos.length });
        }
      } catch (e) {
        return JSON.stringify({ state: 'refused', error: String((e && e.name) || e), videos: videos.length });
      }
      return JSON.stringify({ state: 'asked', how: how, lifted: lifted, playing: playing(best), videos: videos.length });
    })()
    """#

    /// Run a moment after `request`: is its video in picture in picture now? (`seen`: it was, a moment.)
    static let check = #"""
    (() => {
      const pip = window.__cmcPip;
      if (!pip || !pip.video) return JSON.stringify({ state: 'lost' });
      const v = pip.video;
      const root = v.getRootNode ? v.getRootNode() : null;
      const on = v.webkitPresentationMode === 'picture-in-picture' || !!(root && root.pictureInPictureElement === v);
      return JSON.stringify({ state: on ? 'pip' : 'inline', error: pip.error || '', seen: !!pip.seen });
    })()
    """#

    static func answer(from text: String) -> AdBlockPiPAnswer {
        guard let data = text.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = o["state"] as? String else { return .unreadable }
        let error = (o["error"] as? String).map { String($0.prefix(80)) } ?? ""
        switch state {
        case "asked": return .asked(lifted: o["lifted"] as? Bool ?? false)
        case "pip": return .entered
        case "already": return .already
        case "inline": return o["seen"] as? Bool == true ? .kicked : .inline(error: error)
        case "frame": return .inFrame(site: (o["host"] as? String).flatMap { site(host: $0) })
        case "none": return .noVideo
        case "unsupported": return .unsupported
        case "refused": return .refused(error: error)
        default: return .unreadable
        }
    }

    /// No video yet: the page may still be building its player. Asked again twice, `retryDelay` apart.
    static func retry(after answer: AdBlockPiPAnswer, attempt: Int) -> Bool {
        answer == .noVideo && attempt < 2
    }

    static let retryDelay = Duration.milliseconds(700)

    /// The page's script could not do it (a frame of another origin, a video it cannot see, as in a closed shadow root,
    /// or the browser kept the video in the page): the browser's own command may (`AdBlockSafariMenu`), since the
    /// browser sees every video of the page. Not when the page brought the video back by itself.
    static func wantsBrowserCommand(_ answer: AdBlockPiPAnswer) -> Bool {
        switch answer {
        case .inFrame, .noVideo, .inline, .unsupported, .refused: return true
        case .asked, .entered, .already, .kicked, .unreadable: return false
        }
    }

    /// The browser refuses scripts sent by Apple Events (Safari's « Autoriser JavaScript à partir des évènements Apple »,
    /// Chrome's « Allow JavaScript from Apple Events »): both say so in their error.
    static func scriptsRefused(_ error: String) -> Bool {
        error.localizedCaseInsensitiveContains("javascript")
    }

    // MARK: The messages

    /// `menu`: what Safari's own command did after the page's script, when it was tried (`AdBlockSafariMenu`).
    @MainActor
    static func verdict(_ answer: AdBlockPiPAnswer, browser b: AdBlockVideoBrowser, site pageSite: String?,
                        menu: AdBlockSafariMenuOutcome? = nil) -> AdBlockPiPVerdict {
        var site = pageSite
        if case .inFrame(let frameSite) = answer, site == nil { site = frameSite }
        switch menu {
        case .entered?: return verdict(.entered, browser: b, site: site)
        case .already?: return verdict(.already, browser: b, site: site)
        case .kicked?: return verdict(.kicked, browser: b, site: site)
        case .notOffered? where answer != .noVideo:
            let what = "\(b.name) ne propose pas l'image dans l'image pour \(site ?? "cette vidéo")"
            return AdBlockPiPVerdict(success: false, hud: what, issue: AdBlockDetachIssue(text: what + " : le site l'interdit sans doute."))
        case .noAccess?:
            let player = site.map { "Le lecteur de \($0)" } ?? "Le lecteur"
            return AdBlockPiPVerdict(success: false, hud: "\(site ?? "Vidéo dans un cadre") : \(way(b))",
                                     issue: AdBlockDetachIssue(text: "\(player) est dans un cadre fermé : autorise l'Accessibilité à \(AppEdition.name), il ouvrira le menu de la vidéo.",
                                                               settings: .accessibility))
        case .notOffered?, .failed?, nil:
            break // no video for Safari either, or its menu was not where expected: what the page said
        }
        switch answer {
        case .entered:
            return AdBlockPiPVerdict(success: true, hud: "\(site ?? "La vidéo") est dans l'image dans l'image de \(b.name)")
        case .already:
            return AdBlockPiPVerdict(success: true, hud: "\(site ?? "La vidéo") est déjà dans l'image dans l'image")
        case .kicked:
            return AdBlockPiPVerdict(success: false, hud: "\(site ?? "Le site") refuse l'image dans l'image",
                                     issue: AdBlockDetachIssue(text: "\(site ?? "Le site") ramène sa vidéo dans la page dès qu'elle en sort : il refuse l'image dans l'image."))
        case .inFrame:
            let player = site.map { "Le lecteur de \($0)" } ?? "Le lecteur"
            return AdBlockPiPVerdict(success: false, hud: "\(site ?? "Vidéo dans un cadre") : \(way(b))",
                                     issue: AdBlockDetachIssue(text: "\(player) est dans un cadre fermé : \(way(b))."))
        case .noVideo:
            let line = site.map { "Aucune vidéo dans la page de \($0) : lance-la, puis recommence." }
                ?? "Aucune vidéo dans l'onglet affiché de \(b.name) : lance-la, puis recommence."
            return AdBlockPiPVerdict(success: false, hud: site.map { "Aucune vidéo dans la page de \($0)" } ?? "Aucune vidéo dans l'onglet de \(b.name)",
                                     issue: AdBlockDetachIssue(text: line))
        case .asked, .inline, .unsupported, .refused, .unreadable:
            let f = fallback(b)
            return AdBlockPiPVerdict(success: false, hud: f.short, issue: AdBlockDetachIssue(text: f.line))
        }
    }

    /// The browser does not take scripts from the app yet: the steps are in the « ? ».
    @MainActor
    static func scriptsVerdict(_ b: AdBlockVideoBrowser, site: String?) -> AdBlockPiPVerdict {
        AdBlockPiPVerdict(success: false, hud: "\(b.name) doit d'abord écouter \(AppEdition.name) : Multimédia › Vidéo seule",
                          issue: AdBlockDetachIssue(text: "Pour \(site ?? "cette vidéo"), \(b.name) doit accepter le JavaScript des évènements Apple",
                                                    tip: AdBlockTips.safariPause))
    }

    /// The browser's own way to its picture in picture, in a few words. Safari: the video's own menu, which offers it
    /// even in a frame the app cannot reach (TF1+'s player).
    static func way(_ b: AdBlockVideoBrowser) -> String {
        switch b.bundleID {
        case "company.thebrowser.Browser": return "change d'onglet, la vidéo passe dans un coin"
        case "com.vivaldi.Vivaldi": return "bouton Image dans l'image au survol de la vidéo"
        default: return b.chromium ? "note de musique de la barre d'outils › Image dans l'image" : "clic droit sur la vidéo › Activer le mode Image dans l'image"
        }
    }

    /// The browser kept the video in the page: its own way to the picture in picture, in a line (`short` for the HUD).
    static func fallback(_ b: AdBlockVideoBrowser) -> (line: String, short: String) {
        let short = "\(b.name) a refusé : " + way(b)
        switch b.bundleID {
        case "company.thebrowser.Browser":
            return ("Arc a refusé : change d'onglet, Arc garde la vidéo qui joue dans un coin de l'écran.", short)
        case "com.vivaldi.Vivaldi":
            return ("Vivaldi a refusé : survole la vidéo et clique sur son bouton Image dans l'image.", short)
        default:
            if b.chromium {
                return ("\(b.name) a refusé : clique sur la note de musique de la barre d'outils › Image dans l'image.", short)
            }
            let way = way(b)
            return ("\(b.name) a refusé : \(way).", way.prefix(1).uppercased() + way.dropFirst())
        }
    }

    /// `--snapshot --page media --tab safari --pip refus|scripts|aucune|chrome|cadre|accessibilite|renvoyee`: the card
    /// after a page outside the player.
    @MainActor
    static func snapshotIssue(_ state: String) -> AdBlockDetachIssue? {
        let safari = AdBlockVideoBrowser.all[0]
        switch state {
        case "scripts": return scriptsVerdict(safari, site: "Netflix").issue
        case "aucune": return verdict(.noVideo, browser: safari, site: "Disney+").issue
        case "chrome": return verdict(.inline(error: "NotAllowedError"), browser: AdBlockVideoBrowser.all[2], site: "Prime Video").issue
        case "cadre": return verdict(.inFrame(site: "TF1+"), browser: safari, site: "TF1+").issue
        case "accessibilite": return verdict(.inFrame(site: "TF1+"), browser: safari, site: "TF1+", menu: .noAccess).issue
        case "renvoyee": return verdict(.kicked, browser: safari, site: "TF1+").issue
        default: return verdict(.inline(error: ""), browser: safari, site: "Netflix").issue
        }
    }

    // MARK: Checks

    @MainActor
    static func checks() -> [String] {
        var f: [String] = []
        func expect(_ ok: Bool, _ message: String) { if !ok { f.append("image dans l'image : " + message) } }

        // The player for its platforms, the browser's picture in picture elsewhere.
        let routes: [(String, AdBlockDetachRoute)] = [
            ("https://www.netflix.com/watch/81181818?trackId=1", .browser(site: "Netflix")),
            ("https://www.primevideo.com/detail/0ABC", .browser(site: "Prime Video")),
            ("https://www.amazon.fr/gp/video/detail/B0ABC", .browser(site: "Prime Video")),
            ("https://www.amazon.fr/dp/B0ABC", .browser(site: nil)),
            ("https://www.disneyplus.com/fr-fr/play/abc", .browser(site: "Disney+")),
            ("https://tv.apple.com/fr/episode/abc", .browser(site: "Apple TV")),
            ("https://www.apple.com/fr/", .browser(site: nil)),
            ("https://pasnetflix.com/watch", .browser(site: nil)),
            ("https://play.max.com/video/watch/abc", .browser(site: "HBO Max")),
            ("https://www.canalplus.com/live/", .browser(site: "Canal+")),
            ("https://exemple.fr/film.html", .browser(site: nil)),
            ("file:///Users/exemple/Movies/film.mp4", .browser(site: nil)),
            ("favorites://", .nothing),
            ("about:blank", .nothing),
            ("", .nothing)
        ]
        for (raw, want) in routes {
            let got = route(raw)
            expect(got == want, "« \(raw) » va vers \(got) au lieu de \(want)")
        }
        for raw in ["https://www.youtube.com/watch?v=abc", "https://www.twitch.tv/camille_des_cimes", "https://www.france.tv/series/abc",
                    "https://www.arte.tv/fr/videos/123/"] {
            if case .player = route(raw) {} else { expect(false, "« \(raw) » doit rester dans le lecteur sans pub") }
        }
        expect(Set(platforms.map(\.name)).count == platforms.count, "deux plateformes portent le même nom")
        expect(platforms.allSatisfy { $0.domains.allSatisfy { d in d == d.lowercased() && !d.contains("/") && d.contains(".") } },
               "domaine de plateforme mal écrit")

        // The scripts reach the browser unchanged through an AppleScript string.
        let tricky = "a\"b\\c\nd\te\r'f' « g » $h"
        for (name, text) in [("piège", tricky), ("demande", request), ("contrôle", check), ("pause", AdBlockVideoOnly.pause)] {
            var error: NSDictionary?
            let back = NSAppleScript(source: "return " + literal(text))?.executeAndReturnError(&error).stringValue
            expect(error == nil && back == text, "le script « \(name) » ne passe pas intact par AppleScript")
        }
        for b in AdBlockVideoBrowser.all {
            let script = b.javaScript(request)
            let target = "tell application id \"\(b.bundleID)\" to "
            expect(script.hasPrefix(target) && script.contains(literal(request)), "script d'image dans l'image de \(b.name)")
            expect(script.contains(b.chromium ? "execute active tab of front window javascript" : "do JavaScript"), "commande de \(b.name)")
        }

        // The page's answers.
        let answers: [(String, AdBlockPiPAnswer)] = [
            (#"{"state":"asked","how":"webkit","lifted":true,"playing":true,"videos":3}"#, .asked(lifted: true)),
            (#"{"state":"asked","how":"standard","lifted":false}"#, .asked(lifted: false)),
            (#"{"state":"pip","error":""}"#, .entered),
            (#"{"state":"already","videos":1}"#, .already),
            (#"{"state":"inline","error":"NotAllowedError"}"#, .inline(error: "NotAllowedError")),
            (#"{"state":"inline","error":"","seen":false}"#, .inline(error: "")),
            (#"{"state":"inline","error":"","seen":true}"#, .kicked),
            (#"{"state":"frame","host":"prod-player.tf1.fr","videos":0,"frames":1}"#, .inFrame(site: "TF1+")),
            (#"{"state":"frame","host":"player.exemple.net"}"#, .inFrame(site: nil)),
            (#"{"state":"frame","host":""}"#, .inFrame(site: nil)),
            (#"{"state":"none","videos":0}"#, .noVideo),
            (#"{"state":"unsupported"}"#, .unsupported),
            (#"{"state":"refused","error":"TypeError"}"#, .refused(error: "TypeError")),
            (#"{"state":"lost"}"#, .unreadable),
            ("missing value", .unreadable),
            ("", .unreadable)
        ]
        for (text, want) in answers { expect(answer(from: text) == want, "réponse « \(text) » mal lue") }
        expect(scriptsRefused("Vous devez activer l’option « Autoriser JavaScript à partir des évènements Apple » dans le menu Développement")
               && scriptsRefused("Executing JavaScript through AppleScript is turned off.")
               && !scriptsRefused("Safari got an error: Can’t get document 1."), "refus du JavaScript des évènements Apple mal reconnu")

        // No video yet: twice more, then the answer stands. Safari's own command only where the script could not.
        expect(retry(after: .noVideo, attempt: 0) && retry(after: .noVideo, attempt: 1) && !retry(after: .noVideo, attempt: 2),
               "une page sans vidéo doit être relue deux fois, pas plus")
        expect(!retry(after: .inFrame(site: nil), attempt: 0) && !retry(after: .asked(lifted: false), attempt: 0), "seule l'absence de vidéo se relit")
        let byMenu: [AdBlockPiPAnswer] = [.inFrame(site: "TF1+"), .noVideo, .inline(error: ""), .unsupported, .refused(error: "x")]
        let notByMenu: [AdBlockPiPAnswer] = [.entered, .already, .kicked, .unreadable, .asked(lifted: true)]
        expect(byMenu.allSatisfy(wantsBrowserCommand) && !notByMenu.contains(where: wantsBrowserCommand), "quand passer par le menu de Safari")
        expect(AdBlockVideoBrowser.all.filter(AdBlockSafariMenu.serves).map(\.name) == ["Safari", "Safari Technology Preview"],
               "seul Safari a un menu de la page")

        // The messages: one line each, the right way out for each browser.
        let safari = AdBlockVideoBrowser.all[0], chrome = AdBlockVideoBrowser.all[2]
        let done = verdict(.entered, browser: safari, site: "Netflix")
        expect(done.success && done.issue == nil && done.hud == "Netflix est dans l'image dans l'image de Safari", "message de réussite : \(done.hud)")
        let safariLine = verdict(.inline(error: ""), browser: safari, site: "Netflix")
        expect(safariLine.issue?.text == "Safari a refusé : clic droit sur la vidéo › Activer le mode Image dans l'image."
               && safariLine.hud == "Clic droit sur la vidéo › Activer le mode Image dans l'image", "repli de Safari : \(safariLine)")
        let chromeLine = verdict(.inline(error: "NotAllowedError"), browser: chrome, site: nil).issue?.text ?? ""
        expect(chromeLine.hasPrefix("Chrome a refusé") && chromeLine.contains("note de musique"), "repli de Chrome : \(chromeLine)")
        expect(scriptsVerdict(safari, site: "Netflix").issue?.tip == AdBlockTips.safariPause, "le refus du JavaScript doit montrer les étapes")
        expect(verdict(.noVideo, browser: safari, site: "Disney+").issue?.text.hasPrefix("Aucune vidéo dans la page de Disney+") == true, "pas de vidéo")
        let frame = verdict(.inFrame(site: "TF1+"), browser: safari, site: nil)
        expect(frame.issue?.text == "Le lecteur de TF1+ est dans un cadre fermé : clic droit sur la vidéo › Activer le mode Image dans l'image."
               && frame.issue?.settings == nil, "cadre d'une autre origine : \(frame.issue?.text ?? "")")
        let access = verdict(.inFrame(site: nil), browser: safari, site: "TF1+", menu: .noAccess)
        expect(access.issue?.settings == .accessibility && access.issue?.text.contains("Accessibilité") == true && access.hud.contains("clic droit sur la vidéo"),
               "sans l'Accessibilité : la ligne la demande, le message donne le geste à faire")
        expect(verdict(.inline(error: ""), browser: safari, site: "Netflix", menu: .entered).success
               && verdict(.inFrame(site: nil), browser: safari, site: "TF1+", menu: .failed("x")) == verdict(.inFrame(site: nil), browser: safari, site: "TF1+"),
               "le menu de Safari l'emporte quand il a réussi, la page sinon")
        expect(verdict(.kicked, browser: safari, site: "TF1+").issue?.text.hasPrefix("TF1+ ramène sa vidéo") == true
               && verdict(.inFrame(site: nil), browser: safari, site: "TF1+", menu: .kicked) == verdict(.kicked, browser: safari, site: "TF1+"),
               "vidéo ramenée dans la page")
        expect(verdict(.inFrame(site: nil), browser: safari, site: "TF1+", menu: .notOffered).issue?.text.hasPrefix("Safari ne propose pas") == true,
               "menu sans image dans l'image")
        expect(verdict(.noVideo, browser: safari, site: "Disney+", menu: .notOffered) == verdict(.noVideo, browser: safari, site: "Disney+")
               && verdict(.noVideo, browser: safari, site: nil, menu: .entered).success, "pas de vidéo pour la page : Safari en a trouvé une, ou pas")
        let all: [AdBlockPiPAnswer] = [.entered, .already, .noVideo, .inline(error: ""), .unsupported, .refused(error: "x"), .unreadable,
                                       .asked(lifted: false), .kicked, .inFrame(site: nil), .inFrame(site: "TF1+")]
        let menus: [AdBlockSafariMenuOutcome] = [.entered, .already, .kicked, .notOffered, .noAccess, .failed("x")]
        for b in AdBlockVideoBrowser.all {
            let verdicts = all.flatMap { a in [nil, "Netflix"].map { verdict(a, browser: b, site: $0) } }
                + menus.map { verdict(.inFrame(site: nil), browser: b, site: nil, menu: $0) } + [scriptsVerdict(b, site: nil)]
            for v in verdicts {
                expect(!v.hud.isEmpty && v.hud.count <= 90 && !v.hud.contains("\n"), "message trop long pour \(b.name) : \(v.hud)")
                expect((v.issue?.text.count ?? 0) <= 120 && v.success == (v.issue == nil), "ligne de \(b.name) : \(v.issue?.text ?? "")")
            }
        }

        f += AdBlockSafariMenu.checks()
        f += AdBlockPiPCloseGuard.checks()
        // The scripts in a JavaScript engine, on pages made up for the test.
        f += sceneChecks()
        return f
    }

    /// Pages without a browser: elements reduced to what the scripts read. A change of presentation is heard as in a
    /// browser: first in the capture phase of the video's tree, then on the video, in the order the listeners came.
    private static let mock = #"""
    var window = this, document = null;
    var view = { innerWidth: 1000, innerHeight: 600 };
    window.innerWidth = 1000; window.innerHeight = 600;
    function box(x, y, w, h) { return { left: x, top: y, right: x + w, bottom: y + h, width: w, height: h }; }
    function on(list, n, f) {
      for (var i = 0; i < list.length; i++) if (list[i].name === n && list[i].f === f) return;
      list.push({ name: n, f: f });
    }
    function fire(v, n) {
      var ev = { target: v, type: n };
      if (v.root) v.root.listeners.slice().forEach(function (l) { if (l.name === n) l.f(ev); });
      v.listeners.slice().forEach(function (l) { if (l.name === n) l.f(ev); });
    }
    function video(id, r, o) {
      var v = { id: id, tagName: 'VIDEO', paused: !o.playing, ended: false, readyState: o.ready === undefined ? 4 : o.ready,
                attrs: {}, disablePictureInPicture: !!o.disabled, webkitPresentationMode: o.pip ? 'picture-in-picture' : 'inline',
                asked: 0, listeners: [], ownerDocument: { defaultView: view } };
      if (o.disabled) v.attrs.disablepictureinpicture = '';
      v.getBoundingClientRect = function () { return r; };
      v.hasAttribute = function (n) { return Object.prototype.hasOwnProperty.call(v.attrs, n); };
      v.removeAttribute = function (n) { delete v.attrs[n]; };
      v.getRootNode = function () { return v.root; };
      v.addEventListener = function (n, f) { on(v.listeners, n, f); };
      if (o.standard) {
        v.webkitPresentationMode = undefined;
        v.requestPictureInPicture = function () { v.asked += 1; return Promise.reject({ name: 'NotAllowedError' }); };
      } else {
        v.webkitSupportsPresentationMode = function () { return !v.hasAttribute('disablepictureinpicture'); };
        v.webkitSetPresentationMode = function (m) {
          if (m === 'picture-in-picture') v.asked += 1;
          if (m === v.webkitPresentationMode) return;
          v.webkitPresentationMode = m;
          fire(v, 'webkitpresentationmodechanged');
        };
      }
      // TF1+'s player in Safari, word for word: back in the page as soon as it leaves it.
      if (o.kick) v.addEventListener('webkitpresentationmodechanged', function () { 'picture-in-picture' === v.webkitPresentationMode && v.webkitSetPresentationMode('inline'); });
      return v;
    }
    function frame(src, r, attrs, doc) {
      var f = { tagName: 'IFRAME', src: src, attrs: attrs, ownerDocument: { defaultView: view } };
      f.getBoundingClientRect = function () { return r; };
      f.hasAttribute = function (n) { return Object.prototype.hasOwnProperty.call(f.attrs, n); };
      f.getAttribute = function (n) { return f.hasAttribute(n) ? f.attrs[n] : null; };
      Object.defineProperty(f, 'contentDocument', { get: function () { if (doc === 'throw') throw new Error('autre origine'); return doc; } });
      return f;
    }
    function tree(nodes) {
      var r = { pictureInPictureElement: null, listeners: [], querySelectorAll: function () { return nodes; } };
      r.addEventListener = function (n, f, capture) { if (capture) on(r.listeners, n, f); };
      nodes.forEach(function (n) { if (n.tagName === 'VIDEO') n.root = r; });
      return r;
    }
    var tf1 = 'https://prod-player.tf1.fr/8.4.2/player/index.html?&config=%7B%7D';
    function scene(name) {
      window.__cmcPip = null;
      if (name === 'mix') {
        document = tree([
          video('petite', box(10, 10, 160, 90), { playing: true }),
          video('grande-en-pause', box(180, 10, 400, 225), {}),
          { tagName: 'DIV', shadowRoot: tree([video('protegee', box(590, 10, 320, 180), { playing: true, disabled: true })]) },
          video('loin', box(0, 4000, 480, 270), { playing: true }),
          frame(tf1, box(0, 240, 960, 540), { allowfullscreen: '' }, 'throw')
        ]);
      } else if (name === 'pause') {
        document = tree([
          video('petite', box(10, 10, 160, 90), {}),
          video('grande-en-pause', box(180, 10, 400, 225), {}),
          video('loin', box(0, 4000, 480, 270), {})
        ]);
      } else if (name === 'cadre') {
        document = tree([
          video('petite', box(10, 10, 160, 90), { playing: true }),
          frame('https://www.exemple.fr/lecteur', box(0, 100, 640, 360), { allowfullscreen: '' },
                tree([video('dans-le-cadre', box(0, 0, 640, 360), { playing: true })]))
        ]);
      } else if (name === 'autre-origine') {
        document = tree([frame(tf1, box(0, 60, 960, 540), { allow: 'autoplay; encrypted-media', allowfullscreen: '' }, null)]);
      } else if (name === 'apercu-et-cadre') {
        document = tree([
          video('apercu', box(10, 10, 320, 180), {}),
          frame('https://player.exemple.net/embed/abc', box(0, 200, 960, 400), {}, null)
        ]);
      } else if (name === 'lecture-et-cadre') {
        document = tree([
          video('film', box(0, 0, 640, 360), { playing: true }),
          frame('https://player.exemple.net/embed/abc', box(0, 0, 1000, 600), { allow: 'autoplay' }, null)
        ]);
      } else if (name === 'pub') {
        document = tree([
          frame('https://pub.exemple.net/annonce', box(600, 300, 300, 250), {}, null),
          frame('https://player.exemple.net/embed/abc', box(0, 4000, 960, 540), { allowfullscreen: '' }, null)
        ]);
      } else if (name === 'renvoyee') {
        document = tree([video('direct', box(0, 0, 640, 360), { playing: true, disabled: true, kick: true })]);
      } else if (name === 'vide') {
        document = tree([{ tagName: 'DIV' }]);
      } else if (name === 'rien-de-charge') {
        document = tree([video('vide', box(0, 4000, 480, 270), { ready: 0 })]);
      } else if (name === 'deja') {
        document = tree([video('film', box(0, 0, 640, 360), { playing: true, pip: true })]);
      } else if (name === 'chrome') {
        document = tree([video('film', box(0, 0, 640, 360), { playing: true, standard: true })]);
      }
      return 1;
    }
    function probe() {
      var p = window.__cmcPip;
      return JSON.stringify(p ? { id: p.video.id, attribute: p.video.hasAttribute('disablepictureinpicture'), asked: p.video.asked } : null);
    }
    """#

    private static func sceneChecks() -> [String] {
        var f: [String] = []
        func expect(_ ok: Bool, _ message: String) { if !ok { f.append("image dans l'image : " + message) } }
        guard let ctx = JSContext() else { return ["image dans l'image : pas de moteur JavaScript"] }
        func run(_ source: String) -> String {
            ctx.exception = nil
            let value = ctx.evaluateScript(source)?.toString() ?? ""
            if let e = ctx.exception { f.append("image dans l'image : erreur JavaScript « \(e) »"); ctx.exception = nil }
            return value
        }
        // Every script the browsers get parses (without running).
        ctx.setObject(request, forKeyedSubscript: "srcRequest" as NSString)
        ctx.setObject(check, forKeyedSubscript: "srcCheck" as NSString)
        ctx.setObject(AdBlockVideoOnly.pause, forKeyedSubscript: "srcPause" as NSString)
        ctx.setObject(AdBlockVideoOnly.script, forKeyedSubscript: "srcVideoOnly" as NSString)
        for name in ["srcRequest", "srcCheck", "srcPause", "srcVideoOnly"] {
            let r = run("(function () { try { new Function(\(name)); return 'ok'; } catch (e) { return String(e); } })()")
            expect(r == "ok", "\(name) ne se lit pas : \(r)")
        }
        _ = run(mock)
        struct Scene { var name: String; var want: AdBlockPiPAnswer; var pick: String? }
        let scenes = [
            // The largest video playing on screen, even in a shadow root and forbidden: before a larger one paused, a smaller
            // one, one playing off screen, and a frame of another origin that cannot be read.
            Scene(name: "mix", want: .asked(lifted: true), pick: "protegee"),
            Scene(name: "pause", want: .asked(lifted: false), pick: "grande-en-pause"),
            Scene(name: "cadre", want: .asked(lifted: false), pick: "dans-le-cadre"),
            // TF1+: its player alone, in a frame of another origin; a paused preview beside a larger player frame; a
            // video playing beside a frame; an ad box and a player frame off screen are no player.
            Scene(name: "autre-origine", want: .inFrame(site: "TF1+"), pick: nil),
            Scene(name: "apercu-et-cadre", want: .inFrame(site: nil), pick: nil),
            Scene(name: "lecture-et-cadre", want: .asked(lifted: false), pick: "film"),
            Scene(name: "pub", want: .noVideo, pick: nil),
            // Into picture in picture, and straight back (TF1+'s player in Safari).
            Scene(name: "renvoyee", want: .asked(lifted: true), pick: "direct"),
            Scene(name: "vide", want: .noVideo, pick: nil),
            Scene(name: "rien-de-charge", want: .noVideo, pick: nil),
            Scene(name: "deja", want: .already, pick: nil),
            Scene(name: "chrome", want: .asked(lifted: false), pick: "film")
        ]
        for s in scenes {
            _ = run("scene('\(s.name)')")
            let got = answer(from: run(request))
            expect(got == s.want, "page « \(s.name) » : \(got) au lieu de \(s.want)")
            let p = run("probe()")
            if let pick = s.pick {
                expect(p.contains("\"id\":\"\(pick)\"") && p.contains("\"attribute\":false") && p.contains("\"asked\":1"),
                       "page « \(s.name) » : vidéo choisie \(p) au lieu de \(pick), demandée une fois, sans interdiction")
            } else {
                expect(p == "null", "page « \(s.name) » : aucune vidéo ne devait être demandée (\(p))")
            }
            let after = answer(from: run(check))
            switch s.name {
            case "mix", "pause", "cadre", "lecture-et-cadre": expect(after == .entered, "page « \(s.name) » : \(after) après la demande")
            case "renvoyee": expect(after == .kicked, "page « renvoyee » : la vidéo ramenée dans la page n'est pas vue (\(after))")
            case "chrome": expect(after == .inline(error: "NotAllowedError"), "page « chrome » : le refus du navigateur n'est pas lu (\(after))")
            default: expect(after == .unreadable, "page « \(s.name) » : rien ne devait être suivi (\(after))")
            }
        }
        return f
    }
}

// MARK: - Safari's own command

/// What Safari's own picture-in-picture command did (`AdBlockSafariMenu`).
enum AdBlockSafariMenuOutcome: Equatable, Sendable {
    case entered
    case already
    /// A picture-in-picture window came and went at once: the page brought its video back.
    case kicked
    /// The video's menu, then the page menu, opened without a picture-in-picture item.
    case notOffered
    /// The app does not have the Accessibility permission (asked only after a click on « Réglages… »).
    case noAccess
    /// Something on the way was not where it should be (`why`: for the bench and the log).
    case failed(String)

    /// The video is in picture in picture, or was brought back by its page: nothing more to try.
    var settled: Bool {
        switch self {
        case .entered, .already, .kicked, .noAccess: return true
        case .notOffered, .failed: return false
        }
    }
}

/// An element of an accessibility tree, reduced to what the searches read; a tree is a flat list, breadth first.
/// `kind`: its role description (WebKit names a `<video>` « lecture vidéo »); `frame`: global, top left, in points.
struct AdBlockAXNode: Equatable, Sendable {
    var role = ""
    var title = ""
    var label = ""
    var identifier = ""
    var pressable = false
    var parent: Int?
    var kind = ""
    var frame = CGRect.zero
}

/// Safari's words for what the searches look for, in the language it shows them. `video`: WebKit's role description
/// of a `<video>`.
struct AdBlockSafariLabels: Equatable, Sendable {
    var enter: [String]
    var exit: [String]
    var pageMenu: [String]
    var video: [String] = []
}

/// Safari's own picture in picture, for a video the page's script cannot reach (a player in a frame of another origin,
/// as TF1+'s). First the video's own menu, the one a right click on it opens (WebKit's « Activer le mode Image dans
/// l'image »): the video is found in the accessibility tree of the front window's tab, frames included, and asked for
/// its menu (AXShowMenu, as VoiceOver's « menu contextuel »); then the page menu of the address field (« Menu de la
/// page »). Through the Accessibility only, and only once the user granted it: AXShowMenu and AXPress, never a key nor a
/// click. The menu shows for a moment, then the video leaves for its window, drawn by macOS' picture-in-picture agent:
/// that window tells whether it stayed.
enum AdBlockSafariMenu {
    static let pipAgent = "com.apple.PIPAgent"
    /// Safari's strings (its binary is in the system's shared cache, its resources on disk).
    static let safariFramework = "/System/Library/PrivateFrameworks/Safari.framework"
    /// WebKit's identifier of the picture-in-picture command of a video's menu (« Activer » or « Quitter » in its title).
    static let videoMenuIdentifier = "WKMenuItemIdentifierTogglePictureInPicture"

    /// Safari and its Technology Preview: the other browsers have no such menu.
    static func serves(_ b: AdBlockVideoBrowser) -> Bool { !b.chromium }

    // MARK: Pure parts

    /// Safari's words from its strings and WebKit's (`table`, `webCore`, in the user's language), with the French and
    /// English ones anyway.
    static func labels(table: [String: String]?, webCore: [String: String]? = nil) -> AdBlockSafariLabels {
        let safari = table ?? [:], webKit = webCore ?? [:]
        func words(_ keys: [String], _ fixed: [String], from tables: [[String: String]]) -> [String] {
            var out: [String] = []
            for w in tables.flatMap({ t in keys.compactMap { t[$0] } }) + fixed where !w.isEmpty && !out.contains(w) { out.append(w) }
            return out
        }
        return AdBlockSafariLabels(
            enter: words(["Enter Picture in Picture"], ["Activer le mode Image dans l’image", "Enter Picture in Picture"], from: [safari, webKit]),
            exit: words(["Exit Picture in Picture"], ["Quitter le mode Image dans l’image", "Exit Picture in Picture"], from: [safari, webKit]),
            pageMenu: words(["Page Menu (Accessibility Label)", "Page Menu with translate (Accessibility Label)"], ["Menu de la page", "Page Menu"], from: [safari]),
            video: words(["video playback"], ["lecture vidéo", "video playback"], from: [webKit]))
    }

    /// Compared without case, curly apostrophes, odd spaces nor a closing ellipsis.
    static func normalized(_ s: String) -> String {
        var t = s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        for space in ["\u{00A0}", "\u{202F}"] { t = t.replacingOccurrences(of: space, with: " ") }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        for tail in ["…", "..."] where t.hasSuffix(tail) {
            t = String(t.dropLast(tail.count)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    /// The page menu's button among the toolbar's elements (« Menu de la page, traduction disponible » too).
    static func pageMenuButton(_ nodes: [AdBlockAXNode], labels: AdBlockSafariLabels) -> Int? {
        if let i = nodes.firstIndex(where: { $0.identifier == "AssistantButton" && $0.pressable }) { return i }
        let names = labels.pageMenu.map(normalized).filter { !$0.isEmpty }
        return nodes.firstIndex { n in
            n.pressable && ["AXButton", "AXMenuButton", "AXPopUpButton"].contains(n.role)
                && [n.title, n.label].map(normalized).contains { text in names.contains { text.hasPrefix($0) } }
        }
    }

    /// The smallest video worth detaching, seen on screen: no thumbnail nor hover preview.
    static let smallestVideo = CGSize(width: 200, height: 112)

    /// The video being watched among a tab's elements (frames included): the largest one seen in `viewport` (the tab's
    /// web area), when it is no thumbnail. WebKit gives no « playing » in its tree: the size decides.
    static func video(_ nodes: [AdBlockAXNode], viewport: CGRect, labels: AdBlockSafariLabels) -> Int? {
        let kinds = Set(labels.video.map(normalized).filter { !$0.isEmpty })
        var best: Int?, most: CGFloat = 0
        for (i, n) in nodes.enumerated() where kinds.contains(normalized(n.kind)) {
            let seen = n.frame.intersection(viewport)
            guard !seen.isNull, seen.width >= smallestVideo.width, seen.height >= smallestVideo.height else { continue }
            let area = seen.width * seen.height
            if area > most { best = i; most = area }
        }
        return best
    }

    /// The command to press in the open menu, and whether it leaves the picture in picture (the video is already in
    /// it). WebKit's identifier first, then Safari's exact words, else a command speaking of picture in picture; text
    /// that cannot be pressed (or is disabled), nor be part of something that can, is not a command (the page's title).
    static func item(_ nodes: [AdBlockAXNode], labels: AdBlockSafariLabels) -> (index: Int, exit: Bool)? {
        let enter = Set(labels.enter.map(normalized)), exit = Set(labels.exit.map(normalized))
        let leaving = ["quitter", "exit", "sortir"]
        func pressable(_ i: Int) -> Int? {
            var j: Int? = i
            for _ in 0..<3 {
                guard let k = j else { return nil }
                if nodes[k].pressable { return k }
                j = nodes[k].parent
            }
            return nil
        }
        func texts(_ n: AdBlockAXNode) -> [String] { [n.title, n.label].map(normalized).filter { !$0.isEmpty } }
        if let i = nodes.firstIndex(where: { $0.identifier == videoMenuIdentifier && $0.pressable }) {
            let t = texts(nodes[i])
            return (i, t.contains(where: exit.contains) || t.contains { text in leaving.contains { text.hasPrefix($0) } })
        }
        for (i, n) in nodes.enumerated() {
            let t = texts(n)
            if t.contains(where: exit.contains), let k = pressable(i) { return (k, true) }
            if t.contains(where: enter.contains), let k = pressable(i) { return (k, false) }
        }
        let loose = ["image dans l'image", "picture in picture", "pictureinpicture"]
        for (i, n) in nodes.enumerated() where n.pressable || ["AXMenuItem", "AXButton"].contains(n.role) {
            let t = (texts(n) + [n.identifier.lowercased()]).joined(separator: " ")
            guard loose.contains(where: t.contains), let k = pressable(i) else { continue }
            return (k, leaving.contains(where: t.contains))
        }
        return nil
    }

    /// The video's menu, then the page menu: what the user is told. « Not offered » only when both menus opened
    /// without the command; a video menu that could not open (no video in the tree, a page that keeps its right click)
    /// leaves the right click to the user.
    static func combined(video: AdBlockSafariMenuOutcome, page: AdBlockSafariMenuOutcome) -> AdBlockSafariMenuOutcome {
        if video.settled { return video }
        if page.settled { return page }
        if video == .notOffered && page == .notOffered { return .notOffered }
        func why(_ o: AdBlockSafariMenuOutcome) -> String {
            if case .failed(let w) = o { return w }
            return "sans image dans l'image"
        }
        return .failed("menu de la vidéo : \(why(video)) · menu de la page : \(why(page))")
    }

    /// Enough watching: a window of the agent that was not there before the press has been there for `steady` samples.
    static func settled(before: Set<Int>, samples: [Set<Int>], steady: Int = 5) -> Bool {
        samples.count >= steady && samples.suffix(steady).allSatisfy { !$0.subtracting(before).isEmpty }
    }

    /// The agent's windows sampled after the press: one that came and stayed is the video; one that came and went, the
    /// page bringing it back; none, nothing happened.
    static func outcome(before: Set<Int>, samples: [Set<Int>]) -> AdBlockSafariMenuOutcome {
        let came = samples.reduce(Set<Int>()) { $0.union($1) }.subtracting(before)
        guard !came.isEmpty else { return .failed("aucune fenêtre d'image dans l'image") }
        return samples.last.map { !$0.isDisjoint(with: came) } == true ? .entered : .kicked
    }

    // MARK: The real thing

    /// Safari's strings in the language it shows (the user's first one it has).
    static func safariTable() -> [String: String]? { table(Bundle(path: safariFramework), language: nil) }

    /// WebKit's strings (its video's role description, its menu's words) in the language Safari shows.
    static func webCoreTable() -> [String: String]? {
        let safari = Bundle(path: safariFramework)
        let language = safari.flatMap { Bundle.preferredLocalizations(from: $0.localizations, forPreferences: Locale.preferredLanguages).first }
        return table(Bundle(identifier: "com.apple.WebCore"), language: language)
    }

    private static func table(_ bundle: Bundle?, language wanted: String?) -> [String: String]? {
        guard let bundle else { return nil }
        let language = wanted.flatMap { bundle.localizations.contains($0) ? $0 : nil }
            ?? Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: Locale.preferredLanguages).first
        guard let path = bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language) else { return nil }
        return NSDictionary(contentsOfFile: path) as? [String: String]
    }

    /// The windows macOS' picture-in-picture agent shows now (their numbers). No screen recording needed: their owner
    /// is all it reads.
    static func pipWindows() -> Set<Int> {
        let agents = Set(NSRunningApplication.runningApplications(withBundleIdentifier: pipAgent).map { Int($0.processIdentifier) })
        guard !agents.isEmpty else { return [] }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var out = Set<Int>()
        for w in list where agents.contains(w[kCGWindowOwnerPID as String] as? Int ?? -1) {
            if let n = w[kCGWindowNumber as String] as? Int { out.insert(n) }
        }
        return out
    }

    /// The pop-up menus `pid` shows now: their number and frame (global, top left).
    private static func popUpMenus(_ pid: pid_t) -> [Int: CGRect] {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var out: [Int: CGRect] = [:]
        for w in list where w[kCGWindowOwnerPID as String] as? Int == Int(pid) && w[kCGWindowLayer as String] as? Int == level {
            guard let n = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            out[n] = r
        }
        return out
    }

    /// Opens the video's menu of the browser's front window, else its page menu, presses the picture-in-picture
    /// command and watches its window. Blocking (about five seconds at most): off the main thread.
    static func enterPictureInPicture(bundleID: String) -> AdBlockSafariMenuOutcome {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else {
            return .failed("navigateur fermé")
        }
        return enterPictureInPicture(pid: pid)
    }

    /// The same in the process `pid` (the bench gives its own, with a video and a page menu of its own). `log`: each step.
    static func enterPictureInPicture(pid: pid_t, log: ((String) -> Void)? = nil) -> AdBlockSafariMenuOutcome {
        guard AXIsProcessTrusted() else { return .noAccess }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let window = element(app, kAXMainWindowAttribute) ?? children(app, kAXWindowsAttribute).first else {
            return .failed("aucune fenêtre")
        }
        let labels = labels(table: safariTable(), webCore: webCoreTable())
        log?("mots de Safari et de WebKit : vidéo « \(labels.video.joined(separator: " », « ")) », commande « \(labels.enter.first ?? "") »")
        let byVideo = videoMenu(app: app, pid: pid, window: window, labels: labels, log: log)
        log?("menu de la vidéo : \(byVideo)")
        if byVideo.settled { return byVideo }
        let byPage = pageMenu(app: app, window: window, labels: labels)
        log?("menu de la page : \(byPage)")
        return combined(video: byVideo, page: byPage)
    }

    /// The video's own menu: the largest video of the tab (frames included) gets AXShowMenu, which WebKit answers as a
    /// right click in its middle; its picture-in-picture command gets AXPress. A menu without it is closed (AXCancel).
    private static func videoMenu(app: AXUIElement, pid: pid_t, window: AXUIElement, labels: AdBlockSafariLabels,
                                  log: ((String) -> Void)?) -> AdBlockSafariMenuOutcome {
        // WebKit builds its tree on the first question: an empty tab is asked again, briefly.
        var found: (video: AXUIElement, frame: CGRect, read: Int)?
        var page: AXUIElement?
        for attempt in 0..<3 where found == nil {
            if attempt > 0 { usleep(400_000) }
            page = page ?? webArea(window)
            if let page { found = largestVideo(in: page, labels: labels) }
        }
        guard let tab = page else { return .failed("aucune page dans la fenêtre") }
        guard let found else { return .failed("aucune vidéo dans l'arbre d'accessibilité") }
        log?("vidéo trouvée : \(Int(found.frame.width))×\(Int(found.frame.height)) en (\(Int(found.frame.minX)), \(Int(found.frame.minY))), \(found.read) éléments lus")
        // Where WebKit hangs its menu: an element around the tab's page (WKWebView's own), or a new pop-up menu.
        var around: [AXUIElement] = []
        var e = element(tab, kAXParentAttribute)
        for _ in 0..<8 {
            guard let current = e, string(current, kAXRoleAttribute) != "AXWindow" else { break }
            around.append(current)
            e = element(current, kAXParentAttribute)
        }
        let menusBefore = Set(popUpMenus(pid).keys)
        let before = pipWindows()
        // The answer comes once the menu is up: the call does not wait for it.
        AXUIElementSetMessagingTimeout(found.video, 0.5)
        let shown = AXUIElementPerformAction(found.video, kAXShowMenuAction as CFString)
        log?("AXShowMenu sur la vidéo : \(shown == .success ? "fait" : "code \(shown.rawValue)")")
        guard shown == .success || shown == .cannotComplete else { return .failed("menu de la vidéo refusé (\(shown.rawValue))") }
        var menu: AXUIElement?, place = ""
        for _ in 0..<15 where menu == nil {
            usleep(100_000)
            (menu, place) = videoMenuElement(app: app, pid: pid, around: around, menusBefore: menusBefore) ?? (nil, "")
        }
        guard let menu else { return .failed("le menu de la vidéo ne s'est pas ouvert") }
        let content = flatten(menu, depth: 2, limit: 80)
        log?("menu ouvert (\(place)) : " + content.nodes.filter { !$0.title.isEmpty }.map { "« \($0.title) »" + ($0.identifier.hasPrefix("WK") ? " (\($0.identifier))" : "") }.joined(separator: ", "))
        guard let hit = item(content.nodes, labels: labels) else {
            cancel(menu)
            return .notOffered
        }
        if hit.exit {
            cancel(menu)
            return .already
        }
        return press(content.elements[hit.index], before: before) { cancel(menu) }
    }

    /// The tab's page: the largest web area of the window, outside its toolbar.
    private static func webArea(_ window: AXUIElement) -> AXUIElement? {
        var queue = children(window).filter { string($0, kAXRoleAttribute) != "AXToolbar" }.map { ($0, 1) }
        var head = 0, best: AXUIElement?, most: CGFloat = 0
        while head < queue.count && head < 400 {
            let (e, level) = queue[head]
            head += 1
            if string(e, kAXRoleAttribute) == "AXWebArea" {
                let r = frame(e)
                if best == nil || r.width * r.height > most { best = e; most = r.width * r.height }
                continue
            }
            if level < 12 { queue += children(e).map { ($0, level + 1) } }
        }
        return best
    }

    /// The largest video seen in the tab, its frames included. Breadth first, one question per element; what lies
    /// entirely outside the tab's visible part is not entered (the watched video is on screen). Five thousand elements
    /// at most.
    private static func largestVideo(in tab: AXUIElement, labels: AdBlockSafariLabels) -> (video: AXUIElement, frame: CGRect, read: Int)? {
        let viewport = frame(tab)
        let kinds = Set(labels.video.map(normalized))
        let names = [kAXRoleDescriptionAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var queue: [AXUIElement] = children(tab)
        var head = 0
        var nodes: [AdBlockAXNode] = [], elements: [AXUIElement] = []
        while head < queue.count && head < 5000 {
            let e = queue[head]
            head += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(e, names, [], &values) == .success,
                  let v = values as? [AnyObject], v.count == 4 else { continue }
            let kind = v[0] as? String ?? ""
            var origin = CGPoint.zero, size = CGSize.zero
            if CFGetTypeID(v[2]) == AXValueGetTypeID() { AXValueGetValue(v[2] as! AXValue, .cgPoint, &origin) }
            if CFGetTypeID(v[3]) == AXValueGetTypeID() { AXValueGetValue(v[3] as! AXValue, .cgSize, &size) }
            let box = CGRect(origin: origin, size: size)
            if kinds.contains(normalized(kind)) {
                nodes.append(AdBlockAXNode(kind: kind, frame: box))
                elements.append(e)
                continue
            }
            if size.width > 0, size.height > 0, !box.intersects(viewport) { continue }
            queue += v[1] as? [AXUIElement] ?? []
        }
        guard let i = video(nodes, viewport: viewport, labels: labels) else { return nil }
        return (elements[i], nodes[i].frame, head)
    }

    /// The video's menu once up: under an element around the tab's page, else under the new pop-up menu window of the
    /// browser (asked at its middle), else beside its windows.
    private static func videoMenuElement(app: AXUIElement, pid: pid_t, around: [AXUIElement], menusBefore: Set<Int>) -> (AXUIElement, String)? {
        for e in around {
            if let m = children(e).first(where: { string($0, kAXRoleAttribute) == "AXMenu" }) { return (m, "autour de la page") }
        }
        for (number, box) in popUpMenus(pid) where !menusBefore.contains(number) {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(box.midX), Float(box.midY), &hit) == .success else { continue }
            var e = hit
            for _ in 0..<4 {
                guard let current = e else { break }
                if string(current, kAXRoleAttribute) == "AXMenu" { return (current, "fenêtre de menu") }
                e = element(current, kAXParentAttribute)
            }
        }
        return children(app).first { string($0, kAXRoleAttribute) == "AXMenu" }.map { ($0, "à côté des fenêtres") }
    }

    /// The page menu of the address field (« Menu de la page »): its button gets AXPress, then its command.
    private static func pageMenu(app: AXUIElement, window: AXUIElement, labels: AdBlockSafariLabels) -> AdBlockSafariMenuOutcome {
        let toolbar = children(window).first { string($0, kAXRoleAttribute) == "AXToolbar" }
        let bar = flatten(toolbar ?? window, depth: 6, limit: 300)
        guard let b = pageMenuButton(bar.nodes, labels: labels) else { return .failed("bouton du menu de la page introuvable") }
        let button = bar.elements[b]
        let before = pipWindows()
        // An open menu keeps the press waiting for its answer until it closes: the press does not wait for it.
        AXUIElementSetMessagingTimeout(button, 0.3)
        let pressed = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard pressed == .success || pressed == .cannotComplete else { return .failed("menu de la page refusé (\(pressed.rawValue))") }
        AXUIElementSetMessagingTimeout(button, 1)
        var menu: AXUIElement?
        for _ in 0..<15 where menu == nil {
            usleep(100_000)
            menu = openMenu(app: app, window: window, toolbar: toolbar, button: button)
        }
        guard let menu else { return .failed("le menu de la page ne s'est pas ouvert") }
        let content = flatten(menu, depth: 8, limit: 300)
        guard let hit = item(content.nodes, labels: labels) else {
            close(menu, button)
            return .notOffered
        }
        if hit.exit {
            close(menu, button)
            return .already
        }
        return press(content.elements[hit.index], before: before) { close(menu, button) }
    }

    /// Presses the command, then watches the agent's windows. `undo`: closes the menu if the press was refused.
    private static func press(_ command: AXUIElement, before: Set<Int>, undo: () -> Void) -> AdBlockSafariMenuOutcome {
        AXUIElementSetMessagingTimeout(command, 1)
        let done = AXUIElementPerformAction(command, kAXPressAction as CFString)
        guard done == .success || done == .cannotComplete else {
            undo()
            return .failed("commande refusée (\(done.rawValue))")
        }
        var samples: [Set<Int>] = []
        for _ in 0..<12 where !settled(before: before, samples: samples) {
            usleep(200_000)
            samples.append(pipWindows())
        }
        return outcome(before: before, samples: samples)
    }

    /// The menu (or popover) the press opened: under the button, beside the windows, in the window or its toolbar, or
    /// around what has the focus now.
    private static func openMenu(app: AXUIElement, window: AXUIElement, toolbar: AXUIElement?, button: AXUIElement) -> AXUIElement? {
        let kinds: Set<String> = ["AXMenu", "AXPopover"]
        var near = children(button) + children(app) + children(app, kAXWindowsAttribute) + children(window)
        if let toolbar { near += children(toolbar) }
        if let found = near.first(where: { kinds.contains(string($0, kAXRoleAttribute)) }) { return found }
        var e = element(app, kAXFocusedUIElementAttribute)
        for _ in 0..<8 {
            guard let current = e else { break }
            if kinds.contains(string(current, kAXRoleAttribute)) { return current }
            e = element(current, kAXParentAttribute)
        }
        return nil
    }

    /// Closes the menu left open (nothing to press in it).
    private static func close(_ menu: AXUIElement, _ button: AXUIElement) {
        if actions(menu).contains(kAXCancelAction) {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        } else {
            AXUIElementSetMessagingTimeout(button, 0.3)
            _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    /// Closes the video's menu (AXCancel, as Escape would).
    private static func cancel(_ menu: AXUIElement) {
        AXUIElementSetMessagingTimeout(menu, 0.5)
        _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
    }

    /// Breadth first under `root`, without the page itself (Safari's web area holds the whole page). A disabled item
    /// cannot be pressed.
    private static func flatten(_ root: AXUIElement, depth: Int, limit: Int) -> (elements: [AXUIElement], nodes: [AdBlockAXNode]) {
        var elements: [AXUIElement] = [], nodes: [AdBlockAXNode] = []
        var queue: [(element: AXUIElement, parent: Int?, level: Int)] = children(root).map { ($0, nil, 1) }
        var head = 0
        while head < queue.count && elements.count < limit {
            let next = queue[head]
            head += 1
            let role = string(next.element, kAXRoleAttribute)
            if role == "AXWebArea" { continue }
            let enabled = flag(next.element, kAXEnabledAttribute) ?? true
            nodes.append(AdBlockAXNode(role: role, title: string(next.element, kAXTitleAttribute), label: string(next.element, kAXDescriptionAttribute),
                                       identifier: string(next.element, "AXIdentifier"),
                                       pressable: enabled && actions(next.element).contains(kAXPressAction), parent: next.parent))
            elements.append(next.element)
            if next.level < depth {
                let index = elements.count - 1
                queue += children(next.element).map { ($0, index, next.level + 1) }
            }
        }
        return (elements, nodes)
    }

    static func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    static func children(_ e: AXUIElement, _ attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    static func string(_ e: AXUIElement, _ attribute: String) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &ref) == .success else { return "" }
        return ref as? String ?? ""
    }

    private static func flag(_ e: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &ref) == .success else { return nil }
        return ref as? Bool
    }

    /// Its frame on screen: global, top left, in points (as Quartz's events).
    static func frame(_ e: AXUIElement) -> CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &ref) == .success, let ref, CFGetTypeID(ref) == AXValueGetTypeID() {
            AXValueGetValue(ref as! AXValue, .cgPoint, &origin)
        }
        ref = nil
        if AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &ref) == .success, let ref, CFGetTypeID(ref) == AXValueGetTypeID() {
            AXValueGetValue(ref as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    private static func actions(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(e, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    // MARK: Checks

    /// The searches on trees written after Safari's own (its toolbar as read on macOS 27.2) and WebKit's (a video's menu
    /// as WebKit opens it), nothing pressed.
    static func checks() -> [String] {
        var f: [String] = []
        func expect(_ ok: Bool, _ message: String) { if !ok { f.append("menu de Safari : " + message) } }
        let fixed = labels(table: nil)
        expect(fixed.enter.contains("Activer le mode Image dans l’image") && fixed.exit.contains("Exit Picture in Picture")
               && fixed.pageMenu.contains("Menu de la page") && fixed.video == ["lecture vidéo", "video playback"], "mots de Safari par défaut")
        let german = labels(table: ["Enter Picture in Picture": "Bild-in-Bild starten", "Page Menu (Accessibility Label)": "Seitenmenü"],
                            webCore: ["video playback": "Videowiedergabe", "Exit Picture in Picture": "Bild-in-Bild beenden"])
        expect(german.enter.first == "Bild-in-Bild starten" && german.enter.contains("Enter Picture in Picture") && german.pageMenu.first == "Seitenmenü"
               && german.exit.first == "Bild-in-Bild beenden" && german.video.first == "Videowiedergabe",
               "les mots de Safari et de WebKit dans la langue de l'utilisateur passent d'abord")
        expect(normalized("  Activer le mode Image dans l’image… ") == "activer le mode image dans l'image"
               && normalized("Quitter\u{00A0}le mode Image dans l’image") == "quitter le mode image dans l'image", "comparaison des mots")

        // Safari's toolbar as read (nothing pressed): the page menu's button by its identifier, else by its name.
        func node(_ role: String, _ title: String = "", label: String = "", id: String = "", press: Bool = true, parent: Int? = nil) -> AdBlockAXNode {
            AdBlockAXNode(role: role, title: title, label: label, identifier: id, pressable: press, parent: parent)
        }
        var toolbar = [
            node("AXGroup", press: false),
            node("AXButton", label: "afficher la barre latérale", id: "SidebarButton", parent: 0),
            node("AXMenuButton", label: "Sélecteur de groupe d’onglets", id: "TabGroupPickerButton?TabGroup=", parent: 0),
            node("AXGroup", press: false),
            node("AXButton", "Menu de la page", label: "Menu de la page", id: "AssistantButton", parent: 3),
            node("AXButton", "Ajouter la page à la liste de lecture", label: "Ajouter la page à la liste de lecture", id: "OneStepBookmarkingButton", parent: 3),
            node("AXTextField", press: false, parent: 3),
            node("AXButton", "Recharger cette page", label: "Recharger cette page", id: "ReloadButton", parent: 3)
        ]
        expect(pageMenuButton(toolbar, labels: fixed) == 4, "bouton du menu de la page")
        toolbar[4].identifier = ""
        toolbar[4].title = "Menu de la page, traduction disponible"
        expect(pageMenuButton(toolbar, labels: fixed) == 4, "bouton du menu de la page reconnu à son nom")
        toolbar[4].pressable = false
        expect(pageMenuButton(toolbar, labels: fixed) == nil, "un bouton qu'on ne peut presser n'est pas le bon")

        // The open menu: Safari's command, the one that leaves, none, or text that is no command.
        let menu = [
            node("AXMenuItem", "Réduire/agrandir"),
            node("AXMenuItem", "Visualiseur de vidéos"),
            node("AXMenuItem", "Activer le mode Image dans l’image"),
            node("AXMenuItem", "Masquer les éléments gênants…")
        ]
        expect(item(menu, labels: fixed).map { [$0.index, $0.exit ? 1 : 0] } == [2, 0], "commande d'image dans l'image")
        var leaving = menu
        leaving[2].title = "Quitter le mode Image dans l’image"
        expect(item(leaving, labels: fixed).map { [$0.index, $0.exit ? 1 : 0] } == [2, 1], "la vidéo y est déjà")
        let popover = [
            node("AXGroup", press: false),
            node("AXCell", press: true, parent: 0),
            node("AXStaticText", "Activer le mode Image dans l’image", press: false, parent: 1),
            node("AXStaticText", "Comment passer en image dans l'image sur Mac", press: false, parent: 0)
        ]
        expect(item(popover, labels: fixed)?.index == 1, "un texte dans une case qu'on peut presser")
        expect(item(Array(menu.prefix(2)) + [menu[3]], labels: fixed) == nil, "un menu sans image dans l'image")
        expect(item([node("AXStaticText", "Comment passer en image dans l'image sur Mac", press: false)], labels: fixed) == nil,
               "un titre de page n'est pas une commande")
        expect(item([node("AXMenuItem", "Enter Picture in Picture")], labels: german)?.exit == false
               && item([node("AXButton", id: "ExitPictureInPictureButton")], labels: german)?.exit == true, "mots anglais et identifiants")

        // A video's menu as WebKit opens it (read on a WebKit view of macOS 27.2): its command by WebKit's identifier,
        // whatever the language; the one that leaves; a disabled one; a page that covers its video (the frame's menu).
        var opened = [
            node("AXMenuItem", "Afficher les contrôles", id: "WKMenuItemIdentifierShowHideMediaControls"),
            node("AXMenuItem", "Activer le mode plein écran", id: "WKMenuItemIdentifierToggleFullScreen"),
            node("AXMenuItem", "Bild-in-Bild starten", id: videoMenuIdentifier),
            node("AXMenuItem", "Accéder au visualiseur", id: "WKMenuItemIdentifierToggleVideoViewer"),
            node("AXMenuItem", "Inspecter l’élément", id: "WKMenuItemIdentifierInspectElement"),
            node("AXMenuItem", press: false)
        ]
        expect(item(opened, labels: fixed).map { [$0.index, $0.exit ? 1 : 0] } == [2, 0], "menu de la vidéo : identifiant de WebKit")
        opened[2].title = "Quitter le mode Image dans l’image"
        expect(item(opened, labels: fixed).map { [$0.index, $0.exit ? 1 : 0] } == [2, 1], "menu de la vidéo : elle y est déjà")
        opened[2].title = "Bild-in-Bild beenden"
        expect(item(opened, labels: german)?.exit == true, "menu de la vidéo : quitter, dans la langue de l'utilisateur")
        opened[2].pressable = false
        expect(item(opened, labels: fixed) == nil, "une commande désactivée ne se presse pas")
        expect(item([node("AXMenuItem", "Ouvrir le cadre dans une nouvelle fenêtre", id: "WKMenuItemIdentifierOpenFrameInNewWindow")], labels: fixed) == nil,
               "le menu d'un cadre qui couvre la vidéo n'a pas la commande")

        // The video in the tab's tree: the largest one seen, frames included; no thumbnail, nothing off screen, nothing
        // that is no video.
        let tab = CGRect(x: 0, y: 123, width: 1470, height: 779)
        func box(_ kind: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> AdBlockAXNode {
            AdBlockAXNode(role: "AXGroup", kind: kind, frame: CGRect(x: x, y: y, width: w, height: h))
        }
        let page = [
            box("groupe", 0, 123, 1470, 779),
            box("lecture vidéo", 1200, 130, 240, 135),
            box("lecture vidéo", 40, 180, 160, 90),
            box("Lecture vidéo", 0, 160, 1280, 720),
            box("lecture vidéo", 0, 2000, 1470, 827),
            box("lecture audio", 0, 150, 1470, 400)
        ]
        expect(video(page, viewport: tab, labels: fixed) == 3, "la plus grande vidéo vue dans l'onglet")
        expect(video([page[1], page[4]], viewport: tab, labels: fixed) == 0, "une vidéo hors de l'écran ne compte pas")
        expect(video([page[2], page[5], page[0]], viewport: tab, labels: fixed) == nil, "ni une vignette, ni un son, ni un groupe")
        expect(video([box("Videowiedergabe", 0, 160, 640, 360)], viewport: tab, labels: german) == 0
               && video([box("Videowiedergabe", 0, 160, 640, 360)], viewport: tab, labels: fixed) == nil, "rôle de la vidéo dans la langue de Safari")
        expect(video([box("lecture vidéo", -600, 500, 800, 360)], viewport: tab, labels: fixed) == 0
               && video([box("lecture vidéo", -700, 500, 800, 360)], viewport: tab, labels: fixed) == nil, "seule la partie vue compte")

        // The video's menu, then the page menu.
        expect(combined(video: .entered, page: .failed("x")) == .entered && combined(video: .already, page: .notOffered) == .already
               && combined(video: .kicked, page: .entered) == .kicked, "le menu de la vidéo l'emporte")
        expect(combined(video: .failed("pas de vidéo"), page: .entered) == .entered && combined(video: .notOffered, page: .already) == .already,
               "le menu de la page ensuite")
        expect(combined(video: .notOffered, page: .notOffered) == .notOffered, "aucun des deux menus ne la propose")
        if case .failed(let why) = combined(video: .failed("aucune vidéo dans l'arbre d'accessibilité"), page: .notOffered) {
            expect(why.contains("aucune vidéo") && why.contains("sans image dans l'image"), "raisons des deux menus : \(why)")
        } else {
            expect(false, "sans vidéo trouvée, le clic droit reste à faire")
        }

        // The agent's windows after the press.
        let before: Set<Int> = [7]
        expect(outcome(before: before, samples: [[7], [7, 42], [7, 42], [7, 42], [7, 42], [7, 42]]) == .entered, "fenêtre venue et restée")
        expect(outcome(before: before, samples: [[7], [7, 42], [7], [7], [7]]) == .kicked, "fenêtre venue puis repartie")
        expect(outcome(before: [], samples: [[], [], []]) == .failed("aucune fenêtre d'image dans l'image"), "aucune fenêtre")
        expect(outcome(before: [3], samples: [[], [51]]) == .entered, "une autre image dans l'image remplacée")
        expect(settled(before: before, samples: [[7, 42], [7, 42], [7, 42], [7, 42], [7, 42]])
               && !settled(before: before, samples: [[7, 42], [7, 42], [7], [7, 42], [7, 42]]), "assez regardé")
        return f
    }
}

// MARK: - Safari's red button during the picture in picture

/// A window as Quartz lists it: its owner, its number, its layer and its frame (global, top left, in points, as the
/// accessibility frames and the events' locations).
struct AdBlockQuartzWindow: Equatable, Sendable {
    var pid: Int
    var number: Int
    var layer: Int
    var frame: CGRect
    var alpha: Double = 1

    /// The windows on screen, front to back.
    static func onScreen() -> [AdBlockQuartzWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { w in
            guard let number = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: b) else { return nil }
            return AdBlockQuartzWindow(pid: w[kCGWindowOwnerPID as String] as? Int ?? 0, number: number, layer: w[kCGWindowLayer as String] as? Int ?? 0,
                                       frame: frame, alpha: w[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }
}

/// While a picture in picture the app started from Safari is on screen, the red button of the Safari window holding
/// its tab hides Safari instead of closing that window (and stopping the video with it): the user wants Safari out of
/// the way, the video goes on. Nothing else changes: another tab, ⌘W, Safari's other windows, other apps. A session
/// event tap (the left button only), on a thread of its own, swallows the press on that very button of that very window
/// (and its release), then Safari is hidden; every other click goes through at once. The button's frame comes from
/// the Accessibility, read again as the window moves; the tap is gone as soon as the picture in picture closes (its
/// tab closed, Safari quit). Without the Accessibility, nothing is intercepted.
@MainActor
final class AdBlockPiPCloseGuard {
    static let shared = AdBlockPiPCloseGuard()

    private var tap: AdBlockCloseTap?
    private var window: AXUIElement?
    private var observer: AXObserver?
    private var timer: Timer?
    private var quitting: NSObjectProtocol?
    private var pid: pid_t = 0
    private var pip: Set<Int> = []
    /// The bench's: each step.
    var log: ((String) -> Void)?

    var isActive: Bool { tap != nil }
    /// What the tap holds now, and the last press it saw (the bench prints them).
    var target: (button: CGRect, window: Int) { tap?.target ?? (.zero, 0) }
    var lastPress: (point: CGPoint, under: Int, swallowed: Bool)? { tap?.lastPress }

    // MARK: Pure parts

    /// A press at `point` falls in the red button (two points around it). Global, top left, in points: the
    /// Accessibility's frames and Quartz's event locations share that space.
    nonisolated static func inButton(_ point: CGPoint, _ button: CGRect) -> Bool {
        button.width > 0 && button.height > 0 && button.insetBy(dx: -2, dy: -2).contains(point)
    }

    /// A press at `point` is the guarded one: in the red button, and the window it reaches (`under`) is the guarded
    /// one. A window not known (0) is never guarded: a click that might be meant for another window goes through.
    nonisolated static func swallows(_ point: CGPoint, button: CGRect, window: Int, under: Int) -> Bool {
        inButton(point, button) && window != 0 && under == window
    }

    /// The window a press at `point` reaches: the first one under it, front to back, that takes clicks (the Dock's
    /// screen-wide window, above every other, lets them through), or a pop-up menu.
    nonisolated static func front(at point: CGPoint, in windows: [AdBlockQuartzWindow]) -> Int? {
        let menus = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return windows.first { $0.alpha > 0 && ($0.layer < 20 || $0.layer == menus) && $0.frame.contains(point) }?.number
    }

    /// The picture in picture is still on screen: one of the agent's windows it came with (any, when they were not known).
    nonisolated static func stillOn(pip: Set<Int>, now: Set<Int>) -> Bool {
        pip.isEmpty ? !now.isEmpty : !pip.isDisjoint(with: now)
    }

    /// The number of the window whose accessibility frame is `frame`, among `pid`'s ordinary windows (normal to modal
    /// levels; the frontmost when two have the same frame). Both frames are global, top left, in points.
    nonisolated static func number(pid: Int, frame: CGRect, in windows: [AdBlockQuartzWindow]) -> Int? {
        windows.first { $0.pid == pid && (0...8).contains($0.layer) && sameFrame($0.frame, frame) }?.number
    }

    /// Equal within a point (split up: one long condition of CGFloat sums is slow for Xcode 16's type checker).
    nonisolated static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        let dx: CGFloat = abs(a.minX - b.minX)
        let dy: CGFloat = abs(a.minY - b.minY)
        let dw: CGFloat = abs(a.width - b.width)
        let dh: CGFloat = abs(a.height - b.height)
        return dx < 1 && dy < 1 && dw < 1 && dh < 1
    }

    // MARK: The real thing

    /// Starts guarding the front window of `bundleID` while one of `pip` (the agent's windows the picture in picture
    /// came with; any, when empty) stays on screen.
    func watch(bundleID: String, pip: Set<Int>) {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else { return }
        watch(pid: pid, pip: pip)
    }

    func watch(pid: pid_t, pip: Set<Int>) {
        stop()
        guard AXIsProcessTrusted() else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let window = AdBlockSafariMenu.element(app, kAXMainWindowAttribute) ?? AdBlockSafariMenu.children(app, kAXWindowsAttribute).first else { return }
        let tap = AdBlockCloseTap {
            DispatchQueue.main.async { MainActor.assumeIsolated { AdBlockPiPCloseGuard.shared.closeClicked() } }
        }
        self.pid = pid
        self.pip = pip
        self.window = window
        self.tap = tap
        refresh()
        guard tap.start() else {
            log?("tap refusé par macOS")
            stop()
            return
        }
        var made: AXObserver?
        if AXObserverCreate(pid, Self.windowChanged, &made) == .success, let made {
            for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
                AXObserverAddNotification(made, window, name as CFString, nil)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .commonModes)
            observer = made
        }
        let tick = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { AdBlockPiPCloseGuard.shared.check() } }
        tick.tolerance = 0.5
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        quitting = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let gone = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if gone == AdBlockPiPCloseGuard.shared.pid { AdBlockPiPCloseGuard.shared.stop("navigateur quitté") } }
        }
        log?("garde posée : bouton fermer \(target.button), fenêtre n° \(target.window)")
    }

    func stop(_ why: String = "") {
        guard tap != nil || timer != nil else { return }
        tap?.stop()
        tap = nil
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        timer?.invalidate()
        timer = nil
        if let quitting { NSWorkspace.shared.notificationCenter.removeObserver(quitting) }
        quitting = nil
        window = nil
        if !why.isEmpty { log?("garde retirée : \(why)") }
    }

    /// The red button's frame and the window's number, read again.
    private func refresh() {
        guard let window, let tap else { return }
        AXUIElementSetMessagingTimeout(window, 0.25)
        let button = AdBlockSafariMenu.element(window, kAXCloseButtonAttribute).map(AdBlockSafariMenu.frame) ?? .zero
        // A hidden window is not listed: its number stays the one read last.
        let number = Self.number(pid: Int(pid), frame: AdBlockSafariMenu.frame(window), in: AdBlockQuartzWindow.onScreen()) ?? tap.target.window
        tap.update(button: button, window: number)
    }

    /// Every second: the picture in picture still there, the window where it was.
    private func check() {
        guard Self.stillOn(pip: pip, now: AdBlockSafariMenu.pipWindows()) else {
            stop("image dans l'image fermée")
            return
        }
        refresh()
    }

    private func moved(_ name: String) {
        if name == kAXUIElementDestroyedNotification {
            stop("fenêtre fermée")
        } else {
            refresh()
        }
    }

    /// The red button was pressed: Safari steps aside, the video goes on.
    private func closeClicked() {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.hide()
        log?("croix rouge avalée : \(app.localizedName ?? "l'app") cachée")
        ActionLog.write("CROIX ROUGE \(app.localizedName ?? "") : caché pendant l'image dans l'image")
        if log == nil { HUD.show("\(app.localizedName ?? "Safari") caché : la vidéo continue", symbol: "pip.fill") }
    }

    private static let windowChanged: AXObserverCallback = { _, _, name, _ in
        let text = name as String
        MainActor.assumeIsolated { AdBlockPiPCloseGuard.shared.moved(text) }
    }

    // MARK: Checks

    nonisolated static func checks() -> [String] {
        var f: [String] = []
        func expect(_ ok: Bool, _ message: String) { if !ok { f.append("croix rouge : " + message) } }
        // Safari's red button as the Accessibility gives it (global, top left), and Quartz's press locations (the same
        // space): in it, at its edge, beside it; on that window, on another one in front, Quartz not saying.
        let button = CGRect(x: 92, y: 349, width: 14, height: 16)
        expect(swallows(CGPoint(x: 99, y: 357), button: button, window: 4363, under: 4363), "au milieu du bouton")
        expect(swallows(CGPoint(x: 91, y: 348), button: button, window: 4363, under: 4363), "au bord du bouton")
        expect(!swallows(CGPoint(x: 120, y: 357), button: button, window: 4363, under: 4363)
               && !swallows(CGPoint(x: 99, y: 380), button: button, window: 4363, under: 4363), "à côté du bouton")
        expect(!swallows(CGPoint(x: 99, y: 357), button: button, window: 4363, under: 5120), "une autre fenêtre devant le bouton")
        expect(!swallows(CGPoint(x: 99, y: 357), button: button, window: 4363, under: 0)
               && !swallows(CGPoint(x: 99, y: 357), button: button, window: 0, under: 0), "fenêtre inconnue : le clic passe")
        expect(!swallows(CGPoint(x: 0, y: 0), button: .zero, window: 4363, under: 4363), "pas de bouton connu")
        // The window a press reaches, as read on macOS 27.2: the Dock's screen-wide window (layer 20) lets it through;
        // a picture in picture (19) or a pop-up menu (101) over the button takes it; an ordinary window behind does not.
        let screen = [
            AdBlockQuartzWindow(pid: 636, number: 15, layer: 20, frame: CGRect(x: 0, y: 0, width: 1470, height: 956)),
            AdBlockQuartzWindow(pid: 50, number: 4561, layer: 3, frame: CGRect(x: 80, y: 335, width: 700, height: 538)),
            AdBlockQuartzWindow(pid: 51, number: 2955, layer: 0, frame: CGRect(x: 6, y: 34, width: 1464, height: 839))
        ]
        let cross = CGPoint(x: 106, y: 361)
        expect(front(at: cross, in: screen) == 4561 && front(at: CGPoint(x: 30, y: 361), in: screen) == 2955
               && front(at: CGPoint(x: 3, y: 10), in: screen) == nil, "fenêtre atteinte par un clic")
        let pipOver = [AdBlockQuartzWindow(pid: 80, number: 77, layer: 19, frame: CGRect(x: 60, y: 300, width: 320, height: 180))] + screen
        let menuOver = [AdBlockQuartzWindow(pid: 51, number: 78, layer: 101, frame: CGRect(x: 90, y: 340, width: 200, height: 120))] + screen
        let ghost = [AdBlockQuartzWindow(pid: 52, number: 79, layer: 0, frame: CGRect(x: 0, y: 0, width: 1470, height: 956), alpha: 0)] + screen
        expect(front(at: cross, in: pipOver) == 77 && front(at: cross, in: menuOver) == 78 && front(at: cross, in: ghost) == 4561,
               "image dans l'image, menu ou fenêtre transparente devant le bouton")
        // An AppKit point (bottom left of the main screen) is not a Quartz one: the same button, read the wrong way up,
        // misses the press (main screen 956 points high).
        let appKit = CGPoint(x: 99, y: 956 - 357)
        expect(!swallows(appKit, button: button, window: 4363, under: 4363) && swallows(CGPoint(x: appKit.x, y: 956 - appKit.y), button: button, window: 4363, under: 4363),
               "repère de Quartz, pas celui d'AppKit")
        // A screen above the main one: negative coordinates.
        expect(swallows(CGPoint(x: -1500, y: -1062), button: CGRect(x: -1508, y: -1070, width: 14, height: 16), window: 7, under: 7), "écran au-dessus")
        // The picture in picture still there.
        expect(stillOn(pip: [42], now: [7, 42]) && !stillOn(pip: [42], now: [7]) && stillOn(pip: [], now: [7]) && !stillOn(pip: [], now: []),
               "image dans l'image encore là")
        // The window's number from its accessibility frame.
        let windows = [
            AdBlockQuartzWindow(pid: 99, number: 51, layer: 101, frame: CGRect(x: 326, y: 556, width: 336, height: 328)),
            AdBlockQuartzWindow(pid: 99, number: 50, layer: 0, frame: CGRect(x: 0, y: 33, width: 1470, height: 839)),
            AdBlockQuartzWindow(pid: 12, number: 9, layer: 0, frame: CGRect(x: 80, y: 335, width: 700, height: 538)),
            AdBlockQuartzWindow(pid: 99, number: 48, layer: 0, frame: CGRect(x: 80, y: 335, width: 700, height: 538))
        ]
        expect(number(pid: 99, frame: CGRect(x: 80, y: 335, width: 700, height: 538), in: windows) == 48
               && number(pid: 99, frame: CGRect(x: 0, y: 33.4, width: 1470, height: 839), in: windows) == 50
               && number(pid: 99, frame: CGRect(x: 326, y: 556, width: 336, height: 328), in: windows) == nil, "numéro de la fenêtre")
        return f
    }
}

/// The event tap of `AdBlockPiPCloseGuard`, on a thread of its own: left clicks go through untouched, except the press
/// on the guarded red button, swallowed with its release. Its callback only compares numbers: nothing waits.
final class AdBlockCloseTap: @unchecked Sendable {
    private let lock = NSLock()
    private var button = CGRect.zero
    private var window = 0
    private var swallowing = false
    private var port: CFMachPort?
    private let hit: @Sendable () -> Void
    private var press: (point: CGPoint, under: Int, swallowed: Bool)?
    /// The last press seen: where, on which window by Quartz, swallowed or not (the bench prints it).
    var lastPress: (point: CGPoint, under: Int, swallowed: Bool)? { locked { press } }

    init(hit: @escaping @Sendable () -> Void) { self.hit = hit }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var target: (button: CGRect, window: Int) { locked { (button, window) } }

    func update(button: CGRect, window: Int) { locked { self.button = button; self.window = window } }

    /// False when macOS refuses the tap (no Accessibility).
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard let made = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                           callback: Self.callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        locked { port = made }
        let thread = Thread { [self] in
            guard let port = self.locked({ self.port }), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            // Until the port is invalidated: its source leaves the loop, which then has nothing left to run.
            CFRunLoopRun()
        }
        thread.name = "Heartware croix rouge"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func stop() {
        guard let port = locked({ self.port }) else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        locked { self.port = nil }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            if let port = locked({ self.port }) { CGEvent.tapEnable(tap: port, enable: true) }
        case .leftMouseDown:
            let (button, window) = target
            let point = event.location
            var under = 0, swallowed = false
            // Only a press in the button costs a look at the windows (Quartz does not always say which one it reaches).
            if AdBlockPiPCloseGuard.inButton(point, button) {
                under = Int(event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
                if under == 0 { under = AdBlockPiPCloseGuard.front(at: point, in: AdBlockQuartzWindow.onScreen()) ?? 0 }
                swallowed = AdBlockPiPCloseGuard.swallows(point, button: button, window: window, under: under)
            }
            locked {
                press = (point, under, swallowed)
                if swallowed { swallowing = true }
            }
            if swallowed {
                hit()
                return nil
            }
        case .leftMouseUp:
            let swallowed = locked { () -> Bool in
                defer { swallowing = false }
                return swallowing
            }
            if swallowed { return nil }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        return Unmanaged<AdBlockCloseTap>.fromOpaque(info).takeUnretainedValue().handle(type, event)
    }
}

// MARK: - Bench

/// `--adblock pip [page.html|lien]` : the scripts in a real WebKit view of the app (not the user's browser), in a window
/// at the bottom left of the screen for a few seconds. Without a page, a page of its own: four videos (a small one
/// playing, a larger one paused, one playing off screen, one in a shadow root that forbids the picture in picture), then
/// all paused, then the request sent without a user's gesture, then a page without video, a player in a frame of another
/// origin, and a video the page brings back from the picture in picture (at once, as TF1+'s player; a moment later).
/// Says which video was picked, if the ban was lifted, whether WebKit really went into picture in picture (it may refuse
/// in a view of an app) and what macOS' picture-in-picture agent showed meanwhile. With a link: the page as Safari gets
/// it, cookies refused, then each of its frames' videos, frames and shadow roots (`survey`). With `menu:<pid>`: Safari's
/// own commands through the Accessibility (the video's menu, then the page menu), in a process that imitates Safari
/// (never Safari itself); with `croix:<pid>`, then its red button during the picture in picture (`closeBench`).
@MainActor
enum AdBlockPiPBench {
    private static let page = #"""
    <!doctype html><html><head><meta charset='utf-8'><style>
    body { margin: 0; background: #111; }
    video, #hote { display: inline-block; vertical-align: top; margin: 4px; background: #333; }
    </style></head><body>
    <video id='petite' width='160' height='90' muted playsinline></video>
    <video id='grande-en-pause' width='400' height='225' muted playsinline></video>
    <div id='hote'></div>
    <video id='loin' width='480' height='270' muted playsinline style='position: absolute; left: 0; top: 4000px'></video>
    <script>
    const feed = (v, color, play) => {
      const c = document.createElement('canvas');
      c.width = 320; c.height = 180;
      const g = c.getContext('2d');
      let n = 0;
      const draw = () => { g.fillStyle = color; g.fillRect(0, 0, 320, 180); g.fillStyle = '#fff'; g.font = '40px sans-serif'; g.fillText(String(n++), 20, 60); };
      draw();
      setInterval(draw, 50);
      v.srcObject = c.captureStream(20);
      v.muted = true;
      v.play().then(() => { if (!play) v.pause(); }).catch(() => {});
    };
    const host = document.getElementById('hote').attachShadow({ mode: 'open' });
    host.innerHTML = "<video id='protegee' width='320' height='180' muted playsinline disablepictureinpicture></video>";
    feed(document.getElementById('petite'), '#a33', true);
    feed(document.getElementById('grande-en-pause'), '#3a3', false);
    feed(host.getElementById('protegee'), '#33a', true);
    feed(document.getElementById('loin'), '#aa3', true);
    </script></body></html>
    """#

    private static let probe = """
    (() => { const p = window.__cmcPip, v = p && p.video;
      return JSON.stringify(v ? { id: v.id, attribute: v.hasAttribute('disablepictureinpicture'), property: v.disablePictureInPicture,
        supports: v.webkitSupportsPresentationMode ? v.webkitSupportsPresentationMode('picture-in-picture') : null,
        playing: !v.paused, size: [v.videoWidth, v.videoHeight] } : null); })()
    """

    private static let leave = """
    (() => { const p = window.__cmcPip, v = p && p.video;
      if (v && v.webkitPresentationMode === 'picture-in-picture') v.webkitSetPresentationMode('inline');
      else if (document.pictureInPictureElement) document.exitPictureInPicture();
      return 1; })()
    """

    static func run(_ path: String?) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        // `croix:<pid>`: the video's menu, then Safari's red button during the picture in picture, in a stand-in.
        if let path, path.hasPrefix("croix:"), let pid = pid_t(path.dropFirst(6)) {
            await closeBench(pid)
            return
        }
        // `menu:<pid>`: the accessibility path against another process that imitates Safari's page menu (never Safari).
        if let path, path.hasPrefix("menu:"), let pid = pid_t(path.dropFirst(5)) {
            let name = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            guard !name.hasPrefix("com.apple.Safari") else { print("Pas sur Safari lui-même : seulement une imitation."); return }
            let start = Date()
            let outcome = await Task.detached {
                AdBlockSafariMenu.enterPictureInPicture(pid: pid) { print(String(format: "  [%.1f s] ", Date().timeIntervalSince(start)) + $0) }
            }.value
            print(String(format: "Menus du processus %d : %@ en %.1f s", pid, "\(outcome)", Date().timeIntervalSince(start)))
            return
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        // WebKit's own switch for the picture in picture of a view (Safari's is on): read, and turned on for the bench.
        let key = "allowsPictureInPictureMediaPlayback"
        if config.preferences.responds(to: NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")) {
            print("Image dans l'image de la vue : \(config.preferences.value(forKey: key) as? Bool == true ? "permise" : "non permise"), mise à permise pour l'essai")
            config.preferences.setValue(true, forKey: key)
        }
        let size = NSSize(width: 960, height: 360)
        // Really on screen: WebKit holds back the videos of a page it cannot see. Clicks go through it.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        window.level = .floating
        if let path, let url = URL(string: path), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            await survey(url, config: config, window: window)
            window.close()
            return
        }
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        window.contentView = web
        window.orderFrontRegardless()
        if let path {
            let url = URL(fileURLWithPath: FS.expand(path))
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            await AdBlockVideoBench.pump(4)
            _ = await attempt(web, url.lastPathComponent, pick: nil)
            window.close()
            return
        }
        web.loadHTMLString(page, baseURL: nil)
        await AdBlockVideoBench.pump(3)
        var ok = await attempt(web, "Quatre vidéos", pick: "protegee", lifted: true)
        _ = try? await web.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause()); document.getElementById('hote').shadowRoot.querySelector('video').pause(); 1")
        await AdBlockVideoBench.pump(0.5)
        ok = await attempt(web, "Toutes en pause", pick: "grande-en-pause") && ok
        // The same request from a timer, long after any gesture: what a browser sees when nothing marks it as the user's.
        _ = try? await web.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.play()); 1")
        let before = AdBlockSafariMenu.pipWindows()
        _ = try? await web.evaluateJavaScript("window.__cmcPip = null; window.__cmcLater = ''; setTimeout(() => { window.__cmcLater = " + AdBlockVideoPiP.request + "; }, 1500); 1")
        await AdBlockVideoBench.pump(2)
        let later = (try? await web.evaluateJavaScript("window.__cmcLater || ''")) as? String ?? ""
        print("Sans geste de l'utilisateur (minuteur de 1,5 s)")
        print("  réponse : \(later)")
        print("  image dans l'image : \(await follow(web, AdBlockVideoPiP.answer(from: later), before: before).text)")
        web.loadHTMLString("<!doctype html><p>Rien à voir</p>", baseURL: nil)
        await AdBlockVideoBench.pump(1)
        ok = await attempt(web, "Page sans vidéo", pick: nil, want: .noVideo) && ok
        // TF1+'s player: in a frame the page's script cannot enter (here an opaque origin, as prod-player.tf1.fr is to
        // www.tf1.fr), then, reachable, a video that the page brings straight back into it.
        web.loadHTMLString(framed, baseURL: nil)
        await AdBlockVideoBench.pump(3)
        ok = await attempt(web, "Lecteur dans un cadre d'une autre origine", pick: nil, want: .inFrame(site: nil)) && ok
        // TF1+'s code calls for the page while WebKit is still moving the video: WebKit lets it go, the video stays.
        let heard = "JSON.stringify(window.__cmcKick)"
        web.loadHTMLString(kicking(delay: nil), baseURL: nil)
        await AdBlockVideoBench.pump(3)
        ok = await attempt(web, "Vidéo ramenée aussitôt, mot pour mot comme le lecteur de TF1+ dans Safari", pick: "direct", lifted: true,
                           want: .asked(lifted: true), after: .entered) && ok
        print("  la page a entendu : \((try? await web.evaluateJavaScript(heard)) as? String ?? "")")
        web.loadHTMLString(kicking(delay: 1000), baseURL: nil)
        await AdBlockVideoBench.pump(3)
        ok = await attempt(web, "Vidéo ramenée un peu plus tard", pick: "direct", lifted: true, want: .asked(lifted: true), after: .kicked) && ok
        print("  la page a entendu : \((try? await web.evaluateJavaScript(heard)) as? String ?? "")")
        print(ok ? "Bilan : vidéo choisie, interdiction levée, cadre fermé, vidéo ramenée et page sans vidéo conformes" : "Bilan : ÉCHEC")
        window.close()
    }

    /// `--adblock pip croix:<pid>` : in a process that imitates Safari (never Safari itself, whose window must be the
    /// first under each click), the video goes into picture in picture through its menu, then: a click on the red
    /// button (swallowed, the app hidden, its window and the video still there), the app shown again, a click in its
    /// page (goes through; the stand-in then reloads its page, which ends the picture in picture), the guard gone, and
    /// the red button again (the window closes). The clicks are real ones, posted only once the stand-in's window is
    /// the first under their point.
    private static func closeBench(_ pid: pid_t) async {
        guard !(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "").hasPrefix("com.apple.Safari") else {
            print("Pas sur Safari lui-même : seulement une imitation.")
            return
        }
        _ = NSApplication.shared
        let start = Date()
        func say(_ s: String) { print(String(format: "[%5.2f s] ", Date().timeIntervalSince(start)) + s) }
        let before = AdBlockSafariMenu.pipWindows()
        let outcome = await Task.detached { AdBlockSafariMenu.enterPictureInPicture(pid: pid) }.value
        say("image dans l'image par le menu de la vidéo : \(outcome)")
        guard outcome == .entered else { return }
        let guardian = AdBlockPiPCloseGuard.shared
        guardian.log = { say($0) }
        let ours = AdBlockSafariMenu.pipWindows().subtracting(before)
        guardian.watch(pid: pid, pip: ours)
        guard guardian.isActive else { return }
        let (button, number) = guardian.target
        let cross = CGPoint(x: button.midX, y: button.midY)
        let app = NSRunningApplication(processIdentifier: pid)
        func state(_ moment: String) {
            let shown = AdBlockQuartzWindow.onScreen().contains { $0.number == number }
            let open = AdBlockSafariMenu.children(AXUIElementCreateApplication(pid), kAXWindowsAttribute).count
            let press = guardian.lastPress.map { "dernier appui vu par le tap : (\(Int($0.point.x)), \(Int($0.point.y))), fenêtre atteinte n° \($0.under), \($0.swallowed ? "avalé" : "passé")" } ?? "aucun appui vu par le tap"
            say("\(moment) : app \(app?.isHidden == true ? "cachée" : "visible"), fenêtre n° \(number) \(shown ? "à l'écran" : "hors de l'écran"), \(open) fenêtre(s) ouverte(s), "
                + "image dans l'image \(AdBlockPiPCloseGuard.stillOn(pip: ours, now: AdBlockSafariMenu.pipWindows()) ? "toujours là" : "fermée"), garde \(guardian.isActive ? "posée" : "retirée")")
            say("  " + press)
        }
        guard click(cross, owner: pid, say: say) else { guardian.stop(); return }
        await AdBlockVideoBench.pump(1.2)
        state("Après le clic sur la croix rouge")
        app?.unhide()
        await AdBlockVideoBench.pump(1)
        guard let frame = AdBlockQuartzWindow.onScreen().first(where: { $0.number == number })?.frame else { say("fenêtre introuvable"); guardian.stop(); return }
        guard click(CGPoint(x: frame.minX + 300, y: frame.minY + 120), owner: pid, say: say) else { guardian.stop(); return }
        await AdBlockVideoBench.pump(1)
        state("Après un clic dans la page")
        for _ in 0..<12 where guardian.isActive { await AdBlockVideoBench.pump(0.5) }
        state("Image dans l'image refermée par la page")
        guard click(cross, owner: pid, say: say) else { return }
        await AdBlockVideoBench.pump(1)
        state("Après le second clic sur la croix rouge")
        guardian.stop()
        guardian.log = nil
    }

    /// A real click at `p` (global, top left), only when it can reach nothing but `pid`'s window: the first window under
    /// it, front to back, below the Dock's layer (whose screen-wide window lets clicks through), is `pid`'s, and so is
    /// the element the Accessibility finds there.
    private static func click(_ p: CGPoint, owner pid: pid_t, say: (String) -> Void) -> Bool {
        let windows = AdBlockQuartzWindow.onScreen()
        let number = AdBlockPiPCloseGuard.front(at: p, in: windows)
        let front = windows.first { $0.number == number }
        var hit: AXUIElement?, owner: pid_t = 0
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success, let hit {
            AXUIElementGetPid(hit, &owner)
        }
        guard let front, front.pid == Int(pid), owner == pid else {
            say("clic annulé en (\(Int(p.x)), \(Int(p.y))) : ce point n'est pas sur la fenêtre de l'imitation")
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(80_000)
        }
        say("clic posté en (\(Int(p.x)), \(Int(p.y))), sur la fenêtre n° \(front.number) de l'imitation")
        return true
    }

    /// A canvas filmed into `video` (no file, no network), playing.
    private static let feeder = """
    const feed = (v, color) => {
      const c = document.createElement('canvas');
      c.width = 320; c.height = 180;
      const g = c.getContext('2d');
      let n = 0;
      const draw = () => { g.fillStyle = color; g.fillRect(0, 0, 320, 180); g.fillStyle = '#fff'; g.font = '40px sans-serif'; g.fillText(String(n++), 20, 60); };
      draw();
      setInterval(draw, 50);
      v.srcObject = c.captureStream(20);
      v.muted = true;
      v.play().catch(() => {});
    };
    """

    /// The player in a sandboxed frame: an opaque origin, which the page's script cannot enter.
    private static var framed: String {
        let inner = "<!doctype html><body style='margin:0;background:#000'><video id='dans-le-cadre' width='640' height='360' muted playsinline></video><script>"
            + feeder + "feed(document.getElementById('dans-le-cadre'), '#a3a');</script></body>"
        let escaped = inner.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        return "<!doctype html><html><body style='margin:0;background:#111'><iframe sandbox='allow-scripts' allow='autoplay; encrypted-media' allowfullscreen "
            + "width='640' height='360' style='border:0' srcdoc=\"" + escaped + "\"></iframe></body></html>"
    }

    /// A video that forbids the picture in picture and brings itself back into the page: as TF1+'s player does in
    /// Safari, word for word, as soon as it hears the change (`delay` nil), or a moment later.
    private static func kicking(delay: Int?) -> String {
        let back = delay.map { "setTimeout(() => v.webkitSetPresentationMode('inline'), \($0))" } ?? "v.webkitSetPresentationMode('inline')"
        return "<!doctype html><html><body style='margin:0;background:#111'><video id='direct' width='640' height='360' muted playsinline></video><script>"
            + feeder + """
            const v = document.getElementById('direct');
            v.disablePictureInPicture = true;
            window.__cmcKick = [];
            v.addEventListener('webkitpresentationmodechanged', () => {
              window.__cmcKick.push(Math.round(performance.now()) + ' ' + v.webkitPresentationMode);
              'picture-in-picture' === v.webkitPresentationMode && \(back);
            });
            feed(v, '#3aa');
            </script></body></html>
            """
    }

    // MARK: A real page

    /// Every frame's report, by frame (its origin and address): the last one wins.
    private final class FrameListener: NSObject, WKScriptMessageHandler {
        var frames: [String: String] = [:]
        var order: [String] = []

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String else { return }
            let o = message.frameInfo.securityOrigin
            let origin = o.protocol + "://" + o.host + (o.port > 0 ? ":\(o.port)" : "")
            let key = (message.frameInfo.isMainFrame ? "document principal " : "cadre ") + origin
            if frames[key] == nil { order.append(key) }
            frames[key] = body
        }
    }

    /// In every frame of the page (this bench's view only): counts the shadow roots as the page attaches them (closed
    /// ones cannot be found afterwards), mutes the videos, and reports what the frame holds every two seconds.
    private static let surveyor = #"""
    (() => {
      if (window.__hwSurvey) return;
      window.__hwSurvey = 1;
      let closed = 0, open = 0;
      const closedHosts = [];
      const attach = Element.prototype.attachShadow;
      Element.prototype.attachShadow = function (init) {
        if (init && init.mode === 'closed') { closed += 1; closedHosts.push(this.tagName.toLowerCase()); } else { open += 1; }
        return attach.apply(this, arguments);
      };
      const p = HTMLMediaElement.prototype, play = p.play;
      p.play = function () { this.muted = true; return play.apply(this, arguments); };
      document.addEventListener('volumechange', (e) => { if (e.target.muted === false) e.target.muted = true; }, true);
      const rect = (e) => { const b = e.getBoundingClientRect(); return [Math.round(b.x), Math.round(b.y), Math.round(b.width), Math.round(b.height)]; };
      // The cookie banner, refused (this view's store is thrown away): the player only comes after it.
      let refused = false;
      const refuse = () => {
        if (refused || !document.body) return;
        const words = /^\s*(continuer sans accepter|tout refuser|refuser tout|refuser|je refuse)\s*$/i;
        for (const b of document.querySelectorAll('button, a[role=button], [role=button]')) {
          if (words.test(b.textContent || '') && b.getBoundingClientRect().width > 0) { refused = true; b.click(); return; }
        }
      };
      const report = () => {
        refuse();
        const videos = [], frames = [], customs = {};
        let canvases = 0;
        const look = (root, depth, shadow) => {
          let all = [];
          try { all = root.querySelectorAll('*'); } catch (e) { return; }
          for (const e of all) {
            const t = e.tagName;
            if (t === 'VIDEO') {
              videos.push({ rect: rect(e), paused: e.paused, ready: e.readyState, src: (e.currentSrc || e.src || '').slice(0, 48),
                            size: [e.videoWidth, e.videoHeight], noPip: e.disablePictureInPicture, shadow: shadow, mode: e.webkitPresentationMode });
            } else if (t === 'CANVAS') {
              const r = rect(e);
              if (r[2] * r[3] > 40000) canvases += 1;
            } else if (t === 'IFRAME' || t === 'FRAME' || t === 'EMBED' || t === 'OBJECT') {
              let doc = null;
              try { doc = e.contentDocument; } catch (x) {}
              frames.push({ tag: t, src: (e.src || e.data || '').slice(0, 140), rect: rect(e), allow: e.getAttribute('allow') || '', readable: !!doc });
            }
            if (t.includes('-') && !e.shadowRoot) customs[t.toLowerCase()] = rect(e);
            if (e.shadowRoot && depth < 6) look(e.shadowRoot, depth + 1, true);
          }
        };
        look(document, 0, false);
        const big = Object.entries(customs).filter(([k, r]) => r[2] * r[3] > 40000).slice(0, 12);
        const text = window === window.top && document.body ? document.body.innerText.replace(/\s+/g, ' ').slice(0, 280) : '';
        const msg = JSON.stringify({ href: location.href.slice(0, 160), title: document.title.slice(0, 80), videos: videos, frames: frames,
                                     closed: closed, closedHosts: [...new Set(closedHosts)].slice(0, 10), open: open, canvases: canvases,
                                     customs: big, text: text });
        try { window.webkit.messageHandlers.hwSurvey.postMessage(msg); } catch (e) {}
      };
      setInterval(report, 2000);
    })();
    """#

    /// `--adblock pip <lien>`: the page as Safari would show it (its user agent, no blocking), each of its frames' videos,
    /// frames and shadow roots, then the request as Safari's `do JavaScript` sends it, in the main frame only.
    private static func survey(_ url: URL, config: WKWebViewConfiguration, window: NSWindow) async {
        let listener = FrameListener()
        config.applicationNameForUserAgent = "Version/\(AdBlockPlayer.safariVersion) Safari/605.1.15"
        config.userContentController.addUserScript(WKUserScript(source: surveyor, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        config.userContentController.add(listener, name: "hwSurvey")
        let size = NSSize(width: 960, height: 540)
        window.setContentSize(size)
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        window.contentView = web
        window.orderFrontRegardless()
        web.load(URLRequest(url: url))
        print("Page : \(url.absoluteString)")
        for second in stride(from: 6, through: 30, by: 6) {
            await AdBlockVideoBench.pump(6)
            let before = AdBlockSafariMenu.pipWindows()
            let request = (try? await web.evaluateJavaScript("window.__cmcPip = null; " + AdBlockVideoPiP.request)) as? String ?? ""
            print("  \(second) s : \(listener.frames.count) cadre(s) · demande dans le document principal : \(request)")
            if case .asked = AdBlockVideoPiP.answer(from: request) {
                print("  image dans l'image : \(await follow(web, .asked(lifted: false), before: before).text)")
                break
            }
        }
        for key in listener.order { print("\(key)\n  \(listener.frames[key] ?? "")") }
    }

    /// Runs the request as the browser would, then follows the video for a few seconds. True when it went as expected:
    /// `want` answered, `pick` chosen (its ban lifted when `lifted`), and `after` seen once it was asked.
    private static func attempt(_ web: WKWebView, _ title: String, pick: String?, lifted: Bool = false,
                                want: AdBlockPiPAnswer? = nil, after: AdBlockPiPAnswer = .entered) async -> Bool {
        _ = try? await web.evaluateJavaScript("window.__cmcPip = null; 1")
        let before = AdBlockSafariMenu.pipWindows()
        let text = (try? await web.evaluateJavaScript(AdBlockVideoPiP.request)) as? String ?? ""
        let answer = AdBlockVideoPiP.answer(from: text)
        let chosen = (try? await web.evaluateJavaScript(probe)) as? String ?? ""
        print(title)
        print("  réponse : \(text)")
        print("  vidéo choisie : \(chosen)")
        let followed = await follow(web, answer, before: before)
        print("  image dans l'image : \(followed.text)")
        if let want, answer != want { return false }
        guard let pick else { return answer != .unreadable }
        let picked = chosen.contains("\"id\":\"\(pick)\"") && !chosen.contains("\"attribute\":true")
        let liftedOK = !lifted || answer == .asked(lifted: true)
        return picked && liftedOK && followed.last == after
    }

    /// The video a few seconds after the request, and the windows of macOS' picture-in-picture agent meanwhile (what
    /// tells Safari's own command whether it worked); out of picture in picture again afterwards.
    private static func follow(_ web: WKWebView, _ answer: AdBlockPiPAnswer, before: Set<Int>) async -> (text: String, last: AdBlockPiPAnswer) {
        guard case .asked = answer else { return ("rien de demandé (\(answer))", answer) }
        var last = AdBlockPiPAnswer.unreadable
        var samples: [Set<Int>] = []
        for _ in 0..<8 {
            await AdBlockVideoBench.pump(0.35)
            samples.append(AdBlockSafariMenu.pipWindows())
            last = AdBlockVideoPiP.answer(from: (try? await web.evaluateJavaScript(AdBlockVideoPiP.check)) as? String ?? "")
            if last == .entered && AdBlockSafariMenu.settled(before: before, samples: samples, steady: 5) { break }
            if last == .kicked && samples.count >= 4 { break }
            if case .inline(let e) = last, !e.isEmpty { break }
        }
        _ = try? await web.evaluateJavaScript(leave)
        await AdBlockVideoBench.pump(1)
        let windows: String
        switch AdBlockSafariMenu.outcome(before: before, samples: samples) {
        case .entered: windows = "restée"
        case .kicked: windows = "venue puis repartie"
        default: windows = "aucune"
        }
        let text: String
        switch last {
        case .entered: text = "entrée (puis ressortie)"
        case .kicked: text = "entrée, puis ramenée dans la page par le site"
        case .inline(let e): text = "refusée par WebKit" + (e.isEmpty ? "" : " (\(e))")
        default: text = "\(last)"
        }
        return (text + " · fenêtre de l'agent : " + windows, last)
    }
}
