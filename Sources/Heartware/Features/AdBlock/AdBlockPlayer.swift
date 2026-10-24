import SwiftUI
import AppKit
import WebKit

/// What the player says over the video while it deals with an ad.
enum AdBlockPlayerNotice: Equatable {
    /// YouTube holds the video back as long as the ad it had planned would have lasted.
    case youtubeHeld
    /// A Twitch ad break: replaced by the same live in another stream, or cut (the picture waits).
    case twitchSwapped
    case twitchCut
}

/// The ad-free player: YouTube, Twitch and the free French platforms (`AdBlockPlayerSite`) in a window of the app, the
/// blocking engine built in (`AdBlockPlayerScripts`). It browses these sites itself, after the user opened it; links
/// elsewhere open in the default browser. Closing the window stops everything and frees the page.
@Observable
@MainActor
final class AdBlockPlayer: NSObject {
    static let youtube = URL(string: "https://www.youtube.com/")!
    static let twitch = URL(string: "https://www.twitch.tv/")!

    var isOpen = false
    var title = ""
    var address = ""
    var canGoBack = false
    var canGoForward = false
    var loading = false
    var notice: AdBlockPlayerNotice?
    /// Ads cut since the window opened.
    var cut = 0
    /// « Vidéo seule » : the window shows the video alone, small, above the other windows (`AdBlockVideoOnly`).
    private(set) var videoOnly = false
    /// In video-only mode, the window stays above the other windows and on every desktop.
    var pinned = UserDefaults.standard.object(forKey: AdBlockVideoOnly.pinnedKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(pinned, forKey: AdBlockVideoOnly.pinnedKey)
            if let window { applyLevel(window) }
        }
    }
    /// The video-only window's buttons, shown while the mouse moves over it.
    var controls = false
    /// Width over height of the video shown, which the video-only window keeps.
    private(set) var videoRatio: CGFloat = 16 / 9
    /// Why the last « Détacher la vidéo » could not reach the browser, shown on the page.
    var detachIssue: AdBlockDetachIssue?
    /// A « Détacher la vidéo » is reading the browser (a second press waits for it).
    @ObservationIgnored var detaching = false

    @ObservationIgnored weak var model: AdBlockModel?
    @ObservationIgnored private(set) var web: WKWebView?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var watches: [NSKeyValueObservation] = []
    @ObservationIgnored private var noticeWork: DispatchWorkItem?
    @ObservationIgnored private var controlsWork: DispatchWorkItem?
    /// The small windows a page opens itself (« Se connecter avec Google », the pop-out chat).
    @ObservationIgnored private var popups: [NSWindow] = []
    /// Told when the cookies change while the window is open: a sign-in or a sign-out in a page.
    @ObservationIgnored private var cookieWatch: AdBlockCookieProxy?
    @ObservationIgnored private var cookieWork: DispatchWorkItem?
    /// The Labo's notes on what each site calls (`AdBlockPlayerJournal`), nil in the published app.
    @ObservationIgnored private lazy var journal: JSONStore<AdBlockPlayerJournal>? =
        AppEdition.isLab ? JSONStore("player-journal", default: AdBlockPlayerJournal()) : nil

    static let frameName = "Heartware.AdFreePlayer"
    static let videoFrameName = "Heartware.AdFreePlayer.Video"

    /// The player's window is the one the user is in.
    var isFront: Bool { NSApp.isActive && window?.isKeyWindow == true }

    // MARK: Opening

    /// Shows a page; `videoOnly` puts the window in « Vidéo seule » (then the app is not brought forward: the user goes on
    /// with what they were doing), otherwise in the full player.
    func open(_ url: URL, videoOnly: Bool = false) {
        guard !DemoData.isEnabled, !Snapshot.isActive else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        guard let app = AppContext.model else { return }
        if web == nil { makeWindow(app, videoOnly: videoOnly) } else { setVideoOnly(videoOnly) }
        web?.load(URLRequest(url: url))
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        if videoOnly {
            window?.orderFrontRegardless()
        } else {
            // Over the browser even when macOS keeps the app from coming forward (a switch from the browser).
            window?.orderFrontRegardless()
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        ActionLog.write("\(videoOnly ? "VIDÉO SEULE" : "LECTEUR SANS PUB") \(url.host ?? "")")
    }

    /// The page's settings, like Safari's, with the blocking engine; `handler` receives what the pages say ("hw").
    static func configuration(handler: WKScriptMessageHandler, journal: Bool, videoOnly: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Like Safari: YouTube and Twitch serve their full sites, and remember the account the user signs in with.
        config.applicationNameForUserAgent = "Version/\(Self.safariVersion) Safari/605.1.15"
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        let content = WKUserContentController()
        installScripts(content, journal: journal, videoOnly: videoOnly)
        content.add(handler, name: "hw")
        config.userContentController = content
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "heartware-adfree-2",
                                                                 encodedContentRuleList: AdBlockPlayerScripts.rules) { list, _ in
            if let list { content.add(list) }
        }
        return config
    }

    /// The scripts every page gets from its start; changed with the mode, they apply from the next page on.
    static func installScripts(_ content: WKUserContentController, journal: Bool, videoOnly: Bool) {
        content.removeAllUserScripts()
        var sources = AdBlockPlayerSite.all.compactMap(\.script)
        if videoOnly { sources.append(AdBlockVideoOnly.wanted) }
        sources.append(AdBlockVideoOnly.script)
        for source in sources {
            content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        if journal {
            content.addUserScript(WKUserScript(source: AdBlockPlayerJournal.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
    }

    private func makeWindow(_ app: AppModel, videoOnly: Bool) {
        let config = Self.configuration(handler: AdBlockScriptProxy(self), journal: journal != nil, videoOnly: videoOnly)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1240, height: 780), configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        watches = [
            web.observe(\.title) { [weak self] w, _ in MainActor.assumeIsolated { self?.title = w.title ?? "" } },
            web.observe(\.url) { [weak self] w, _ in MainActor.assumeIsolated { self?.address = w.url?.absoluteString ?? "" } },
            web.observe(\.canGoBack) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoBack = w.canGoBack } },
            web.observe(\.canGoForward) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoForward = w.canGoForward } },
            web.observe(\.isLoading) { [weak self] w, _ in MainActor.assumeIsolated { self?.loading = w.isLoading } }
        ]
        self.web = web
        let cookies = AdBlockCookieProxy(self)
        web.configuration.websiteDataStore.httpCookieStore.add(cookies)
        cookieWatch = cookies

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Lecteur sans pub"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = AdBlockPlayerHost(rootView: AdBlockPlayerView(player: self).environment(app))
        window.delegate = self
        self.window = window
        self.videoOnly = videoOnly
        applyMode(window)
        isOpen = true
        cut = 0
    }

    // MARK: Video only

    /// Switches the window between the full player and « Vidéo seule », on the page shown.
    func setVideoOnly(_ on: Bool) {
        guard on != videoOnly else { return }
        videoOnly = on
        guard let window, let web else { return }
        Self.installScripts(web.configuration.userContentController, journal: journal != nil, videoOnly: on)
        web.evaluateJavaScript("window.__cmcVideoOnly && window.__cmcVideoOnly(\(on))", completionHandler: nil)
        controls = false
        if window.isMiniaturized { window.deminiaturize(nil) }
        if window.styleMask.contains(.fullScreen) {
            // Out of full screen first: the window takes its small size once it is back (`windowDidExitFullScreen`).
            window.toggleFullScreen(nil)
        } else {
            applyMode(window)
        }
        if on {
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// The window's look and size for the mode; each mode keeps its own place on screen.
    private func applyMode(_ window: NSWindow) {
        let on = videoOnly
        window.setFrameAutosaveName("")
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = on
        }
        window.title = on ? "Vidéo seule" : "Lecteur sans pub"
        window.titleVisibility = on ? .hidden : .visible
        if on {
            window.minSize = NSSize(width: 200, height: 112)
            window.contentAspectRatio = NSSize(width: videoRatio, height: 1)
            if window.setFrameUsingName(Self.videoFrameName) {
                // Saved with the last video's shape (macOS does not apply the ratio to a frame it restores).
                window.setFrame(AdBlockVideoOnly.fit(window.frame, ratio: videoRatio, in: visible(window)), display: true)
            } else {
                window.setFrame(AdBlockVideoOnly.place(.bottomRight, width: AdBlockVideoOnly.sizes[1].width * visible(window).width,
                                                       ratio: videoRatio, in: visible(window)), display: true)
            }
        } else {
            window.minSize = NSSize(width: 640, height: 420)
            window.contentResizeIncrements = NSSize(width: 1, height: 1) // no aspect ratio
            if !window.setFrameUsingName(Self.frameName) {
                window.setContentSize(NSSize(width: 1240, height: 820))
                window.center()
            }
        }
        applyLevel(window)
        window.setFrameAutosaveName(on ? Self.videoFrameName : Self.frameName)
    }

    private func applyLevel(_ window: NSWindow) {
        let floats = videoOnly && pinned
        window.level = floats ? .floating : .normal
        window.collectionBehavior = !videoOnly ? [.fullScreenPrimary] : floats ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenNone]
    }

    private func visible(_ window: NSWindow) -> NSRect {
        (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Moves the video-only window to a corner of its screen, at its size or at `size` (a share of the screen's width).
    func place(_ corner: AdBlockVideoCorner?, size: CGFloat? = nil) {
        guard let window, videoOnly else { return }
        let screen = visible(window)
        let width = size.map { $0 * screen.width } ?? window.frame.width
        let to = corner ?? AdBlockVideoOnly.nearestCorner(of: window.frame, in: screen)
        window.setFrame(AdBlockVideoOnly.place(to, width: width, ratio: videoRatio, in: screen), display: true, animate: true)
    }

    /// The page found a video of another shape: the window takes it, keeping its area and its corner.
    private func adopt(width: Double, height: Double) {
        guard width > 0, height > 0 else { return }
        let ratio = min(max(CGFloat(width / height), 0.3), 4)
        guard abs(ratio - videoRatio) / videoRatio > 0.02 else { return }
        videoRatio = ratio
        guard videoOnly, let window else { return }
        window.contentAspectRatio = NSSize(width: ratio, height: 1)
        window.setFrame(AdBlockVideoOnly.fit(window.frame, ratio: ratio, in: visible(window)), display: true, animate: true)
    }

    /// The buttons appear while the mouse moves, and go 2 s after it stops (not while it rests on them).
    func pointerMoved(overButtons: Bool) {
        if !controls { withAnimation(.easeOut(duration: 0.15)) { controls = true } }
        controlsWork?.cancel()
        guard !overButtons else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { withAnimation(.easeOut(duration: 0.3)) { self?.controls = false } }
        }
        controlsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func pointerLeft() {
        controlsWork?.cancel()
        withAnimation(.easeOut(duration: 0.3)) { controls = false }
    }

    /// The snapshot's video-only window: its buttons and a notice over the (empty) video.
    func previewVideoOnly() {
        videoOnly = true
        controls = true
        notice = .twitchSwapped
    }

    /// Safari's own version, for the user agent (the sites serve their full pages to it).
    static var safariVersion: String {
        (NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")?["CFBundleShortVersionString"] as? String) ?? "18.0"
    }

    func close() {
        window?.close()
    }

    func goBack() { web?.goBack() }
    func goForward() { web?.goForward() }
    func reload() { web?.reload() }

    func openInSafari() {
        guard let url = web?.url else { return }
        // Given back to the browser on purpose: the automatic switch leaves it there.
        model?.handoff.giveBack(url)
        NSWorkspace.shared.open(url)
    }

    /// After a sign-out: the page shown again, signed out (a Google account also serves the other sites).
    func reloadAfterSignOut() {
        if web?.url != nil { web?.reload() }
    }

    /// The accounts are read again a moment after the cookies stop changing (the sites change some on every page).
    fileprivate func cookiesChanged() {
        guard cookieWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.cookieWork = nil
                self?.model?.refreshAccounts()
            }
        }
        cookieWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: Windows opened by the pages

    /// A window the page opens itself, small, over the player: the page that opened it gets its answer (a sign-in).
    private func popup(_ configuration: WKWebViewConfiguration, features: WKWindowFeatures) -> WKWebView {
        let size = NSSize(width: min(max(CGFloat(truncating: features.width ?? 520), 360), 1000),
                          height: min(max(CGFloat(truncating: features.height ?? 680), 400), 900))
        let page = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        page.navigationDelegate = self
        page.uiDelegate = self
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Lecteur sans pub"
        w.isReleasedWhenClosed = false
        w.contentView = page
        w.delegate = self
        if let parent = window {
            w.level = parent.level
            w.setFrameOrigin(NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.midY - size.height / 2))
        } else {
            w.center()
        }
        popups.append(w)
        w.makeKeyAndOrderFront(nil)
        return page
    }

    // MARK: Messages from the pages

    fileprivate func received(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        let site = body["site"] as? String ?? ""
        switch type {
        case "ad", "adbreak":
            cut += 1
            model?.countVideoAd(site: site)
        case "held":
            show(.youtubeHeld, for: 40)
        case "released", "adbreak-end":
            show(nil, for: 0)
        case "journal":
            guard let journal, let site = web?.url.flatMap(AdBlockPlayerSite.site(of:)) else { return }
            journal.value.add(body, site: site.key)
        case "swap":
            show(.twitchSwapped, for: 8)
        case "strip":
            show(.twitchCut, for: 120)
        case "vo":
            adopt(width: body["w"] as? Double ?? 0, height: body["h"] as? Double ?? 0)
        default:
            break
        }
    }

    /// A notice, gone by itself after `seconds` (in case its end is never reported).
    private func show(_ n: AdBlockPlayerNotice?, for seconds: Double) {
        noticeWork?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { notice = n }
        guard n != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { withAnimation(.easeOut(duration: 0.25)) { self?.notice = nil } }
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: Links

    /// Hosts the player shows itself (the sites, their sign-in and video servers); any other page opens in the default browser.
    static func belongs(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" }
        return AdBlockPlayerSite.all.contains { $0.owns(host) }
    }

    /// A YouTube or Twitch address worth opening in the player (short links made whole), a page of another site of the
    /// player (France.tv, TF1+, M6+, Arte, Pluto TV), or nil.
    static func playable(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host?.lowercased(), url.scheme == "https" || url.scheme == "http" else { return nil }
        if host == "youtu.be" {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
            var c = URLComponents(string: "https://www.youtube.com/watch")!
            c.queryItems = [URLQueryItem(name: "v", value: id)] + (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            return c.url
        }
        let youtube = host == "youtube.com" || host.hasSuffix(".youtube.com")
        let twitch = host == "twitch.tv" || host.hasSuffix(".twitch.tv")
        if !youtube, !twitch, AdBlockPlayerSite.others.contains(where: { $0.owns(host) }) {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.scheme = "https"
            return c?.url
        }
        guard youtube || twitch else { return nil }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.scheme = "https"
        if youtube, host == "m.youtube.com" || host == "youtube.com" { c?.host = "www.youtube.com" }
        if twitch, host == "m.twitch.tv" || host == "twitch.tv" { c?.host = "www.twitch.tv" }
        return c?.url
    }

    /// The Safari bookmark that hands the page shown to the player (Safari asks once whether to open Heartware).
    static let bookmarklet = "javascript:location.href='heartware://regarder?url='+encodeURIComponent(location.href)"
}

extension AdBlockPlayer: WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // The pages of another site, opened by the user in a frame of its own: the default browser shows them.
        if action.targetFrame?.isMainFrame != false, let url = action.request.url, !Self.belongs(url), url.scheme?.hasPrefix("http") == true {
            NSWorkspace.shared.open(url)
            // A window opened for that page alone has nothing left to show.
            if webView !== web, webView.backForwardList.currentItem == nil { webView.window?.close() }
            return .cancel
        }
        return .allow
    }

    /// A link that asks for a new tab: in this window if it belongs to the sites, in the browser otherwise. A window the
    /// page opens itself (« Se connecter avec Google », the pop-out chat) gets a small window of its own.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = action.request.url
        if let url, url.scheme?.hasPrefix("http") == true {
            guard Self.belongs(url) else {
                NSWorkspace.shared.open(url)
                return nil
            }
            if action.navigationType == .linkActivated {
                (web ?? webView).load(URLRequest(url: url))
                return nil
            }
        }
        return popup(configuration, features: windowFeatures)
    }

    /// The page closed its own window (a sign-in that is done).
    func webViewDidClose(_ webView: WKWebView) {
        if webView !== web { webView.window?.close() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView !== web, let title = webView.title, !title.isEmpty { webView.window?.title = title }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if videoOnly, let window { applyMode(window) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else {
            // A window a page opened: its page stops and goes.
            if let w = notification.object as? NSWindow {
                if let page = w.contentView as? WKWebView {
                    page.stopLoading()
                    page.navigationDelegate = nil
                    page.uiDelegate = nil
                }
                w.contentView = nil
                popups.removeAll { $0 === w }
            }
            return
        }
        let opened = popups
        popups = []
        opened.forEach { $0.close() }
        if let cookieWatch { web?.configuration.websiteDataStore.httpCookieStore.remove(cookieWatch) }
        cookieWatch = nil
        cookieWork?.cancel()
        cookieWork = nil
        model?.refreshAccounts()
        // The page stops (sound and picture) and its memory is freed.
        watches = []
        web?.stopLoading()
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "hw")
        web?.loadHTMLString("", baseURL: nil)
        web = nil
        window?.contentView = nil
        window = nil
        isOpen = false
        notice = nil
        videoOnly = false
        controls = false
        videoRatio = 16 / 9
    }
}

/// The window's content answers the first click even while another app is in front (the video-only window's buttons).
private final class AdBlockPlayerHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Holds the player weakly, like the message handler below.
private final class AdBlockCookieProxy: NSObject, WKHTTPCookieStoreObserver {
    weak var player: AdBlockPlayer?

    init(_ player: AdBlockPlayer) {
        self.player = player
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        MainActor.assumeIsolated { player?.cookiesChanged() }
    }
}

/// Holds the player weakly: WebKit keeps its message handlers for as long as the page lives.
private final class AdBlockScriptProxy: NSObject, WKScriptMessageHandler {
    weak var player: AdBlockPlayer?

    init(_ player: AdBlockPlayer) {
        self.player = player
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { player?.received(body) }
    }
}

// MARK: - The window

/// The player's window in the snapshots, 16:9 in « Vidéo seule » (read when drawn, after `--tab`).
struct AdBlockPlayerSnapshot: View {
    var player: AdBlockPlayer

    var body: some View {
        AdBlockPlayerView(player: player).frame(height: player.videoOnly ? 540 : 520)
    }
}

struct AdBlockPlayerView: View {
    var player: AdBlockPlayer

    /// One place for the page in both modes: SwiftUI keeps the same web view when the mode changes.
    var body: some View {
        let video = player.videoOnly
        VStack(spacing: 0) {
            if !video { toolbar }
            ZStack(alignment: .top) {
                if let web = player.web {
                    AdBlockWebView(web: web)
                } else if video {
                    AdBlockVideoPlaceholder()
                } else {
                    Theme.bg
                }
                if video { AdBlockVideoOverlay(player: player) }
            }
            .overlay(alignment: .bottom) {
                if let notice = player.notice {
                    AdBlockNoticeView(notice: notice, compact: video)
                        .padding(.bottom, video ? 12 : 28)
                        .allowsHitTesting(false)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(Theme.bg)
        .ignoresSafeArea(.container, edges: video ? .all : [])
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            // Room for the window's own buttons.
            Spacer().frame(width: 64)
            button("chevron.left", "Page précédente", enabled: player.canGoBack) { player.goBack() }
            button("chevron.right", "Page suivante", enabled: player.canGoForward) { player.goForward() }
            button(player.loading ? "xmark" : "arrow.clockwise", player.loading ? "Arrêter" : "Recharger", enabled: true) {
                if player.loading { player.web?.stopLoading() } else { player.reload() }
            }
            Button("YouTube") { player.open(AdBlockPlayer.youtube) }.buttonStyle(SoftButtonStyle(small: true))
            Button("Twitch") { player.open(AdBlockPlayer.twitch) }.buttonStyle(SoftButtonStyle(small: true))
            BorderlessMenu {
                ForEach(AdBlockPlayerSite.others) { site in
                    Button(site.name) { player.open(site.home) }
                }
            } label: {
                Text("Plus").font(.ui(11.5, .medium)).foregroundStyle(Theme.text2)
            }
            Text(player.title.isEmpty ? "Lecteur sans pub" : player.title)
                .font(.ui(12.5, .medium)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity)
            if let model = player.model { AdBlockAccountsMenu(model: model) }
            Tag(text: Fmt.plural(player.cut, "pub coupée", "pubs coupées"), symbol: "hand.raised.fill", tint: Theme.good, filled: true)
                .help("Depuis l'ouverture de cette fenêtre")
            button("pip.enter", "Vidéo seule : la vidéo seule dans une petite fenêtre au-dessus des autres", enabled: !player.address.isEmpty) {
                player.setVideoOnly(true)
            }
            button("safari", "Ouvrir cette page dans Safari", enabled: !player.address.isEmpty) { player.openInSafari() }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func button(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.ui(12.5, .semibold)).foregroundStyle(enabled ? Theme.text : Theme.text3)
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

/// What the player says over the video, with the mascot at work.
struct AdBlockNoticeView: View {
    var notice: AdBlockPlayerNotice
    /// The video-only window's version: the title alone.
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            BusyMascot(.sweeping, pixel: compact ? 1 : 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(compact ? 11.5 : 13, .semibold)).foregroundStyle(Theme.text)
                if !compact {
                    Text(detail).font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, compact ? 10 : 16)
        .padding(.vertical, compact ? 6 : 12)
        .frame(maxWidth: compact ? nil : 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous).fill(Theme.cardRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: Theme.line))
        .themedShadow(color: .black.opacity(0.35), radius: 14, y: 4)
    }

    private var title: String {
        switch notice {
        case .youtubeHeld: return "Pub coupée"
        case .twitchSwapped: return "Coupure pub remplacée"
        case .twitchCut: return "Coupure pub retirée"
        }
    }

    private var detail: String {
        switch notice {
        case .youtubeHeld: return "YouTube retient la vidéo le temps qu'aurait duré sa pub : elle démarre dans quelques secondes, sans pub."
        case .twitchSwapped: return "Tu regardes le même direct par un autre flux, sans pub. La qualité peut baisser un instant."
        case .twitchCut: return "Twitch a remplacé le direct par sa pub : l'image attend la fin de la coupure, sans la pub."
        }
    }
}

/// The page itself, owned by the player (it outlives SwiftUI's redraws).
struct AdBlockWebView: NSViewRepresentable {
    var web: WKWebView

    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
