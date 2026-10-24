import Foundation
import IOKit
import AppKit
import Observation

/// One reading of what macOS lets any app read about the chip, without administrator rights:
/// temperatures (SMC and HID sensors), power (SMC), frequencies and GPU power (IOReport), GPU load (IOAccelerator), fans.
struct PerformanceSensorSample: Equatable, Sendable {
    /// The processor: average of its core sensors (what Activity-style monitors show), or the hottest die sensor (°C).
    var chipTemp: Double?
    /// The hottest processor sensor (°C).
    var hotspotTemp: Double?
    var gpuTemp: Double?
    var ssdTemp: Double?
    var batteryTemp: Double?
    /// The whole Mac (W), screen included.
    var systemPower: Double?
    /// What the charger delivers (W), 0 on battery.
    var adapterPower: Double?
    var cpuPower: Double?
    var gpuPower: Double?
    /// 0…1
    var gpuUsage: Double?
    var gpuFrequency: Double?
    var pCluster: PerformanceCluster?
    var eCluster: PerformanceCluster?
    var fans: [PerformanceFan] = []

    var isEmpty: Bool { chipTemp == nil && systemPower == nil && gpuUsage == nil && pCluster == nil }
}

/// A group of cores of the same kind (performance or efficiency), from IOReport's residencies.
struct PerformanceCluster: Equatable, Sendable {
    /// MHz, averaged over the time the cores were awake.
    var frequency: Double
    var maxFrequency: Double
    /// Share of the time the cluster was awake, 0…1.
    var active: Double

    var speedRatio: Double { maxFrequency > 0 ? frequency / maxFrequency : 0 }
}

struct PerformanceFan: Equatable, Identifiable, Sendable {
    var id: Int
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double

    var fraction: Double { maxRPM > minRPM ? max(0, min(1, (rpm - minRPM) / (maxRPM - minRPM))) : 0 }
}

// MARK: - Reader

/// Opens the sensors once and reads them on demand. Every call is serialized: the monitor's timer,
/// the benchmark and `--dump` may all ask at once.
final class PerformanceSensorReader: @unchecked Sendable {
    static let shared = PerformanceSensorReader()

    private let lock = NSLock()
    private var opened = false
    private var smc: PerformanceSMC?
    private var hid: PerformanceHID?
    private var report: PerformanceIOReport?

    /// Reads everything. The frequencies and the GPU power are averages since the previous call
    /// (nil on the very first one).
    func sample() -> PerformanceSensorSample {
        lock.lock()
        defer { lock.unlock() }
        if DemoData.isEnabled { return PerformanceDemo.sensors() }
        if !opened {
            opened = true
            smc = PerformanceSMC()
            hid = PerformanceHID()
            report = PerformanceIOReport()
        }
        var s = PerformanceSensorSample()
        let hidTemps = hid?.temperatures() ?? []
        let dies = hidTemps.filter { $0.name.localizedCaseInsensitiveContains("tdie") }.map(\.value)
        s.ssdTemp = Self.average(hidTemps.filter { $0.name.localizedCaseInsensitiveContains("NAND") }.map(\.value))
        s.batteryTemp = Self.average(hidTemps.filter { $0.name.localizedCaseInsensitiveContains("battery") }.map(\.value))
        if let smc {
            let cpu = smc.temperatures(smc.cpuKeys)
            s.chipTemp = Self.average(cpu)
            s.hotspotTemp = cpu.max()
            s.gpuTemp = Self.average(smc.temperatures(smc.gpuKeys))
            if s.ssdTemp == nil { s.ssdTemp = smc.temperatures(["TH0x", "TH0T", "TH0a"]).first }
            if s.batteryTemp == nil { s.batteryTemp = smc.temperatures(["TB0T", "TB1T"]).first }
            s.systemPower = smc.power("PSTR")
            s.adapterPower = smc.power("PDTR")
            s.fans = smc.fans()
        }
        // Chips whose SMC sensor names are not known here: the die sensors.
        if s.chipTemp == nil { s.chipTemp = dies.max() }
        if s.hotspotTemp == nil { s.hotspotTemp = dies.max() }
        if let r = report?.sample() {
            s.pCluster = r.p
            s.eCluster = r.e
            s.gpuFrequency = r.gpuFrequency
            s.gpuPower = r.gpuPower
            s.cpuPower = r.cpuPower
        }
        s.gpuUsage = PerformanceGPU.usage()
        return s
    }

    private let quickLock = NSLock()
    private var quickValue: Double?
    private var quickPending = false

    /// The processor temperature for the menu bar, without ever waiting: the last value read, while a fresh one is read
    /// in the background (opening the sensors the first time takes a moment; then a read is a few SMC calls).
    func quickTemperature() -> Double? {
        if DemoData.isEnabled { return PerformanceDemo.sensors().chipTemp }
        quickLock.lock()
        let value = quickValue
        let start = !quickPending
        quickPending = true
        quickLock.unlock()
        if start {
            DispatchQueue.global(qos: .utility).async {
                let t = self.readProcessorTemperature()
                self.quickLock.lock()
                self.quickValue = t ?? self.quickValue
                self.quickPending = false
                self.quickLock.unlock()
            }
        }
        return value
    }

    private func readProcessorTemperature() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        if !opened {
            opened = true
            smc = PerformanceSMC()
            hid = PerformanceHID()
            report = PerformanceIOReport()
        }
        if let smc, let t = Self.average(smc.temperatures(smc.cpuKeys)) { return t }
        return hid?.temperatures().filter { $0.name.localizedCaseInsensitiveContains("tdie") }.map(\.value).max()
    }

    /// What each source gave, for `--dump`.
    func describe() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if DemoData.isEnabled { return ["capteurs de démonstration"] }
        if !opened {
            opened = true
            smc = PerformanceSMC()
            hid = PerformanceHID()
            report = PerformanceIOReport()
        }
        var lines: [String] = []
        lines.append("SMC : " + (smc.map { "\($0.keyCount) clés, \($0.cpuKeys.count) capteurs processeur, \($0.gpuKeys.count) GPU" } ?? "inaccessible"))
        let temps = hid?.temperatures() ?? []
        lines.append("Capteurs HID : " + (hid == nil ? "inaccessibles" : "\(temps.count) températures"))
        lines.append("IOReport : " + (report.map { "fréquences E \($0.eTable.count) paliers, P \($0.pTable.count), GPU \($0.gpuTable.count)" } ?? "inaccessible"))
        return lines
    }

    static func average(_ v: [Double]) -> Double? {
        v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    /// A plausible temperature (a missing sensor answers 0, -1 or a huge value).
    static func plausible(_ t: Double) -> Bool { t > 5 && t < 125 }
}

// MARK: - SMC

/// The System Management Controller: temperatures, power rails and fans. Reading needs no privilege.
final class PerformanceSMC {
    private var connection: io_connect_t = 0
    private(set) var keyCount = 0
    private(set) var cpuKeys: [String] = []
    private(set) var gpuKeys: [String] = []
    private var infoCache: [UInt32: (size: UInt32, type: UInt32)] = [:]

    // Layout of the driver's SMCKeyData_t (80 bytes).
    private static let size = 80
    private static let keyOffset = 0
    private static let dataSizeOffset = 28
    private static let dataTypeOffset = 32
    private static let resultOffset = 40
    private static let commandOffset = 42
    private static let data32Offset = 44
    private static let bytesOffset = 48

    private static let readKey: UInt8 = 5
    private static let keyFromIndex: UInt8 = 8
    private static let keyInfo: UInt8 = 9

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        keyCount = Int(raw("#KEY").map { Self.bigEndian($0.bytes) } ?? 0)
        // The sensor names differ from one chip to the next: they are looked up once.
        var temps: [String] = []
        for i in 0..<min(keyCount, 4000) {
            guard let k = key(at: i), k.hasPrefix("T") else { continue }
            temps.append(k)
        }
        let appleSilicon = temps.contains { $0.hasPrefix("Tp") }
        if appleSilicon {
            cpuKeys = temps.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }
            gpuKeys = temps.filter { $0.hasPrefix("Tg") }
        } else {
            cpuKeys = temps.filter { ["TC0P", "TC0D", "TC0E", "TC0F", "TCXC"].contains($0) || ($0.hasPrefix("TC") && $0.hasSuffix("c")) }
            gpuKeys = temps.filter { ["TG0P", "TG0D", "TG0H"].contains($0) }
        }
        // Keep only the sensors that answer with a temperature.
        cpuKeys = cpuKeys.filter { value($0).map(PerformanceSensorReader.plausible) == true }
        gpuKeys = gpuKeys.filter { value($0).map(PerformanceSensorReader.plausible) == true }
    }

    deinit { IOServiceClose(connection) }

    func temperatures(_ keys: [String]) -> [Double] {
        keys.compactMap { value($0) }.filter(PerformanceSensorReader.plausible)
    }

    func power(_ key: String) -> Double? {
        guard let w = value(key), w >= 0, w < 1000 else { return nil }
        return w
    }

    func fans() -> [PerformanceFan] {
        guard let n = value("FNum"), n >= 1 else { return [] }
        return (0..<min(Int(n), 4)).compactMap { i in
            guard let rpm = value("F\(i)Ac") else { return nil }
            return PerformanceFan(id: i, rpm: max(0, rpm), minRPM: value("F\(i)Mn") ?? 0, maxRPM: value("F\(i)Mx") ?? 0)
        }
    }

    /// A key as a number, whatever its encoding.
    func value(_ key: String) -> Double? {
        guard let r = raw(key) else { return nil }
        return Self.decode(type: r.type, bytes: r.bytes)
    }

    static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let v = Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
            return v.isFinite ? v : nil
        case "ui8 ", "si8 ":
            guard let b = bytes.first else { return nil }
            return type == "si8 " ? Double(Int8(bitPattern: b)) : Double(b)
        case "ui16", "ui32":
            return Double(bigEndian(bytes))
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "fp88":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 256
        default:
            return nil
        }
    }

    static func code(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }

    static func name(_ v: UInt32) -> String {
        String(bytes: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)], encoding: .ascii) ?? ""
    }

    static func bigEndian(_ bytes: [UInt8]) -> UInt32 { bytes.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }

    private func raw(_ key: String) -> (type: String, bytes: [UInt8])? {
        let k = Self.code(key)
        guard let info = info(k), info.size > 0, info.size <= 32 else { return nil }
        var input = [UInt8](repeating: 0, count: Self.size)
        put(&input, Self.keyOffset, k)
        put(&input, Self.dataSizeOffset, info.size)
        input[Self.commandOffset] = Self.readKey
        guard let out = call(input) else { return nil }
        return (Self.name(info.type), Array(out[Self.bytesOffset..<Self.bytesOffset + Int(info.size)]))
    }

    private func info(_ key: UInt32) -> (size: UInt32, type: UInt32)? {
        if let cached = infoCache[key] { return cached }
        var input = [UInt8](repeating: 0, count: Self.size)
        put(&input, Self.keyOffset, key)
        input[Self.commandOffset] = Self.keyInfo
        guard let out = call(input) else { return nil }
        let i = (size: get(out, Self.dataSizeOffset), type: get(out, Self.dataTypeOffset))
        infoCache[key] = i
        return i
    }

    private func key(at index: Int) -> String? {
        var input = [UInt8](repeating: 0, count: Self.size)
        put(&input, Self.data32Offset, UInt32(index))
        input[Self.commandOffset] = Self.keyFromIndex
        guard let out = call(input) else { return nil }
        return Self.name(get(out, Self.keyOffset))
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var inp = input
        var out = [UInt8](repeating: 0, count: Self.size)
        var outSize = Self.size
        let kr = IOConnectCallStructMethod(connection, 2, &inp, Self.size, &out, &outSize)
        guard kr == KERN_SUCCESS, out[Self.resultOffset] == 0 else { return nil }
        return out
    }

    private func put(_ b: inout [UInt8], _ offset: Int, _ v: UInt32) {
        for i in 0..<4 { b[offset + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
    }

    private func get(_ b: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(b[offset + $1]) << (8 * UInt32($1)) }
    }
}

// MARK: - HID temperature sensors

/// The temperature sensors of Apple silicon, through the HID event system. Its functions are not in the public
/// headers: they are looked up at run time, and everything is simply unavailable if one is missing.
final class PerformanceHID {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double

    private static let temperatureEvent: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    private let client: AnyObject
    private let copyEvent: CopyEvent
    private let getFloat: GetFloat
    private let services: [(name: String, service: AnyObject)]

    init?() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = Self.symbol(h, "IOHIDEventSystemClientCreate", ClientCreate.self),
              let setMatching = Self.symbol(h, "IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = Self.symbol(h, "IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = Self.symbol(h, "IOHIDServiceClientCopyProperty", CopyProperty.self),
              let copyEvent = Self.symbol(h, "IOHIDServiceClientCopyEvent", CopyEvent.self),
              let getFloat = Self.symbol(h, "IOHIDEventGetFloatValue", GetFloat.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        // Usage page 0xff00, usage 5: Apple's temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let list = (copyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        guard !list.isEmpty else { return nil }
        self.client = client
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        services = list.map { s in
            ((copyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String) ?? "?", s)
        }
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _ type: T.Type) -> T? {
        guard let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    func temperatures() -> [(name: String, value: Double)] {
        services.compactMap { s in
            guard !s.name.localizedCaseInsensitiveContains("tcal"),
                  let event = copyEvent(s.service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            let v = getFloat(event, Self.temperatureField)
            return PerformanceSensorReader.plausible(v) ? (s.name, v) : nil
        }
    }
}

// MARK: - IOReport (frequencies and energy)

/// Apple silicon's activity counters: how long each core cluster spent at each frequency, and the energy of the GPU.
/// Looked up at run time in libIOReport, like the HID sensors.
final class PerformanceIOReport {
    struct Reading {
        var p: PerformanceCluster?
        var e: PerformanceCluster?
        var gpuFrequency: Double?
        var gpuPower: Double?
        var cpuPower: Double?
    }

    private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeChannels = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                                                           UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias GetInteger = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: CreateSamples
    private let createDelta: CreateSamplesDelta
    private let group: GetString
    private let subgroup: GetString
    private let channelName: GetString
    private let unitLabel: GetString
    private let integer: GetInteger
    private let stateCount: StateCount
    private let stateName: StateName
    private let residency: StateResidency
    private let subscription: OpaquePointer
    private let subscribed: CFMutableDictionary
    private var previous: (samples: CFDictionary, at: Date)?

    let eTable: [Double]
    let pTable: [Double]
    let gpuTable: [Double]

    init?() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW),
              let copyChannels = Self.symbol(h, "IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let merge = Self.symbol(h, "IOReportMergeChannels", MergeChannels.self),
              let subscribe = Self.symbol(h, "IOReportCreateSubscription", CreateSubscription.self),
              let createSamples = Self.symbol(h, "IOReportCreateSamples", CreateSamples.self),
              let createDelta = Self.symbol(h, "IOReportCreateSamplesDelta", CreateSamplesDelta.self),
              let group = Self.symbol(h, "IOReportChannelGetGroup", GetString.self),
              let subgroup = Self.symbol(h, "IOReportChannelGetSubGroup", GetString.self),
              let channelName = Self.symbol(h, "IOReportChannelGetChannelName", GetString.self),
              let unitLabel = Self.symbol(h, "IOReportChannelGetUnitLabel", GetString.self),
              let integer = Self.symbol(h, "IOReportSimpleGetIntegerValue", GetInteger.self),
              let stateCount = Self.symbol(h, "IOReportStateGetCount", StateCount.self),
              let stateName = Self.symbol(h, "IOReportStateGetNameForIndex", StateName.self),
              let residency = Self.symbol(h, "IOReportStateGetResidency", StateResidency.self) else { return nil }
        var all: CFMutableDictionary?
        let wanted: [(String, String?)] = [("Energy Model", nil), ("CPU Stats", "CPU Complex Performance States"),
                                           ("GPU Stats", "GPU Performance States")]
        for (g, s) in wanted {
            guard let c = copyChannels(g as CFString, s as CFString?, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let base = all { merge(base, c, nil) } else { all = c }
        }
        guard let all, let channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(all), all) else { return nil }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = subscribe(nil, channels, &subbed, 0, nil), let subscribed = subbed?.takeRetainedValue() else { return nil }
        self.createSamples = createSamples
        self.createDelta = createDelta
        self.group = group
        self.subgroup = subgroup
        self.channelName = channelName
        self.unitLabel = unitLabel
        self.integer = integer
        self.stateCount = stateCount
        self.stateName = stateName
        self.residency = residency
        self.subscription = sub
        self.subscribed = subscribed
        let tables = Self.frequencyTables()
        eTable = tables["voltage-states1-sram"] ?? []
        pTable = tables["voltage-states5-sram"] ?? []
        gpuTable = (tables["voltage-states9-sram"] ?? tables["voltage-states9"] ?? []).filter { $0 > 0 }
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _ type: T.Type) -> T? {
        guard let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    /// The frequency of each step (MHz), from the power manager's description in the I/O registry.
    private static func frequencyTables() -> [String: [Double]] {
        let pmgr = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard pmgr != 0 else { return [:] }
        defer { IOObjectRelease(pmgr) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(pmgr, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return [:] }
        var tables: [String: [Double]] = [:]
        for (k, v) in d where k.hasPrefix("voltage-states") {
            guard let data = v as? Data else { continue }
            tables[k] = PerformanceIOReport.frequencies(data)
        }
        return tables
    }

    /// Pairs of 32-bit (frequency, voltage): the frequency is in Hz on most chips, in kHz on some.
    static func frequencies(_ data: Data) -> [Double] {
        var out: [Double] = []
        data.withUnsafeBytes { raw in
            var i = 0
            while i + 8 <= raw.count {
                let f = Double(raw.loadUnaligned(fromByteOffset: i, as: UInt32.self))
                out.append(f > 1e8 ? f / 1e6 : (f > 1e5 ? f / 1e3 : f))
                i += 8
            }
        }
        return out
    }

    func sample() -> Reading? {
        guard let now = createSamples(subscription, subscribed, nil)?.takeRetainedValue() else { return nil }
        let date = Date()
        defer { previous = (now, date) }
        guard let prev = previous, let delta = createDelta(prev.samples, now, nil)?.takeRetainedValue() else { return nil }
        let dt = date.timeIntervalSince(prev.at)
        guard dt > 0.05, let channels = (delta as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return nil }
        var r = Reading()
        var eStates: [[(String, Int64)]] = [], pStates: [[(String, Int64)]] = [], gpuStates: [[(String, Int64)]] = []
        var cpuEnergy: Double = 0
        for ch in channels {
            let g = group(ch)?.takeUnretainedValue() as String? ?? ""
            let name = channelName(ch)?.takeUnretainedValue() as String? ?? ""
            if g == "Energy Model" {
                let unit = unitLabel(ch)?.takeUnretainedValue() as String? ?? ""
                let joules = Self.joules(integer(ch, 0), unit: unit)
                if name == "GPU Energy" { r.gpuPower = joules / dt }
                if name == "CPU Energy" { cpuEnergy = joules }
                continue
            }
            let states = (0..<stateCount(ch)).map { i in
                ((stateName(ch, i)?.takeUnretainedValue() as String?) ?? "", residency(ch, i))
            }
            let sub = subgroup(ch)?.takeUnretainedValue() as String? ?? ""
            if sub == "CPU Complex Performance States" {
                // ECPU / PCPU (and PCPU1… on the bigger chips); ECPM / PCPM are the same clusters seen by the power manager.
                if name.hasPrefix("ECPU") { eStates.append(states) }
                if name.hasPrefix("PCPU") { pStates.append(states) }
            } else if sub == "GPU Performance States", name == "GPUPH" {
                gpuStates.append(states)
            }
        }
        r.e = Self.cluster(eStates, table: eTable)
        r.p = Self.cluster(pStates, table: pTable)
        r.gpuFrequency = Self.cluster(gpuStates, table: gpuTable).flatMap { $0.active > 0.001 ? $0.frequency : nil }
        if cpuEnergy > 0 { r.cpuPower = cpuEnergy / dt }
        return r
    }

    static func joules(_ value: Int64, unit: String) -> Double {
        switch unit {
        case "nJ": return Double(value) / 1e9
        case "uJ", "µJ": return Double(value) / 1e6
        default: return Double(value) / 1e3
        }
    }

    /// Average frequency while awake and share of time awake, from the residency of each state.
    /// The active states, in order, match the steps of the frequency table.
    static func cluster(_ channels: [[(String, Int64)]], table: [Double]) -> PerformanceCluster? {
        guard !channels.isEmpty, !table.isEmpty else { return nil }
        var idle: Int64 = 0
        var activeRes = [Int64](repeating: 0, count: table.count)
        for states in channels {
            var index = 0
            for (name, res) in states {
                if ["IDLE", "OFF", "DOWN"].contains(name) {
                    idle += res
                } else {
                    if index < activeRes.count { activeRes[index] += res }
                    index += 1
                }
            }
        }
        let active = activeRes.reduce(0, +)
        let total = active + idle
        guard total > 0 else { return nil }
        let freq = active > 0 ? zip(activeRes, table).reduce(0.0) { $0 + Double($1.0) * $1.1 } / Double(active) : 0
        return PerformanceCluster(frequency: freq, maxFrequency: table.max() ?? 0, active: Double(active) / Double(total))
    }
}

// MARK: - GPU load

enum PerformanceGPU {
    /// "Device Utilization %" of the graphics accelerator, 0…1.
    static func usage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var found: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            if found == nil,
               let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let v = stats["Device Utilization %"] as? Int {
                found = Double(min(100, max(0, v))) / 100
            }
            IOObjectRelease(service)
        }
        return found
    }
}

// MARK: - Live sampler

/// The sensors, sampled every 2 seconds while something shows them (the Boost and Monitor tabs).
@Observable
@MainActor
final class PerformanceSensors {
    enum Viewer: Hashable {
        case boost, monitor, bench
    }

    nonisolated static let historyLength = 60
    nonisolated static let interval: TimeInterval = 2

    var current = PerformanceSensorSample()
    var chipHistory: [Double] = []
    var powerHistory: [Double] = []
    var gpuHistory: [Double] = []
    var lastSample: Date?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var viewers: Set<Viewer> = []
    @ObservationIgnored private var busy = false

    var isSampling: Bool { timer != nil }

    init() {
        // A snapshot of the real Mac renders before any onAppear: read once now (twice for the frequencies).
        if Snapshot.isActive && !DemoData.isEnabled {
            _ = PerformanceSensorReader.shared.sample()
            usleep(300_000)
            record(PerformanceSensorReader.shared.sample())
        }
    }

    func show(_ viewer: Viewer, _ visible: Bool) {
        guard !Snapshot.isActive, !DemoData.isEnabled else { return }
        if visible { viewers.insert(viewer) } else { viewers.remove(viewer) }
        if viewers.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            refresh()
            let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    // A window covered, minimised or on another Space keeps its pages: nothing to read for them.
                    guard AppContext.mainWindow?.occlusionState.contains(.visible) ?? true else { return }
                    self?.refresh()
                }
            }
            t.tolerance = 0.4
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// One reading now, off the main thread.
    func refresh() {
        guard !busy, !DemoData.isEnabled else { return }
        busy = true
        Task {
            let s = await Task.detached(priority: .utility) { PerformanceSensorReader.shared.sample() }.value
            busy = false
            record(s)
        }
    }

    func record(_ s: PerformanceSensorSample) {
        current = s
        lastSample = Date()
        if let t = s.chipTemp { push(t, to: &chipHistory) }
        if let w = s.systemPower { push(w, to: &powerHistory) }
        if let g = s.gpuUsage { push(g, to: &gpuHistory) }
    }

    private func push(_ v: Double, to array: inout [Double]) {
        array.append(v)
        if array.count > Self.historyLength { array.removeFirst(array.count - Self.historyLength) }
    }

    func loadDemo() {
        current = PerformanceDemo.sensors()
        let h = PerformanceDemo.histories()
        chipHistory = h.chip
        powerHistory = h.power
        gpuHistory = h.gpu
        lastSample = Date()
    }
}
