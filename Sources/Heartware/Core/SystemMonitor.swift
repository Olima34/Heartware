import Foundation
import Darwin
import IOKit
import IOKit.ps
import Observation

/// Battery details from IOKit (nil on desktop Macs).
struct BatteryInfo: Equatable {
    var level: Double            // 0…1
    var isCharging: Bool
    var onAC: Bool
    var minutesLeft: Int?        // to empty, or to full when charging
    var cycleCount: Int?
    var health: Double?          // max capacity / design capacity
    var temperature: Double?     // °C
}

enum MemoryPressure: Int {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: return "Normale"
        case .warning: return "Élevée"
        case .critical: return "Critique"
        }
    }
}

/// Live system metrics, sampled every couple of seconds while something shows them. Cheap syscalls only.
@Observable
@MainActor
final class SystemMonitor {
    static let historyLength = 60
    /// The pace when the menu bar text alone shows the values.
    static let lightInterval: TimeInterval = 5

    /// What shows the live values. The timer runs only while one of them is on screen: with the window closed and the
    /// icon alone in the menu bar, the monitor costs nothing, and `refresh()` still gives fresh values on demand.
    enum Viewer: Hashable {
        case window, panel, menuBar
    }

    /// What the menu bar text reads. When it is the only viewer, only that is sampled, every `lightInterval`:
    /// no curves, no battery, no load average.
    struct Readings: OptionSet {
        let rawValue: Int
        static let cpu = Readings(rawValue: 1)
        static let memory = Readings(rawValue: 2)
        static let network = Readings(rawValue: 4)
        static let disk = Readings(rawValue: 8)
    }

    /// Off: nothing on screen. Light: the menu bar text alone. Full: the main window or the menu bar panel.
    enum Pace {
        case off, light, full
    }

    // CPU
    var cpu: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var cpuHistory: [Double] = []
    var coreCount = ProcessInfo.processInfo.activeProcessorCount
    var loadAverage: Double = 0

    // Memory
    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var memCached: UInt64 = 0
    var memFree: UInt64 = 0
    var memUsed: UInt64 { memApp + memWired + memCompressed }
    var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    var memHistory: [Double] = []
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: MemoryPressure = .normal

    // Disk (data volume)
    var diskTotal: Int64 = 0
    var diskFree: Int64 = 0          // including purgeable space
    var diskFreeStrict: Int64 = 0    // really empty space
    var diskUsedFraction: Double { diskTotal > 0 ? 1 - Double(diskFree) / Double(diskTotal) : 0 }

    // Network
    var netIn: Double = 0            // bytes per second
    var netOut: Double = 0
    var netInHistory: [Double] = []
    var netOutHistory: [Double] = []
    var netTotalIn: UInt64 = 0
    var netTotalOut: UInt64 = 0

    // Misc
    var battery: BatteryInfo?
    var thermal: ProcessInfo.ThermalState = .nominal
    var bootDate: Date?
    var uptime: TimeInterval { bootDate.map { Date().timeIntervalSince($0) } ?? ProcessInfo.processInfo.systemUptime }
    /// Not observed: nothing on screen shows it, and it changes at every sample.
    @ObservationIgnored var lastSample = Date()

    @ObservationIgnored private var timer: Timer?
    /// False for the one-shot monitors (diagnostic, snapshots, self-tests): they never sample on a timer.
    @ObservationIgnored private var live = false
    @ObservationIgnored private var viewers: Set<Viewer> = []
    /// The pace the timer runs at.
    @ObservationIgnored private(set) var pace: Pace = .off
    /// What the menu bar text reads (set by the status item with its metric).
    @ObservationIgnored var menuBarReadings: Readings = [.cpu, .memory]

    /// The figures of the menu bar text: the observed values at full pace, and at light pace these alone, kept out of
    /// observation (a page left in a hidden window is not redrawn for them).
    struct MenuFigures: Equatable {
        var cpu = 0.0
        var memory = 0.0
        var netIn = 0.0
        var netOut = 0.0
        var diskFree: Int64 = 0
    }

    @ObservationIgnored private(set) var menuFigures = MenuFigures()
    /// The processor at light pace, not observed (the curves keep their own pace).
    @ObservationIgnored private var lightCPU: [Double] = []

    /// The latest processor readings, whatever the pace: the curves at full pace, the light readings otherwise.
    var recentCPU: [Double] { pace == .full || lightCPU.isEmpty ? cpuHistory : lightCPU }
    /// Called after each sample (the menu bar text follows the values).
    @ObservationIgnored var onSample: (@MainActor () -> Void)?
    @ObservationIgnored private var prevTicks: (ticks: [UInt32], at: Date)?
    @ObservationIgnored private var prevNet: (bytesIn: UInt64, bytesOut: UInt64, at: Date)?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var lightTick = 0
    /// The free space "for important usage" asks macOS to weigh what it could purge: read only for what shows it.
    @ObservationIgnored private var importantRead = Date.distantPast
    /// Health and cycles come from the battery controller's whole registry entry: read once an hour at most.
    @ObservationIgnored private var batteryDetailsRead = Date.distantPast
    private let host = mach_host_self()
    @ObservationIgnored private var pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        return UInt64(size)
    }()

    var interval: TimeInterval = 2
    var isSampling: Bool { timer != nil }

    /// The menu bar's own pace, never quicker than the settings' one.
    private var lightPeriod: TimeInterval { max(Self.lightInterval, interval) }

    init(start: Bool = true) {
        bootDate = Self.readBootDate()
        sample()
        if start { self.start() }
    }

    /// Goes live: samples every `interval` (read again from the settings) while something shows the values.
    func start() {
        live = true
        let saved = UserDefaults.standard.double(forKey: Preferences.refreshKey)
        interval = saved > 0 ? saved : 2
        // A new interval: the timer starts again at the new pace.
        let current = pace
        pace = .off
        timer?.invalidate()
        timer = nil
        applyPace(from: current)
    }

    /// `viewer` appeared or went away: the timer stops when nothing shows the values any more, slows down when the
    /// menu bar text alone does, and comes back to its full pace (with a sample right away if the values are old) as
    /// soon as the window or the panel does.
    func show(_ viewer: Viewer, _ visible: Bool) {
        if visible { viewers.insert(viewer) } else { viewers.remove(viewer) }
        let current = pace
        applyPace(from: current)
    }

    private var wantedPace: Pace {
        guard live else { return .off }
        if viewers.contains(.window) || viewers.contains(.panel) { return .full }
        return viewers.contains(.menuBar) ? .light : .off
    }

    private func applyPace(from previous: Pace) {
        let wanted = wantedPace
        guard wanted != pace || (wanted != .off && timer == nil) else { return }
        pace = wanted
        switch wanted {
        case .off:
            timer?.invalidate()
            timer = nil
            lightCPU = []
        case .light:
            // Readings of an earlier light period would pass for recent ones.
            lightCPU = []
            if previous == .off {
                // Nothing was read for a while: what the text shows now, and its first rate a second later.
                sampleLight()
                schedule(every: lightPeriod, firstIn: 1)
            } else {
                schedule(every: lightPeriod, firstIn: lightPeriod)
            }
        case .full:
            resume()
        }
    }

    /// Fresh values for a reader that does not watch the screen (alerts, the health history, the assistant):
    /// one sample right away when the timer is paused or light, kept out of the curves so they keep their pace.
    func refresh() {
        if DemoData.isEnabled { return }
        if pace == .full {
            sampleDisk(important: false, publish: true)
        } else {
            sample(record: false, everything: true, important: false)
        }
    }

    private func resume() {
        let age = Date().timeIntervalSince(lastSample)
        guard age > interval * 1.5 || !lastSampleWasFull else {
            // Still fresh (a window that flickers between Spaces): the timer just picks up the pace.
            schedule(every: interval, firstIn: max(0.1, interval - age))
            return
        }
        // CPU and network are rates: over a long pause they would be averages, not what happens now. They restart from
        // here (unless the menu bar text kept them going) and the next sample comes soon; memory, disk and battery are
        // read right away.
        sample(record: true, everything: true, important: true)
        schedule(every: interval, firstIn: min(0.5, interval))
    }

    /// False after a light sample: the window coming back reads everything at once.
    @ObservationIgnored private var lastSampleWasFull = true

    private func schedule(every period: TimeInterval, firstIn delay: TimeInterval) {
        timer?.invalidate()
        let light = pace == .light
        let t = Timer(fire: Date().addingTimeInterval(delay), interval: period, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if light { self?.sampleLight() } else { self?.sample() }
            }
        }
        t.tolerance = light ? max(1, period * 0.25) : period * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func sample() {
        sample(record: true, everything: false, important: false)
    }

    /// `record` adds the values to the curves; `everything` also reads the disk and the battery, which change slowly;
    /// `important` the free space for important usage, which only the screen needs at once.
    private func sample(record: Bool, everything: Bool, important: Bool) {
        tick += 1
        lastSampleWasFull = true
        defer { onSample?() }
        if DemoData.isEnabled {
            DemoData.sample(self, tick: tick)
            menuFigures = MenuFigures(cpu: cpu, memory: memFraction, netIn: netIn, netOut: netOut, diskFree: diskFree)
            return
        }
        sampleCPU(record: record, publish: true)
        sampleMemory(record: record, publish: true)
        sampleNetwork(record: record, publish: true)
        if everything || tick % 5 == 1 {
            // Shown in the window and the panel: refreshed every 15 samples there, else reused a while.
            sampleDisk(important: important || (pace == .full && tick % 15 == 1), publish: true)
        }
        if everything || tick % 15 == 1 { sampleBattery() }
        assign(\.thermal, ProcessInfo.processInfo.thermalState)
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) > 0 { assign(\.loadAverage, loads[0]) }
        lastSample = Date()
    }

    /// The menu bar text alone: only what its metric reads (the temperature metric reads its own sensors), into
    /// `menuFigures`. No observed value changes: the pages of a hidden window are not redrawn.
    private func sampleLight() {
        tick += 1
        lightTick += 1
        defer { onSample?() }
        lastSampleWasFull = false
        if DemoData.isEnabled {
            // The demo's values are made up from the tick: they keep moving in the menu bar too.
            DemoData.sample(self, tick: tick)
            menuFigures = MenuFigures(cpu: cpu, memory: memFraction, netIn: netIn, netOut: netOut, diskFree: diskFree)
            return
        }
        let r = menuBarReadings
        // Always the processor and the heat, a syscall each: the chamois' mood reads them (`recentCPU`) even when the
        // menu bar shows something else.
        if sampleCPU(record: false, publish: false) { push(menuFigures.cpu, to: &lightCPU) }
        assign(\.thermal, ProcessInfo.processInfo.thermalState)
        if r.contains(.memory) { sampleMemory(record: false, publish: false) }
        if r.contains(.network) { sampleNetwork(record: false, publish: false) }
        // The free space moves slowly: every half minute.
        if r.contains(.disk), lightTick % 6 == 1 { sampleDisk(important: true, publish: false) }
        lastSample = Date()
    }

    /// Assigns only a new value: `@Observable` would otherwise redraw whatever reads it, even for the same value.
    private func assign<T: Equatable>(_ path: ReferenceWritableKeyPath<SystemMonitor, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    private func push(_ v: Double, to array: inout [Double]) {
        array.append(v)
        if array.count > Self.historyLength { array.removeFirst(array.count - Self.historyLength) }
    }

    /// A rate is measured against a recent reading only: an older one would give an average over the pause.
    private func isRecent(_ date: Date) -> Bool {
        Date().timeIntervalSince(date) < 3 * max(interval, lightPeriod)
    }

    // MARK: CPU

    /// `publish` false (the menu bar text alone): the figure goes to `menuFigures` only.
    /// False when no rate could be measured (the previous reading is too old): nothing was updated.
    @discardableResult
    private func sampleCPU(record: Bool, publish: Bool) -> Bool {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return false }
        let t = info.cpu_ticks
        let ticks = [t.0, t.1, t.2, t.3] // user, system, idle, nice
        let now = Date()
        defer { prevTicks = (ticks, now) }
        // A reader that does not watch the screen (`refresh`) gets the average since the last reading, however old.
        guard let prev = prevTicks, isRecent(prev.at) || (publish && !record) else { return false }
        let d = zip(ticks, prev.ticks).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        guard total > 0 else { return false }
        let user = (d[0] + d[3]) / total
        let system = d[1] / total
        menuFigures.cpu = min(1, user + system)
        guard publish else { return true }
        assign(\.cpuUser, user)
        assign(\.cpuSystem, system)
        assign(\.cpu, menuFigures.cpu)
        if record { push(cpu, to: &cpuHistory) }
        return true
    }

    // MARK: Memory

    /// `publish` false (the menu bar text alone): the used fraction only, into `menuFigures`, without the swap and the
    /// memory pressure.
    private func sampleMemory(record: Bool, publish: Bool) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let p = pageSize
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            let app = (internalPages > purgeable ? internalPages - purgeable : 0) * p
            let wired = UInt64(stats.wire_count) * p
            let compressed = UInt64(stats.compressor_page_count) * p
            menuFigures.memory = memTotal > 0 ? Double(app + wired + compressed) / Double(memTotal) : 0
            guard publish else { return }
            assign(\.memApp, app)
            assign(\.memWired, wired)
            assign(\.memCompressed, compressed)
            assign(\.memCached, (UInt64(stats.external_page_count) + purgeable) * p)
            assign(\.memFree, UInt64(stats.free_count) * p)
            if record { push(memFraction, to: &memHistory) }
        }
        guard publish else { return }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            assign(\.swapUsed, swap.xsu_used)
            assign(\.swapTotal, swap.xsu_total)
        }

        var level: Int32 = 1
        var lsize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &lsize, nil, 0) == 0 {
            assign(\.pressure, MemoryPressure(rawValue: Int(level)) ?? .normal)
        }
    }

    // MARK: Disk

    /// Reads the free space now, the purgeable part included (after a cleanup, for what shows it).
    func sampleDisk() {
        sampleDisk(important: true, publish: true)
    }

    /// `important`: the free space for important usage too, which makes macOS weigh what it could purge. Otherwise it
    /// is kept from the last reading (ten minutes at most) and only the cheap figures are read.
    private func sampleDisk(important: Bool, publish: Bool) {
        if DemoData.isEnabled {
            DemoData.sampleDisk(self)
            menuFigures.diskFree = diskFree
            return
        }
        guard let v = try? URL(fileURLWithPath: FS.home).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) else { return }
        let strict = Int64(v.volumeAvailableCapacity ?? 0)
        // Until a new reading for important usage comes, the last one stands (never less than the really empty space).
        menuFigures.diskFree = max(menuFigures.diskFree, strict)
        if publish {
            assign(\.diskTotal, Int64(v.volumeTotalCapacity ?? 0))
            assign(\.diskFreeStrict, strict)
            assign(\.diskFree, menuFigures.diskFree)
        }
        if important || Date().timeIntervalSince(importantRead) > 600 { readImportant(publish: publish) }
    }

    @ObservationIgnored private var importantPending = false
    /// Asked again while a reading was under way (a cleanup just freed space): one more reading follows it.
    @ObservationIgnored private var importantAgain: Bool?

    /// The free space for important usage is asked of CacheDelete, another process that can take seconds to answer
    /// (right after waking up above all): read away from the main thread, one reading at a time, applied when it comes.
    private func readImportant(publish: Bool) {
        guard !importantPending else {
            importantAgain = (importantAgain ?? false) || publish
            return
        }
        importantPending = true
        importantRead = Date()
        let home = FS.home
        Task.detached(priority: .utility) { [weak self] in
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
            let v = try? URL(fileURLWithPath: home).resourceValues(forKeys: keys)
            let important = v?.volumeAvailableCapacityForImportantUsage
            let strict = v.flatMap { $0.volumeAvailableCapacity }.map(Int64.init)
            await self?.importantCame(important ?? strict, strict: strict, publish: publish)
        }
    }

    private func importantCame(_ free: Int64?, strict: Int64?, publish: Bool) {
        importantPending = false
        if let free {
            // Never less than the really empty space, which may have grown since the reading began.
            let value = max(free, strict ?? 0, diskFreeStrict)
            menuFigures.diskFree = value
            if publish || pace == .full { assign(\.diskFree, value) }
        }
        if let again = importantAgain {
            importantAgain = nil
            readImportant(publish: again)
        }
    }

    // MARK: Network

    /// `publish` false (the menu bar text alone): the rates go to `menuFigures` only.
    private func sampleNetwork(record: Bool, publish: Bool) {
        guard let (bytesIn, bytesOut) = Self.readInterfaceBytes() else { return }
        let now = Date()
        defer { prevNet = (bytesIn, bytesOut, now) }
        if let prev = prevNet, isRecent(prev.at) {
            let dt = now.timeIntervalSince(prev.at)
            if dt > 0, bytesIn >= prev.bytesIn, bytesOut >= prev.bytesOut {
                menuFigures.netIn = Double(bytesIn - prev.bytesIn) / dt
                menuFigures.netOut = Double(bytesOut - prev.bytesOut) / dt
                if publish {
                    assign(\.netIn, menuFigures.netIn)
                    assign(\.netOut, menuFigures.netOut)
                    if record {
                        push(netIn, to: &netInHistory)
                        push(netOut, to: &netOutHistory)
                    }
                }
            }
        }
        guard publish else { return }
        assign(\.netTotalIn, bytesIn)
        assign(\.netTotalOut, bytesOut)
    }

    /// Sums the 64-bit byte counters of the physical interfaces (en*). The name comes with each interface's message
    /// (its link-level address follows it), so no other call is needed per interface.
    nonisolated static func readInterfaceBytes() -> (UInt64, UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }
        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        var offset = 0
        let headerSize = MemoryLayout<if_msghdr2>.size
        buf.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + headerSize <= len {
                    let m = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if isPhysical(raw, at: offset + headerSize, end: min(len, offset + Int(hdr.ifm_msglen)),
                                  hasLink: m.ifm_addrs & RTA_IFP != 0, index: m.ifm_index) {
                        totalIn += m.ifm_data.ifi_ibytes
                        totalOut += m.ifm_data.ifi_obytes
                    }
                }
                let step = Int(hdr.ifm_msglen)
                if step <= 0 { break }
                offset += step
            }
        }
        return (totalIn, totalOut)
    }

    /// The interface's name starts with "en": read in the `sockaddr_dl` after its message, or asked by index when the
    /// message carries none.
    nonisolated private static func isPhysical(_ raw: UnsafeRawBufferPointer, at start: Int, end: Int, hasLink: Bool, index: UInt16) -> Bool {
        // Byte by byte: the address may be shorter than a whole `sockaddr_dl` (no hardware address).
        let family = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_family) ?? 1
        let nameLength = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_nlen) ?? 5
        let name = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) ?? 8
        if hasLink, start + name + 2 <= end, Int32(raw[start + family]) == AF_LINK {
            return raw[start + nameLength] >= 2 && raw[start + name] == UInt8(ascii: "e") && raw[start + name + 1] == UInt8(ascii: "n")
        }
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        guard if_indextoname(UInt32(index), &buffer) != nil else { return false }
        return String(cString: buffer).hasPrefix("en")
    }

    // MARK: Battery

    /// Level and charge every reading; health, cycles and temperature (the controller's whole registry entry) once an
    /// hour at most, kept from the last reading in between.
    private func sampleBattery() {
        let details = battery == nil || Date().timeIntervalSince(batteryDetailsRead) > 3_600
        var info = Self.readBattery(details: details)
        if details {
            batteryDetailsRead = Date()
        } else if let old = battery {
            info?.cycleCount = old.cycleCount
            info?.health = old.health
            info?.temperature = old.temperature
        }
        assign(\.battery, info)
    }

    nonisolated static func readBattery(details: Bool = true) -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (desc["Type"] as? String) == "InternalBattery" else { continue }
            let current = desc["Current Capacity"] as? Int ?? 0
            let maxCap = max(1, desc["Max Capacity"] as? Int ?? 100)
            let charging = desc["Is Charging"] as? Bool ?? false
            let onAC = (desc["Power Source State"] as? String) == "AC Power"
            let minutes = charging ? desc["Time to Full Charge"] as? Int : desc["Time to Empty"] as? Int
            var info = BatteryInfo(level: Double(current) / Double(maxCap), isCharging: charging, onAC: onAC,
                                   minutesLeft: (minutes ?? -1) > 0 ? minutes : nil)
            // Health and cycles from the battery controller.
            guard details else { return info }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let d = props?.takeRetainedValue() as? [String: Any] {
                    let nested = d["BatteryData"] as? [String: Any] ?? [:]
                    func int(_ k: String) -> Int? { d[k] as? Int ?? nested[k] as? Int }
                    info.cycleCount = int("CycleCount")
                    let design = int("DesignCapacity") ?? 0
                    // System Settings shows the nominal capacity against the design capacity.
                    let rawMax = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") ?? 0
                    if design > 0 && rawMax > 0 { info.health = min(1, Double(rawMax) / Double(design)) }
                    if let t = d["Temperature"] as? Int { info.temperature = Double(t) / 100 }
                }
            }
            return info
        }
        return nil
    }

    nonisolated static func readBootDate() -> Date? {
        if DemoData.isEnabled { return DemoData.bootDate }
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    /// The timer runs only while something shows the values, and never for a one-shot monitor.
    static func selfTest() -> [String] {
        var failures: [String] = []
        let oneShot = SystemMonitor(start: false)
        oneShot.show(.window, true)
        if oneShot.isSampling { failures.append("moniteur : un moniteur ponctuel échantillonne en continu") }
        let m = SystemMonitor(start: true)
        defer { m.show(.window, false); m.show(.panel, false); m.show(.menuBar, false) }
        if m.isSampling { failures.append("moniteur : échantillonne alors que rien ne l'affiche") }
        m.show(.window, true)
        m.show(.panel, true)
        m.show(.window, false)
        if !m.isSampling { failures.append("moniteur : arrêté alors que le panneau du menu d'état est ouvert") }
        m.show(.panel, false)
        if m.isSampling { failures.append("moniteur : continue une fois la fenêtre et le panneau fermés") }
        m.show(.menuBar, true)
        if !m.isSampling { failures.append("moniteur : ne reprend pas pour la barre des menus") }
        // The menu bar text alone: a slow pace, back to full speed as soon as the window shows.
        if m.pace != .light || m.lightPeriod < Self.lightInterval || (m.timer?.tolerance ?? 0) < 1 {
            failures.append("moniteur : la barre des menus seule n'échantillonne pas au ralenti (5 s, tolérance d'au moins 1 s)")
        }
        m.show(.window, true)
        if m.pace != .full || (m.timer?.timeInterval ?? 0) > m.interval {
            failures.append("moniteur : la fenêtre ne remet pas le rythme complet")
        }
        m.show(.window, false)
        if m.pace != .light { failures.append("moniteur : la fenêtre partie, la barre des menus ne repasse pas au ralenti") }
        return failures
    }

    var thermalLabel: String {
        switch thermal {
        case .nominal: return "Normale"
        case .fair: return "Tiède"
        case .serious: return "Chaude"
        case .critical: return "Critique"
        @unknown default: return "—"
        }
    }

    static var modelName: String {
        if DemoData.isEnabled { return DemoData.modelName }
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static var chipName: String {
        if DemoData.isEnabled { return DemoData.chipName }
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// "27.1"
    static var osVersion: String {
        if DemoData.isEnabled { return DemoData.osVersion }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
}
