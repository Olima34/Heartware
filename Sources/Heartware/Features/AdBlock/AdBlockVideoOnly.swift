import SwiftUI
import AppKit
import WebKit

/// A corner of the screen for the video-only window.
enum AdBlockVideoCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var title: String {
        switch self {
        case .topLeft: return "En haut à gauche"
        case .topRight: return "En haut à droite"
        case .bottomLeft: return "En bas à gauche"
        case .bottomRight: return "En bas à droite"
        }
    }

    var left: Bool { self == .topLeft || self == .bottomLeft }
    var top: Bool { self == .topLeft || self == .topRight }
}

/// A browser whose front tab « Détacher la vidéo » reads (AppleScript, macOS asks once), and pauses when the browser lets
/// the app run a script in its pages.
struct AdBlockVideoBrowser: Equatable, Sendable {
    var name: String
    var bundleID: String
    var chromium: Bool

    static let all = [
        AdBlockVideoBrowser(name: "Safari", bundleID: "com.apple.Safari", chromium: false),
        AdBlockVideoBrowser(name: "Safari Technology Preview", bundleID: "com.apple.SafariTechnologyPreview", chromium: false),
        AdBlockVideoBrowser(name: "Chrome", bundleID: "com.google.Chrome", chromium: true),
        AdBlockVideoBrowser(name: "Brave", bundleID: "com.brave.Browser", chromium: true),
        AdBlockVideoBrowser(name: "Edge", bundleID: "com.microsoft.edgemac", chromium: true),
        AdBlockVideoBrowser(name: "Arc", bundleID: "company.thebrowser.Browser", chromium: true),
        AdBlockVideoBrowser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", chromium: true)
    ]

    static func named(_ bundleID: String?) -> AdBlockVideoBrowser? {
        all.first { $0.bundleID == bundleID }
    }

    /// The address of the tab shown. Fixed text: nothing read from a page goes into a script.
    var urlScript: String {
        chromium ? "tell application id \"\(bundleID)\" to return URL of active tab of front window"
                 : "tell application id \"\(bundleID)\" to return URL of front document"
    }

    /// Pauses the tab's main video and says where it was (`AdBlockVideoOnly.pause`).
    var pauseScript: String { javaScript(AdBlockVideoOnly.pause) }

    /// Runs `js` (fixed text of the app, escaped) in the tab whose address `urlScript` reads.
    func javaScript(_ js: String) -> String {
        let source = AdBlockVideoPiP.literal(js)
        return chromium ? "tell application id \"\(bundleID)\" to execute active tab of front window javascript \(source)"
                        : "tell application id \"\(bundleID)\" to do JavaScript \(source) in front document"
    }
}

/// Where the browser's video was when it was detached.
struct AdBlockVideoMoment: Equatable {
    var seconds: Double
    var live: Bool
    /// An ad was playing in the browser: its time is not the video's.
    var ad: Bool
}

/// « Vidéo seule » : the video or the live the user watches, alone in the ad-free player's window, made small, above the
/// other windows and on every desktop. The page stays whole (the site's own controls, quality, sound…): a script hides
/// everything around its player and lays the player over the whole window.
enum AdBlockVideoOnly {
    static let commandID = "adblock_video_only"
    static let pinnedKey = "Heartware.VideoOnly.Pinned"
    static let scriptsKey = "Heartware.VideoOnly.Scripts"
    static let margin: CGFloat = 16
    /// The sizes offered, as a share of the screen's width.
    static let sizes: [(title: String, width: CGFloat)] = [("petite", 0.24), ("moyenne", 0.34), ("grande", 0.5)]

    // MARK: The window

    /// The window at a corner of the screen, `width` wide (within the screen) and of the video's shape.
    static func place(_ corner: AdBlockVideoCorner, width: CGFloat, ratio: CGFloat, in screen: NSRect) -> NSRect {
        var w = min(max(width, 200), screen.width - 2 * margin)
        var h = w / ratio
        if h > screen.height - 2 * margin {
            h = screen.height - 2 * margin
            w = h * ratio
        }
        let x = corner.left ? screen.minX + margin : screen.maxX - margin - w
        let y = corner.top ? screen.maxY - margin - h : screen.minY + margin
        return NSRect(x: x, y: y, width: w, height: h).integral
    }

    static func nearestCorner(of frame: NSRect, in screen: NSRect) -> AdBlockVideoCorner {
        switch (frame.midX < screen.midX, frame.midY > screen.midY) {
        case (true, true): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    /// The window reshaped for a video of another shape: same area, the corner nearest the screen's edge kept in place,
    /// all of it on the screen.
    static func fit(_ frame: NSRect, ratio: CGFloat, in screen: NSRect) -> NSRect {
        var w = (frame.width * frame.height * ratio).squareRoot()
        var h = w / ratio
        if w > screen.width { w = screen.width; h = w / ratio }
        if h > screen.height { h = screen.height; w = h * ratio }
        let corner = nearestCorner(of: frame, in: screen)
        var x = corner.left ? frame.minX : frame.maxX - w
        var y = corner.top ? frame.maxY - h : frame.minY
        x = min(max(x, screen.minX), screen.maxX - w)
        y = min(max(y, screen.minY), screen.maxY - h)
        return NSRect(x: x, y: y, width: w, height: h).integral
    }

    // MARK: The browser's tab

    /// The address to open so the video goes on where the browser was: YouTube and Twitch replays; a live goes on live.
    static func resume(_ url: URL, at moment: AdBlockVideoMoment?) -> URL {
        guard let m = moment, !m.live, !m.ad, m.seconds >= 3, m.seconds < 1_000_000,
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host?.lowercased() else { return url }
        let s = Int(m.seconds)
        var items = (c.queryItems ?? []).filter { $0.name != "t" }
        if (host == "youtube.com" || host.hasSuffix(".youtube.com")) && c.path == "/watch" {
            items.append(URLQueryItem(name: "t", value: "\(s)s"))
        } else if (host == "twitch.tv" || host.hasSuffix(".twitch.tv")) && c.path.hasPrefix("/videos/") {
            items.append(URLQueryItem(name: "t", value: "\(s / 3600)h\(s / 60 % 60)m\(s % 60)s"))
        } else {
            return url
        }
        c.queryItems = items
        return c.url ?? url
    }

    /// What `pause` answered: "none" (no video) or its JSON.
    static func moment(from text: String) -> AdBlockVideoMoment? {
        guard let data = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = (o["t"] as? NSNumber)?.doubleValue, t.isFinite else { return nil }
        return AdBlockVideoMoment(seconds: t, live: o["live"] as? Bool ?? false, ad: o["ad"] as? Bool ?? false)
    }

    /// Run in the browser's tab: pauses its largest video and tells where it was. No double quote nor backslash (it sits in
    /// an AppleScript string).
    static let pause = "(function(){var b=null,a=0;document.querySelectorAll('video').forEach(function(v){var r=v.getBoundingClientRect(),s=r.width*r.height;if(s>a){a=s;b=v}});if(!b)return 'none';var d=b.duration;b.pause();return JSON.stringify({t:b.currentTime||0,live:!isFinite(d)||!!document.querySelector('.ytp-live'),ad:!!document.querySelector('.ad-showing')})})()"

    /// The browser in front, or the one whose window is the highest on screen (the app's own window may be in front when
    /// the user clicked its button).
    nonisolated static func frontmostBrowser() -> AdBlockVideoBrowser? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in windows where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int else { continue }
            if let b = AdBlockVideoBrowser.named(NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier) { return b }
        }
        return AdBlockVideoBrowser.all.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }
    }

    /// Whether the browser let the app run its pause script, the last time (nil: never tried).
    static func scriptsAllowed(_ b: AdBlockVideoBrowser) -> Bool? {
        (UserDefaults.standard.dictionary(forKey: scriptsKey) as? [String: Bool])?[b.bundleID]
    }

    static func remember(scripts: Bool, for b: AdBlockVideoBrowser) {
        var all = UserDefaults.standard.dictionary(forKey: scriptsKey) as? [String: Bool] ?? [:]
        all[b.bundleID] = scripts
        UserDefaults.standard.set(all, forKey: scriptsKey)
    }

    // MARK: The page

    /// Added before `script` while the window is in video-only mode: every new page starts with its video alone.
    static let wanted = "window.__cmcVideoOnlyWanted = true;"

    /// In every page of the player. `__cmcVideoOnly(true)` finds the player (YouTube's, Twitch's, else the largest video
    /// with the box that holds its controls), lays it over the whole window and hides everything beside it, again each
    /// second (the sites change their pages as they go); it reports the video's size ("vo"). `false` gives the page back.
    static let script = #"""
    (() => {
      if (window.__cmcVideoOnly) return;
      const host = location.hostname;
      const yt = /(^|\.)youtube(-nocookie)?\.com$/.test(host);
      const tw = /(^|\.)twitch\.tv$/.test(host);
      // Twitch pages that are no channel nor replay: their players (the home page's carousel) are not what is watched.
      const twitchPages = ['', 'directory', 'search', 'settings', 'downloads', 'p', 'subscriptions', 'wallet', 'inventory', 'drops',
                           'friends', 'messages', 'turbo', 'prime', 'store', 'jobs', 'following'];
      const css = `
        html.hw-vo, html.hw-vo body { overflow: hidden !important; background: #000 !important; }
        html.hw-vo .hw-vo-off { display: none !important; }
        html.hw-vo .hw-vo-up { transform: none !important; filter: none !important; perspective: none !important; contain: none !important;
          will-change: auto !important; backdrop-filter: none !important; content-visibility: visible !important; }
        html.hw-vo .hw-vo-box { position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important;
          max-width: none !important; max-height: none !important; min-width: 0 !important; min-height: 0 !important; margin: 0 !important;
          padding: 0 !important; border-radius: 0 !important; transform: none !important; z-index: 2147483647 !important; background: #000 !important; }
        html.hw-vo .hw-vo-in { max-width: none !important; max-height: none !important; }
        html.hw-vo .hw-vo-box video { object-fit: contain !important; }
      `;
      let on = false, box = null, timer = 0, style = null, sent = '';
      const post = (m) => { try { window.webkit.messageHandlers.hw.postMessage(Object.assign({ type: 'vo' }, m)); } catch (e) {} };
      const watchable = () => {
        const p = location.pathname;
        if (yt) return /^\/(watch|live\/|shorts\/|embed\/)/.test(p);
        if (tw) return !twitchPages.includes((p.split('/')[1] || '').toLowerCase());
        return true;
      };
      const area = (e) => { const r = e.getBoundingClientRect(); return r.width * r.height; };
      const biggest = (root) => {
        let best = null, most = 0;
        root.querySelectorAll('video').forEach(v => { const a = area(v); if (a > most) { most = a; best = v; } });
        return best;
      };
      const pick = () => {
        if (!watchable()) return null;
        if (yt) {
          const p = document.querySelector('#movie_player') || document.querySelector('#shorts-player');
          return p && p.querySelector('video') ? p : null;
        }
        if (tw) {
          const p = document.querySelector('[data-a-target="video-player"]');
          if (p && p.querySelector('video')) return p;
        }
        const v = biggest(document);
        if (!v || area(v) < 160 * 90) return null;
        // Up to the box that still has the video's size: the site's controls are in it.
        const r = v.getBoundingClientRect();
        let el = v;
        while (el.parentElement && el.parentElement !== document.body) {
          const q = el.parentElement.getBoundingClientRect();
          if (q.width > r.width * 1.1 + 8 || q.height > r.height * 1.25 + 8) break;
          el = el.parentElement;
        }
        return el;
      };
      // Everything beside the player's branch, at each level up to the body; inside the player, the boxes around the
      // video lose the height limits the page gave them (Twitch's: the window's height minus the title below).
      const hide = () => {
        for (let e = biggest(box); e && e !== box; e = e.parentElement) e.classList.add('hw-vo-in');
        // The site may move its player elsewhere in the page: a box hidden as a sibling can become one of its parents.
        for (let el = box; el && el !== document.body && el.parentElement; el = el.parentElement) {
          const up = el.parentElement;
          el.classList.remove('hw-vo-off');
          up.classList.remove('hw-vo-off');
          up.classList.add('hw-vo-up');
          for (const s of up.children) {
            if (s !== el && s !== style && !/^(SCRIPT|STYLE|LINK|META)$/.test(s.tagName)) s.classList.add('hw-vo-off');
          }
        }
      };
      const unmark = () => {
        document.documentElement.classList.remove('hw-vo');
        document.querySelectorAll('.hw-vo-box, .hw-vo-up, .hw-vo-off, .hw-vo-in').forEach(e => e.classList.remove('hw-vo-box', 'hw-vo-up', 'hw-vo-off', 'hw-vo-in'));
      };
      // The site's player lays itself out again for its new size.
      const kick = () => {
        window.dispatchEvent(new Event('resize'));
        setTimeout(() => window.dispatchEvent(new Event('resize')), 400);
      };
      const report = () => {
        const v = box && biggest(box);
        const m = { found: !!box, w: v ? v.videoWidth : 0, h: v ? v.videoHeight : 0 };
        const key = JSON.stringify(m);
        if (key !== sent) { sent = key; post(m); }
      };
      const tick = () => {
        if (!on || !document.documentElement || !document.body) return;
        if (!style) style = Object.assign(document.createElement('style'), { textContent: css });
        if (!style.isConnected) (document.head || document.documentElement).appendChild(style);
        if (!box || !box.isConnected || !box.querySelector('video') || !watchable()) {
          const next = pick();
          if (next !== box) {
            unmark();
            box = next;
            if (box) { document.documentElement.classList.add('hw-vo'); box.classList.add('hw-vo-box'); hide(); kick(); }
          }
        }
        if (box) hide();
        report();
      };
      window.__cmcVideoOnly = (want) => {
        on = !!want;
        clearInterval(timer);
        if (on) { tick(); timer = setInterval(tick, 1000); }
        else { unmark(); box = null; sent = ''; kick(); }
      };
      if (window.__cmcVideoOnlyWanted) window.__cmcVideoOnly(true);
    })();
    """#

    // MARK: Checks

    static func checks() -> [String] {
        var f: [String] = []
        func expect(_ ok: Bool, _ message: String) { if !ok { f.append("vidéo seule : " + message) } }
        let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)

        // Corners and sizes: inside the screen, of the video's shape, at the right corner.
        for corner in AdBlockVideoCorner.allCases {
            let r = place(corner, width: 480, ratio: 16 / 9, in: screen)
            expect(screen.contains(r), "\(corner.title) sort de l'écran")
            expect(abs(r.width / r.height - 16 / 9) < 0.01, "\(corner.title) n'a pas la forme de la vidéo")
            expect(nearestCorner(of: r, in: screen) == corner, "\(corner.title) n'est pas reconnu comme son coin")
        }
        let br = place(.bottomRight, width: 480, ratio: 16 / 9, in: screen)
        expect(br.maxX == screen.maxX - margin && br.minY == screen.minY + margin && br.width == 480, "coin en bas à droite mal placé : \(br)")
        let tall = place(.topLeft, width: 1400, ratio: 9 / 16, in: screen)
        expect(tall.height <= screen.height - 2 * margin && screen.contains(tall), "une vidéo verticale trop grande doit tenir dans l'écran")
        expect(place(.topLeft, width: 50, ratio: 16 / 9, in: screen).width == 200, "la plus petite fenêtre fait 200 points de large")

        // A video of another shape: same area, same corner, on the screen.
        let wide = NSRect(x: 900, y: 41, width: 524, height: 295)
        let short = fit(wide, ratio: 9 / 16, in: screen)
        expect(abs(short.width / short.height - 9 / 16) < 0.01, "forme d'une vidéo verticale non prise")
        expect(abs(short.width * short.height - wide.width * wide.height) / (wide.width * wide.height) < 0.02, "l'aire change avec la forme")
        expect(short.maxX == wide.maxX && short.minY == wide.minY, "le coin en bas à droite doit rester en place")
        expect(screen.contains(fit(NSRect(x: 0, y: 25, width: 1400, height: 800), ratio: 9 / 16, in: screen)), "une fenêtre reformée doit rester dans l'écran")

        // Where the video goes on.
        func resumed(_ s: String, _ m: AdBlockVideoMoment?) -> String { resume(URL(string: s)!, at: m).absoluteString }
        let at = AdBlockVideoMoment(seconds: 754.6, live: false, ad: false)
        expect(resumed("https://www.youtube.com/watch?v=abc&t=10s&list=L", at) == "https://www.youtube.com/watch?v=abc&list=L&t=754s", "reprise YouTube")
        expect(resumed("https://www.twitch.tv/videos/123", AdBlockVideoMoment(seconds: 3_725, live: false, ad: false)) == "https://www.twitch.tv/videos/123?t=1h2m5s", "reprise d'une rediffusion Twitch")
        expect(resumed("https://www.twitch.tv/rasmelthor", at) == "https://www.twitch.tv/rasmelthor", "un direct Twitch reste en direct")
        expect(resumed("https://www.youtube.com/watch?v=abc", AdBlockVideoMoment(seconds: 754, live: true, ad: false)) == "https://www.youtube.com/watch?v=abc", "un direct YouTube reste en direct")
        expect(resumed("https://www.youtube.com/watch?v=abc", AdBlockVideoMoment(seconds: 12, live: false, ad: true)) == "https://www.youtube.com/watch?v=abc", "le temps d'une pub n'est pas celui de la vidéo")
        expect(resumed("https://www.youtube.com/watch?v=abc", AdBlockVideoMoment(seconds: 1, live: false, ad: false)) == "https://www.youtube.com/watch?v=abc", "au tout début, pas de temps")
        expect(resumed("https://www.youtube.com/watch?v=abc", nil) == "https://www.youtube.com/watch?v=abc", "sans réponse du navigateur, l'adresse telle quelle")
        expect(resumed("https://www.youtube.com/watch?v=abc", AdBlockVideoMoment(seconds: 1e300, live: false, ad: false)) == "https://www.youtube.com/watch?v=abc", "un temps absurde est ignoré")

        // The browser's answer.
        expect(moment(from: #"{"t":754.6,"live":false,"ad":false}"#) == at, "réponse du navigateur mal lue")
        expect(moment(from: "none") == nil && moment(from: "") == nil && moment(from: #"{"t":null}"#) == nil, "pas de vidéo : pas de moment")

        // The scripts sent to the browsers stay fixed text an AppleScript string can hold.
        expect(!pause.contains("\"") && !pause.contains("\\"), "le script de pause ne doit contenir ni guillemet double ni barre oblique inverse")
        for b in AdBlockVideoBrowser.all {
            expect(b.bundleID.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." }, "identifiant de \(b.name)")
            expect(NSAppleScript(source: b.urlScript) != nil && b.pauseScript.contains(pause), "scripts de \(b.name)")
        }
        expect(AdBlockVideoBrowser.named("com.apple.Safari")?.chromium == false && AdBlockVideoBrowser.named("com.google.Chrome")?.chromium == true
               && AdBlockVideoBrowser.named("com.apple.finder") == nil, "navigateurs reconnus")
        expect(script.contains("__cmcVideoOnlyWanted") && wanted.contains("__cmcVideoOnlyWanted"), "le mode doit passer d'une page à l'autre")
        return f
    }
}

// MARK: - Detaching

extension AdBlockPlayer {
    /// The video the user is watching, alone in a small window: the browser's front tab (paused there and resumed here at
    /// the same second when the browser lets the app run a script), or else the page already in the player. A page the
    /// player does not show (Netflix, Prime Video, Disney+…) goes into the browser's own picture in picture.
    func detach() async {
        guard !DemoData.isEnabled, !Snapshot.isActive else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        guard !detaching else { return }
        detaching = true
        defer { detaching = false }
        detachIssue = nil
        // The player's own window in front: its page. Otherwise the browser in front, or the highest on screen.
        if isFront, !address.isEmpty {
            setVideoOnly(true)
            return
        }
        var browser = AdBlockVideoBrowser.named(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        if browser == nil { browser = await Task.detached { AdBlockVideoOnly.frontmostBrowser() }.value }
        guard let browser else {
            if isOpen, !address.isEmpty {
                setVideoOnly(true)
            } else {
                HUD.show("Aucune vidéo à détacher : lance-la dans Safari.", symbol: "exclamationmark.circle.fill")
            }
            return
        }
        let read = await Task.detached(priority: .userInitiated) { Shell.appleScript(browser.urlScript) }.value
        if read.status == -1743 || read.status == -1744 {
            detachIssue = AdBlockDetachIssue(text: "\(AppEdition.name) n'a pas le droit de piloter \(browser.name) : active-le dans Réglages Système › Confidentialité et sécurité › Automatisation.",
                                             settings: .automation)
            HUD.show("Autorise \(AppEdition.name) à piloter \(browser.name), puis recommence.", symbol: "exclamationmark.circle.fill")
            Finder.open(PermissionKind.safari.settingsURL)
            return
        }
        guard read.ok, !read.out.isEmpty else {
            HUD.show("Aucune page ouverte dans \(browser.name).", symbol: "exclamationmark.circle.fill")
            return
        }
        switch AdBlockVideoPiP.route(read.out) {
        case .player(let page):
            await detachToPlayer(browser, page: page)
        case .browser(let site):
            await browserPictureInPicture(browser, site: site, host: URL(string: read.out)?.host ?? "")
        case .nothing:
            report(AdBlockVideoPiP.verdict(.noVideo, browser: browser, site: nil))
        }
    }

    /// YouTube, Twitch and the player's other platforms: paused in the browser, on here at the same second.
    private func detachToPlayer(_ browser: AdBlockVideoBrowser, page: URL) async {
        let paused = await Task.detached(priority: .userInitiated) { Shell.appleScript(browser.pauseScript) }.value
        if paused.ok {
            AdBlockVideoOnly.remember(scripts: true, for: browser)
        } else if paused.err.localizedCaseInsensitiveContains("javascript") {
            AdBlockVideoOnly.remember(scripts: false, for: browser)
        }
        open(AdBlockVideoOnly.resume(page, at: paused.ok ? AdBlockVideoOnly.moment(from: paused.out) : nil), videoOnly: true)
        if !paused.ok {
            HUD.show("\(browser.name) joue encore la vidéo : mets-la en pause là-bas.", symbol: "exclamationmark.circle.fill")
        }
    }

    /// Any other page: the browser keeps its video (session, licence) and puts it in its own picture in picture. The
    /// page's script first; when it cannot reach the video (a player in a frame of another origin, as TF1+'s) or the
    /// browser kept it in the page, Safari's own command (the video's menu, then the page menu), through the
    /// Accessibility the user granted. Once in it, Safari's red button hides Safari instead of closing the video's window.
    private func browserPictureInPicture(_ browser: AdBlockVideoBrowser, site: String?, host: String) async {
        let pipBefore = AdBlockSafariMenu.pipWindows()
        let request = browser.javaScript(AdBlockVideoPiP.request)
        var answer = AdBlockPiPAnswer.unreadable
        for attempt in 0... {
            let asked = await Task.detached(priority: .userInitiated) { Shell.appleScript(request) }.value
            if asked.ok {
                AdBlockVideoOnly.remember(scripts: true, for: browser)
                answer = AdBlockVideoPiP.answer(from: asked.out)
            } else if AdBlockVideoPiP.scriptsRefused(asked.err) {
                AdBlockVideoOnly.remember(scripts: false, for: browser)
                report(AdBlockVideoPiP.scriptsVerdict(browser, site: site))
                return
            } else {
                answer = .refused(error: asked.err)
            }
            // A player built a moment after the page: asked again, briefly.
            guard AdBlockVideoPiP.retry(after: answer, attempt: attempt) else { break }
            try? await Task.sleep(for: AdBlockVideoPiP.retryDelay)
        }
        if case .asked = answer { answer = await watchPictureInPicture(browser) }
        var menu: AdBlockSafariMenuOutcome?
        if AdBlockSafariMenu.serves(browser), AdBlockVideoPiP.wantsBrowserCommand(answer) {
            if AXIsProcessTrusted() {
                let id = browser.bundleID
                menu = await Task.detached(priority: .userInitiated) { AdBlockSafariMenu.enterPictureInPicture(bundleID: id) }.value
            } else if case .inFrame = answer {
                menu = .noAccess
            }
        }
        let verdict = AdBlockVideoPiP.verdict(answer, browser: browser, site: site, menu: menu)
        if verdict.success { ActionLog.write("IMAGE DANS L'IMAGE \(browser.name) \(host)\(menu == nil ? "" : " (menu de Safari)")") }
        if verdict.success, AdBlockSafariMenu.serves(browser), answer == .entered || menu == .entered {
            AdBlockPiPCloseGuard.shared.watch(bundleID: browser.bundleID, pip: AdBlockSafariMenu.pipWindows().subtracting(pipBefore))
        }
        report(verdict)
    }

    /// The browser takes a moment to move the video: still in picture in picture a moment later, it kept it there.
    private func watchPictureInPicture(_ browser: AdBlockVideoBrowser) async -> AdBlockPiPAnswer {
        let check = browser.javaScript(AdBlockVideoPiP.check)
        var last = AdBlockPiPAnswer.unreadable
        var seen = 0
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(350))
            let read = await Task.detached(priority: .userInitiated) { Shell.appleScript(check) }.value
            last = read.ok ? AdBlockVideoPiP.answer(from: read.out) : .unreadable
            if last == .entered {
                seen += 1
                if seen == 2 { break }
            } else if last == .kicked {
                break // the page brought it back
            } else if case .inline(let error) = last, !error.isEmpty {
                break // the browser said no
            } else {
                seen = 0
            }
        }
        return last
    }

    private func report(_ verdict: AdBlockPiPVerdict) {
        detachIssue = verdict.issue
        HUD.show(verdict.hud, symbol: verdict.success ? "pip.fill" : "exclamationmark.circle.fill")
    }
}

// MARK: - The window

/// Over the video-only window's page: the buttons, shown while the mouse moves over it.
struct AdBlockVideoOverlay: View {
    var player: AdBlockPlayer

    var body: some View {
        ZStack(alignment: .top) {
            if !Snapshot.isActive { // AppKit views draw as placeholders in snapshots
                AdBlockVideoHover { point in
                    player.pointerMoved(overButtons: point.y < 44)
                } left: {
                    player.pointerLeft()
                }
            }
            if player.controls {
                AdBlockVideoBar(player: player)
                    .transition(.opacity)
            }
        }
    }
}

/// What the snapshots show in place of the video.
struct AdBlockVideoPlaceholder: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.sidebar, Theme.bg], startPoint: .top, endPoint: .bottom)
            if Theme.icons != .hidden {
                Image(systemName: "play.fill").font(.ui(44, .bold)).foregroundStyle(Theme.text3.opacity(0.5))
            }
        }
    }
}

/// The buttons at the top of the video-only window; the strip around them moves the window.
struct AdBlockVideoBar: View {
    var player: AdBlockPlayer

    var body: some View {
        HStack(spacing: 6) {
            round("xmark", "Fermer la vidéo") { player.close() }
            round("pip.exit", "Lecteur complet : la page entière, avec le chat ou les commentaires") { player.setVideoOnly(false) }
            Spacer(minLength: 0)
            round("rectangle.inset.bottomright.filled", "Ranger dans un coin de l'écran, changer de taille") { AdBlockVideoMenu.show(player) }
            round(player.pinned ? "pin.fill" : "pin.slash",
                  player.pinned ? "Au-dessus de tes autres fenêtres, sur tous tes bureaux (clic : la laisser passer derrière)"
                                : "Passe derrière tes autres fenêtres (clic : la garder au-dessus)") { player.pinned.toggle() }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background { if !Snapshot.isActive { AdBlockVideoDragArea() } }
    }

    private func round(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.ui(11, .semibold)).foregroundStyle(Theme.text)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.r(13), style: .continuous).fill(Theme.cardRaised.opacity(0.92)))
                .overlay(RoundedRectangle(cornerRadius: Theme.r(13), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The corners and sizes, in a menu under the mouse.
@MainActor
enum AdBlockVideoMenu {
    static func show(_ player: AdBlockPlayer) {
        let menu = NSMenu()
        for corner in AdBlockVideoCorner.allCases {
            menu.addItem(item(corner.title) { player.place(corner) })
        }
        menu.addItem(.separator())
        for size in AdBlockVideoOnly.sizes {
            menu.addItem(item("Taille \(size.title)") { player.place(nil, size: size.width) })
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private static func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let target = AdBlockMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(AdBlockMenuAction.run), keyEquivalent: "")
        item.target = target
        item.representedObject = target // the menu item keeps its target alive
        return item
    }
}

@MainActor
private final class AdBlockMenuAction: NSObject {
    let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() { action() }
}

/// Drags the window (the video's page takes every click on the video itself).
private struct AdBlockVideoDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Strip() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Strip: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// Follows the mouse over the window, even while another app is in front, without taking any click.
private struct AdBlockVideoHover: NSViewRepresentable {
    var moved: (CGPoint) -> Void
    var left: () -> Void

    func makeNSView(context: Context) -> Tracker {
        let t = Tracker()
        t.moved = moved
        t.left = left
        return t
    }

    func updateNSView(_ t: Tracker, context: Context) {
        t.moved = moved
        t.left = left
    }

    final class Tracker: NSView {
        var moved: ((CGPoint) -> Void)?
        var left: (() -> Void)?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseMoved(with event: NSEvent) { moved?(convert(event.locationInWindow, from: nil)) }
        override func mouseEntered(with event: NSEvent) { moved?(convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { left?() }
    }
}

// MARK: - The page's panel

/// « Vidéo seule » on the player's tab: the button and its shortcut. The rest waits in its « ? », and comes back as a
/// warning when Safari kept playing the last video detached.
struct AdBlockVideoPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.adblock
        let target = HotkeysTarget.command(id: AdBlockVideoOnly.commandID, title: "Vidéo seule")
        let combo = app.hotkeys.binding(for: target)?.combo
        Panel(title: "Vidéo seule", subtitle: "La vidéo de ton navigateur, seule dans une petite fenêtre au-dessus des autres",
              symbol: "pip", tint: AdBlockStyle.tint) {
            HelpTipButton(tip: AdBlockTips.videoOnly)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button { Task { await m.player.detach() } } label: { label("Détacher la vidéo", "pip.enter") }
                        .buttonStyle(SoftButtonStyle(prominent: true))
                    if let combo {
                        Tag(text: combo.display, symbol: "keyboard", tint: Theme.text2)
                            .help("Ton raccourci, à changer dans Raccourcis")
                    } else {
                        Button("Lui donner un raccourci") { app.hotkeys.add(target) }
                            .buttonStyle(SoftButtonStyle(small: true))
                    }
                    Spacer(minLength: 0)
                }
                if let issue = m.player.detachIssue {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(issue.text).font(.ui(11.5, .medium)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                        if let tip = issue.tip { HelpTipButton(tip: tip, size: 12) }
                        Spacer(minLength: 0)
                        if let settings = issue.settings {
                            Button("Réglages…") { settings.open() }
                                .buttonStyle(SoftButtonStyle(small: true))
                        }
                    }
                } else if m.safariRefusedPause {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if Theme.icons != .hidden {
                            Image(systemName: "exclamationmark.triangle.fill").font(.ui(10.5)).foregroundStyle(Theme.warn)
                        }
                        Text("Safari n'écoute pas encore \(AppEdition.name)").font(.ui(11.5, .medium)).foregroundStyle(Theme.warn)
                        HelpTipButton(tip: AdBlockTips.safariPause, size: 12)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func label(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            if Theme.icons != .hidden { Image(systemName: symbol).font(.ui(12, .semibold)) }
            Text(text)
        }
    }
}

// MARK: - Bench

/// `--adblock video <lien> [image.png]` : the page in a real WebKit view, in video-only mode, muted, as the player shows
/// it (scripts, blocking rules), in a 640×360 window at the bottom left of the screen for about a minute. Says what was
/// isolated (and the boxes from the player down to its video) and writes what the window shows.
@MainActor
enum AdBlockVideoBench {
    private final class Listener: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { messages.append(body) }
        }
    }

    /// The bench never plays a sound.
    private static let mute = """
    (() => {
      const p = HTMLMediaElement.prototype, play = p.play;
      p.play = function () { this.muted = true; return play.apply(this, arguments); };
      document.addEventListener('volumechange', e => { if (e.target.muted === false) e.target.muted = true; }, true);
    })();
    """

    private static let probe = """
    (() => {
      const box = document.querySelector('.hw-vo-box');
      const rect = e => { if (!e) return null; const b = e.getBoundingClientRect(); return [Math.round(b.x), Math.round(b.y), Math.round(b.width), Math.round(b.height)]; };
      const v = box && [...box.querySelectorAll('video')].sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];
      const others = [...document.body.querySelectorAll('*')].filter(e => !box || (!box.contains(e) && !e.contains(box))).filter(e => {
        const b = e.getBoundingClientRect(), s = getComputedStyle(e);
        return b.width > 4 && b.height > 4 && s.visibility !== 'hidden' && b.bottom > 0 && b.right > 0 && b.top < innerHeight && b.left < innerWidth;
      }).length;
      return JSON.stringify({ page: location.href, box: box ? (box.id ? '#' + box.id : String(box.className).slice(0, 60)) : null,
        boxRect: rect(box), video: rect(v), videoSize: v ? [v.videoWidth, v.videoHeight] : null, playing: v ? !v.paused : null,
        muted: v ? v.muted : null, ready: v ? v.readyState : null, error: v && v.error ? v.error.code : null,
        hidden: document.visibilityState, others, viewport: [innerWidth, innerHeight],
        chain: (() => { const out = []; for (let e = v; e && box && e !== box.parentElement; e = e.parentElement) { const s = getComputedStyle(e), b = e.getBoundingClientRect();
          out.push(e.tagName.toLowerCase() + '.' + String(e.className).split(' ').filter(c => !/^(Layout|ScAspect|sc-)/.test(c)).slice(0, 3).join('.') + ' ' + Math.round(b.width) + 'x' + Math.round(b.height) + ' ' + s.position + ' ' + (e.getAttribute('style') || '').slice(0, 80)); } return out; })() });
    })()
    """

    static func run(_ url: URL, png: String?) async {
        setvbuf(stdout, nil, _IOLBF, 0) // each line as it comes, even into a pipe
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching() // windows are only "visible" to WebKit once the app has launched
        let listener = Listener()
        let config = AdBlockPlayer.configuration(handler: listener, journal: false, videoOnly: true)
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: mute, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        let size = NSSize(width: 640, height: 360)
        // Really on screen: WebKit holds back the video of a page it cannot see (even a window all but transparent).
        // Clicks go through it.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        window.level = .floating
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        window.contentView = web
        window.orderFrontRegardless()
        let start = Date()
        web.load(URLRequest(url: url))
        print("Vidéo seule : \(url.absoluteString)")
        while Date().timeIntervalSince(start) < 45 {
            await pump(0.5)
            if listener.messages.contains(where: { $0["type"] as? String == "vo" && ($0["w"] as? Double ?? 0) > 0 }) { break }
        }
        await pump(4)
        print(String(format: "Attendu %.0f s", Date().timeIntervalSince(start)))
        for m in listener.messages {
            let text = m.filter { $0.key != "hosts" }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            print("  message : \(text)")
        }
        if let info = try? await web.evaluateJavaScript(probe) as? String { print("  page : \(info)") }
        if let png, let image = try? await web.takeSnapshot(configuration: nil),
           let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            do { print("  image : \(try FileOps.write(data, to: URL(fileURLWithPath: png)).path)") } catch { print("  image : échec, \(error.localizedDescription)") }
        }
        // Back to the whole page: what the user sees after « Lecteur complet ».
        _ = try? await web.evaluateJavaScript("window.__cmcVideoOnly(false); 1")
        await pump(1)
        if let info = try? await web.evaluateJavaScript(probe) as? String { print("  page rendue : \(info)") }
        window.close()
    }

    /// The window server's events, handled as the app would (the command line runs no app loop): without them the
    /// window never learns it is on screen, and WebKit keeps the page hidden.
    /// Between two, the main queue runs (WebKit answers through it).
    static func pump(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            while let event = NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
