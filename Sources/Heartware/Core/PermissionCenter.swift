import AppKit
import ApplicationServices
import CoreLocation
import Security
import UserNotifications
import Network
import Photos

/// Every macOS permission the app may use, with its state and a way to ask for all of them in one go
/// (Réglages › Autorisations › « Tout autoriser »). Nothing is asked without that click.
enum PermissionKind: String, CaseIterable, Identifiable {
    case notifications, location, finder, systemEvents, safari, folders, localNetwork, photos, accessibility, fullDiskAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notifications: return "Notifications"
        case .location: return "Localisation"
        case .finder: return "Piloter le Finder"
        case .systemEvents: return "Piloter Événements système"
        case .safari: return "Piloter Safari"
        case .folders: return "Bureau, Documents et Téléchargements"
        case .localNetwork: return "Réseau local"
        case .photos: return "Photos"
        case .accessibility: return "Accessibilité"
        case .fullDiskAccess: return "Accès complet au disque"
        }
    }

    var purpose: String {
        switch self {
        case .notifications: return "Alertes de disque, de mémoire ou de batterie, bilan des automatisations"
        case .location: return "Afficher le nom du réseau Wi-Fi (ta position n'est jamais lue)"
        case .finder: return "Mettre à la Corbeille les apps installées par un administrateur, vider la Corbeille, la roue du Convertisseur sur les fichiers sélectionnés"
        case .systemEvents: return "Mode sombre, redémarrer, éteindre, masquer les autres apps depuis le lanceur"
        case .safari: return "Passer YouTube et Twitch de Safari au lecteur sans pub, détacher la vidéo que tu regardes dans sa petite fenêtre"
        case .folders: return "Index des fichiers du lanceur, rangement de Téléchargements, conversions et copies du Convertisseur"
        case .localNetwork: return "Mesurer la latence de ta box et des appareils de ton réseau"
        case .photos: return "Supprimer de ta photothèque iCloud les photos de l'iPhone que tu as triées"
        case .accessibility: return "Ranger les fenêtres au clavier, coller depuis l'historique du presse-papiers, l'image dans l'image de Safari"
        case .fullDiskAccess: return "Voir la Corbeille, Mail, Safari et les autorisations des autres apps"
        }
    }

    var symbol: String {
        switch self {
        case .notifications: return "bell"
        case .location: return "location"
        case .finder: return "face.smiling"
        case .systemEvents: return "gearshape.2"
        case .safari: return "safari"
        case .folders: return "folder"
        case .localNetwork: return "wifi"
        case .photos: return "photo.on.rectangle"
        case .accessibility: return "accessibility"
        case .fullDiskAccess: return "externaldrive.badge.checkmark"
        }
    }

    /// Granted in System Settings by the user (macOS shows no prompt for these): the pane is opened for them.
    var needsSettings: Bool { self == .accessibility || self == .fullDiskAccess }

    var settingsURL: String {
        switch self {
        case .notifications: return "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .location: return "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        case .finder, .systemEvents, .safari: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .folders: return "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        case .localNetwork: return "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        case .photos: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
        case .accessibility: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .fullDiskAccess: return Permissions.fullDiskAccessURL
        }
    }
}

enum PermissionState: Equatable {
    case granted, denied, notAsked, asked

    var label: String {
        switch self {
        case .granted: return "Accordée"
        case .denied: return "Refusée"
        case .notAsked: return "Pas encore demandée"
        case .asked: return "Demandée"
        }
    }
}

@Observable
@MainActor
final class PermissionCenter {
    static let shared = PermissionCenter()

    var states: [PermissionKind: PermissionState] = [:]
    /// The step of « Tout autoriser » in progress.
    var current: PermissionKind?
    var isRunning = false
    /// Waiting for the user to flip a switch in System Settings (since when: after a few seconds, the row explains
    /// what to do when the switch is already on).
    var waitingForSettings = false
    var waitingSince: Date?
    /// After a reset, macOS may leave the app out of the list: the user adds it back (+, or a drag from the Finder).
    var addBack: PermissionKind?
    /// Answers macOS gave that cannot be read again later (System Events not running, local network).
    @ObservationIgnored private var remembered: [PermissionKind: PermissionState] = [:]
    @ObservationIgnored private var lastNetworkCheck = Date.distantPast
    @ObservationIgnored private var skipWait = false
    /// One location manager for every check (each new one costs a round trip to the location daemon), made on first use.
    @ObservationIgnored private var locationManager: CLLocationManager?

    private var locationStatus: CLAuthorizationStatus {
        let manager = locationManager ?? CLLocationManager()
        locationManager = manager
        return manager.authorizationStatus
    }

    private static let askedKey = "permissions.asked"
    private static let safari = "com.apple.Safari"

    var grantedCount: Int { PermissionKind.allCases.filter { states[$0] == .granted }.count }

    // MARK: State

    func refresh() async {
        if DemoData.isEnabled {
            for k in PermissionKind.allCases { states[k] = .granted }
            return
        }
        var s: [PermissionKind: PermissionState] = [:]
        // Outside an app bundle the notification center throws: it is only asked for in the assembled app.
        if Notifier.available {
            let notif = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            s[.notifications] = notif == .authorized || notif == .provisional ? .granted : (notif == .denied ? .denied : .notAsked)
        } else {
            s[.notifications] = .notAsked
        }
        switch locationStatus {
        case .authorizedAlways, .authorized: s[.location] = .granted
        case .denied, .restricted: s[.location] = .denied
        default: s[.location] = .notAsked
        }
        let asked = Set(UserDefaults.standard.stringArray(forKey: Self.askedKey) ?? [])
        s[.finder] = await Self.automation("com.apple.finder")
        // System Events only answers while it runs: not running and already asked means "asked".
        let events = await Self.automation("com.apple.systemevents")
        if events == .notAsked, asked.contains(PermissionKind.systemEvents.rawValue) {
            s[.systemEvents] = remembered[.systemEvents] ?? .asked // not running right now: the last answer
        } else {
            s[.systemEvents] = events
        }
        s[.photos] = PhonePhotoLibrary.access
        // Safari too, and it is not always open.
        let safari = await Self.automation(Self.safari)
        if safari == .notAsked, asked.contains(PermissionKind.safari.rawValue) {
            s[.safari] = remembered[.safari] ?? .asked
        } else {
            s[.safari] = safari
        }
        let fda = Permissions.hasFullDiskAccess
        s[.fullDiskAccess] = fda ? .granted : .notAsked
        s[.accessibility] = AXIsProcessTrusted() ? .granted : .notAsked
        // macOS gives no way to read these two without asking: what was asked is remembered. The folders are read
        // off the main thread, and not while macOS may still be showing its question.
        if fda {
            s[.folders] = .granted
        } else if !asked.contains(PermissionKind.folders.rawValue) {
            s[.folders] = .notAsked
        } else if isRunning && current == .folders {
            s[.folders] = states[.folders] ?? .asked
        } else {
            s[.folders] = await Task.detached { Self.foldersReadable() }.value ? .granted : .denied
        }
        if asked.contains(PermissionKind.localNetwork.rawValue) {
            s[.localNetwork] = remembered[.localNetwork] ?? states[.localNetwork] ?? .asked
            // Checked again now and then (a connection to the box; no prompt once macOS has its answer).
            if Date().timeIntervalSince(lastNetworkCheck) > 20, !(isRunning && current == .localNetwork) {
                lastNetworkCheck = Date()
                Task {
                    let state = await Self.localNetwork(wait: 3)
                    if state != .asked { remembered[.localNetwork] = state; states[.localNetwork] = state }
                }
            }
        } else {
            s[.localNetwork] = .notAsked
        }
        states = s
    }

    /// Asks macOS whether the app may send Apple events to an app, without showing anything.
    nonisolated static func automation(_ bundleID: String, ask: Bool = false) async -> PermissionState {
        await Task.detached(priority: .userInitiated) {
            var target = AEAddressDesc()
            let created = bundleID.withCString { AECreateDesc(DescType(typeApplicationBundleID), $0, strlen($0), &target) }
            guard created == noErr else { return PermissionState.notAsked }
            defer { AEDisposeDesc(&target) }
            let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
            switch status {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .denied
            default: return .notAsked // not decided yet, or the app is not running
            }
        }.value
    }

    nonisolated private static func foldersReadable() -> Bool {
        ["Desktop", "Documents", "Downloads"].allSatisfy { (try? FileManager.default.contentsOfDirectory(atPath: FS.home + "/" + $0)) != nil }
    }

    // MARK: Asking

    /// Asks for everything still missing (or only `kinds`, in their order), one after the other: macOS' own prompts
    /// first, then the two System Settings switches (the pane opens and the app waits until the switch is on, or « Passer »).
    func requestAll(_ kinds: [PermissionKind] = PermissionKind.allCases) async {
        guard !isRunning, !DemoData.isEnabled else { return }
        isRunning = true
        defer {
            isRunning = false
            current = nil
            waitingForSettings = false
        }
        await refresh()
        for kind in kinds where states[kind] != .granted {
            current = kind
            await request(kind)
            await refresh()
        }
    }

    func request(_ kind: PermissionKind) async {
        guard !DemoData.isEnabled else { return }
        switch kind {
        case .notifications:
            guard Notifier.available else { return }
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        case .location:
            LocationAsker.shared.ask()
            await wait(seconds: 30) { self.locationStatus != .notDetermined }
        case .finder:
            _ = await Self.automation("com.apple.finder", ask: true)
        case .systemEvents:
            remember(.systemEvents)
            // System Events only answers while it runs: launched in the background first, then macOS asks.
            let url = URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.addsToRecentItems = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            await wait(seconds: 5) { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemevents").isEmpty }
            remembered[.systemEvents] = await Self.automation("com.apple.systemevents", ask: true)
        case .safari:
            remember(.safari)
            // macOS only asks while Safari runs: opened hidden if it is not, and closed again after the answer.
            var launched: NSRunningApplication?
            if NSRunningApplication.runningApplications(withBundleIdentifier: Self.safari).isEmpty,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.safari) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.hides = true
                config.addsToRecentItems = false
                launched = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
                await wait(seconds: 5) { launched?.isFinishedLaunching == true }
            }
            remembered[.safari] = await Self.automation(Self.safari, ask: true)
            if let launched, launched.isHidden { launched.terminate() } // left alone if the user turned to it meanwhile
        case .folders:
            remember(.folders)
            // Reading each folder makes macOS ask (without Full Disk Access).
            _ = await Task.detached(priority: .userInitiated) { Self.foldersReadable() }.value
        case .localNetwork:
            remember(.localNetwork)
            lastNetworkCheck = Date()
            // A connection from the app itself to the box: macOS asks, and the outcome says whether it is allowed.
            remembered[.localNetwork] = await Self.localNetwork(wait: 40)
        case .photos:
            _ = await PhonePhotoLibrary.requestAccess()
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) {
                Finder.open(kind.settingsURL)
                await waitForSettings { AXIsProcessTrusted() }
            }
        case .fullDiskAccess:
            Finder.open(kind.settingsURL)
            await waitForSettings { Permissions.hasFullDiskAccess }
        }
    }

    /// The switch is on in System Settings but macOS does not apply it: it remembers an older build of the app
    /// (another signature). Its entry is removed (`tccutil reset`, for this app only), then asked again.
    func reset(_ kind: PermissionKind) async {
        guard !DemoData.isEnabled, let bundleID = Bundle.main.bundleIdentifier else { return }
        let service: String
        switch kind {
        case .accessibility: service = "Accessibility"
        case .fullDiskAccess: service = "SystemPolicyAllFiles"
        case .finder, .systemEvents, .safari: service = "AppleEvents"
        default: return
        }
        let r = await Task.detached { Shell.run("/usr/bin/tccutil", ["reset", service, bundleID], timeout: 10) }.value
        ActionLog.write("AUTORISATION RÉINITIALISÉE \(service) : \(r.ok ? "ok" : r.all.trimmingCharacters(in: .whitespacesAndNewlines))")
        skipWait = true // a wait in progress stops; the new request below waits again
        try? await Task.sleep(nanoseconds: 600_000_000)
        if kind.needsSettings {
            // macOS does not always put the app back in the list by itself: shown in the Finder, ready to be
            // dragged in (or picked after +), with System Settings opened above.
            addBack = kind
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Bundle.main.bundlePath)])
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        await request(kind)
        addBack = nil
        await refresh()
    }

    /// Lets « Tout autoriser » go on without waiting for a System Settings switch.
    func skip() {
        skipWait = true
    }

    private func waitForSettings(_ done: @escaping @MainActor () -> Bool) async {
        waitingForSettings = true
        waitingSince = Date()
        skipWait = false
        await wait(seconds: 180) { done() || self.skipWait }
        waitingForSettings = false
        waitingSince = nil
    }

    /// A cancelled task stops waiting at once: `Task.sleep` would throw right away and the loop would spin on the main
    /// thread until `end`.
    private func wait(seconds: Double, until done: @escaping @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done(), !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func remember(_ kind: PermissionKind) {
        var asked = Set(UserDefaults.standard.stringArray(forKey: Self.askedKey) ?? [])
        asked.insert(kind.rawValue)
        UserDefaults.standard.set(Array(asked), forKey: Self.askedKey)
    }

    // MARK: Local network

    /// Connects to the box (DNS port): reached (even refused) means allowed; "no route" means macOS blocks it.
    /// While macOS shows its question the attempts go on, up to `wait` seconds.
    nonisolated static func localNetwork(wait: Double) async -> PermissionState {
        let route = await Task.detached { Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 5).out }.value
        guard let gateway = route.split(separator: "\n").first(where: { $0.contains("gateway:") })?
            .split(separator: ":").last?.trimmingCharacters(in: .whitespaces), !gateway.isEmpty else { return .asked }
        let end = Date().addingTimeInterval(wait)
        var last = PermissionState.asked
        repeat {
            last = await connect(gateway, timeout: 3)
            if last == .granted { return .granted }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        } while Date() < end && !Task.isCancelled
        return last
    }

    nonisolated private static func connect(_ host: String, timeout: Double) async -> PermissionState {
        final class Once: @unchecked Sendable {
            let lock = NSLock()
            var done = false
            func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        return await withCheckedContinuation { continuation in
            let once = Once()
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 53, using: .tcp)
            let queue = DispatchQueue(label: "heartware.localnetwork")
            @Sendable func finish(_ s: PermissionState) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: s)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.granted)
                case .failed(let e), .waiting(let e):
                    if case .posix(let code) = e {
                        if code == .ECONNREFUSED || code == .ECONNRESET { finish(.granted) } // the box answered
                        else if code == .EHOSTUNREACH || code == .ENETUNREACH || code == .EPERM { finish(.denied) }
                    } else if case .dns(let code) = e, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                        finish(.denied)
                    }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.asked) }
        }
    }

    // MARK: Signature

    /// True when the app is signed with a real (even local) certificate: macOS then keeps its permissions
    /// from one build to the next. Ad hoc signatures (and `swift build`) change at every build.
    nonisolated static var hasStableSignature: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = dict[kSecCodeInfoCertificates as String] as? [Any] ?? []
        return !certificates.isEmpty && flags & 0x2 == 0 // 0x2: kSecCodeSignatureAdhoc
    }
}
