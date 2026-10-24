import AppKit
import ApplicationServices
import CoreLocation

/// The macOS permissions modules may need, beyond Full Disk Access (`Permissions`).
/// Ask only after a click, through `PermissionCard`.
enum AppPermission: String, CaseIterable {
    case fullDiskAccess, accessibility, location, notifications

    var title: String {
        switch self {
        case .fullDiskAccess: return "Accès complet au disque"
        case .accessibility: return "Accessibilité"
        case .location: return "Service de localisation"
        case .notifications: return "Notifications"
        }
    }

    var settingsURL: String {
        switch self {
        case .fullDiskAccess: return Permissions.fullDiskAccessURL
        case .accessibility: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .location: return "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        case .notifications: return "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        }
    }

    /// One manager for every check: each new one costs a round trip to the location daemon (the Network page asks
    /// every few seconds while the Wi-Fi name is hidden).
    @MainActor private static let locationManager = CLLocationManager()

    @MainActor
    var isGranted: Bool {
        if DemoData.isEnabled { return true }
        switch self {
        case .fullDiskAccess: return Permissions.hasFullDiskAccess
        case .accessibility: return AXIsProcessTrusted()
        case .location:
            let s = Self.locationManager.authorizationStatus
            return s == .authorizedAlways || s == .authorized
        case .notifications: return Notifier.available
        }
    }

    /// Shows macOS' own prompt when there is one, else opens the right Settings pane.
    @MainActor
    func request() {
        guard !DemoData.isEnabled else { return }
        switch self {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { Finder.open(settingsURL) }
        case .location:
            LocationAsker.shared.ask()
        case .notifications:
            Notifier.requestPermission()
        case .fullDiskAccess:
            Finder.open(settingsURL)
        }
    }
}

/// Keeps the CLLocationManager alive while macOS shows its prompt.
@MainActor
final class LocationAsker: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAsker()
    private let manager = CLLocationManager()

    func ask() {
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
    }
}
