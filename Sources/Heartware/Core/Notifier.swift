import Foundation
import UserNotifications

/// The only way modules post a notification. Throttled per id, silent in demo mode,
/// and shown even while the app is in front (thanks to the delegate).
@MainActor
enum Notifier {
    private static var last: [String: Date] = [:]
    private static let delegate = ForegroundDelegate()

    /// Notifications need a real .app bundle (not `swift run`).
    static var available: Bool {
        !DemoData.isEnabled && Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// Call once at launch.
    static func setUp() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts at most once per `throttle` seconds for the same `id`.
    static func post(id: String, title: String, body: String, throttle: TimeInterval = 6 * 3600) {
        guard available else { return }
        if let d = last[id], Date().timeIntervalSince(d) < throttle { return }
        last[id] = Date()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id + "." + UUID().uuidString,
                                                                     content: content, trigger: nil))
    }

    private final class ForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }
    }
}
