import AppKit

/// Watches file drags in every app and asks for the wheel as soon as a file starts moving (or, if the user prefers, only
/// after a gesture: held still before moving, a quick shake, or ⇧), then follows the pointer while the wheel is open.
/// Mouse events reach a global monitor without any permission (only keys need one).
/// Costs nothing at rest: only presses and drags wake it, a drag that is not of files is dropped after a look at the
/// drag pasteboard's types (its content is read once, when the wheel opens), and the ⇧ poll runs only during a file drag.
@MainActor
final class WheelWatcher {
    enum Gesture: String {
        /// The file just started moving.
        case drag
        case hold, shake, shift
    }

    var settings = WheelSettings()
    /// The wheel is wanted at this point of the screen (y up) for these files.
    var onOpen: ((NSPoint, [URL], Gesture) -> Void)?
    /// The button went up after the wheel opened (dropped on it, or anywhere else).
    var onRelease: (() -> Void)?
    /// Where the pointer is while the wheel is open (screen, y up): over it, around it, or far away.
    var onMove: ((NSPoint) -> Void)?

    private var monitors: [Any] = []
    private var down: (time: TimeInterval, point: NSPoint, change: Int)?
    private var movedAt: TimeInterval?
    /// nil until the drag pasteboard was looked at: true for files, false for anything else (text, a window…).
    private var fileDrag: Bool?
    private var shake = WheelShake()
    private var opened = false
    /// ⇧ opens the wheel when it goes down: held on after the wheel was left, it waits to be pressed again.
    private var shiftArmed = true
    /// The pause before the move is judged once, as soon as both the move and the drag are known.
    private var holdJudged = false
    private var poll: Timer?

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty, !DemoData.isEnabled, !Snapshot.isActive else { return }
        let handlers: [(NSEvent.EventTypeMask, (WheelWatcher, NSEvent) -> Void)] = [
            (.leftMouseDown, { $0.pressed($1) }),
            (.leftMouseDragged, { $0.dragged($1) }),
            (.leftMouseUp, { w, _ in w.released() })
        ]
        for (mask, handle) in handlers {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handle(self, event)
                }
            }) {
                monitors.append(m)
            }
        }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        reset()
    }

    private func reset() {
        down = nil
        movedAt = nil
        fileDrag = nil
        opened = false
        shiftArmed = true
        holdJudged = false
        shake.reset()
        poll?.invalidate()
        poll = nil
    }

    /// The wheel was left during the drag (the pointer went far): another shake (or ⇧ pressed again) brings it back.
    func rearm() {
        guard down != nil, opened else { return }
        opened = false
        shake.reset()
        shiftArmed = !NSEvent.modifierFlags.contains(.shift)
        startPoll()
    }

    // MARK: Events

    private func pressed(_ event: NSEvent) {
        reset()
        guard settings.enabled, settings.canOpen else { return }
        // The drag pasteboard's counter moves when a drag starts: compared at each move until it does.
        down = (event.timestamp, NSEvent.mouseLocation, NSPasteboard(name: .drag).changeCount)
    }

    private func dragged(_ event: NSEvent) {
        guard let d = down, fileDrag != false else { return }
        let p = NSEvent.mouseLocation
        if opened {
            onMove?(p)
            return
        }
        if movedAt == nil, WheelGestureRules.moved(from: d.point, to: p) { movedAt = event.timestamp }
        if fileDrag == nil {
            // A look at each move until the drag starts, a few pixels after the press: the wheel comes with it.
            let pasteboard = NSPasteboard(name: .drag)
            guard pasteboard.changeCount != d.change else {
                // Well on its way and still no drag: a text selection, a window, a slider. Left alone from now on.
                if hypot(p.x - d.point.x, p.y - d.point.y) > 40 { fileDrag = false }
                return
            }
            // Only the list of types: it reads nothing of the content and makes macOS ask nothing.
            fileDrag = (pasteboard.types ?? []).contains(.fileURL)
            guard fileDrag == true else { return }
            if settings.instant {
                open(.drag)
                return
            }
            startPoll()
        }
        // The drag may start a pixel or two before the pointer counts as moving, or the other way round.
        if settings.hold && !settings.instant, !holdJudged, let moved = movedAt {
            holdJudged = true
            if WheelGestureRules.held(downAt: d.time, movedAt: moved, delay: settings.holdDelay) {
                open(.hold)
                return
            }
        }
        if shiftPressed(event.modifierFlags) {
            open(.shift)
        } else if settings.shake && shake.feed(x: p.x, at: event.timestamp) {
            open(.shake)
        }
    }

    private func released() {
        let wasOpen = opened
        reset()
        if wasOpen { onRelease?() }
    }

    /// ⇧ pressed without moving, and a drag that ended where no release reached the monitor.
    private func startPoll() {
        guard poll == nil else { return }
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        t.tolerance = 0.03
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    private func check() {
        guard down != nil, !opened else {
            poll?.invalidate()
            poll = nil
            return
        }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            released()
        } else if shiftPressed(NSEvent.modifierFlags) {
            open(.shift)
        }
    }

    private func shiftPressed(_ flags: NSEvent.ModifierFlags) -> Bool {
        let down = flags.contains(.shift)
        if !down { shiftArmed = true }
        return settings.shift && down && shiftArmed
    }

    private func open(_ gesture: Gesture) {
        let pasteboard = NSPasteboard(name: .drag)
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            // File promises (Photos, Mail) have no file yet: nothing the wheel can work on.
            fileDrag = false
            return
        }
        opened = true
        if gesture == .shift { shiftArmed = false }
        poll?.invalidate()
        poll = nil
        onOpen?(NSEvent.mouseLocation, urls, gesture)
    }
}
