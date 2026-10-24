import SwiftUI
import AppKit
import ServiceManagement

/// The app model, reachable from AppKit entry points (delegate, Finder service) that SwiftUI does not reach.
@MainActor
enum AppContext {
    static var model: AppModel?
    /// Captured from the main window's view: SwiftUI's way to (re)create a closed window.
    static var openWindow: OpenWindowAction?

    /// Brings the main window to the front, recreating it if it was closed.
    static func showMainWindow() {
        // The pages come back before the window does, so it never shows up empty.
        setMainWindowOpen(true)
        if DockIconMode.current == .whileWindowOpen { NSApp.setActivationPolicy(.regular) }
        if let w = mainWindow {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static var mainWindow: NSWindow? {
        NSApp.windows.first { w in
            (w.identifier?.rawValue.hasPrefix("main") ?? false) && (w.isVisible || w.isMiniaturized)
        }
    }

    /// The system monitor samples at its full pace only while something shows its values: here, the main window on
    /// screen (not closed, minimised, hidden, on another Space or fully covered). The pages' own samples and small
    /// animations follow the same state (`AppModel.mainWindowOnScreen`).
    /// The pages, though, stay drawn until the window closes, so that they keep their state off screen.
    static func noteMainWindowVisibility(closing: Bool = false) {
        let windows = closing ? [] : NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") ?? false }
        // Closing is the only way to lose the pages; any way back on screen (Dock, menu bar, Window menu) brings them back.
        if closing { setMainWindowOpen(false) } else if windows.contains(where: \.isVisible) { setMainWindowOpen(true) }
        let onScreen = !NSApp.isHidden
            && windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
        model?.setMainWindowOnScreen(onScreen)
    }

    private static func setMainWindowOpen(_ open: Bool) {
        guard let model, model.mainWindowOpen != open else { return }
        model.mainWindowOpen = open
        // Back on screen: the tools used since are placed again (never while the sidebar is in front of the user).
        if open { model.profile.refresh(model) }
    }

    /// No Dock icon by default, like Raycast: the app lives in the menu bar and behind its shortcut.
    static func applyDockIcon(windowClosing: Bool = false) {
        let windowOpen = !windowClosing && mainWindow != nil
        let regular: Bool
        switch DockIconMode.current {
        case .never: regular = false
        case .whileWindowOpen: regular = windowOpen
        case .always: regular = true
        }
        let policy: NSApplication.ActivationPolicy = regular ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Leaving .regular hides the app's windows from the front: keep the open window where it is.
        if !regular, windowOpen { DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) } }
    }
}

/// When the app shows an icon in the Dock (and in ⌘⇥).
enum DockIconMode: String, CaseIterable, Identifiable {
    case never, whileWindowOpen, always

    static let key = "app.dockIcon"
    var id: String { rawValue }

    static var current: DockIconMode {
        UserDefaults.standard.string(forKey: key).flatMap(DockIconMode.init(rawValue:)) ?? .never
    }

    var title: String {
        switch self {
        case .never: return "Jamais, comme Raycast"
        case .whileWindowOpen: return "Quand la fenêtre est ouverte"
        case .always: return "Toujours"
        }
    }
}

/// Launch at login: on by default (the launcher and the shortcuts must always answer), once per Mac; the user can turn it off.
enum LoginItem {
    static let defaultAppliedKey = "app.loginItemDefaulted"
    static let labKey = "app.loginItemLabChecked"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ on: Bool) -> String? {
        guard !DemoData.isEnabled else { return DemoData.refusal }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Impossible : lance l'app assemblée depuis Applications (\(error.localizedDescription))."
        }
    }

    static func applyDefaultOnce() {
        // The Labo copy opens at login only when asked (Réglages › Général): the published app does, and only one of the
        // two can own the shortcuts. A Labo built before this rule registered itself: undone once.
        if AppEdition.isLab {
            guard !DemoData.isEnabled, !UserDefaults.standard.bool(forKey: labKey) else { return }
            UserDefaults.standard.set(true, forKey: labKey)
            if isEnabled { set(false) }
            return
        }
        // Not for a copy macOS runs from a provisional folder (opened straight from its archive): that path goes away.
        guard !DemoData.isEnabled, !UserDefaults.standard.bool(forKey: defaultAppliedKey),
              Bundle.main.bundlePath.hasSuffix(".app"), !Bundle.main.bundlePath.contains("/AppTranslocation/") else { return }
        UserDefaults.standard.set(true, forKey: defaultAppliedKey)
        if !isEnabled { set(true) }
    }

    /// True when macOS opened the app at login (no window then, just the menu bar and the shortcuts).
    /// Only meaningful in `applicationDidFinishLaunching`: AppKit sends it while handling the launch event,
    /// which does not exist yet in `applicationWillFinishLaunching` and is gone right after.
    static var launchedAtLogin: Bool { isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent) }

    /// The "open application" event that macOS sends to a login item carries `keyAELaunchedAsLogInItem`.
    static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    static func selfTest() -> [String] {
        func openApp(_ prop: OSType?) -> NSAppleEventDescriptor {
            let e = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
            if let prop { e.setParam(NSAppleEventDescriptor(enumCode: prop), forKeyword: AEKeyword(keyAEPropData)) }
            return e
        }
        let reopen = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                            transactionID: AETransactionID(kAnyTransactionID))
        reopen.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        var failures: [String] = []
        if !isLoginLaunch(openApp(OSType(keyAELaunchedAsLogInItem))) { failures.append("ouverture à la connexion non reconnue") }
        for (name, event) in [("sans événement", nil), ("ouverture normale", openApp(nil)),
                              ("ouverture comme service", openApp(OSType(keyAELaunchedAsServiceItem))), ("réouverture", reopen)]
        where isLoginLaunch(event) {
            failures.append("ouverture à la connexion reconnue à tort (\(name))")
        }
        return failures
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = FinderServices()
    private var statusItem: StatusItemController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before the first window: a theme that is always light or dark sets the appearance of every window,
        // and the first-launch cards show the login item as it really is.
        MainActor.assumeIsolated { ThemeStore.shared.applyAppearance() }
        LoginItem.applyDefaultOnce()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read first: the launch event is only there while AppKit handles it (not before, nor after this method).
        let atLogin = LoginItem.launchedAtLogin
        MainActor.assumeIsolated {
            AppContext.applyDockIcon()
            if atLogin {
                // Opened at login: stay in the background, like Raycast. SwiftUI opens no window then;
                // one that macOS would restore anyway closes too.
                DispatchQueue.main.async { AppContext.mainWindow?.close() }
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
                guard let w = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    if w.identifier?.rawValue.hasPrefix("main") ?? false {
                        AppContext.applyDockIcon(windowClosing: true)
                        AppContext.noteMainWindowVisibility(closing: true)
                    } else if !(w is NSPanel), w.styleMask.contains(.titled), w.isKeyWindow,
                              w.identifier?.rawValue != "fillsign" {
                        // (The signing window opens over the Finder: closing it leaves the user where they were.)
                        // Without a Dock icon, closing the settings would send the app behind the others and hide its
                        // main window: it comes back to the front instead.
                        DispatchQueue.main.async {
                            guard let main = AppContext.mainWindow, !main.isMiniaturized else { return }
                            main.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                }
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
                guard let w = note.object as? NSWindow, w.identifier?.rawValue.hasPrefix("main") ?? false else { return }
                MainActor.assumeIsolated {
                    AppContext.applyDockIcon()
                    AppContext.noteMainWindowVisibility()
                }
            }
            // Covered, on another Space, minimised or back: the occlusion changes. Minimising and ⌘H are listened to as
            // well, so the state never waits for the occlusion to settle.
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                    guard let w = note.object as? NSWindow, w.identifier?.rawValue.hasPrefix("main") ?? false else { return }
                    MainActor.assumeIsolated { AppContext.noteMainWindowVisibility() }
                }
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { AppContext.noteMainWindowVisibility() }
                }
            }
        }
        MainActor.assumeIsolated {
            Notifier.setUp()
            // From now on the main thread is watched: a freeze is written down, and never holds a restart up.
            MainWatchdog.shared.start()
            if UserDefaults.standard.bool(forKey: MainWatchdog.relaunchedKey) {
                UserDefaults.standard.removeObject(forKey: MainWatchdog.relaunchedKey)
                Notifier.post(id: "watchdog.relaunched", title: "\(AppEdition.name) a redémarré tout seul",
                              body: "Il s'était figé. Ce qui s'est passé est noté dans ~/Library/Logs/Heartware.", throttle: 0)
            }
            NSApp.servicesProvider = services
            NSUpdateDynamicServices()
            if let app = AppContext.model {
                statusItem = StatusItemController(app: app)
                AppContext.noteMainWindowVisibility()
                app.startModules()
                // Sombre partout is gone: what it had changed on this Mac is put back, once.
                RetiredDarkMode.restore()
            }
            NotificationCenter.default.addObserver(forName: .openMainWindow, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppContext.showMainWindow() }
            }
        }
    }

    /// Files dropped on the Dock icon go to the Convertisseur's window; `heartware://` links drive the app
    /// (Shortcuts, Raycast, Terminal: `open heartware://launcher`).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            guard let app = AppContext.model else { return }
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty { app.converter.present(files) }
            for url in urls where url.scheme == "heartware" { URLActions.handle(url, app: app) }
        }
    }

    /// Modules release what they hold (Caféine, timers) and save their data.
    /// ⌘Q with a document being signed and not saved asks first, like closing its window.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppContext.model?.fillSign.windowMayClose() ?? true } ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let app = AppContext.model { ModuleRegistry.stopAll(app, only: app.startedModules) }
        }
        // The JSON stores write in the background: what was saved a moment ago reaches the disk before the app ends.
        // The last changes still waiting for their half second, then every write under way.
        DataStore.savePending()
        DataStore.waitForWrites()
    }

    /// The menu bar keeps running when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock click, Raycast, Spotlight or Finder on an app that is already running: bring the window back.
    /// SwiftUI does not recreate a closed `Window` scene by itself, so the menu bar label (always alive) opens it.
    /// An open window comes to the front too: without a Dock icon (« Jamais »), macOS does not bring the app forward
    /// by itself and the window would stay behind the others.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
        return true
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("heartware.openMainWindow")
}

struct HeartwareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let m = AppModel()
        AppContext.model = m
        _model = State(initialValue: m)
    }

    /// 1100 × 720, never more than the screen shows: a minimum the window cannot reach on a small screen (or a large
    /// text setting) has AppKit and SwiftUI resize it against each other.
    private static var minimumSize: CGSize {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? CGSize(width: 1100, height: 720)
        return CGSize(width: min(1100, visible.width), height: min(720, max(480, visible.height - 40)))
    }

    var body: some Scene {
        Window(AppEdition.name, id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Analyse") {
                Button("Ouvrir le lanceur") { model.launcher.show() }
                Divider()
                Button("Analyse intelligente") {
                    model.page = .dashboard
                    Task { await model.smartScan() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Analyser les fichiers inutiles") {
                    model.page = .cleanup
                    Task { await model.cleanup.scan() }
                }
                Button("Faire le bilan de sécurité") {
                    model.page = .protection
                    Task { await model.protection.audit() }
                }
                Button("Explorer le dossier personnel") {
                    model.page = .storage
                    Task { await model.storage.scan(FS.home) }
                }
                Divider()
                Button("Journal des suppressions") {
                    if FS.exists(ActionLog.file) { NSWorkspace.shared.open(URL(fileURLWithPath: ActionLog.file)) }
                }
            }
            CommandMenu("Aller à") {
                Button("Page précédente") { model.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(model.backPages.isEmpty)
                Button("Page suivante") { model.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(model.forwardPages.isEmpty)
                Divider()
                // The sidebar's order, « Autres outils » last: ⌘1…⌘9 are its first nine pages.
                ForEach(Array(model.profile.menuOrder.enumerated()), id: \.element) { i, p in
                    // Only the first nine pages get ⌘1…⌘9 (Character("10") would crash).
                    if i < 9 {
                        Button(p.title) { model.page = p }
                            .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    } else {
                        Button(p.title) { model.page = p }
                    }
                }
            }
        }


        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// "Convertir avec Heartware" in the Finder's right-click › Services menu (declared in Info.plist by build_app.sh).
final class FinderServices: NSObject {
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "Aucun fichier reçu." as NSString
            return
        }
        MainActor.assumeIsolated {
            guard let app = AppContext.model else { return }
            app.converter.present(urls)
        }
    }
}

/// `heartware://launcher` opens the launcher, `heartware://page/wheel` a section,
/// `heartware://run/act_smart_scan` a launcher command. Any web page, mail or app can open such a link (`open -g` too):
/// only `urlSafe` commands (navigation, read-only analyses) run straight away; any other asks first, "Annuler" being the
/// default answer; a risky (`.confirm`) one never runs from a link: the launcher opens with it selected, the user decides there.
@MainActor
enum URLActions {
    /// Opening a link brings the app to the front, and its main window would take the keyboard from the launcher panel
    /// (which then closes): the app steps back first, like when the panel opens with its shortcut.
    private static func inPanel(_ open: @escaping @MainActor () -> Void) {
        NSApp.deactivate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { open() } }
    }

    /// The links of pages that were folded into others (Shortcuts, bookmarks made before) lead to where they went.
    private static func openFormerPage(_ name: String, app: AppModel) {
        switch name {
        case "converter", "fillsign": LauncherAppActions.openMain(app, .wheel)
        case "youtube": inPanel { app.launcher.show() }
        case "translator": inPanel { app.launcher.showTranslator() }
        case "network": app.network.showInSettings(.connection)
        case "cinema": app.media.show(.watch, app: app)
        case "adblock": app.media.show(.blocker, app: app)
        case "windows": app.hotkeys.show(.windows, app: app)
        case "launcher": app.hotkeys.show(.heartware, app: app)
        case "clipboard": app.clipboard.window.show()
        default: break
        }
    }

    static func handle(_ url: URL, app: AppModel) {
        let parts = [url.host ?? ""] + url.pathComponents.filter { $0 != "/" }
        switch parts.first {
        case "launcher":
            inPanel { app.launcher.show() }
        case "page":
            guard let name = parts.dropFirst().first else { return }
            if let page = Page(rawValue: name) {
                app.page = page
                NotificationCenter.default.post(name: .openMainWindow, object: nil)
            } else {
                openFormerPage(name, app: app)
            }
        case "regarder":
            // A YouTube or Twitch page sent by the Safari bookmark: shown in the ad-free player (nothing else is accepted).
            let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value ?? ""
            if let page = AdBlockPlayer.playable(raw) { app.adblock.player.open(page) }
        case "run":
            guard let id = parts.dropFirst().first, let command = ModuleRegistry.commands(app).first(where: { $0.id == id }) else { return }
            if case .confirm = command.risk {
                inPanel { select(command, app: app) }
                return
            }
            guard command.urlSafe || confirmFromLink(command) else { return }
            if command.staysInLauncher {
                inPanel { Task { await CommandRunner.execute(command, app: app) } }
            } else {
                Task { await CommandRunner.execute(command, app: app) }
            }
        default:
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
    }

    /// A risky command asked by a link: the launcher opens on it, nothing runs before the user's Entrée (and its confirmation).
    private static func select(_ command: AppCommand, app: AppModel) {
        let launcher = app.launcher
        launcher.show()
        launcher.query = command.title
        if let i = launcher.flat.firstIndex(where: { $0.id == command.id }) {
            launcher.selection = i
        } else {
            launcher.hide()
            HUD.show("Un lien a demandé « \(command.title) » : lance-le toi-même depuis le lanceur si tu le veux.",
                     symbol: "hand.raised.fill")
        }
    }

    /// Any other command not marked `urlSafe`: a link cannot run it without the user's yes.
    /// "Annuler" answers Entrée; "Exécuter" has no key, it needs a click.
    static func confirmFromLink(_ command: AppCommand) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Un lien venu d'une autre app demande : \(command.title)"
        alert.informativeText = (command.subtitle.map { "\($0)\n\n" } ?? "")
            + "Une page web, un message ou une autre app a ouvert un lien vers Heartware. Si tu n'es pas à l'origine de cette demande, annule."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Annuler").keyEquivalent = "\r"
        alert.addButton(withTitle: "Exécuter").keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
