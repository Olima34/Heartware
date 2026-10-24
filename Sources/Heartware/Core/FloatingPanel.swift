import AppKit
import SwiftUI

/// A borderless panel that floats above every app (full-screen ones included), takes the keyboard
/// without bringing the app to the front, and closes when it loses focus or on Esc.
/// Used by the launcher and by small pop-up tools.
final class FloatingPanel: NSPanel {
    var onClose: (() -> Void)?
    var closesOnResignKey = true

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        guard closesOnResignKey, isVisible else { return }
        // Closes when the user goes elsewhere, not when one of the app's own windows (an alert, a system sheet)
        // takes the keyboard for a moment: that one comes and goes, the panel stays.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isKeyWindow else { return }
            if let key = NSApp.keyWindow, key !== self, key.isVisible, !(key is FloatingPanel) {
                // The main window or the settings: the user moved on.
                let id = key.identifier?.rawValue ?? ""
                if !(id.hasPrefix("main") || id.contains("Settings")) { return }
            }
            self.close()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func close() {
        super.close()
        onClose?()
    }

    /// Hosts a SwiftUI view (with the app model in its environment).
    func setContent<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        contentView = host
    }

    /// Shows the panel on the screen that has the mouse, a third of the way down.
    func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let origin = NSPoint(x: f.midX - frame.width / 2, y: f.maxY - f.height * 0.28 - frame.height)
            setFrameOrigin(origin)
        }
        makeKeyAndOrderFront(nil)
    }
}

/// A short message that appears in the middle of the screen and fades away ("Copié !").
@MainActor
enum HUD {
    private static var panel: FloatingPanel?
    private static var hideWork: DispatchWorkItem?
    /// Counts the messages shown: a fade that ends after a newer message must not hide it.
    private static var shown = 0

    static func show(_ text: String, symbol: String = "checkmark.circle.fill") {
        show(text, icon: Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
            .foregroundStyle(symbol.hasPrefix("xmark") ? Theme.bad : symbol.hasPrefix("exclamationmark") ? Theme.warn : Theme.good))
    }

    /// The same with a drawn icon (the Refuge's blueberry).
    static func show<Icon: View>(_ text: String, icon: Icon) {
        guard !Snapshot.isActive else { return }
        let p = panel ?? {
            let p = FloatingPanel(size: NSSize(width: 320, height: 64))
            p.closesOnResignKey = false
            p.ignoresMouseEvents = true
            p.level = .statusBar
            panel = p
            return p
        }()
        p.setContent(
            HStack(spacing: 10) {
                icon
                Text(text).font(.ui(13.5, .medium)).foregroundStyle(Theme.text).lineLimit(2)
            }
            .padding(.horizontal, 18)
            .frame(width: 320, height: 64)
            .background(RoundedRectangle(cornerRadius: Theme.r(16), style: .continuous).fill(Theme.cardRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(16), style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: Theme.line))
        )
        if let f = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.midX - 160, y: f.minY + f.height * 0.18))
        }
        shown += 1
        let ticket = shown
        // Through the animator, so that it also stops the fade of a previous message still running.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            p.animator().alphaValue = 1
        }
        p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { if ticket == shown { p.orderOut(nil) } }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}
