import AppKit
import CoreGraphics

/// The pointer that hides by itself. Kept in its own file ("toolbox-cursor"): a field added to `ToolboxSettings`
/// would make the older toolbox file unreadable.
struct ToolboxCursorSettings: Codable, Equatable {
    var enabled = false
    /// Seconds without moving the mouse before the pointer hides.
    var delay = 5
    /// Only while one of `apps` is in front (else in every app).
    var onlyApps = false
    var apps: [ToolboxCursorApp] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ToolboxCursorSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        delay = ToolboxCursorRule.clamp((try? c.decodeIfPresent(Int.self, forKey: .delay)) ?? d.delay)
        onlyApps = (try? c.decodeIfPresent(Bool.self, forKey: .onlyApps)) ?? d.onlyApps
        apps = (try? c.decodeIfPresent([ToolboxCursorApp].self, forKey: .apps)) ?? d.apps
    }
}

struct ToolboxCursorApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    /// Where the app was when it was added (for its icon).
    var path: String?

    var id: String { bundleID }
}

/// A request typed in the launcher after « curseur ».
enum ToolboxCursorRequest: Equatable {
    case on, off
    case seconds(Int)
}

/// What the hider does next.
enum ToolboxCursorStep: Equatable {
    case hide
    /// Look again in that many seconds (when the delay may have run out).
    case check(after: TimeInterval)
    /// The app in front is not one of the chosen apps: nothing to do until another app comes to the front.
    case waitForApp
}

/// The rules, apart from the window server (checked by `--selftest`).
enum ToolboxCursorRule {
    static let delays = [2, 3, 5, 10, 30, 60]

    static func clamp(_ seconds: Int) -> Int { min(600, max(1, seconds)) }

    static func label(_ seconds: Int) -> String {
        seconds >= 60 && seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
    }

    /// What follows « curseur » in the launcher: "off", nothing or "on", or a delay ("10", "10 s", "1 min").
    static func parse(_ text: String) -> ToolboxCursorRequest? {
        let t = Fuzzy.fold(text).trimmingCharacters(in: .whitespaces)
        if t.isEmpty || ["on", "oui", "actif", "activer", "cacher", "masquer"].contains(t) { return .on }
        if ["off", "non", "stop", "arret", "arreter", "desactiver", "montrer", "afficher", "visible"].contains(t) { return .off }
        let digits = t.prefix { $0.isNumber }
        guard let n = Int(digits), n > 0 else { return nil }
        let unit = t.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        switch unit {
        case "", "s", "sec", "secs", "seconde", "secondes": return n <= 600 ? .seconds(n) : nil
        case "m", "mn", "min", "mins", "minute", "minutes": return n <= 10 ? .seconds(n * 60) : nil
        default: return nil
        }
    }

    static func applies(_ s: ToolboxCursorSettings, frontmost: String?) -> Bool {
        guard s.onlyApps else { return true }
        guard let frontmost else { return false }
        return s.apps.contains { $0.bundleID == frontmost }
    }

    /// `idle`: seconds since the mouse last moved or clicked.
    static func next(idle: TimeInterval, settings s: ToolboxCursorSettings, frontmost: String?) -> ToolboxCursorStep {
        guard applies(s, frontmost: frontmost) else { return .waitForApp }
        let left = Double(s.delay) - idle
        // A quarter of a second at least: never a busy loop, whatever the clock says.
        return left <= 0 ? .hide : .check(after: max(0.25, left))
    }
}

/// Hides the pointer after a while without moving the mouse, and shows it again at the first movement or click.
/// Scrolling and typing leave it hidden: a page can be read or a video paused without it coming back.
///
/// It costs one timer wake-up per delay while the mouse moves, and none at all once hidden (event monitors bring it
/// back). The window server hides the pointer for the app in front only, unless the connection sets
/// "SetsCursorInBackground", a private property looked up at run time (like the HID sensors): without it, only
/// Heartware's own windows would hide it.
@MainActor
final class ToolboxCursorHider {
    private(set) var isHidden = false
    private(set) var isRunning = false
    /// Called when the pointer hides or shows.
    var onChange: (@MainActor (Bool) -> Void)?

    private var settings = ToolboxCursorSettings()
    private var timer: Timer?
    private var monitors: [Any] = []
    /// Who shows the pointer again, the watchdog (the app stopped answering) or the app: exactly one of them.
    private var showClaim: ToolboxCursorClaim?
    private var activation: NSObjectProtocol?
    private static var background: Bool?

    /// Follows the settings: starts, adjusts or stops. Never runs in demo or snapshot modes.
    func update(_ s: ToolboxCursorSettings) {
        settings = s
        guard s.enabled, !DemoData.isEnabled, !Snapshot.isActive else {
            halt()
            return
        }
        if !isRunning {
            isRunning = true
            Self.allowInBackground()
            activation = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }
        // A new delay or a new list of apps counts from now on; a hidden pointer stays hidden until the mouse moves.
        if !isHidden { check() }
    }

    /// Stops watching and shows the pointer again.
    func halt() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        reveal()
    }

    private func check() {
        timer?.invalidate()
        timer = nil
        guard isRunning, !isHidden else { return }
        switch ToolboxCursorRule.next(idle: Self.idleSeconds(), settings: settings,
                                      frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
        case .hide:
            conceal()
        case .check(let seconds):
            let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            t.tolerance = min(0.5, seconds * 0.1)
            RunLoop.main.add(t, forMode: .common)
            timer = t
        case .waitForApp:
            break
        }
    }

    private static let wakeEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                                            .leftMouseDown, .rightMouseDown, .otherMouseDown]

    private func conceal() {
        guard !isHidden, CGDisplayHideCursor(CGMainDisplayID()) == .success else { return }
        isHidden = true
        // Only a mouse event handled here brings the pointer back: if the app hangs meanwhile, the watchdog does, from
        // its own thread (a pointer gone from every app would make the whole Mac look dead).
        let claim = ToolboxCursorClaim()
        showClaim = claim
        MainWatchdog.shared.arm("cursor") {
            if claim.take() { CGDisplayShowCursor(CGMainDisplayID()) }
        }
        // Mouse events reach a global monitor without the Accessibility permission (only keys need it).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: Self.wakeEvents, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: Self.wakeEvents, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.moved() }
            return event
        }) { monitors.append(m) }
        onChange?(true)
    }

    private func moved() {
        reveal()
        check()
    }

    /// One show for each hide: the window server counts them.
    private func reveal() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        guard isHidden else { return }
        MainWatchdog.shared.disarm("cursor")
        if showClaim?.take() ?? true { CGDisplayShowCursor(CGMainDisplayID()) }
        showClaim = nil
        isHidden = false
        onChange?(false)
    }

    /// Seconds since the mouse moved, dragged or clicked anywhere (no permission needed).
    static func idleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    /// Lets this app hide the pointer while another app is in front. False if the private functions are gone.
    @discardableResult
    static func allowInBackground() -> Bool {
        if let background { return background }
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        var ok = false
        if let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
           let connection = dlsym(h, "_CGSDefaultConnection"), let set = dlsym(h, "CGSSetConnectionProperty") {
            let c = unsafeBitCast(connection, to: DefaultConnection.self)()
            ok = unsafeBitCast(set, to: SetProperty.self)(c, c, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
        }
        background = ok
        return ok
    }

    /// For `dump()`: nil until the hider first ran.
    static var backgroundAllowed: Bool? { background }
}

/// Taken once: the pointer hidden once is shown once (the window server counts them).
final class ToolboxCursorClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !taken else { return false }
        taken = true
        return true
    }
}
