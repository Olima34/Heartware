import Foundation
import AppKit
import Observation

// MARK: - macOS energy mode and Game Mode

enum PerformanceEnergyLevel: String, CaseIterable, Identifiable, Sendable {
    case automatic, low, high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatique"
        case .low: return "Économie d'énergie"
        case .high: return "Haute performance"
        }
    }
}

/// macOS' energy mode, as `pmset -g` reports it for the power source in use.
struct PerformanceEnergy: Equatable, Sendable {
    var level: PerformanceEnergyLevel
    /// "lowpowermode" on most Macs, "powermode" (0 automatic, 1 low, 2 high) on those with a high power mode.
    var key: String

    var supportsHigh: Bool { key == "powermode" }
    var levels: [PerformanceEnergyLevel] { supportsHigh ? [.automatic, .low, .high] : [.automatic, .low] }
}

enum PerformanceGamePolicy: String, Sendable {
    case auto, on, off
}

enum PerformancePower {
    static func energy() -> PerformanceEnergy? {
        if DemoData.isEnabled { return PerformanceEnergy(level: .automatic, key: "powermode") }
        return parse(Shell.run("/usr/bin/pmset", ["-g"], timeout: 5).out)
    }

    /// Reads the "Currently in use" section of `pmset -g`.
    static func parse(_ text: String) -> PerformanceEnergy? {
        var inUse = false
        for line in text.split(separator: "\n") {
            if line.contains("Currently in use") { inUse = true; continue }
            guard inUse else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let v = Int(parts[1]) else { continue }
            if parts[0] == "powermode" {
                return PerformanceEnergy(level: v == 1 ? .low : (v == 2 ? .high : .automatic), key: "powermode")
            }
            if parts[0] == "lowpowermode" {
                return PerformanceEnergy(level: v == 1 ? .low : .automatic, key: "lowpowermode")
            }
        }
        return nil
    }

    /// The energy value of each power source ("b": battery, "c": charger), from `pmset -g custom`.
    static func perSource(key: String) -> [String: Int] {
        if DemoData.isEnabled { return [:] }
        return parseSources(Shell.run("/usr/bin/pmset", ["-g", "custom"], timeout: 5).out, key: key)
    }

    static func parseSources(_ text: String, key: String) -> [String: Int] {
        var out: [String: Int] = [:]
        var source: String?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Battery Power") { source = "b"; continue }
            if line.hasPrefix("AC Power") { source = "c"; continue }
            if line.hasPrefix("UPS Power") { source = nil; continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let source, parts.count >= 2, parts[0] == key, let v = Int(parts[1]) else { continue }
            out[source] = v
        }
        return out
    }

    /// Puts back each power source's own value (a Mac in economy on battery only stays so).
    static func restoreCommand(_ values: [String: Int], key: String) -> String? {
        let parts = values.sorted { $0.key < $1.key }.filter { ["b", "c"].contains($0.key) && (0...2).contains($0.value) }
            .map { "-\($0.key) \(key) \($0.value)" }
        return parts.isEmpty ? nil : parts.map { "/usr/bin/pmset \($0)" }.joined(separator: " && ")
    }

    static func command(_ level: PerformanceEnergyLevel, key: String) -> String {
        let value: Int
        switch level {
        case .automatic: value = 0
        case .low: value = 1
        case .high: value = 2
        }
        return "/usr/bin/pmset -a \(key == "powermode" ? "powermode" : "lowpowermode") \(key == "powermode" ? value : min(value, 1))"
    }

    /// Changes the energy mode for every power source. macOS asks for the password in its own window.
    static func setEnergy(_ level: PerformanceEnergyLevel, key: String) -> Shell.Output {
        Shell.runAsAdmin(command(level, key: key))
    }

    /// Apple's Game Mode switch ships with Xcode.
    static let gamePolicyTool: String? = {
        if DemoData.isEnabled { return "/usr/bin/true" }
        let candidates = ["/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl",
                          "/Library/Developer/CommandLineTools/usr/bin/gamepolicyctl"]
        if let found = candidates.first(where: { Shell.exists($0) }) { return found }
        // The selected developer folder (an Xcode installed elsewhere). `xcode-select -p` only prints it: unlike xcrun,
        // it never offers to install the developer tools.
        let r = Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 5)
        let dir = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = dir + "/usr/bin/gamepolicyctl"
        return r.ok && !dir.isEmpty && Shell.exists(path) ? path : nil
    }()

    static func gamePolicy() -> PerformanceGamePolicy? {
        if DemoData.isEnabled { return .auto }
        guard let tool = gamePolicyTool else { return nil }
        return parseGamePolicy(Shell.run(tool, ["game-mode", "status"], timeout: 5).out)
    }

    /// "Game mode enablement policy is currently automatic." (colors removed).
    static func parseGamePolicy(_ text: String) -> PerformanceGamePolicy? {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).lowercased()
        guard let r = plain.range(of: "policy is currently ") else { return nil }
        let word = plain[r.upperBound...].prefix { $0.isLetter }
        switch word {
        case "automatic", "auto": return .auto
        case "on", "enabled", "forced": return .on
        case "off", "disabled": return .off
        default: return nil
        }
    }

    @discardableResult
    static func setGamePolicy(_ p: PerformanceGamePolicy) -> Bool {
        guard let tool = gamePolicyTool else { return false }
        return Shell.run(tool, ["game-mode", "set", p.rawValue], timeout: 10).ok
    }
}

// MARK: - Boost

/// The Boost: runs the governor according to the chosen mode. Event driven: an app coming to the front gets its
/// priority back at once; otherwise one sweep every 10 seconds (≈ 10 ms of work), and nothing at all when the mode is off.
@Observable
@MainActor
final class PerformanceBoost {
    nonisolated static let modeKey = "performance.mode"
    nonisolated static let sweepInterval: TimeInterval = 10

    private(set) var mode: PerformanceMode
    var demotions: [PerformanceDemotion] = []
    /// Busy apps in the background still at full speed.
    var busy: [PerformanceGroup] = []
    var rules: PerformanceRules {
        didSet { rulesStore.value = rules }
    }
    /// Intelligent mode switches to Performance while a game is in front.
    var gameBoost: Bool {
        didSet {
            UserDefaults.standard.set(gameBoost, forKey: "performance.gameBoost")
            sweepSoon()
        }
    }
    /// Intelligent mode moves everything in the background while macOS says the chip is warm.
    var heatAssist: Bool {
        didSet {
            UserDefaults.standard.set(heatAssist, forKey: "performance.heatAssist")
            sweepSoon()
        }
    }
    /// macOS reports the chip as warm (thermal state fair or worse).
    var hotNow = false
    /// Performance mode also forces Apple's Game Mode (when Xcode provides the switch).
    var forceGameMode: Bool {
        didSet { UserDefaults.standard.set(forceGameMode, forKey: "performance.forceGameMode") }
    }
    var energy: PerformanceEnergy?
    var gamePolicy: PerformanceGamePolicy?
    var gameModeAvailable = false
    /// The game in front while the Intelligent mode acts as Performance.
    var gameInFront: String?
    var message: (text: String, ok: Bool)?
    var energyBusy = false
    var lastSweep: Date?

    @ObservationIgnored private let engine = PerformanceGovernorEngine()
    @ObservationIgnored private let leftovers = JSONStore<[PerformanceDemotion]>("performance-demotions", default: [])
    @ObservationIgnored private let rulesStore: JSONStore<PerformanceRules>
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The shared watch of who plays sound (`DeviceActivity`): an app that starts playing gets its speed back.
    @ObservationIgnored private var audioWatch: UUID?
    @ObservationIgnored private var sounding: Set<pid_t> = []
    @ObservationIgnored private var pendingSweep: DispatchWorkItem?
    @ObservationIgnored private var sweeping = false
    @ObservationIgnored private var sweepAgain = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var gameCache: [String: Bool] = [:]
    /// The mode to go back to when the Boost quick toggle is switched off.
    @ObservationIgnored private var previousMode: PerformanceMode

    init() {
        let d = UserDefaults.standard
        let saved = DemoData.isEnabled ? nil : PerformanceMode(rawValue: d.string(forKey: Self.modeKey) ?? "")
        mode = saved ?? .off
        previousMode = PerformanceMode(rawValue: d.string(forKey: "performance.previousMode") ?? "") ?? .off
        gameBoost = d.object(forKey: "performance.gameBoost") as? Bool ?? true
        heatAssist = d.object(forKey: "performance.heatAssist") as? Bool ?? true
        forceGameMode = d.object(forKey: "performance.forceGameMode") as? Bool ?? true
        let store = JSONStore<PerformanceRules>("performance-rules", default: .initial)
        rulesStore = store
        rules = store.value
        // A snapshot of the real Mac renders before any onAppear.
        if Snapshot.isActive && !DemoData.isEnabled {
            energy = PerformancePower.energy()
            gameModeAvailable = PerformancePower.gamePolicyTool != nil
            gamePolicy = PerformancePower.gamePolicy()
        }
    }

    var lowPowerByUs: Bool {
        get { UserDefaults.standard.bool(forKey: "performance.lowPowerByUs") }
        set { UserDefaults.standard.set(newValue, forKey: "performance.lowPowerByUs") }
    }

    var gameModeByUs: Bool {
        get { UserDefaults.standard.bool(forKey: "performance.gameModeByUs") }
        set { UserDefaults.standard.set(newValue, forKey: "performance.gameModeByUs") }
    }

    /// What the governor applies right now: Intelligent becomes Performance while a game is in front,
    /// or while the chip is warm (when the heat reflex is on).
    var effectiveMode: PerformanceMode {
        mode == .smart && (gameInFront != nil || coolingDown) ? .performance : mode
    }

    /// The heat reflex is acting right now.
    var coolingDown: Bool { mode == .smart && heatAssist && hotNow }

    // MARK: Life cycle

    /// At launch: puts back whatever a previous run left slowed (after a crash), then resumes the saved mode.
    func start() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        if !leftovers.value.isEmpty {
            engine.recover(leftovers.value)
            leftovers.value = []
            leftovers.flush()
        }
        if mode != .off { activate() }
        if mode == .performance && forceGameMode {
            applyGameMode(true)
        } else if gameModeByUs {
            // Left forced by a run that did not get to put it back.
            applyGameMode(false)
        }
        Task { await refreshPowerState() }
    }

    /// When the app quits: every process gets its full priority back, and Game Mode its automatic policy.
    func stop() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        deactivate()
        // Synchronous: the app is about to exit, a task would never run.
        if gameModeByUs, PerformancePower.setGamePolicy(.auto) { gameModeByUs = false }
    }

    private func activate() {
        guard !active else { return }
        active = true
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontChanged(app) }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sweepSoon(1) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalChanged() }
        })
        thermalChanged()
        audioWatch = DeviceActivity.shared.watch { [weak self] state in
            guard let self, self.active, state.sounding != self.sounding else { return }
            self.sounding = state.sounding
            self.sweepSoon(0.2)
        }
        let t = Timer(timeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepSoon(0) }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        updateGameInFront(NSWorkspace.shared.frontmostApplication)
        sweepSoon(0)
    }

    private func deactivate() {
        active = false
        timer?.invalidate()
        timer = nil
        pendingSweep?.cancel()
        pendingSweep = nil
        for o in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            NotificationCenter.default.removeObserver(o)
        }
        observers.removeAll()
        hotNow = false
        if let audioWatch { DeviceActivity.shared.unwatch(audioWatch) }
        audioWatch = nil
        sounding = []
        engine.restoreAllNow()
        MainWatchdog.shared.disarm("boost")
        demotions = []
        busy = []
        gameInFront = nil
        leftovers.value = []
        leftovers.flush()
    }

    // MARK: Mode

    func setMode(_ new: PerformanceMode) {
        guard new != mode else { return }
        let old = mode
        if !old.isWide { previousMode = old }
        UserDefaults.standard.set(previousMode.rawValue, forKey: "performance.previousMode")
        mode = new
        message = nil
        if !DemoData.isEnabled { UserDefaults.standard.set(new.rawValue, forKey: Self.modeKey) }
        ActionLog.write("BOOST mode \(new.title)")
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }

        // Apple's Game Mode follows the Performance mode, when the user wants it.
        if new == .performance && forceGameMode && gameModeAvailable { applyGameMode(true) }
        if old == .performance && gameModeByUs { applyGameMode(false) }

        if new == .off {
            deactivate()
        } else if !active {
            activate()
        } else {
            // A narrower mode: what it no longer moves gets its priority back at the next sweep.
            sweepSoon(0)
        }

        // Fraîcheur also asks macOS for its energy saving mode (password), and gives each power source its own value
        // back afterwards.
        if new == .cool, energy?.level != .low {
            let key = energy?.key ?? "lowpowermode"
            let saved = PerformancePower.perSource(key: key)
            Task {
                if await setEnergy(.low) {
                    lowPowerByUs = true
                    UserDefaults.standard.set(saved, forKey: "performance.energyBefore")
                }
            }
        } else if old == .cool, lowPowerByUs {
            Task {
                let saved = UserDefaults.standard.dictionary(forKey: "performance.energyBefore") as? [String: Int] ?? [:]
                if await restoreEnergy(saved) { lowPowerByUs = false }
            }
        }
    }

    /// The Boost quick toggle: Performance on, or back to the previous mode.
    func toggleBoost() {
        setMode(mode == .performance ? previousMode : .performance)
    }

    func toggleCool() {
        setMode(mode == .cool ? previousMode : .cool)
    }

    func setForceGameMode(_ on: Bool) {
        forceGameMode = on
        guard mode == .performance, gameModeAvailable, !DemoData.isEnabled, !Snapshot.isActive else { return }
        applyGameMode(on)
    }

    private func applyGameMode(_ on: Bool) {
        Task {
            let ok = await Task.detached(priority: .utility) { PerformancePower.setGamePolicy(on ? .on : .auto) }.value
            if ok { gameModeByUs = on }
            gamePolicy = await Task.detached(priority: .utility) { PerformancePower.gamePolicy() }.value
        }
    }

    private func thermalChanged() {
        let state = ProcessInfo.processInfo.thermalState
        let hot = state == .fair || state == .serious || state == .critical
        guard hot != hotNow else { return }
        hotNow = hot
        if heatAssist && mode == .smart { ActionLog.write(hot ? "BOOST chaleur : arrière-plan sur les cœurs économes" : "BOOST chaleur terminée") }
        sweepSoon(0.2)
    }

    // MARK: Sweeps

    func sweepSoon(_ delay: TimeInterval = 0.3) {
        guard active else { return }
        pendingSweep?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.sweep() }
            }
        }
        pendingSweep = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func sweep() async {
        guard active, mode != .off else { return }
        if sweeping {
            sweepAgain = true
            return
        }
        sweeping = true
        let front = NSWorkspace.shared.frontmostApplication
        updateGameInFront(front)
        let ctx = PerformanceSweepContext(mode: effectiveMode, frontPID: front?.processIdentifier, apps: Self.runningApps(), rules: rules)
        let r = await engine.sweep(ctx)
        sweeping = false
        // The mode may have been switched off while the sweep ran.
        guard active else { return }
        publish(r.demotions)
        busy = r.busy
        lastSweep = Date()
        if sweepAgain {
            sweepAgain = false
            sweepSoon(0.1)
        }
    }

    private func publish(_ list: [PerformanceDemotion]) {
        demotions = list
        // The crash-recovery file changes only when the moved processes do (not at every new processor reading).
        func signature(_ l: [PerformanceDemotion]) -> [String] { l.map { $0.key + $0.pids.map { "\($0.pid):\($0.start)" }.joined(separator: ",") } }
        if signature(list) != signature(leftovers.value) { leftovers.value = list }
        // Their full speed comes back through the main thread (an app coming to the front): if the app hangs, the
        // watchdog gives it back to all of them from its own thread.
        if list.isEmpty {
            MainWatchdog.shared.disarm("boost")
        } else {
            let engine = self.engine
            MainWatchdog.shared.arm("boost") { engine.restoreAllNow() }
        }
    }

    /// An app came to the front: its processes get their priority back right away, before any sweep.
    private func frontChanged(_ app: NSRunningApplication?) {
        updateGameInFront(app)
        if let app {
            let pid = app.processIdentifier
            let keys = Set(demotions.filter { d in d.pids.contains { $0.pid == pid } || (d.bundleID != nil && d.bundleID == app.bundleIdentifier) }.map(\.key))
            if !keys.isEmpty {
                Task { publish(await engine.restore(keys: keys)) }
            }
        }
        sweepSoon(0.4)
    }

    private func updateGameInFront(_ app: NSRunningApplication?) {
        guard mode == .smart, gameBoost, let app, let url = app.bundleURL else {
            gameInFront = nil
            return
        }
        let path = url.path
        let isGame = gameCache[path] ?? Self.isGame(bundle: url)
        gameCache[path] = isGame
        gameInFront = isGame ? (app.localizedName ?? url.deletingPathExtension().lastPathComponent) : nil
    }

    /// A game declares the "games" category, or comes from a game store's library.
    nonisolated static func isGame(bundle url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.contains("/steamapps/") || path.contains("/epic games/") || path.contains("/gog galaxy/games/") { return true }
        let category = (Bundle(url: url)?.infoDictionary?["LSApplicationCategoryType"] as? String) ?? ""
        return category.contains("games")
    }

    static func runningApps() -> [Int32: PerformanceAppInfo] {
        var out: [Int32: PerformanceAppInfo] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let kind: PerformanceGroupKind
            switch app.activationPolicy {
            case .regular: kind = .app
            case .accessory: kind = .menuBar
            default: kind = .helper
            }
            out[app.processIdentifier] = PerformanceAppInfo(name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "?",
                                                            bundleID: app.bundleIdentifier, kind: kind)
        }
        return out
    }

    // MARK: User actions

    /// Full speed for this app until the next sweep decides again (the Intelligent mode may slow it later if it stays busy).
    func restore(_ d: PerformanceDemotion) {
        guard !DemoData.isEnabled else {
            demotions.removeAll { $0.key == d.key }
            return
        }
        Task { publish(await engine.restore(keys: [d.key])) }
    }

    func restoreAll() {
        guard !DemoData.isEnabled else {
            demotions = []
            return
        }
        let keys = Set(demotions.map(\.key))
        Task { publish(await engine.restore(keys: keys)) }
    }

    /// Slows this app now, until it comes back to the front. Turns the Intelligent mode on if nothing was on.
    func slowNow(_ g: PerformanceGroup) {
        guard !DemoData.isEnabled else {
            message = (DemoData.refusal, false)
            return
        }
        if mode == .off { setMode(.smart) }
        Task {
            publish(await engine.demoteNow(g))
            busy.removeAll { $0.key == g.key }
        }
    }

    func isProtected(bundleID: String?, key: String) -> Bool {
        rules.protected.contains { $0 == bundleID || $0 == key }
    }

    /// Never slowed again (the identifier is the bundle ID when there is one).
    func protect(bundleID: String?, key: String) {
        let id = bundleID ?? key
        if !rules.protected.contains(id) { rules.protected.append(id) }
        rules.alwaysSlow.removeAll { $0 == key }
        if let d = demotions.first(where: { $0.key == key }) { restore(d) }
        sweepSoon()
    }

    func unprotect(_ id: String) {
        rules.protected.removeAll { $0 == id }
        sweepSoon()
    }

    func toggleAlwaysSlow(key: String, bundleID: String?) {
        if rules.alwaysSlow.contains(key) {
            rules.alwaysSlow.removeAll { $0 == key }
        } else {
            rules.alwaysSlow.append(key)
            rules.protected.removeAll { $0 == key || $0 == bundleID }
            if mode == .off { setMode(.smart) }
        }
        sweepSoon()
    }

    func resetRules() {
        rules = .initial
        sweepSoon()
    }

    // MARK: Energy

    func refreshPowerState() async {
        let (e, g, available) = await Task.detached(priority: .utility) {
            (PerformancePower.energy(), PerformancePower.gamePolicy(), PerformancePower.gamePolicyTool != nil)
        }.value
        energy = e
        gamePolicy = g
        gameModeAvailable = available
    }

    /// Puts back the energy value each power source had before Fraîcheur (automatic if unknown).
    private func restoreEnergy(_ saved: [String: Int]) async -> Bool {
        guard let key = energy?.key ?? PerformancePower.energy()?.key,
              let command = PerformancePower.restoreCommand(saved, key: key) else {
            return await setEnergy(.automatic)
        }
        energyBusy = true
        let out = await Task.detached(priority: .userInitiated) { Shell.runAsAdmin(command) }.value
        energyBusy = false
        await refreshPowerState()
        message = out.ok ? ("Mode d'énergie de macOS remis comme avant Fraîcheur.", true)
            : (out.err.isEmpty ? "Le mode d'énergie n'a pas changé." : out.err.trimmingCharacters(in: .whitespacesAndNewlines), false)
        if out.ok { ActionLog.write("ÉNERGIE rétablie") }
        return out.ok
    }

    /// Changes macOS' energy mode (password in macOS' own window).
    @discardableResult
    func setEnergy(_ level: PerformanceEnergyLevel) async -> Bool {
        guard !DemoData.isEnabled else {
            message = (DemoData.refusal, false)
            return false
        }
        guard let key = energy?.key ?? PerformancePower.energy()?.key, !energyBusy else { return false }
        energyBusy = true
        let out = await Task.detached(priority: .userInitiated) { PerformancePower.setEnergy(level, key: key) }.value
        energyBusy = false
        await refreshPowerState()
        if out.ok {
            message = ("Mode d'énergie de macOS : \(level.title.lowercased()).", true)
            ActionLog.write("ÉNERGIE \(level.title)")
        } else {
            message = (out.err.isEmpty ? "Le mode d'énergie n'a pas changé." : out.err.trimmingCharacters(in: .whitespacesAndNewlines), false)
        }
        return out.ok
    }

    // MARK: Demo

    func loadDemo() {
        mode = .smart
        demotions = PerformanceDemo.demotions()
        busy = PerformanceDemo.busyGroups()
        energy = PerformanceEnergy(level: .automatic, key: "powermode")
        gamePolicy = .auto
        gameModeAvailable = true
        lastSweep = Date()
    }
}
