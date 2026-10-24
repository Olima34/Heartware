import SwiftUI

/// An on/off switch a module shows in the menu bar panel (Caféine, presse-papiers…).
struct QuickToggle: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let isOn: Bool
    let toggle: @MainActor () -> Void
}

/// What every module of `Features/<Module>/` gives the rest of the app.
/// All requirements have defaults, so a module only implements what it uses.
@MainActor
protocol AppModule: AnyObject {
    /// Short text next to the module in the sidebar (a count, a size…), or nil.
    var sidebarBadge: String? { get }
    /// Called once at launch of the real app (never in demo, snapshot or command line modes), or at the end of the
    /// first-launch cards: register hot keys, timers, scheduler jobs, observers.
    func start(app: AppModel)
    func stop()
    /// Fills the module with fictional data for `--demo` (README screenshots).
    func loadDemo()
    /// Selects a tab for `--snapshot --tab <name>` (ignore names that are not yours).
    func applySnapshotTab(_ tab: String)
    /// Switches shown in the menu bar panel.
    var quickToggles: [QuickToggle] { get }
    /// Fixed commands for the launcher (and Claude).
    func commands(app: AppModel) -> [AppCommand]
    /// Results computed from what the user typed (calculator, search…). Keep it fast: called on every keystroke.
    func results(for query: String, app: AppModel) -> [AppCommand]
    /// Pure checks run by `--selftest`: return the failures, or [] when all is well.
    func selfTest() -> [String]
    /// Lines printed by `--dump --only <rawValue of the page>`.
    func dump() -> [String]
}

extension AppModule {
    var sidebarBadge: String? { nil }
    func start(app: AppModel) {}
    func stop() {}
    func loadDemo() {}
    func applySnapshotTab(_ tab: String) {}
    var quickToggles: [QuickToggle] { [] }
    func commands(app: AppModel) -> [AppCommand] { [] }
    func results(for query: String, app: AppModel) -> [AppCommand] { [] }
    func selfTest() -> [String] { [] }
    func dump() -> [String] { [] }
}

/// A module in the registry: its name for `--dump --only`, its label in the self-tests and the page that shows it.
struct ModuleEntry {
    /// `--dump --only <id>` (launcher, converter, youtube…).
    let id: String
    let title: String
    /// The sidebar page that shows it, or nil for a module without a page of its own: it lives in the launcher
    /// (YouTube, Traducteur), its own window (Presse-papiers), the settings (Réseau) or the windows of the Convertisseur
    /// (Remplir et signer). The launcher's settings are on the Raccourcis page.
    let page: Page?
    let module: any AppModule
}

/// The single list of modules. Adding a module means adding it here, in `AppModel`, and if it has a page in `Page`,
/// `PageView`, `BottomBar` and the profiles that need it (`ToolProfileKind.pages`);
/// everything else (launcher, demo, self-tests, snapshots, menu bar) goes through this registry.
@MainActor
enum ModuleRegistry {
    static func modules(_ app: AppModel) -> [ModuleEntry] {
        // One append per module: a single literal of existentials takes Xcode 16's type checker too long.
        // A page's first module gives its sidebar badge.
        var list: [ModuleEntry] = []
        func add(_ id: String, _ title: String, _ page: Page?, _ module: any AppModule) {
            list.append(ModuleEntry(id: id, title: title, page: page, module: module))
        }
        add("performance", Page.performance.title, .performance, app.performance)
        add("battery", Page.battery.title, .battery, app.battery)
        add("phone", Page.phone.title, .phone, app.phone)
        add("launcher", "Lanceur", .hotkeys, app.launcher)
        add("hotkeys", Page.hotkeys.title, .hotkeys, app.hotkeys)
        add("windows", "Fenêtres", .hotkeys, app.windows)
        add("wheel", Page.wheel.title, .wheel, app.wheel)
        add("converter", "Conversions", .wheel, app.converter)
        add("fillsign", "Remplir et signer", nil, app.fillSign)
        add("youtube", "Vidéos YouTube", nil, app.youtube)
        add("media", Page.media.title, .media, app.media)
        add("cinema", "Films et séries", .media, app.cinema)
        add("adblock", "Bloqueur de pub", .media, app.adblock)
        add("vpn", "VPN", .media, app.vpn)
        add("translator", "Traducteur", nil, app.translator)
        add("toolbox", Page.toolbox.title, .toolbox, app.toolbox)
        add("clipboard", "Presse-papiers", nil, app.clipboard)
        add("updates", Page.updates.title, .updates, app.updates)
        add("network", "Réseau", nil, app.network)
        add("automation", Page.automation.title, .automation, app.automation)
        add("assistant", Page.assistant.title, .assistant, app.assistant)
        add("protection", Page.protection.title, .protection, app.protection)
        add("refuge", Page.refuge.title, .refuge, app.refuge)
        return list
    }

    static func module(for page: Page, app: AppModel) -> (any AppModule)? {
        modules(app).first { $0.page == page }?.module
    }

    /// `only`: just these modules (`AppModel.startModules` holds the others back during the first-launch cards).
    static func startAll(_ app: AppModel, only ids: Set<String>? = nil) {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        for e in modules(app) where ids?.contains(e.id) ?? true { e.module.start(app: app) }
    }

    /// Called when the app quits: modules release what they hold (Caféine, timers) and save their data.
    /// `only`: the modules that were started.
    static func stopAll(_ app: AppModel, only ids: Set<String>? = nil) {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        for e in modules(app) where ids?.contains(e.id) ?? true { e.module.stop() }
    }

    static func loadDemo(_ app: AppModel) {
        for e in modules(app) { e.module.loadDemo() }
    }

    /// `only`: the page being captured, so that a tab name shared by two modules reaches the right one.
    static func applySnapshotTab(_ tab: String, only: Page? = nil, app: AppModel) {
        for e in modules(app) where only == nil || only == e.page { e.module.applySnapshotTab(tab) }
    }

    static func quickToggles(_ app: AppModel) -> [QuickToggle] {
        modules(app).flatMap { $0.module.quickToggles }
    }

    static func commands(_ app: AppModel) -> [AppCommand] {
        modules(app).flatMap { $0.module.commands(app: app) }
    }

    static func results(for query: String, app: AppModel) -> [AppCommand] {
        modules(app).flatMap { $0.module.results(for: query, app: app) }
    }

    /// Module self-tests plus the rules every command must follow.
    static func selfTest(_ app: AppModel) -> [String] {
        var failures: [String] = []
        for e in modules(app) {
            failures += e.module.selfTest().map { "[\(e.title)] \($0)" }
        }
        // Each floating window keeps to its own job: the launcher, the file window, the clipboard history.
        if DemoData.isEnabled { failures += LauncherModel.windowChecks(app).map { "[Lanceur] \($0)" } }
        var seen = Set<String>()
        for c in commands(app) {
            if !AppCommand.isValidID(c.id) { failures.append("Identifiant de commande invalide : \(c.id)") }
            if !seen.insert(c.id).inserted { failures.append("Identifiant de commande en double : \(c.id)") }
            // A heartware://run/… link never runs a risky command by itself.
            if case .confirm = c.risk, c.urlSafe { failures.append("Commande risquée exécutable par lien : \(c.id)") }
        }
        // Navigation still works from a link; a system action asks first.
        let byID = Dictionary(commands(app).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, safe) in [("open_dashboard", true), ("launcher_open", true), ("act_scan_junk", true), ("sys_sleep", false),
                           ("sys_empty_trash", false), ("tool_password", false)] where byID[id]?.urlSafe != safe {
            failures.append("Commande \(id) : exécution par lien \(safe ? "refusée" : "permise") à tort")
        }
        if case .confirm = byID["sys_hidden_files"]?.risk {} else { failures.append("sys_hidden_files relance le Finder sans demander") }
        return failures
    }
}
