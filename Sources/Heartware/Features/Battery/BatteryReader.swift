import Foundation
import IOKit
import IOKit.ps
import ObjectiveC

/// Everything the battery page shows, read from IOKit (no permission needed).
struct BatteryReading: Equatable {
    /// What macOS shows in the menu bar, 0…100.
    var percent: Int
    var isCharging: Bool
    var onAC: Bool
    var fullyCharged = false
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var cycleCount: Int?
    /// Cycles the battery is designed for (1 000 on recent Macs).
    var designCycles: Int?
    /// mAh when new, and today.
    var designCapacity: Int?
    var maxCapacity: Int?
    var temperature: Double?
    /// V, and A (negative while the battery gives power).
    var voltage: Double?
    var amperage: Double?
    /// What the charger gives right now (W), and its name.
    var adapterWatts: Int?
    var adapterName: String?

    /// Maximum capacity against design capacity, as System Settings shows it.
    var health: Double? {
        guard let d = designCapacity, let m = maxCapacity, d > 0, m > 0 else { return nil }
        return min(1, Double(m) / Double(d))
    }

    /// W going into the battery (positive) or out of it (negative).
    var batteryPower: Double? {
        guard let v = voltage, let a = amperage else { return nil }
        return v * a
    }

    /// Plugged in, not charging and not full: something (a charge limit, heat, Optimised Charging) holds the charge.
    var isHeld: Bool { onAC && !isCharging && !fullyCharged && percent < 100 }
}

enum BatteryReader {
    /// nil on a Mac without a battery.
    static func read() -> BatteryReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (desc["Type"] as? String) == "InternalBattery" else { continue }
            let current = desc["Current Capacity"] as? Int ?? 0
            let maxCap = max(1, desc["Max Capacity"] as? Int ?? 100)
            func minutes(_ key: String) -> Int? { (desc[key] as? Int).flatMap { $0 > 0 && $0 < 6000 ? $0 : nil } }
            var r = BatteryReading(percent: min(100, max(0, Int((Double(current) * 100 / Double(maxCap)).rounded()))),
                                   isCharging: desc["Is Charging"] as? Bool ?? false,
                                   onAC: (desc["Power Source State"] as? String) == "AC Power",
                                   fullyCharged: desc["Is Charged"] as? Bool ?? false,
                                   minutesToEmpty: minutes("Time to Empty"), minutesToFull: minutes("Time to Full Charge"))
            readController(&r)
            return r
        }
        return nil
    }

    /// Cycles, capacities, voltage, current and charger from the battery controller.
    private static func readController(_ r: inout BatteryReading) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return }
        let nested = d["BatteryData"] as? [String: Any] ?? [:]
        // Signed values (the current) come as 64-bit numbers: -44 mA reads 18446744073709551572 as an unsigned one.
        func number(_ k: String) -> Int64? { ((d[k] ?? nested[k]) as? NSNumber)?.int64Value }
        func positive(_ k: String) -> Int? { number(k).flatMap { $0 > 0 && $0 < 1_000_000 ? Int($0) : nil } }
        r.cycleCount = number("CycleCount").flatMap { $0 >= 0 && $0 < 100_000 ? Int($0) : nil }
        r.designCycles = positive("DesignCycleCount9C")
        r.designCapacity = positive("DesignCapacity")
        r.maxCapacity = positive("NominalChargeCapacity") ?? positive("AppleRawMaxCapacity")
        if let t = number("Temperature"), t > 0 { r.temperature = Double(t) / 100 }
        if let v = positive("Voltage") { r.voltage = Double(v) / 1000 }
        if let a = number("Amperage"), abs(a) < 20_000 { r.amperage = Double(a) / 1000 }
        if r.onAC, let adapter = d["AdapterDetails"] as? [String: Any] {
            r.adapterWatts = (adapter["Watts"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            let name = ((adapter["Name"] as? String) ?? (adapter["Description"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            r.adapterName = name.isEmpty ? nil : name
        }
    }
}

// MARK: - macOS' charge limit

/// What macOS says about its own charge limit (Réglages Système › Batterie › Limite de charge).
struct BatteryLimitState: Equatable {
    /// This Mac and this version of macOS have the setting.
    var supported: Bool
    /// The limit, in %: 100 means none.
    var limit: Int?
    /// The values the setting offers (80, 85, 90, 95, 100).
    var choices: [Int]
}

/// macOS' charge limit, through PowerUI: the private framework behind the Battery settings, looked up at run time
/// (like the HID sensors). Reading needs nothing; macOS may keep the change for System Settings alone, and then
/// `set` says so instead of failing silently. The calls go to a system agent: never from the main thread.
enum BatteryChargeLimit {
    private static let queue = DispatchQueue(label: "heartware.battery.limit")

    private typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    private typealias InitName = @convention(c) (Unmanaged<AnyObject>, Selector, NSString) -> Unmanaged<AnyObject>?
    private typealias GetBool = @convention(c) (AnyObject, Selector) -> ObjCBool
    private typealias GetLimit = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> UInt8
    private typealias GetObject = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?
    private typealias SetLimit = @convention(c) (AnyObject, Selector, UInt8, AutoreleasingUnsafeMutablePointer<NSError?>?) -> ObjCBool

    /// The PowerUI client, made once (nil without the framework).
    nonisolated(unsafe) private static var cached: AnyObject??

    private static func client() -> AnyObject? {
        if let cached { return cached }
        var made: AnyObject?
        if dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
           let cls = NSClassFromString("PowerUISmartChargeClient"),
           let allocMethod = class_getClassMethod(cls, NSSelectorFromString("alloc")) {
            let initSel = NSSelectorFromString("initWithClientName:")
            if class_respondsToSelector(cls, initSel), let initIMP = class_getMethodImplementation(cls, initSel) {
                // alloc gives an object init takes over: neither is managed by Swift until init returns.
                let alloc = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)
                if let raw = alloc(cls, NSSelectorFromString("alloc")) {
                    made = unsafeBitCast(initIMP, to: InitName.self)(raw, initSel, "Clean My Claude" as NSString)?.takeRetainedValue()
                }
            }
        }
        cached = .some(made)
        return made
    }

    private static func imp<T>(_ object: AnyObject, _ name: String, as type: T.Type) -> (Selector, T)? {
        let sel = NSSelectorFromString(name)
        guard let cls = object_getClass(object), class_respondsToSelector(cls, sel),
              let imp = class_getMethodImplementation(cls, sel) else { return nil }
        return (sel, unsafeBitCast(imp, to: type))
    }

    /// Reads the setting. Blocks for a moment (a call to a system agent): call it off the main thread.
    static func read() -> BatteryLimitState {
        if DemoData.isEnabled { return BatteryLimitState(supported: true, limit: 80, choices: BatteryRules.defaultChoices) }
        return queue.sync {
            autoreleasepool {
                guard let c = client(), let (supSel, supported) = imp(c, "isMCLSupported", as: GetBool.self),
                      supported(c, supSel).boolValue else { return BatteryLimitState(supported: false, limit: nil, choices: []) }
                var limit: Int?
                if let (sel, get) = imp(c, "getMCLLimitWithError:", as: GetLimit.self) {
                    var error: NSError?
                    let v = Int(get(c, sel, &error))
                    if error == nil, (50...100).contains(v) { limit = v }
                }
                var choices = BatteryRules.defaultChoices
                if let (sel, get) = imp(c, "availableChargeLimitsWithError:", as: GetObject.self) {
                    var error: NSError?
                    let list = (get(c, sel, &error)?.takeUnretainedValue() as? [NSNumber])?.map(\.intValue).filter { (50...100).contains($0) }
                    if let list, !list.isEmpty { choices = list.sorted() }
                }
                return BatteryLimitState(supported: true, limit: limit, choices: choices)
            }
        }
    }

    /// Asks macOS to stop charging at `percent`. nil when done, else why not.
    static func set(_ percent: Int) -> String? {
        guard !DemoData.isEnabled else { return DemoData.refusal }
        guard (50...100).contains(percent) else { return "Limite hors des valeurs possibles." }
        return queue.sync {
            autoreleasepool {
                guard let c = client(), let (sel, set) = imp(c, "setMCLLimit:error:", as: SetLimit.self) else {
                    return "Ton macOS n'a pas de limite de charge."
                }
                var error: NSError?
                if set(c, sel, UInt8(percent), &error).boolValue, error == nil { return nil }
                return error?.localizedDescription ?? "macOS a refusé le changement."
            }
        }
    }

    static let settingsURL = "x-apple.systempreferences:com.apple.Battery-Settings.extension"
}
