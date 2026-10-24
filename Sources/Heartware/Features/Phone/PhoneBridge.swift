import Foundation

/// Apple's private MobileDevice framework, the one Finder uses to talk to an iPhone, loaded at run time (coconutBattery
/// and iMazing go through it too). It needs no Developer Mode: the iPhone only has to trust the Mac.
/// Everything here reads: name, model, iOS, storage, battery, backup. Should a future macOS change it, `isAvailable`
/// turns false and the page keeps what ImageCaptureCore (public) shows: the photos and videos.
enum PhoneBridge {
    typealias Device = UnsafeMutableRawPointer
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

    private typealias Subscribe = @convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    private typealias Call = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias Identifier = @convention(c) (Device) -> Unmanaged<CFString>?
    private typealias CopyValue = @convention(c) (Device, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias StartService = @convention(c) (Device, CFString, CFDictionary?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    private typealias Send = @convention(c) (UnsafeMutableRawPointer, CFPropertyList, Int) -> Int32
    private typealias Receive = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Unmanaged<CFPropertyList>?>, UnsafeMutablePointer<Int>?) -> Int32
    private typealias Invalidate = @convention(c) (UnsafeMutableRawPointer) -> Void

    /// The functions used, all found or none (a partial set would be a framework this code does not know).
    private struct Functions {
        let subscribe: Subscribe
        let unsubscribe, interface, connect, disconnect, isPaired, validate, pair, startSession, stopSession: Call
        let identifier: Identifier
        let copyValue: CopyValue
        let startService: StartService
        let send: Send
        let receive: Receive
        let invalidate: Invalidate

        init?() {
            guard let h = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW) else { return nil }
            func f<T>(_ name: String, _: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
            guard let subscribe = f("AMDeviceNotificationSubscribe", Subscribe.self),
                  let unsubscribe = f("AMDeviceNotificationUnsubscribe", Call.self),
                  let interface = f("AMDeviceGetInterfaceType", Call.self),
                  let connect = f("AMDeviceConnect", Call.self),
                  let disconnect = f("AMDeviceDisconnect", Call.self),
                  let isPaired = f("AMDeviceIsPaired", Call.self),
                  let validate = f("AMDeviceValidatePairing", Call.self),
                  let pair = f("AMDevicePair", Call.self),
                  let startSession = f("AMDeviceStartSession", Call.self),
                  let stopSession = f("AMDeviceStopSession", Call.self),
                  let identifier = f("AMDeviceCopyDeviceIdentifier", Identifier.self),
                  let copyValue = f("AMDeviceCopyValue", CopyValue.self),
                  let startService = f("AMDeviceSecureStartService", StartService.self),
                  let send = f("AMDServiceConnectionSendMessage", Send.self),
                  let receive = f("AMDServiceConnectionReceiveMessage", Receive.self),
                  let invalidate = f("AMDServiceConnectionInvalidate", Invalidate.self)
            else { return nil }
            (self.subscribe, self.unsubscribe, self.interface, self.connect, self.disconnect) = (subscribe, unsubscribe, interface, connect, disconnect)
            (self.isPaired, self.validate, self.pair, self.startSession, self.stopSession) = (isPaired, validate, pair, startSession, stopSession)
            (self.identifier, self.copyValue, self.startService) = (identifier, copyValue, startService)
            (self.send, self.receive, self.invalidate) = (send, receive, invalidate)
        }
    }

    private static let fns = Functions()
    /// Every call to the framework goes through this queue, one at a time and never on the main thread.
    static let queue = DispatchQueue(label: "heartware.phone.device", qos: .userInitiated)

    static var isAvailable: Bool { fns != nil }

    // MARK: Plugged and unplugged

    enum Event { case attached, detached }

    /// Starts listening (on the main run loop). `context` comes back with each event; the device pointer is only valid
    /// during the call: `retain` it to keep it.
    static func subscribe(_ callback: Callback, context: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
        guard let fns else { return nil }
        var note: UnsafeMutableRawPointer?
        return fns.subscribe(callback, 0, 0, context, &note) == 0 ? note : nil
    }

    static func unsubscribe(_ note: UnsafeMutableRawPointer) {
        _ = fns?.unsubscribe(note)
    }

    /// What a notification carries: the device, and whether it came or went (1 and 2; 3 is the end of the subscription).
    static func event(_ info: UnsafeMutableRawPointer) -> (device: Device, event: Event)? {
        let device = info.load(as: Device.self)
        switch info.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UInt32.self) {
        case 1: return (device, .attached)
        case 2: return (device, .detached)
        default: return nil
        }
    }

    /// A device handed to `queue`, the only place it is used from.
    struct Handle: @unchecked Sendable { let device: Device }

    static func retain(_ d: Device) { _ = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(d)).retain() }
    static func release(_ d: Device) { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(d)).release() }

    static func identifier(_ d: Device) -> String? { fns?.identifier(d)?.takeRetainedValue() as String? }
    /// By cable, not through « Afficher cet iPhone en Wi-Fi ».
    static func isUSB(_ d: Device) -> Bool { fns?.interface(d) == 1 }

    // MARK: Reading

    enum Reading {
        case info(PhoneInfo)
        /// Plugged, but it has not trusted this Mac yet (or was locked when asked).
        case untrusted
        case failed
    }

    /// Reads everything the page shows, in about a second. Call on `queue`.
    static func read(_ d: Device, udid: String) -> Reading {
        guard let fns, fns.connect(d) == 0 else { return .failed }
        defer { _ = fns.disconnect(d) }
        guard fns.isPaired(d) == 1, fns.validate(d) == 0, fns.startSession(d) == 0 else { return .untrusted }
        defer { _ = fns.stopSession(d) }
        func value(_ domain: String?, _ key: String?) -> Any? { fns.copyValue(d, domain as CFString?, key as CFString?)?.takeRetainedValue() }
        let backup = value("com.apple.mobile.backup", nil) as? [String: Any]
        let info = PhoneInfo(udid: udid,
                             name: value(nil, "DeviceName") as? String ?? "iPhone",
                             productType: value(nil, "ProductType") as? String ?? "",
                             deviceClass: value(nil, "DeviceClass") as? String ?? "iPhone",
                             iosVersion: value(nil, "ProductVersion") as? String ?? "",
                             build: value(nil, "BuildVersion") as? String ?? "",
                             storage: PhoneRules.storage(value("com.apple.disk_usage", nil) as? [String: Any] ?? [:]),
                             battery: PhoneRules.battery(lockdown: value("com.apple.mobile.battery", nil) as? [String: Any] ?? [:],
                                                         registry: batteryRegistry(d)),
                             cloudBackup: (backup?["CloudBackupEnabled"] as? NSNumber)?.boolValue,
                             localBackup: localBackupDate(udid))
        return .info(info)
    }

    /// Shows « Faire confiance à cet ordinateur ? » on the iPhone (it must be unlocked). Call on `queue`.
    static func askTrust(_ d: Device) {
        guard let fns, fns.connect(d) == 0 else { return }
        _ = fns.pair(d)
        _ = fns.disconnect(d)
    }

    /// The battery gauge, through the diagnostics service: cycles and capacities (inside `BatteryData` on recent iPhones).
    private static func batteryRegistry(_ d: Device) -> [String: Any] {
        for request in [["Request": "IORegistry", "EntryName": "AppleSmartBattery"], ["Request": "IORegistry", "EntryClass": "IOPMPowerSource"]] {
            if let reply = diagnostics(d, request),
               let registry = (reply["Diagnostics"] as? [String: Any])?["IORegistry"] as? [String: Any], !registry.isEmpty {
                return registry
            }
        }
        return [:]
    }

    private static func diagnostics(_ d: Device, _ request: [String: Any]) -> [String: Any]? {
        guard let fns else { return nil }
        var connection: UnsafeMutableRawPointer?
        guard fns.startService(d, "com.apple.mobile.diagnostics_relay" as CFString, nil, &connection) == 0, let c = connection else { return nil }
        defer {
            _ = fns.send(c, ["Request": "Goodbye"] as CFDictionary, Int(PropertyListSerialization.PropertyListFormat.xml.rawValue))
            fns.invalidate(c)
            release(c)
        }
        guard fns.send(c, request as CFDictionary, Int(PropertyListSerialization.PropertyListFormat.xml.rawValue)) == 0 else { return nil }
        var reply: Unmanaged<CFPropertyList>?
        guard fns.receive(c, &reply, nil) == 0 else { return nil }
        return reply?.takeRetainedValue() as? [String: Any]
    }

    /// The last backup to this Mac, from Finder's folder (readable with Full Disk Access only).
    private static func localBackupDate(_ udid: String) -> Date? {
        let plist = FS.home + "/Library/Application Support/MobileSync/Backup/\(udid)/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return dict["Last Backup Date"] as? Date
    }
}
