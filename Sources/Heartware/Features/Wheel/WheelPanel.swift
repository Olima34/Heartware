import AppKit
import SwiftUI
import Carbon.HIToolbox

/// The wheel's window: a disc of glass centered on the pointer, above every app. During a drag it is a drop target
/// (the segment under the pointer lights up, the drop runs it); moving away fades it, and past `leaveDistance` from its
/// edge it goes and the drag goes on as if nothing happened (the file is only being moved).
/// Opened by a click or a shortcut, the mouse (or the arrows and ↩) picks, Esc or a click elsewhere closes it.
@MainActor
final class WheelOverlay {
    let state = WheelOverlayState()
    /// The action chosen (nil: the hub, every action in a list), the files, and where the wheel was on screen (y up).
    var onChoose: ((WheelAction?, [WheelFile], NSPoint) -> Void)?
    /// Closed during a drag without a drop (the pointer went away): the drag goes on, the wheel may come back.
    var onLeft: (() -> Void)?
    private var panel: WheelPanel?
    private var closeWork: DispatchWorkItem?
    /// During a drag: a release the monitor did not see still closes the wheel.
    private var buttonPoll: Timer?
    private(set) var isOpen = false
    /// A drop was taken: the release that comes with it does not close the wheel before the action starts.
    private var dropped = false
    private(set) var center: NSPoint = .zero
    /// Past this distance from the wheel's edge (screen points), the wheel goes.
    var leaveDistance: CGFloat = 170

    func open(_ files: [WheelFile], menu: WheelMenu, at point: NSPoint, clicking: Bool, hint: Bool) {
        closeWork?.cancel()
        closeWork = nil
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: CGSize(width: 1440, height: 900))
        let frame = WheelGeometry.panelFrame(center: point, visible: visible)
        let p = panel ?? makePanel()
        p.clicking = clicking
        p.setFrame(frame, display: false)
        center = NSPoint(x: frame.midX, y: frame.midY)
        state.files = files
        state.menu = menu
        state.hovered = nil
        state.chosen = nil
        state.clicking = clicking
        state.hint = hint
        // Opened by a shortcut the hub can be clicked at once; during a drag, only once the pointer has been on a
        // segment (a drag that ends where it started is dropped on nothing).
        state.hubArmed = clicking
        state.shown = false
        (p.contentView as? WheelSurface)?.clicking = clicking
        isOpen = true
        dropped = false
        p.alphaValue = 1
        if clicking {
            p.makeKeyAndOrderFront(nil)
            p.makeFirstResponder(p.contentView)
            // Under the pointer already: what it points at lights up without waiting for a move.
            (p.contentView as? WheelSurface)?.hoverAtPointer()
        } else {
            p.orderFrontRegardless()
            watchButton()
        }
        DispatchQueue.main.async { [weak self] in self?.state.shown = true }
    }

    private func makePanel() -> WheelPanel {
        let p = WheelPanel()
        let surface = WheelSurface(state: state)
        surface.overlay = self
        p.contentView = surface
        p.onCancel = { [weak self] in self?.close() }
        panel = p
        return p
    }

    private func watchButton() {
        buttonPoll?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isOpen || self.state.clicking { self.buttonPoll?.invalidate(); self.buttonPoll = nil; return }
                if NSEvent.pressedMouseButtons & 1 == 0 { self.released() } else { self.track(NSEvent.mouseLocation) }
            }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        buttonPoll = t
    }

    func hover(_ hit: WheelGeometry.Hit?) {
        guard isOpen, state.hovered != hit else { return }
        if case .format = hit { state.hubArmed = true }
        if case .tool = hit { state.hubArmed = true }
        state.hovered = hit
    }

    /// Where the pointer is during a drag (screen, y up): out of the wheel it fades, and too far it goes.
    func track(_ point: NSPoint) {
        guard isOpen, !state.clicking, !dropped, let p = panel else { return }
        let beyond = hypot(point.x - center.x, point.y - center.y) - WheelGeometry.radius
        guard let alpha = WheelGeometry.fade(beyond: beyond, limit: leaveDistance) else {
            close()
            onLeft?()
            return
        }
        if abs(p.alphaValue - alpha) > 0.02 { p.alphaValue = alpha }
    }

    /// The button went up after a drag: dropped elsewhere, the wheel goes (a drop on it is handled by `chose`).
    func released() {
        // Once: the button poll sees the same release again a quarter of a second later, and must not put it off.
        guard isOpen, !state.clicking, !dropped, closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.dropped else { return }
            self.close()
        }
        closeWork = work
        // The drop reaches the wheel just after the release: it gets the time to arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// A segment (or the hub) was chosen: it flashes, the wheel goes, the action starts.
    func chose(_ hit: WheelGeometry.Hit, urls: [URL]) {
        guard isOpen, !dropped else { return }
        dropped = true
        closeWork?.cancel()
        closeWork = nil
        panel?.alphaValue = 1
        let action = state.action(at: hit)
        if hit != .hub && action == nil {
            close()
            return
        }
        state.chosen = hit
        state.hovered = hit
        // The files the drop brought, else those read when the wheel opened.
        let fresh = urls.map { WheelFile(url: $0) }
        let files = fresh.isEmpty ? state.files : fresh
        let where_ = center
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self else { return }
            self.close()
            self.onChoose?(action, files, where_)
        }
    }

    func close() {
        closeWork?.cancel()
        closeWork = nil
        guard isOpen else { return }
        isOpen = false
        buttonPoll?.invalidate()
        buttonPoll = nil
        state.shown = false
        let p = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard self?.isOpen == false else { return }
            p?.orderOut(nil)
        }
    }

    // MARK: Keyboard (opened by a shortcut)

    /// ← → walk through every action of the wheel, ↩ runs the one lit, Esc closes.
    func step(_ delta: Int) {
        let all: [WheelGeometry.Hit] = state.menu.formats.indices.map { .format($0) } + state.menu.tools.indices.map { .tool($0) }
        guard !all.isEmpty else { return }
        let i = state.hovered.flatMap { all.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        state.hovered = all[(i + delta + all.count) % all.count]
    }

    func confirm() {
        if let hit = state.hovered { chose(hit, urls: []) } else { chose(.hub, urls: []) }
    }
}

/// The borderless panel of the wheel. It takes the keyboard only when opened by a click or a shortcut (Esc, arrows):
/// during a drag the app that drags keeps it.
final class WheelPanel: NSPanel {
    var clicking = false
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: WheelGeometry.side, height: WheelGeometry.side),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        // Its own shadow is drawn around the disc; the window's would follow the square.
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { clicking }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resignKey() {
        super.resignKey()
        // Clicked elsewhere: the wheel goes.
        if clicking && isVisible {
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
        }
    }
}

/// The wheel's content: the SwiftUI drawing, and on top of it everything that comes from the mouse. The drawing never
/// gets an event (it would not know the segments); this view finds the segment under the pointer and tells the overlay.
final class WheelSurface: NSView {
    weak var overlay: WheelOverlay?
    var clicking = false
    private let host: NSHostingView<WheelView>
    private var tracking: NSTrackingArea?

    init(state: WheelOverlayState) {
        host = NSHostingView(rootView: WheelView(state: state))
        super.init(frame: NSRect(x: 0, y: 0, width: WheelGeometry.side, height: WheelGeometry.side))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The whole disc answers (the drawing beneath never does); outside it, nothing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let p = wheelPoint(local)
        return hypot(p.x, p.y) <= WheelGeometry.radius + WheelGeometry.slack ? self : nil
    }

    /// From this view's coordinates (y up) to the wheel's (from its center, y down).
    private func wheelPoint(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x - bounds.midX, y: bounds.midY - p.y)
    }

    private func hit(_ windowPoint: NSPoint) -> WheelGeometry.Hit? {
        overlay?.state.geometry.hit(wheelPoint(convert(windowPoint, from: nil)))
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        overlay?.hover(nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let state = overlay?.state, let hit = state.hovered else { return false }
        return (hit != .hub || state.hubArmed) && Self.operation(sender) != []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let hit = overlay?.state.hovered else { return false }
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        overlay?.chose(hit, urls: urls)
        return true
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let hit = hit(sender.draggingLocation)
        overlay?.hover(hit)
        guard let hit, let state = overlay?.state else { return [] }
        if hit == .hub && !state.hubArmed { return [] }
        if hit != .hub && state.action(at: hit) == nil { return [] }
        return Self.operation(sender)
    }

    /// A copy: the original stays where it is. Never a move, which would let the app that drags delete it afterwards.
    private static func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
        let mask = sender.draggingSourceOperationMask
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        if mask.contains(.link) { return .link }
        return []
    }

    // MARK: Mouse and keyboard (opened by a click or a shortcut)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    func hoverAtPointer() {
        guard let window else { return }
        overlay?.hover(hit(window.mouseLocationOutsideOfEventStream))
    }

    override func mouseMoved(with event: NSEvent) {
        guard clicking else { return }
        overlay?.hover(hit(event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) {
        guard clicking else { return }
        overlay?.hover(nil)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard clicking else { return }
        if let hit = hit(event.locationInWindow) {
            overlay?.chose(hit, urls: [])
        } else {
            overlay?.close()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard clicking else { return super.keyDown(with: event) }
        switch Int(event.keyCode) {
        case kVK_RightArrow, kVK_DownArrow, kVK_Tab: overlay?.step(1)
        case kVK_LeftArrow, kVK_UpArrow: overlay?.step(-1)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: overlay?.confirm()
        case kVK_Escape: overlay?.close()
        default: super.keyDown(with: event)
        }
    }
}
