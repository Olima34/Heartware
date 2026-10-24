import SwiftUI
import AppKit
import QuartzCore

// MARK: - The pile's physics

/// How dragged files follow the pointer: they fly from their rows into a pile under it, the cards beneath trail a
/// little behind, and each one hangs from the pointer like a pendulum, swinging with the movements.
/// Screen points (y goes up). Pure: `checks()` runs it without any window.
struct LauncherDragPhysics {
    struct Card {
        /// What is left of the flight from the row to the pile (back to zero, or back home when the drop is cancelled).
        var flight: CGVector
        var flightSpeed = CGVector.zero
        /// Where the flight started, from the pointer.
        var home: CGVector
        /// The point the card hangs from: the pointer for the top card, a point trailing behind it for the others.
        var anchor: CGPoint
        var anchorSpeed = CGVector.zero
        /// The pendulum's weight, horizontally: left behind when the pointer moves, it tilts the card.
        var bob: CGFloat
        var bobSpeed: CGFloat = 0
    }

    /// From the pointer to the weight of a card: the longer, the less a card tilts.
    static let length = 80.0
    /// The furthest a card tilts, in degrees.
    static let maxTilt = 30.0
    /// A row further away starts its flight from that distance (the pile's window is not larger).
    static let maxReach = 250.0

    private(set) var cards: [Card]
    private(set) var pointer: CGPoint
    private(set) var elapsed = 0.0
    /// The drop was cancelled: the cards fly back to their rows.
    var homing = false

    /// `origins`: where each card starts (its row's icon), nil for one that appears under the pile.
    init(pointer: CGPoint, origins: [CGPoint?]) {
        self.pointer = pointer
        let first = origins.first.flatMap { $0 } ?? pointer
        cards = origins.map { origin in
            var offset = CGVector(dx: (origin ?? first).x - pointer.x, dy: (origin ?? first).y - pointer.y)
            let distance = hypot(offset.dx, offset.dy)
            if distance > Self.maxReach {
                offset.dx *= Self.maxReach / distance
                offset.dy *= Self.maxReach / distance
            }
            return Card(flight: offset, home: offset, anchor: pointer, bob: pointer.x)
        }
    }

    /// Moves everything forward by `dt` seconds, the pointer now at `pointer`.
    mutating func step(to pointer: CGPoint, dt: Double) {
        self.pointer = pointer
        var left = min(max(dt, 0), 0.1)
        // Small steps: the springs stay steady whatever the frame rate.
        while left > 0 {
            let h = min(left, 1.0 / 240)
            left -= h
            elapsed += h
            advance(h)
        }
    }

    private mutating func advance(_ h: Double) {
        for i in cards.indices {
            var c = cards[i]
            let target = homing ? c.home : .zero
            let flightFreq = homing ? 3.2 : 3.4 + 0.2 * Double(i)
            Self.spring(&c.flight.dx, &c.flightSpeed.dx, target: target.dx, freq: flightFreq, damping: 0.86, dt: h)
            Self.spring(&c.flight.dy, &c.flightSpeed.dy, target: target.dy, freq: flightFreq, damping: 0.86, dt: h)
            if i == 0 {
                c.anchor = pointer
                c.anchorSpeed = .zero
            } else {
                // The cards beneath follow more loosely, the lower the looser: a short trail while moving.
                let trail = max(4.5, 9 - 1.3 * Double(i))
                Self.spring(&c.anchor.x, &c.anchorSpeed.dx, target: pointer.x, freq: trail, damping: 0.78, dt: h)
                Self.spring(&c.anchor.y, &c.anchorSpeed.dy, target: pointer.y, freq: trail, damping: 0.78, dt: h)
            }
            // The weight hangs under the point the card follows, held back by the air: it lags when the pointer moves,
            // then swings. Only the pointer moves it, not the flight from the row (that would toss the cards about).
            let swing = max(1.3, 1.9 - 0.12 * Double(i))
            Self.spring(&c.bob, &c.bobSpeed, target: c.anchor.x, freq: swing, damping: 0.28, dt: h)
            cards[i] = c
        }
    }

    /// A damped spring toward `target`. The damping slows the speed itself, like air on a pendulum:
    /// what follows a moving target stays a little behind it, then overshoots when it stops.
    private static func spring(_ x: inout CGFloat, _ v: inout CGFloat, target: CGFloat, freq: CGFloat, damping: CGFloat, dt: Double) {
        let w = 2 * .pi * freq
        v += (-w * w * (x - target) - 2 * damping * w * v) * dt
        x += v * dt
    }

    /// Where card `i` hangs from, on screen.
    func pivot(_ i: Int) -> CGPoint {
        let c = cards[i]
        return CGPoint(x: c.anchor.x + c.flight.dx, y: c.anchor.y + c.flight.dy)
    }

    /// How much card `i` tilts, in degrees, clockwise as seen on screen: its weight left on the left tilts it clockwise.
    func tilt(_ i: Int) -> Double {
        let c = cards[i]
        let raw = -atan(Double(c.bob - c.anchor.x) / Self.length) * 180 / .pi
        return Self.maxTilt * tanh(raw / Self.maxTilt)
    }

    /// The rules of the pile, simulated without any window.
    static func checks() -> [String] {
        var failures: [String] = []
        let start = CGPoint(x: 500, y: 400)
        var p = LauncherDragPhysics(pointer: start, origins: [CGPoint(x: 300, y: 420), CGPoint(x: 310, y: 300), nil, CGPoint(x: 0, y: 2000)])
        if hypot(p.cards[3].flight.dx, p.cards[3].flight.dy) > maxReach + 0.5 { failures.append("glisser : un fichier lointain part de trop loin") }
        if p.cards[2].flight != p.cards[0].flight { failures.append("glisser : un fichier caché devrait partir de la pile") }
        // Still pointer: everything lands under it, and stops swinging.
        for _ in 0..<90 { p.step(to: start, dt: 1.0 / 60) }
        for i in p.cards.indices where hypot(p.pivot(i).x - start.x, p.pivot(i).y - start.y) > 1.5 || abs(p.tilt(i)) > 1 {
            failures.append("glisser : la carte \(i) n'a pas rejoint la pile (\(Int(p.pivot(i).x)), \(Int(p.pivot(i).y)), \(Int(p.tilt(i)))°)")
        }
        // Moving right: the weight stays behind on the left, the cards tilt clockwise, the lower ones trail.
        var x = start.x
        var maxTilt = 0.0
        for _ in 0..<30 {
            x += 700.0 / 60
            p.step(to: CGPoint(x: x, y: start.y), dt: 1.0 / 60)
            maxTilt = max(maxTilt, abs(p.tilt(0)))
        }
        if p.tilt(0) < 8 { failures.append("glisser : vers la droite, la pile devrait pencher (\(Int(p.tilt(0)))°)") }
        if maxTilt > Self.maxTilt { failures.append("glisser : la pile penche trop (\(Int(maxTilt))°)") }
        if p.pivot(1).x > x - 5 || abs(p.pivot(0).x - x) > 1 { failures.append("glisser : la carte du dessus suit le pointeur, les autres traînent derrière") }
        // Stopping: it swings past the vertical, then settles.
        var swung = false
        for _ in 0..<60 {
            p.step(to: CGPoint(x: x, y: start.y), dt: 1.0 / 60)
            if p.tilt(0) < -2 { swung = true }
        }
        if !swung { failures.append("glisser : à l'arrêt, la pile devrait se balancer") }
        for _ in 0..<240 { p.step(to: CGPoint(x: x, y: start.y), dt: 1.0 / 60) }
        if abs(p.tilt(0)) > 0.5 { failures.append("glisser : la pile ne s'arrête pas de se balancer (\(p.tilt(0))°)") }
        // A long frame (the Mac busy) does not throw the cards away.
        p.step(to: CGPoint(x: x + 300, y: start.y), dt: 0.5)
        if !p.pivot(0).x.isFinite || abs(p.tilt(0)) > Self.maxTilt { failures.append("glisser : une image lente fait sauter la pile") }
        // Cancelled: back to the rows.
        p.homing = true
        for _ in 0..<120 { p.step(to: CGPoint(x: x, y: start.y), dt: 1.0 / 60) }
        let back = p.pivot(0)
        if hypot(back.x - (x - 200), back.y - (start.y + 20)) > 3 { failures.append("glisser : annulé, le fichier devrait revenir à sa ligne") }
        return failures
    }
}

// MARK: - The drag

/// Files dragged out of the file window: copied where they are dropped, never moved (the source only allows a copy),
/// and drawn as a pile that swings under the pointer, in a window of its own that lets every click through.
@MainActor
final class LauncherDrag: NSObject, NSDraggingSource {
    /// The drag under way (a second one cannot start before it is over).
    private static var current: LauncherDrag?
    static var isActive: Bool { current != nil }
    /// The pile's window, centered on the pointer: large enough for a card's flight from its row.
    static let canvas = CGSize(width: 640, height: 640)
    private static let clear = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { _ in true }

    private let stack: LauncherDragStack
    private var physics: LauncherDragPhysics
    /// The cards that appear under the pile (their row is out of sight): they fade in.
    private let hidden: [Bool]
    private var panel: NSPanel?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var endPoint: CGPoint?
    private var ending: (at: Double, dropped: Bool)?

    private init(paths: [String], origins: [CGPoint?], pointer: CGPoint) {
        physics = LauncherDragPhysics(pointer: pointer, origins: origins)
        hidden = origins.map { $0 == nil }
        stack = LauncherDragStack(paths: paths, canvas: Self.canvas)
        super.init()
        stack.poses = Self.poses(physics, hidden: hidden, ending: nil, center: CGPoint(x: Self.canvas.width / 2, y: Self.canvas.height / 2))
    }

    /// Starts dragging `paths` (the one under the pointer first) from `view`, on the mouse event that moved it.
    static func begin(paths: [String], origins: [CGPoint?], from view: NSView, event: NSEvent) {
        guard current == nil, !paths.isEmpty else { return }
        let drag = LauncherDrag(paths: paths, origins: origins, pointer: NSEvent.mouseLocation)
        let local = view.convert(event.locationInWindow, from: nil)
        let items = paths.enumerated().map { i, path -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: path) as NSURL)
            // Invisible: the pile replaces the system's image. One frame each, side by side, where the Finder sets them down.
            item.setDraggingFrame(NSRect(x: local.x - 16 + CGFloat(i % 6) * 40, y: local.y - 16 + CGFloat(i / 6) * 40, width: 32, height: 32),
                                  contents: clear)
            return item
        }
        current = drag
        let session = view.beginDraggingSession(with: items, event: event, source: drag)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// ⌘ or ⌥ held (⌘ picks the files) never turn the copy into a move.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        show()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Self.current = nil
        endPoint = screenPoint
        ending = (physics.elapsed, operation != [])
        // Dropped nowhere: the files go back to their rows.
        if operation == [] { physics.homing = true }
        if panel == nil { finish() }
    }

    // MARK: The pile's window

    private func show() {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.canvas), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)))
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: LauncherDragStackView(stack: stack))
        host.sizingOptions = []
        p.contentView = host
        place(p, at: physics.pointer)
        p.orderFrontRegardless()
        panel = p
        // Every frame of the screen, only while the files are dragged.
        let link = host.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func place(_ p: NSPanel, at pointer: CGPoint) {
        p.setFrameOrigin(NSPoint(x: (pointer.x - Self.canvas.width / 2).rounded(), y: (pointer.y - Self.canvas.height / 2).rounded()))
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTick == 0 ? 1.0 / 60 : now - lastTick
        lastTick = now
        let pointer = endPoint ?? NSEvent.mouseLocation
        physics.step(to: pointer, dt: dt)
        guard let panel else { return }
        place(panel, at: pointer)
        // The window sits on whole points: the pile is drawn from where it really is.
        let center = CGPoint(x: Self.canvas.width / 2 + (pointer.x - Self.canvas.width / 2 - panel.frame.minX),
                             y: Self.canvas.height / 2 - (pointer.y - Self.canvas.height / 2 - panel.frame.minY))
        stack.poses = Self.poses(physics, hidden: hidden, ending: ending, center: center)
        if let ending, physics.elapsed - ending.at > Self.fade(dropped: ending.dropped) { finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    private static func fade(dropped: Bool) -> Double {
        dropped ? 0.2 : 0.34
    }

    /// The cards as drawn: `center` is where the pointer is in the canvas (top-left origin).
    static func poses(_ physics: LauncherDragPhysics, hidden: [Bool], ending: (at: Double, dropped: Bool)?, center: CGPoint) -> [LauncherDragPose] {
        let t = physics.elapsed
        // From the size of a row's icon to a card, as they land.
        let grown = 1 - pow(1 - min(1, t / 0.26), 3)
        var poses: [LauncherDragPose] = []
        for i in physics.cards.indices.prefix(LauncherDragStack.shown) {
            let pivot = physics.pivot(i)
            let rest = LauncherDragStack.rest[i]
            var scale = 0.34 + 0.66 * grown
            var opacity = hidden[i] ? min(1, t / 0.16) : 1
            if let ending {
                let k = min(1, (t - ending.at) / fade(dropped: ending.dropped))
                opacity *= 1 - k
                scale *= ending.dropped ? 1 - 0.3 * k : 1 - 0.6 * k
            }
            poses.append(LauncherDragPose(
                pivot: CGPoint(x: center.x + pivot.x - physics.pointer.x + rest.x * grown,
                               y: center.y - (pivot.y - physics.pointer.y) + rest.y * grown),
                angle: physics.tilt(i) + rest.angle * grown,
                scale: scale,
                opacity: opacity))
        }
        return poses
    }
}

/// One card of the pile, as drawn.
struct LauncherDragPose: Equatable {
    /// The point it hangs from, in the canvas (the pointer's for the top card).
    var pivot: CGPoint
    var angle: Double
    var scale: Double
    var opacity: Double
}

/// What the pile's window draws, updated every frame.
@Observable
@MainActor
final class LauncherDragStack {
    /// The cards drawn (the others only count in the badge).
    static let shown = 5
    /// Each card a little askew under the one above: a pile, not a single file.
    static let rest: [(x: Double, y: Double, angle: Double)] = [(0, 0, 0), (4, 3, -6), (-4, 5, 5), (5, 7, -3.5), (-3, 9, 7)]

    let paths: [String]
    let canvas: CGSize
    var poses: [LauncherDragPose] = []

    init(paths: [String], canvas: CGSize) {
        self.paths = paths
        self.canvas = canvas
    }
}

struct LauncherDragStackView: View {
    var stack: LauncherDragStack

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(stack.poses.indices.reversed(), id: \.self) { i in
                let pose = stack.poses[i]
                LauncherDragCard(path: stack.paths[i], count: i == 0 && stack.paths.count > 1 ? stack.paths.count : nil)
                    .scaleEffect(pose.scale, anchor: LauncherDragCard.pivot)
                    .rotationEffect(.degrees(pose.angle), anchor: LauncherDragCard.pivot)
                    .opacity(pose.opacity)
                    .position(x: pose.pivot.x, y: pose.pivot.y + LauncherDragCard.size.height / 2 - LauncherDragCard.pivotFromTop)
            }
        }
        .frame(width: stack.canvas.width, height: stack.canvas.height, alignment: .topLeading)
    }
}

/// A dragged file: its icon and name on a card, held by the top (where the pointer is).
struct LauncherDragCard: View {
    static let size = CGSize(width: 86, height: 98)
    static let pivotFromTop: CGFloat = 12
    static var pivot: UnitPoint { UnitPoint(x: 0.5, y: pivotFromTop / size.height) }

    var path: String
    /// How many files are dragged, on the top card.
    var count: Int?

    var body: some View {
        VStack(spacing: 5) {
            FileIcon(path: path, size: 50)
            Text((path as NSString).lastPathComponent)
                .font(.ui(10.5, .medium)).foregroundStyle(Theme.text)
                .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
        }
        .padding(.top, 10)
        .padding(.horizontal, 6)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).fill(Theme.cardRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: Theme.line))
        .themedShadow(color: .black.opacity(0.3), radius: 9, y: 5)
        .overlay(alignment: .topTrailing) {
            if let count {
                Text(Fmt.int(count))
                    .font(.ui(11.5, .bold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(PillShape().fill(Theme.accent))
                    .offset(x: 9, y: -9)
            }
        }
    }
}

// MARK: - Picking files and dragging them

extension LauncherModel {
    /// ⌘-click or ⌘↩ in the file window: the file or folder joins the selection, or leaves it.
    /// False for anything else (the launcher's own results keep their secondary action).
    @discardableResult
    func toggleMark(_ command: AppCommand) -> Bool {
        guard scope == .files, let path = Self.filePath(of: command) else { return false }
        toggleMark(path: path)
        return true
    }

    func toggleMark(path: String) {
        if let i = marked.firstIndex(of: path) { marked.remove(at: i) } else { marked.append(path) }
    }

    func toggleMarkSelected() -> Bool {
        let items = flat
        return items.indices.contains(selection) && toggleMark(items[selection])
    }

    /// A file or folder of the results is dragged (from its row, or from the preview): it goes alone, or with the whole
    /// selection when it belongs to it, and is copied where it lands.
    func beginFileDrag(_ path: String, fromRow: Bool) {
        guard !LauncherDrag.isActive, !DemoData.isEnabled, !Snapshot.isActive, let view = panelView, let window = view.window else { return }
        closeActions()
        let paths = Self.dragOrder(path, marked: marked)
        let rows = flat.map(Self.filePath(of:))
        let origins = paths.enumerated().map { i, p -> CGPoint? in
            // The preview's file starts under the pointer; the others leave their rows, if they can be seen.
            guard i > 0 || fromRow, let index = rows.firstIndex(of: p) else { return nil }
            return iconOnScreen(index, in: view)
        }
        // The event that moved the mouse (SwiftUI's gesture runs inside it); one like it otherwise.
        let event = NSApp.currentEvent.flatMap { $0.type == .leftMouseDragged && $0.window === window ? $0 : nil }
            ?? NSEvent.mouseEvent(with: .leftMouseDragged, location: window.mouseLocationOutsideOfEventStream, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: 1, pressure: 1)
        guard let event else { return }
        LauncherDrag.begin(paths: paths, origins: origins, from: view, event: event)
    }

    /// What a drag takes: the file under the pointer on top, then the rest of the selection if it belongs to it
    /// (like the Finder: an unpicked file goes alone, the selection stays as it was).
    static func dragOrder(_ path: String, marked: [String]) -> [String] {
        marked.contains(path) ? [path] + marked.filter { $0 != path } : [path]
    }

    /// Where the icon of result `index` is on screen, nil when its row is scrolled out of sight.
    private func iconOnScreen(_ index: Int, in view: NSView) -> CGPoint? {
        guard let row = rowFrames[index], let window = view.window else { return nil }
        // The icon: the row's margin and padding, then half its width.
        let icon = CGPoint(x: row.minX + 6 + 12 + 13, y: row.midY)
        guard listViewport.insetBy(dx: 0, dy: -6).contains(icon) else { return nil }
        return window.convertPoint(toScreen: view.convert(icon, to: nil))
    }

    /// `--tab glisser`: three files picked, the pile caught mid-swing over the results (drawn in the panel itself).
    func snapshotDrag() -> LauncherDragStack? {
        let paths = flat.compactMap(Self.filePath(of:)).filter { !isFolder($0) }.prefix(3)
        guard paths.count == 3 else { return nil }
        marked = Array(paths)
        let pointer = CGPoint(x: 600, y: 300)
        var physics = LauncherDragPhysics(pointer: pointer, origins: [CGPoint(x: 120, y: 330), CGPoint(x: 120, y: 280), CGPoint(x: 120, y: 236)])
        var x = pointer.x
        for _ in 0..<40 {
            x += 9
            physics.step(to: CGPoint(x: x, y: pointer.y), dt: 1.0 / 60)
        }
        let stack = LauncherDragStack(paths: Array(paths), canvas: CGSize(width: LauncherView.width, height: LauncherView.height))
        stack.poses = LauncherDrag.poses(physics, hidden: [false, false, false], ending: nil, center: CGPoint(x: 600, y: 215))
        return stack
    }
}
