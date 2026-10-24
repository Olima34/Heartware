import SwiftUI
import AppKit
import Observation

enum Page: String, CaseIterable, Identifiable {
    // Declared in sidebar order: the first nine get ⌘1…⌘9.
    case dashboard, refuge, cleanup, protection, performance, battery, updates, apps, storage
    case phone, wheel, media, toolbox
    case hotkeys, automation
    case assistant, menubar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Tableau de bord"
        case .refuge: return "Le Refuge"
        case .cleanup: return "Nettoyage du système"
        case .protection: return "Protection et confidentialité"
        case .performance: return "Optimisation"
        case .battery: return "Batterie"
        case .updates: return "Mises à jour"
        case .apps: return "Applications"
        case .storage: return "Espace de stockage"
        case .phone: return "iPhone"
        case .wheel: return "Convertisseur"
        case .media: return "Multimédia"
        case .hotkeys: return "Raccourcis"
        case .toolbox: return "Boîte à outils"
        case .automation: return "Automatisations"
        case .assistant: return "Assistant Claude"
        case .menubar: return "Menu d'état"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .refuge: return "house"
        case .cleanup: return "sparkles"
        case .protection: return "lock.shield"
        case .performance: return "bolt"
        case .battery: return "battery.75percent"
        case .updates: return "arrow.down.circle"
        case .apps: return "square.grid.2x2"
        case .storage: return "chart.pie"
        case .phone: return "iphone"
        case .wheel: return "arrow.left.arrow.right.square"
        case .media: return "play.tv"
        case .hotkeys: return "keyboard"
        case .toolbox: return "wrench.and.screwdriver"
        case .automation: return "clock.arrow.2.circlepath"
        case .assistant: return "sparkle"
        case .menubar: return "menubar.rectangle"
        }
    }

    /// One line on what the page is for (the profile panel, the dashboard's suggestions).
    var pitch: String {
        switch self {
        case .dashboard: return "Ton Mac en un coup d'œil et l'analyse intelligente."
        case .refuge: return "Ton chamois : il grandit quand tu prends soin du Mac."
        case .cleanup: return "Caches, journaux et fichiers oubliés : tu choisis ce qui part."
        case .protection: return "Défenses de macOS, logiciels malveillants et traces laissées."
        case .performance: return "Boost, capteurs, démarrage : un Mac plus frais et plus vif."
        case .battery: return "Limite de recharge, alerte de batterie faible et santé."
        case .updates: return "Homebrew, tes apps et macOS à jour, au même endroit."
        case .apps: return "Les apps que tu n'ouvres plus, désinstallées sans rien oublier."
        case .storage: return "La carte de ton disque, les gros fichiers et les doublons."
        case .phone: return "Branche ton iPhone : sa santé, et ses photos et vidéos triées."
        case .wheel: return "Glisse un fichier : une roue pour convertir, recadrer, annoter, remplir ou signer, sans rien ouvrir."
        case .media: return "Films et séries, vidéos sans pub, pubs bloquées et un VPN gratuit pour changer de pays."
        case .toolbox: return "Couleurs, mots de passe, Caféine et autres petits outils."
        case .hotkeys: return "Tes raccourcis, le lanceur et tes fenêtres rangées au clavier."
        case .automation: return "Ton Mac s'entretient tout seul, selon tes règles."
        case .assistant: return "Pose tes questions sur ton Mac, Claude te répond."
        case .menubar: return "Processeur, mémoire et actions express dans la barre des menus."
        }
    }

    static let groups: [(String, [Page])] = [
        ("Accueil", [.dashboard, .refuge]),
        ("Entretien", [.cleanup, .protection, .performance, .battery, .updates]),
        ("Espace", [.apps, .storage, .phone]),
        ("Outils", [.wheel, .media, .toolbox]),
        ("Contrôle", [.hotkeys, .automation]),
        ("Claude", [.assistant]),
        ("En continu", [.menubar])
    ]
}

/// Running totals of what the app freed, kept between launches.
struct CleanupHistory {
    var totalFreed: Int64
    var runs: Int
    var last: Date?

    static func load() -> CleanupHistory {
        let d = UserDefaults.standard
        return CleanupHistory(totalFreed: Int64(d.double(forKey: "history.freed")), runs: d.integer(forKey: "history.runs"),
                              last: d.object(forKey: "history.last") as? Date)
    }

    mutating func record(_ bytes: Int64) {
        guard bytes > 0 else { return }
        totalFreed += bytes
        runs += 1
        last = Date()
        let d = UserDefaults.standard
        d.set(Double(totalFreed), forKey: "history.freed")
        d.set(runs, forKey: "history.runs")
        d.set(last, forKey: "history.last")
    }
}

@Observable
@MainActor
final class AppModel {
    var page: Page = .dashboard {
        didSet {
            guard page != oldValue else { return }
            if !walkingHistory {
                backPages.append(oldValue)
                if backPages.count > 50 { backPages.removeFirst() }
                forwardPages.removeAll()
            }
            profile.recordVisit(page)
            refuge.visited(page)
        }
    }
    /// The pages left behind, and those left by going back: the ‹ › of the toolbar, ⌘[ and ⌘].
    private(set) var backPages: [Page] = []
    private(set) var forwardPages: [Page] = []
    @ObservationIgnored private var walkingHistory = false

    func goBack() {
        guard let p = backPages.popLast() else { return }
        forwardPages.append(page)
        walkingHistory = true
        page = p
        walkingHistory = false
    }

    func goForward() {
        guard let p = forwardPages.popLast() else { return }
        backPages.append(page)
        walkingHistory = true
        page = p
        walkingHistory = false
    }
    let monitor: SystemMonitor
    let cleanup = CleanupModel()
    let protection = ProtectionModel()
    let performance = PerformanceModel()
    let apps = AppsModel()
    let storage = StorageModel()
    let startup = StartupModel()
    // Modules (Features/<Module>/), listed in ModuleRegistry.
    let launcher = LauncherModel()
    let converter = ConverterModel()
    let wheel = WheelModel()
    let fillSign = FillSignModel()
    let youtube = YouTubeModel()
    let cinema = CinemaModel()
    let toolbox = ToolboxModel()
    let clipboard = ClipboardModel()
    let updates = UpdatesModel()
    let network = NetworkModel()
    let windows = WindowsModel()
    let automation = AutomationModel()
    let assistant = AssistantModel()
    let translator = TranslatorModel()
    let hotkeys = HotkeysModel()
    let battery = BatteryModel()
    let adblock = AdBlockModel()
    /// Windscribe's free VPN, on the Multimédia page.
    let vpn = VPNModel()
    /// The Multimédia page: Films et séries and the ad blocker together.
    let media = MediaModel()
    let phone = PhoneModel()
    /// The chamois and its Refuge: blueberries, stages, notebook, badges, moods.
    let refuge = RefugeModel()
    /// The profile: which tools the sidebar and the dashboard put forward.
    let profile = ToolProfileModel()
    var history = DemoData.isEnabled ? DemoData.history : CleanupHistory.load()
    var fullDiskAccess = Permissions.hasFullDiskAccess
    var showOnboarding = !DemoData.isEnabled && !UserDefaults.standard.bool(forKey: Preferences.onboardedKey)
    /// The profile panel, in the middle of the main window.
    var showProfilePanel = false
    /// False once the main window is closed, not when it is only covered, minimised or on another Space.
    /// A closed SwiftUI window keeps its views alive and redrawn: RootView drops the pages until it reopens.
    var mainWindowOpen = true
    /// True while the main window is really on screen: open, not minimised, not hidden (⌘H), on the current Space and
    /// not fully covered. What only the eye needs pauses while it is false: the monitor's full pace, the samples of the
    /// pages (processes, network), the small animations (`\.mainWindowOnScreen`). The pages themselves stay, with their state.
    private(set) var mainWindowOnScreen = true
    var smartScanRunning = false
    var smartScanDate: Date?

    init(liveMonitor: Bool = true) {
        monitor = SystemMonitor(start: liveMonitor)
        let freed: (Int64) -> Void = { [weak self] bytes in
            self?.history.record(bytes)
            self?.monitor.sampleDisk()
            if bytes > 0 { self?.refuge.cleaned() }
        }
        cleanup.onFreed = freed
        protection.onFreed = freed
        // What takes care of the Mac feeds the chamois.
        refuge.attach(self)
        protection.onFixed = { [weak self] id, title in self?.refuge.fixed(id, title: title) }
        protection.onNeutralized = { [weak self] ids in self?.refuge.neutralized(ids) }
        updates.onUpgraded = { [weak self] count in self?.refuge.upgraded(count) }
        CommandRunner.onRun = { [weak self] id in self?.refuge.usedTool(id) }
        if DemoData.isEnabled {
            DemoData.populate(self)
            ModuleRegistry.loadDemo(self)
            profile.loadDemo()
        }
        profile.refresh(self)
        if !DemoData.isEnabled && liveMonitor {
            updateAlertsTimer()
            // The alerts are switched in the settings, the Menu d'état and Automatisations pages (`@AppStorage`).
            defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                      queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAlertsTimer() }
            }
        }
    }

    @ObservationIgnored private var alertsTimer: Timer?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

    /// The disk, memory and heat check runs once a minute, only while the alerts are on.
    private func updateAlertsTimer() {
        let on = Alerts.isOn
        if !on {
            alertsTimer?.invalidate()
            alertsTimer = nil
        } else if alertsTimer == nil {
            let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, Alerts.isOn else { return }
                    // With nothing on screen the monitor is paused: it samples once for the check.
                    self.monitor.refresh()
                    Alerts.check(self.monitor)
                }
            }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            alertsTimer = t
        }
    }

    /// The main window came on screen or went away (`AppContext.noteMainWindowVisibility`).
    func setMainWindowOnScreen(_ on: Bool) {
        monitor.show(.window, on)
        guard on != mainWindowOnScreen else { return }
        mainWindowOnScreen = on
        performance.setWindowOnScreen(on)
    }

    func refreshPermissions() {
        fullDiskAccess = Permissions.hasFullDiskAccess
    }

    /// The one-click checkup: junk, security, apps and startup items, all at once.
    func smartScan() async {
        guard !smartScanRunning else { return }
        smartScanRunning = true
        refreshPermissions()
        async let a: Void = cleanup.scan()
        async let b: Void = protection.audit()
        async let c: Void = apps.scan()
        // The malware scan reads the startup items: they come first.
        async let d: Void = startupThenThreats()
        _ = await (a, b, c, d)
        smartScanDate = Date()
        smartScanRunning = false
        refuge.scanned()
    }

    private func startupThenThreats() async {
        await startup.scan()
        await protection.scan(deep: false)
    }

    func finishOnboarding() {
        if !DemoData.isEnabled { UserDefaults.standard.set(true, forKey: Preferences.onboardedKey) }
        showOnboarding = false
        startModules()
        profile.refresh(self)
    }

    // MARK: Modules

    /// The modules started so far.
    @ObservationIgnored private(set) var startedModules: Set<String> = []

    /// Starts the modules at launch. While the first-launch cards are up only the launcher starts (its shortcut, the
    /// list of apps): the others wait for the last card, so that nothing they do at launch (file index, folder
    /// watchers, automations, clipboard) brings a macOS question before the Autorisations card has explained it.
    func startModules() {
        let ids: Set<String> = showOnboarding ? ["launcher"] : Set(ModuleRegistry.modules(self).map(\.id))
        let new = ids.subtracting(startedModules)
        guard !new.isEmpty else { return }
        startedModules.formUnion(new)
        ModuleRegistry.startAll(self, only: new)
    }

    // MARK: Health

    /// 0…100, from free space, memory pressure, security and junk.
    var healthScore: Int {
        var score = 0.0
        let freeFrac = monitor.diskTotal > 0 ? Double(monitor.diskFree) / Double(monitor.diskTotal) : 0.3
        score += 30 * min(1, freeFrac / 0.25)
        switch monitor.pressure {
        case .normal: score += 20
        case .warning: score += 10
        case .critical: score += 0
        }
        if protection.hasAudit {
            score += 30 * protection.securityRatio
        } else {
            score += 22
        }
        // A piece of malware outweighs everything else.
        if !protection.malware.isEmpty { score -= 25 }
        if cleanup.hasResults {
            let junkGB = Double(cleanup.recommendedSize) / 1e9
            score += 20 * (1 - min(1, junkGB / 20))
        } else {
            score += 15
        }
        return max(0, Int(score.rounded()))
    }

    var healthLabel: String {
        switch healthScore {
        case 85...: return "Excellente forme"
        case 70..<85: return "Bonne forme"
        case 50..<70: return "Peut mieux faire"
        default: return "À surveiller"
        }
    }

    var healthColor: Color {
        switch healthScore {
        case 85...: return Theme.good
        case 70..<85: return Theme.accent
        case 50..<70: return Theme.warn
        default: return Theme.bad
        }
    }
}
