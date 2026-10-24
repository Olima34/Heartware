import AppKit
import ApplicationServices

/// The Accessibility calls that read and move another app's window. Needs `AppPermission.accessibility`.
@MainActor
enum WindowsAX {
    struct Target {
        let app: AXUIElement
        let window: AXUIElement
    }

    /// A frozen app answers nothing: give up after half a second instead of blocking the app.
    private static let timeout: Float = 0.5
    private static let enhancedUI = "AXEnhancedUserInterface" as CFString
    private static let fullScreen = "AXFullScreen" as CFString

    /// The focused window of the frontmost app (or of `pid`).
    static func focusedWindow(pid: pid_t? = nil) -> Target? {
        guard let pid = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let window = element(app, kAXFocusedWindowAttribute as CFString) ?? element(app, kAXMainWindowAttribute as CFString) else {
            return nil
        }
        AXUIElementSetMessagingTimeout(window, timeout)
        return Target(app: app, window: window)
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let p = value(window, kAXPositionAttribute as CFString), AXValueGetValue(p, .cgPoint, &origin),
              let s = value(window, kAXSizeAttribute as CFString), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func isFullScreen(_ window: AXUIElement) -> Bool {
        bool(window, fullScreen) == true
    }

    static func isResizable(_ window: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    /// Size, then position, then size again: the first resize may be limited by the old screen,
    /// the second one completes it once the window is in place. Chrome and Electron apps animate
    /// every change while `AXEnhancedUserInterface` is on, so it is switched off meanwhile.
    static func setFrame(_ r: CGRect, of t: Target, resize: Bool) {
        let enhanced = bool(t.app, enhancedUI) == true
        if enhanced { AXUIElementSetAttributeValue(t.app, enhancedUI, kCFBooleanFalse) }
        if resize { setSize(r.size, t.window) }
        setPosition(r.origin, t.window)
        if resize { setSize(r.size, t.window) }
        if enhanced { AXUIElementSetAttributeValue(t.app, enhancedUI, kCFBooleanTrue) }
    }

    static func setPosition(_ p: CGPoint, _ window: AXUIElement) {
        var v = p
        if let value = AXValueCreate(.cgPoint, &v) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    static func setSize(_ s: CGSize, _ window: AXUIElement) {
        var v = s
        if let value = AXValueCreate(.cgSize, &v) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    /// Screens in Accessibility coordinates (origin at the top left of the main screen).
    static func screens() -> [WindowsScreen] {
        let all = NSScreen.screens
        guard let primary = all.first else { return [] }
        let maxY = primary.frame.maxY
        return all.map {
            WindowsScreen(frame: WindowsGeometry.flip($0.frame, primaryMaxY: maxY),
                          visible: WindowsGeometry.flip($0.visibleFrame, primaryMaxY: maxY))
        }
    }

    // MARK: Helpers

    private static func element(_ el: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func bool(_ el: AXUIElement, _ attribute: CFString) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute, &ref) == .success, let ref,
              CFGetTypeID(ref) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((ref as! CFBoolean))
    }

    private static func value(_ el: AXUIElement, _ attribute: CFString) -> AXValue? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return (ref as! AXValue)
    }
}
