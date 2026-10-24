import Foundation
import AppKit
import CoreAudio
import CoreGraphics
import Darwin

// MARK: - Modes

/// How Heartware shares the chip between the app in front and everything else.
/// The lever is macOS' own background band (`PRIO_DARWIN_BG`, what `taskpolicy -b` sets): on Apple silicon those
/// processes run on the efficiency cores only, with throttled disk and network. They keep working, slower and cooler,
/// and get their full priority back the moment they come to the front.
enum PerformanceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off, smart, performance, cool

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Désactivé"
        case .smart: return "Intelligent"
        case .performance: return "Performance"
        case .cool: return "Fraîcheur"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "pause.circle"
        case .smart: return "wand.and.stars"
        case .performance: return "bolt.fill"
        case .cool: return "snowflake"
        }
    }

    var summary: String {
        switch self {
        case .off: return "macOS répartit seul le travail, rien n'est touché."
        case .smart: return "Les apps en arrière-plan qui s'emballent passent sur les cœurs économes, tout l'arrière-plan quand la puce chauffe. Pleine vitesse dès que tu y reviens."
        case .performance: return "Toute la puissance pour l'app au premier plan : le reste tourne sur les cœurs économes. Pour jouer, monter une vidéo, compiler."
        case .cool: return "Comme Performance, et macOS passe en économie d'énergie : moins de chaleur, moins de bruit, plus d'autonomie."
        }
    }

    /// Everything in the background is moved, not only what overheats.
    var isWide: Bool { self == .performance || self == .cool }
}

/// A process, identified for good: a pid alone can be reused by a new process.
struct PerformancePID: Codable, Hashable, Sendable {
    let pid: Int32
    let start: UInt64
}

/// An app (or a background service) that Heartware moved to the efficiency cores.
struct PerformanceDemotion: Codable, Identifiable, Equatable, Sendable {
    enum Cause: String, Codable, Sendable {
        /// The mode moves everything that is in the background (Performance, Fraîcheur, a game in front).
        case mode
        /// It used a lot of processor for a while (Intelligent).
        case busy
        /// The user asked for this app to always be slowed in the background.
        case rule
        /// The user slowed it once, until it comes back to the front.
        case manual
    }

    var id: String { key }
    let key: String
    var name: String
    var appPath: String?
    var bundleID: String?
    var pids: [PerformancePID]
    var since: Date
    var cause: Cause
    /// % of one core when it was moved.
    var cpuBefore: Double
    /// % of one core now, on the efficiency cores.
    var cpuNow: Double = 0

    var reason: String {
        switch cause {
        case .mode: return "Arrière-plan pendant le mode actif"
        case .busy: return "S'emballait en arrière-plan (\(Fmt.int(cpuBefore)) % de processeur)"
        case .rule: return "Toujours ralentie en arrière-plan, à ta demande"
        case .manual: return "Ralentie à ta demande jusqu'à ce que tu y reviennes"
        }
    }
}

/// What the user decided, kept between launches.
struct PerformanceRules: Codable, Equatable, Sendable {
    /// Bundle identifiers (or executable paths) never slowed.
    var protected: [String]
    /// Group keys (app paths) always slowed when in the background.
    var alwaysSlow: [String] = []

    /// Apps whose work in the background is the point: exports, recordings, virtual machines, builds.
    static let defaultProtected = [
        "com.obsproject.obs-studio", "com.streamlabs.slobs", "com.ecamm.EcammLive", "com.apple.FinalCut", "com.apple.Compressor",
        "com.apple.motionapp", "com.apple.logic10", "com.apple.mainstage3", "com.blackmagic-design.DaVinciResolve",
        "com.blackmagic-design.DaVinciResolveLite", "fr.handbrake.HandBrake", "org.blenderfoundation.blender", "com.apple.dt.Xcode",
        "com.docker.docker", "com.utmapp.UTM", "com.parallels.desktop.console", "com.vmware.fusion", "com.apple.ScreenSharing",
        "com.apple.screencaptureui", "com.apple.QuickTimePlayerX", "com.electron.ollama", "ai.elementlabs.lmstudio"
    ]

    static let initial = PerformanceRules(protected: defaultProtected)
}

// MARK: - Processes of the user

struct PerformanceProc: Sendable {
    let id: PerformancePID
    var parent: Int32 = 0
    let path: String
    let cpuTime: UInt64     // ns, user + system
    let priority: Int32     // 4 in the background band
    let memory: UInt64
}

enum PerformanceProcScan {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(max(1, tb.numer)), UInt64(max(1, tb.denom)))
    }()

    /// The current user's processes (the only ones an app may move), read straight from the kernel: ≈ 10 ms.
    static func current() -> [PerformanceProc] {
        let uid = getuid()
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        var out: [PerformanceProc] = []
        out.reserveCapacity(Int(max(0, count)))
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(max(0, count))) where pid > 0 {
            guard let bsd = bsdInfo(pid), bsd.pbi_uid == uid else { continue }
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize,
                  proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let ticks = task.pti_total_user &+ task.pti_total_system
            out.append(PerformanceProc(id: PerformancePID(pid: pid, start: startTime(bsd)), parent: Int32(bsd.pbi_ppid), path: path,
                                       cpuTime: ticks / timebase.denom * timebase.numer, priority: task.pti_priority,
                                       memory: task.pti_resident_size))
        }
        return out
    }

    /// The scheduling priority the kernel gives the process now: 4 in the background band, about 31 otherwise.
    static func priority(of pid: Int32) -> Int32? {
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size ? task.pti_priority : nil
    }

    /// The process' start time, or nil once it is gone.
    static func start(of pid: Int32) -> UInt64? {
        bsdInfo(pid).map(startTime)
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size ? bsd : nil
    }

    private static func startTime(_ bsd: proc_bsdinfo) -> UInt64 {
        UInt64(bsd.pbi_start_tvsec) &* 1_000_000 &+ UInt64(bsd.pbi_start_tvusec)
    }

    /// Moves a process to the background band (efficiency cores, throttled I/O) or back.
    @discardableResult
    static func setBackground(_ p: PerformancePID, _ on: Bool) -> Bool {
        // The pid may have been reused since: only the very same process is touched.
        guard !DemoData.isEnabled, p.pid > 1, p.pid != getpid(), start(of: p.pid) == p.start else { return false }
        return setpriority(PRIO_DARWIN_PROCESS, id_t(p.pid), on ? PRIO_DARWIN_BG : 0) == 0
    }
}

// MARK: - Sound and keyboard: never slowed

enum PerformanceAudio {
    /// Processes playing or recording sound right now (CoreAudio, macOS 14+): music, calls, streams.
    static func activePIDs() -> Set<Int32> {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        var out = Set<Int32>()
        for id in ids where uint(id, kAudioProcessPropertyIsRunningOutput) != 0 || uint(id, kAudioProcessPropertyIsRunningInput) != 0 {
            var pid: pid_t = 0
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var s = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(id, &a, 0, nil, &s, &pid) == noErr, pid > 0 { out.insert(pid) }
        }
        return out
    }

    private static func uint(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var s = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr ? v : 0
    }

    /// Processes watching the keyboard or the mouse (window managers, text expanders…): slowing them would slow every keystroke.
    static func eventTapPIDs() -> Set<Int32> {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return [] }
        return Set(taps.prefix(Int(count)).filter(\.enabled).map { Int32($0.tappingProcess) })
    }
}

// MARK: - Planning (pure)

enum PerformanceGroupKind: String, Sendable {
    /// An app with a Dock icon.
    case app
    /// An app living in the menu bar.
    case menuBar
    /// A helper inside an app bundle, without a window (updaters, sync agents…).
    case helper
    /// An Apple service that only does background work (photo analysis, indexing…).
    case daemon
    /// Anything else: never touched.
    case other
}

/// One app with all its helper processes, as seen by one sweep.
struct PerformanceGroup: Sendable {
    let key: String
    var name: String
    var appPath: String?
    var bundleID: String?
    var kind: PerformanceGroupKind
    var pids: [PerformancePID]
    /// % of one core since the previous sweep.
    var cpu: Double = 0
    var memory: UInt64 = 0
    var audio = false
    var watchesKeyboard = false
    /// One of its processes was started by the app in front (a build launched from the Terminal, a game from its launcher).
    var launchedByFront = false
    /// Processes macOS already keeps in the background band itself (App Nap, hidden browser tabs, indexing): never touched.
    var alreadyBackground: Set<PerformancePID> = []
    /// Its extensions, which work for other apps and for macOS (File Provider, Quick Look, Share…): never touched.
    var serving: Set<PerformancePID> = []

    /// What the Boost can actually move.
    var movable: [PerformancePID] { pids.filter { !alreadyBackground.contains($0) && !serving.contains($0) } }
}

/// Whether a group may be moved, and why not.
enum PerformanceVerdict: Equatable {
    case demote(PerformanceDemotion.Cause)
    case keep(String)
}

enum PerformancePlanner {
    /// % of one core above which an app in the background counts as busy, and for how long without a break it takes.
    static let busyCPU = 15.0
    static let busyMenuBarCPU = 25.0
    static let busyDuration: TimeInterval = 20

    /// Apple services that only work for later: moving them never slows what the user is doing.
    static let backgroundDaemons: [String: String] = [
        "photoanalysisd": "Analyse des photos",
        "mediaanalysisd": "Analyse des photos et vidéos",
        "mdworker_shared": "Indexation Spotlight",
        "suggestd": "Suggestions de Siri",
        "knowledge-agent": "Apprentissage de macOS",
        "intelligenceplatformd": "Index d'Apple Intelligence",
        "ReportCrash": "Rapports de plantage"
    ]

    /// Cloud sync clients: they live in the menu bar but are pure background work.
    static let syncClients = [
        "com.getdropbox.dropbox", "com.google.drivefs", "com.microsoft.OneDrive", "com.box.desktop", "mega.mac", "com.pcloud",
        "com.synology", "com.backblaze", "com.haystacksoftware", "com.nextcloud", "com.owncloud", "com.tresorit", "com.maestral",
        "com.insynchq", "com.resilio"
    ]

    /// Folders where apps live. System agents (Finder, Dock, Siri, Spotlight…) live elsewhere and are never touched.
    static func isAppFolder(_ key: String, home: String = FS.home) -> Bool {
        ["/Applications/", home + "/Applications/", "/System/Applications/", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/"]
            .contains { key.hasPrefix($0) }
    }

    private static func rank(_ k: PerformanceGroupKind) -> Int {
        switch k {
        case .app: return 3
        case .menuBar: return 2
        case .helper: return 1
        default: return 0
        }
    }

    static func isSyncClient(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return syncClients.contains { id.hasPrefix($0.lowercased()) }
    }

    /// Apps the whole Mac waits on when they are slow: the network itself (VPN), a screen shared with someone, the
    /// passwords every app asks for. Never slowed by a mode or a sweep (the user may still slow one by hand).
    static let infrastructure = [
        "com.wireguard.macos", "io.tailscale.ipn", "com.cisco.anyconnect", "com.cisco.secureclient", "com.paloaltonetworks.globalprotect",
        "com.fortinet", "ch.protonvpn", "com.nordvpn", "net.mullvad", "com.expressvpn", "com.surfshark", "com.privateinternetaccess",
        "com.teamviewer", "com.philandro.anydesk", "tv.parsec", "com.google.chromeremotedesktop", "com.realvnc", "com.microsoft.rdc",
        "com.1password", "com.agilebits", "com.bitwarden", "com.dashlane", "com.lastpass", "com.apple.passwords", "com.keepassxc",
        "org.keepassxc", "com.enpass", "com.nordpass"
    ]

    static func isInfrastructure(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return infrastructure.contains { id.hasPrefix($0) }
    }

    /// An app extension (`.appex`) works for others: a File Provider for every Open dialog and the Finder, a Quick Look
    /// or Share extension for the app that calls it. Slowed with its app, it would slow the whole Mac; and its work, done
    /// for others, never gets its app slowed either.
    static func isServing(_ path: String) -> Bool {
        path.contains(".appex/")
    }

    /// % of one core above which the group counts as busy: a menu bar app is allowed more (it often works for the user).
    static func busyThreshold(_ g: PerformanceGroup) -> Double {
        g.kind == .menuBar && !isSyncClient(g.bundleID) ? busyMenuBarCPU : busyCPU
    }

    /// The decision for one group. `busyFor`: how long it has been busy without a break (seconds).
    static func verdict(_ g: PerformanceGroup, mode: PerformanceMode, frontKey: String?, ownKey: String,
                        rules: PerformanceRules, busyFor: TimeInterval) -> PerformanceVerdict {
        let busy = busyFor >= busyDuration
        if mode == .off { return .keep("Mode désactivé") }
        if g.key == ownKey { return .keep("\(AppEdition.name)") }
        if g.key == frontKey { return .keep("Au premier plan") }
        if g.launchedByFront { return .keep("Lancé par l'app au premier plan") }
        if g.kind == .other { return .keep("Composant du système") }
        if g.audio { return .keep("Joue ou enregistre du son") }
        if g.watchesKeyboard { return .keep("Surveille le clavier ou la souris") }
        if rules.protected.contains(where: { $0 == g.bundleID || $0 == g.key }) { return .keep("Protégée") }
        if rules.alwaysSlow.contains(g.key) { return .demote(.rule) }
        if isInfrastructure(g.bundleID) { return .keep("Réseau, partage d'écran ou mots de passe") }
        switch g.kind {
        case .menuBar:
            // The other apps wait for their files from it: only when it runs wild, whatever the mode.
            if isSyncClient(g.bundleID) { return busy ? .demote(.busy) : .keep("Calme") }
            // Counted at its own threshold already: a short reading between two sweeps does not undo it.
            return busy ? .demote(.busy) : .keep("App de la barre des menus")
        case .app, .helper, .daemon:
            if mode.isWide { return .demote(.mode) }
            return busy ? .demote(.busy) : .keep("Calme")
        case .other:
            return .keep("Composant du système")
        }
    }

    /// Groups the processes by app. `apps`: what NSWorkspace knows of each running app, by pid.
    static func groups(_ procs: [PerformanceProc], apps: [Int32: PerformanceAppInfo], audio: Set<Int32>, taps: Set<Int32>,
                       frontPID: Int32? = nil, home: String = FS.home) -> [String: PerformanceGroup] {
        let frontTree = descendants(of: frontPID, in: procs)
        // The app bundle each running app was launched from, as the kernel names it (Safari lives in a cryptex).
        var infoByKey: [String: PerformanceAppInfo] = [:]
        for p in procs {
            guard let info = apps[p.id.pid] else { continue }
            let key = ProcessList.identity(of: p.path).key
            // The main app speaks for the bundle: a Dock app over a menu bar app over a helper registered on its own.
            if let existing = infoByKey[key], rank(existing.kind) >= rank(info.kind) { continue }
            infoByKey[key] = info
        }
        var groups: [String: PerformanceGroup] = [:]
        for p in procs {
            let identity = ProcessList.identity(of: p.path)
            let kind: PerformanceGroupKind
            var name = identity.name
            let info = infoByKey[identity.key]
            if identity.app != nil && isAppFolder(identity.key, home: home) {
                kind = info?.kind ?? .helper
                name = info?.name ?? name
            } else if identity.app == nil, let label = backgroundDaemons[identity.name],
                      p.path.hasPrefix("/System/") || p.path.hasPrefix("/usr/") {
                kind = .daemon
                name = label
            } else {
                kind = .other
            }
            var g = groups[identity.key] ?? PerformanceGroup(key: identity.key, name: name, appPath: identity.app,
                                                             bundleID: info?.bundleID ?? identity.app.flatMap(bundleIdentifier), kind: kind, pids: [])
            g.pids.append(p.id)
            if p.priority <= 4 { g.alreadyBackground.insert(p.id) }
            if isServing(p.path) { g.serving.insert(p.id) }
            g.launchedByFront = g.launchedByFront || frontTree.contains(p.id.pid)
            g.memory += p.memory
            g.audio = g.audio || audio.contains(p.id.pid)
            g.watchesKeyboard = g.watchesKeyboard || taps.contains(p.id.pid)
            groups[identity.key] = g
        }
        return groups
    }
}

extension PerformancePlanner {
    /// Every process started, directly or not, by `pid` (the app in front excluded).
    static func descendants(of pid: Int32?, in procs: [PerformanceProc]) -> Set<Int32> {
        guard let pid else { return [] }
        var children: [Int32: [Int32]] = [:]
        for p in procs { children[p.parent, default: []].append(p.id.pid) }
        var out = Set<Int32>()
        var queue = children[pid] ?? []
        while let next = queue.popLast() {
            guard out.insert(next).inserted else { continue }
            queue += children[next] ?? []
        }
        return out
    }

    private final class BundleIDs: @unchecked Sendable {
        let lock = NSLock()
        var byPath: [String: String?] = [:]
    }
    private static let bundleIDs = BundleIDs()

    /// The identifier of an app bundle that is not running itself (its helpers are), read once from its Info.plist.
    static func bundleIdentifier(_ path: String) -> String? {
        bundleIDs.lock.lock()
        if let known = bundleIDs.byPath[path] {
            bundleIDs.lock.unlock()
            return known
        }
        bundleIDs.lock.unlock()
        let id = DemoData.isEnabled ? nil : Bundle(path: path)?.bundleIdentifier
        bundleIDs.lock.lock()
        bundleIDs.byPath[path] = id
        bundleIDs.lock.unlock()
        return id
    }
}

/// What the main thread knows of a running app.
struct PerformanceAppInfo: Sendable {
    var name: String
    var bundleID: String?
    var kind: PerformanceGroupKind
}

// MARK: - Engine

/// Everything one sweep needs from the main thread.
struct PerformanceSweepContext: Sendable {
    var mode: PerformanceMode
    var frontPID: Int32?
    var apps: [Int32: PerformanceAppInfo]
    var rules: PerformanceRules
}

struct PerformanceSweepResult: Sendable {
    var demotions: [PerformanceDemotion]
    /// The busiest groups still at full speed in the background (% of one core), for the "candidates" list.
    var busy: [PerformanceGroup]
    var frontKey: String?
}

/// Moves and restores processes on its own serial queue: the sweeps, the "app came to the front" fast path and the
/// restore at quit never race. Remembers every process it moved, so that it can always put them back.
final class PerformanceGovernorEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "heartware.performance.governor", qos: .utility)
    private var demoted: [String: PerformanceDemotion] = [:]
    /// Processor time of each process at the last full sweep, the baseline of the next measure.
    private var lastCPU: [PerformancePID: UInt64] = [:]
    private var lastSweep: Date?
    /// How long each group has been busy without a break, counted on full sweeps only.
    private var busyFor: [String: TimeInterval] = [:]
    /// How long an app slowed for running wild stays so before it is measured again: doubled each time it is slowed
    /// again soon after (two minutes, then four, eight… half an hour at most), so a greedy app does not swing back and forth.
    private var holds: [String: TimeInterval] = [:]
    /// When an app slowed for running wild got its speed back at the end of its hold.
    private var released: [String: Date] = [:]
    private let ownKey: String

    /// Sweeps closer together than this (an app came to the front, a sound started) decide with the current measure
    /// but do not move the baseline nor count as busy time: a burst of a few seconds never gets an app slowed.
    static let fullSweep: TimeInterval = 5
    /// An app slowed because it ran wild is measured again after this long: calm by then, it gets its speed back,
    /// even if it never comes to the front (a menu bar app almost never does).
    static let busyHold: TimeInterval = 120

    init() {
        ownKey = ProcessList.identity(of: Bundle.main.executablePath ?? "").key
    }

    /// One sweep, waited for (command line checks).
    func sweepNow(_ ctx: PerformanceSweepContext) -> PerformanceSweepResult {
        queue.sync { runSweep(ctx) }
    }

    func sweep(_ ctx: PerformanceSweepContext) async -> PerformanceSweepResult {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: self.runSweep(ctx)) }
        }
    }

    /// Gives full speed back to these groups right away (the app came to the front, the user asked).
    func restore(keys: Set<String>) async -> [PerformanceDemotion] {
        await withCheckedContinuation { c in
            queue.async {
                let procs = PerformanceProcScan.current()
                for k in keys { self.restoreGroup(k, procs: procs) }
                c.resume(returning: self.list)
            }
        }
    }

    /// Restores everything now (quitting, mode off). Returns how many processes got their priority back.
    @discardableResult
    func restoreAllNow() -> Int {
        queue.sync {
            let procs = PerformanceProcScan.current()
            var n = 0
            for k in Array(demoted.keys) { n += restoreGroup(k, procs: procs) }
            busyFor.removeAll()
            return n
        }
    }

    /// Slows one group now, until it comes to the front (the "Ralentir" buttons).
    func demoteNow(_ g: PerformanceGroup) async -> [PerformanceDemotion] {
        await withCheckedContinuation { c in
            queue.async {
                let moved = g.movable.filter { PerformanceProcScan.setBackground($0, true) }
                if var d = self.demoted[g.key] {
                    // A sweep got there first: the newly moved processes join it, and it stays until the front.
                    let known = Set(d.pids)
                    d.pids += moved.filter { !known.contains($0) }
                    if d.cause == .busy { d.cause = .manual }
                    self.demoted[g.key] = d
                } else if !moved.isEmpty {
                    self.demoted[g.key] = PerformanceDemotion(key: g.key, name: g.name, appPath: g.appPath, bundleID: g.bundleID,
                                                              pids: moved, since: Date(), cause: .manual, cpuBefore: g.cpu, cpuNow: g.cpu)
                }
                c.resume(returning: self.list)
            }
        }
    }

    /// Processes moved by a previous run that did not get to restore them (a crash): put back if they still exist,
    /// with the processes they started since (born in the background band).
    func recover(_ leftovers: [PerformanceDemotion]) {
        queue.sync {
            let procs = PerformanceProcScan.current()
            for var d in leftovers {
                Self.adoptDescendants(&d, procs: procs)
                for p in d.pids { PerformanceProcScan.setBackground(p, false) }
            }
        }
    }

    private var list: [PerformanceDemotion] { demoted.values.sorted { $0.since < $1.since } }

    @discardableResult
    private func restoreGroup(_ key: String, procs: [PerformanceProc]) -> Int {
        guard var d = demoted.removeValue(forKey: key) else { return 0 }
        Self.adoptDescendants(&d, procs: procs)
        for p in d.pids { PerformanceProcScan.setBackground(p, false) }
        busyFor[key] = 0
        return d.pids.count
    }

    /// A process started by a slowed one inherits its background band from the kernel. The ones started since the
    /// group was slowed (and still in the band) are counted with it, so that they get their priority back with it:
    /// the renderer of a new browser tab, a shell, a language server…
    static func adoptDescendants(_ d: inout PerformanceDemotion, procs: [PerformanceProc]) {
        let since = UInt64(max(0, d.since.timeIntervalSince1970 - 1) * 1_000_000)
        var children: [Int32: [PerformanceProc]] = [:]
        for p in procs { children[p.parent, default: []].append(p) }
        var known = Set(d.pids)
        var parents = d.pids.map(\.pid)
        while let parent = parents.popLast() {
            for c in children[parent] ?? [] where c.id.start >= since && c.priority <= 4 && !known.contains(c.id) {
                d.pids.append(c.id)
                known.insert(c.id)
                parents.append(c.id.pid)
            }
        }
    }

    private func runSweep(_ ctx: PerformanceSweepContext) -> PerformanceSweepResult {
        let now = Date()
        let procs = PerformanceProcScan.current()
        // Who plays sound: the shared watch's latest reading while it runs (no CoreAudio call from this queue then).
        let audio = DeviceActivity.shared.isWatching ? DeviceActivity.shared.state.sounding : PerformanceAudio.activePIDs()
        let taps = PerformanceAudio.eventTapPIDs()
        var groups = PerformancePlanner.groups(procs, apps: ctx.apps, audio: audio, taps: taps, frontPID: ctx.frontPID)
        let frontKey = ctx.frontPID.flatMap { pid in procs.first { $0.id.pid == pid } }.map { ProcessList.identity(of: $0.path).key }

        // Processor use since the last full sweep, per group.
        let dt = lastSweep.map { now.timeIntervalSince($0) } ?? 0
        if dt > 0.5 {
            for p in procs where !PerformancePlanner.isServing(p.path) {
                guard let before = lastCPU[p.id], p.cpuTime >= before else { continue }
                let key = ProcessList.identity(of: p.path).key
                groups[key]?.cpu += Double(p.cpuTime - before) / 1e9 / dt * 100
            }
        }
        let full = lastSweep == nil || dt >= Self.fullSweep
        if full {
            var cpuNow: [PerformancePID: UInt64] = [:]
            for p in procs { cpuNow[p.id] = p.cpuTime }
            lastCPU = cpuNow
            lastSweep = now
        }

        // Forget the processes that ended, and count those the slowed ones started since.
        let alive = Set(procs.map(\.id))
        for (k, var d) in demoted {
            d.pids = d.pids.filter { alive.contains($0) }
            Self.adoptDescendants(&d, procs: procs)
            if d.pids.isEmpty { demoted[k] = nil } else { demoted[k] = d }
        }

        for (key, g) in groups {
            let hold = holds[key] ?? Self.busyHold
            if full && dt > 0 {
                // One threshold for counting and deciding: an app that calms down just below it is never swung back and forth.
                if g.cpu >= PerformancePlanner.busyThreshold(g) {
                    busyFor[key, default: 0] += dt
                } else if demoted[key].map({ $0.cause != .busy || now.timeIntervalSince($0.since) >= hold }) ?? true {
                    busyFor[key] = 0
                }
            }
            let verdict = PerformancePlanner.verdict(g, mode: ctx.mode, frontKey: frontKey, ownKey: ownKey, rules: ctx.rules,
                                                     busyFor: busyFor[key] ?? 0)
            switch verdict {
            case .demote(let cause):
                if var d = demoted[key] {
                    // Already slowed: catch its new helper processes, and keep the strongest cause.
                    let known = Set(d.pids)
                    for p in g.movable where !known.contains(p) && PerformanceProcScan.setBackground(p, true) { d.pids.append(p) }
                    if cause == .rule || (cause == .mode && d.cause == .busy) { d.cause = cause }
                    d.cpuNow = g.cpu
                    demoted[key] = d
                } else {
                    let moved = g.movable.filter { PerformanceProcScan.setBackground($0, true) }
                    guard !moved.isEmpty else { continue }
                    if cause == .busy {
                        // Busy again soon after its speed came back: it waits twice as long before the next measure.
                        let again = released[key].map { now.timeIntervalSince($0) < 600 } ?? false
                        holds[key] = again ? min(1800, hold * 2) : Self.busyHold
                    }
                    demoted[key] = PerformanceDemotion(key: key, name: g.name, appPath: g.appPath, bundleID: g.bundleID, pids: moved,
                                                       since: now, cause: cause, cpuBefore: g.cpu, cpuNow: g.cpu)
                }
            case .keep:
                // Back to full speed: it came to the front, plays sound, got protected, or the mode no longer moves it.
                if let d = demoted[key] {
                    // Slowed on request: it stays so until it comes to the front. Slowed because it was busy: for two
                    // minutes at least, then as long as it stays busy.
                    // Measured again only at a full sweep: a reading over a fraction of a second is no proof of calm.
                    let held = d.cause == .manual || (d.cause == .busy && (now.timeIntervalSince(d.since) < hold || !full))
                    // A VPN or a password manager is only ever slowed by hand.
                    let stays = ctx.mode != .off && key != frontKey && !g.audio && !g.watchesKeyboard && !g.launchedByFront
                        && (d.cause == .manual || !PerformancePlanner.isInfrastructure(g.bundleID))
                        && !ctx.rules.protected.contains(where: { $0 == g.bundleID || $0 == key })
                    if held && stays {
                        demoted[key]?.cpuNow = g.cpu
                    } else {
                        // Its hold ran out (not the front, a sound or the mode): the next one, if it runs wild again, is longer.
                        if d.cause == .busy, !held, stays { released[key] = now }
                        restoreGroup(key, procs: procs)
                    }
                }
            }
        }
        busyFor = busyFor.filter { groups[$0.key] != nil }
        holds = holds.filter { groups[$0.key] != nil }
        released = released.filter { groups[$0.key] != nil && now.timeIntervalSince($0.value) < 600 }
        let busy = groups.values
            .filter { demoted[$0.key] == nil && $0.key != frontKey && $0.key != ownKey && $0.kind != .other && $0.cpu >= 5 && !$0.movable.isEmpty
                && !PerformancePlanner.isInfrastructure($0.bundleID) }
            .sorted { $0.cpu > $1.cpu }
        return PerformanceSweepResult(demotions: list, busy: Array(busy.prefix(6)), frontKey: frontKey)
    }
}
