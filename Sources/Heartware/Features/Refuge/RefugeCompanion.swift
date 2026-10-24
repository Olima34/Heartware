import SwiftUI
import AppKit
import ApplicationServices

/// What the desktop companion shows: its frame, its look and mood, a jump, a word, how it leans.
@Observable
@MainActor
final class RefugeCompanionState {
    var frame = 0
    var look = RefugeLook(stage: .cabri)
    var mood: RefugeMood = .happy
    var lift = 0
    var word: String?
    /// 0 standing, 90 leaning in from the left edge, -90 from the right, 180 hanging from the top.
    var rotation: Double = 0
}

/// Somewhere it can stand: the bottom of the screen beside the Dock, the top of the Dock, or the top edge of a window
/// where no other window covers it. `minX`…`maxX` is where the middle of its feet may go; `left` follows the window when
/// it is dragged.
struct RefugeSurface: Equatable {
    /// The window's number; 0 for the bottom of the screen, -1 for the top of the Dock.
    var id: Int
    var y: CGFloat
    var minX: CGFloat
    var maxX: CGFloat
    var left: CGFloat

    func contains(_ x: CGFloat) -> Bool { x >= minX - 1 && x <= maxX + 1 }
}

/// Its view takes the first click even while the app is in the background: a caress needs no activation.
private final class RefugeCompanionHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A borderless panel that may sit partly off the screen (leaning in from an edge).
private final class RefugeCompanionPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
}

/// The desktop companion: it always stands on something. It walks along the bottom of the screen, on the Dock, and
/// along the top edges of the windows (even right under the menu bar), hops from one to another, follows a window that
/// is dragged. When it loses its footing (its window closes or slides away), it jumps to the nearest edge, clings to a
/// side of the screen, its head peeking in, or hangs upside down from the top; else it drops to what is below. It also
/// leans in from the sides and hangs from the top on its own, naps, and jumps when blueberries come in. Off by default; four frames per
/// second, only while it is out. A click is a caress; three quick ones send it away (the menu bar panel calls it back).
/// Clicks anywhere else go through to what is underneath.
@MainActor
final class RefugeCompanion {
    private var panel: RefugeCompanionPanel?
    private var timer: Timer?
    private weak var model: RefugeModel?
    private let state = RefugeCompanionState()
    /// Where the middle of its feet is.
    private var feet = CGPoint.zero
    private var surface: RefugeSurface?
    private var surfaces: [RefugeSurface] = []
    private var direction: CGFloat = 1
    private var mode: Mode = .walk
    private var ticksLeft = 40
    private var wordTicks = 0
    private var jumpTicks = 0
    private var fallSpeed: CGFloat = 0
    private var jump: Jump?
    private var taps: [Date] = []
    /// Walking in from off the screen.
    private var entering = false
    /// Its window moved at the last reading: it is being dragged, the next frames follow it closely.
    private var following = false
    /// The screens are off or the session is not in front: it rests, nothing runs.
    private var observers: [NSObjectProtocol] = []
    /// The windows and the Dock are read on a queue of their own (the window server and the Dock can be slow to answer,
    /// right after waking up above all): one reading at a time, the frames use the latest one.
    private var reading = false
    private static let readQueue = DispatchQueue(label: "heartware.refuge.surfaces", qos: .utility)

    private enum Mode: Equatable {
        case walk, sit, sleep, jumping, falling, leaving
        case lean(left: Bool)
        case hang
    }

    /// A jump in progress: from where, to where, what it does on landing.
    private struct Jump {
        enum Landing { case surface(RefugeSurface), lean(left: Bool), hang }
        var from: CGPoint
        var to: CGPoint
        var step = 0
        var steps: Int
        var height: CGFloat
        var landing: Landing
        /// A hop from one edge onto the next: it walks on after landing.
        var walkOn = false
    }

    static let pixel: CGFloat = 3
    static let size = NSSize(width: 96, height: 86)
    /// Half the width of its feet: how close to the end of an edge it may walk.
    nonisolated static let reach: CGFloat = 28
    /// The chamois' square in the panel: centred, at the bottom.
    private static var figure: CGRect {
        let side = CGFloat(RefugeFigure.cols) * pixel
        return CGRect(x: (size.width - side) / 2, y: 0, width: side, height: side)
    }

    var isOut: Bool { panel != nil }

    func start(_ model: RefugeModel) {
        self.model = model
        guard panel == nil, let f = Self.screenFrame else { return }
        let p = RefugeCompanionPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        p.isFloatingPanel = true
        // Above the menu bar: it may stand on a window right under it, or hang from it.
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        let host = RefugeCompanionHost(rootView: RefugeCompanionView(state: state, tap: { [weak self] in self?.tapped() }))
        // The panel keeps its size: the view never resizes it.
        host.sizingOptions = []
        p.contentView = host
        // It comes in from the right, walking along the bottom of the screen (the windows come with the first reading).
        surfaces = Self.surfaces(windows: [], full: (NSScreen.main ?? NSScreen.screens.first)?.frame ?? f, visible: f, dock: nil)
        surface = surfaces.filter { $0.id <= 0 }.max { $0.maxX < $1.maxX }
        feet = CGPoint(x: f.maxX + Self.size.width / 2, y: surface?.y ?? f.minY)
        direction = -1
        mode = .walk
        entering = true
        ticksLeft = 70
        p.setFrameOrigin(origin)
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p
        refreshLook()
        readSurfaces(f)
        startTicking()
        // Nobody sees it with the screens off or the session locked: it waits, without a single frame.
        let center = NSWorkspace.shared.notificationCenter
        for (name, on) in [(NSWorkspace.screensDidSleepNotification, false), (NSWorkspace.sessionDidResignActiveNotification, false),
                           (NSWorkspace.screensDidWakeNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, true)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { on ? self?.startTicking() : self?.stopTicking() }
            })
        }
    }

    func stop() {
        stopTicking()
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }

    private func startTicking() {
        guard timer == nil, panel != nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    /// Blueberries came in, or it ate: a little jump and a word.
    func react(_ word: String) {
        guard panel != nil, mode != .leaving else { return }
        say(word)
        jumpTicks = 3
        if mode == .sleep { mode = .sit; ticksLeft = 20 }
    }

    private static var screenFrame: NSRect? { (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame }

    /// The panel's corner for where its feet are.
    private var origin: CGPoint { CGPoint(x: feet.x - Self.size.width / 2, y: feet.y) }

    private func say(_ word: String) {
        state.word = word
        wordTicks = 10
    }

    /// A caress; three quick ones and it leaves.
    private func tapped() {
        let now = Date()
        taps = taps.filter { now.timeIntervalSince($0) < 0.9 } + [now]
        if taps.count >= 3 {
            taps = []
            leave()
            return
        }
        model?.pet()
        say(model?.reaction ?? "Hi hi !")
        jumpTicks = 2
    }

    private func leave() {
        mode = .leaving
        state.rotation = 0
        say("À plus tard !")
        jumpTicks = 3
        ticksLeft = 6
    }

    private func refreshLook() {
        guard let model else { return }
        state.look = model.look()
        state.mood = model.mood()
    }

    // MARK: Each frame

    private func tick() {
        guard let panel, let f = Self.screenFrame else { return }
        state.frame += 1
        if state.frame % 20 == 0, mode != .sleep { refreshLook() }
        if wordTicks > 0 { wordTicks -= 1; if wordTicks == 0, mode != .leaving { state.word = nil } }
        state.lift = jumpTicks > 0 ? (jumpTicks % 2 == 1 ? 2 : 1) : 0
        if jumpTicks > 0 { jumpTicks -= 1 }
        ticksLeft -= 1

        // Where it can stand (a description of every window, from the window server): twice a second on a window,
        // which it follows (every frame while the window is dragged), or falls when it is gone; twice a second while
        // it jumps or falls; right before it chooses what to do next; and every two seconds on the bottom of the
        // screen, which only moves with the Dock.
        let onWindow = (surface?.id ?? 0) != 0
        let airborne = mode == .jumping || mode == .falling
        if following || ticksLeft <= 0 || ((onWindow || airborne) && state.frame % 2 == 0) || state.frame % 8 == 0 {
            readSurfaces(f)
        }

        let night = RefugeRules.isNight(Calendar.current.component(.hour, from: Date()))
        switch mode {
        case .walk:
            guard let s = surface else { startFalling(); break }
            feet.x += direction * 3
            if state.frame % 2 == 0, jumpTicks == 0 { state.lift = 1 }
            // Coming in from off the screen, it keeps walking in; then it turns at the ends of its edge.
            if entering, s.contains(feet.x) { entering = false }
            if !entering, feet.x < s.minX || feet.x > s.maxX {
                // At the end of its edge: a hop onto the next one if it is right there (the Dock, a window), else it turns.
                let edge = direction > 0 ? s.maxX : s.minX
                if let next = surfaces.first(where: { $0 != s && abs($0.y - s.y) < 150
                    && abs((direction > 0 ? $0.minX : $0.maxX) - edge) < 2 * Self.reach + 50 }) {
                    leap(to: CGPoint(x: direction > 0 ? next.minX : next.maxX, y: next.y), landing: .surface(next), walkOn: true)
                    break
                }
                feet.x = min(max(feet.x, s.minX), s.maxX)
                direction = -direction
                if Bool.random() { next(f, night: night) }
            }
            if ticksLeft <= 0 { next(f, night: night) }
        case .sit:
            if ticksLeft <= 0 { next(f, night: night) }
        case .sleep:
            // A nap: at night it takes many, between two strolls.
            state.mood = .sleepy
            if ticksLeft <= 0 {
                refreshLook()
                next(f, night: night)
            }
        case .jumping:
            guard var j = jump else { startFalling(); break }
            j.step += 1
            let t = CGFloat(j.step) / CGFloat(j.steps)
            feet.x = j.from.x + (j.to.x - j.from.x) * t
            feet.y = j.from.y + (j.to.y - j.from.y) * t + j.height * sin(t * .pi)
            jump = j
            if j.step >= j.steps { land(j.landing, f: f) }
        case .falling:
            fallSpeed = min(fallSpeed + 3, 36)
            let below = landing(under: feet, maxY: feet.y)
            feet.y -= fallSpeed
            if let below, feet.y <= below.y {
                feet.y = below.y
                surface = below
                mode = .sit
                ticksLeft = Int.random(in: 8...16)
                jumpTicks = 2
                say("Ouf !")
            } else if feet.y < f.minY - 200 {
                // Off the screen somehow: back on its feet at the bottom.
                surface = surfaces.first { $0.id == 0 }
                feet = CGPoint(x: min(max(feet.x, f.minX + Self.reach), f.maxX - Self.reach), y: f.minY)
                mode = .sit
            }
        case .lean(let left):
            // Clinging to the edge, a little in and out, as if it were looking around.
            let peek: CGFloat = state.frame % 8 < 4 ? 30 : 34
            feet.x = left ? f.minX - (Self.figure.maxX - peek) + Self.size.width / 2 : f.maxX - Self.figure.minX - peek + Self.size.width / 2
            if ticksLeft <= 0 {
                // It lets go of the edge, back on the screen, and drops to what is below.
                feet.x = left ? f.minX + Self.reach + 4 : f.maxX - Self.reach - 4
                startFalling()
            }
        case .hang:
            // Upside down under the menu bar, swinging a little.
            feet.y = f.maxY - Self.figure.height - (state.frame % 8 < 4 ? 0 : 3)
            if ticksLeft <= 0 { startFalling() }
        case .leaving:
            if ticksLeft <= 0 {
                panel.alphaValue = max(0, panel.alphaValue - 0.25)
                if panel.alphaValue <= 0 {
                    stop()
                    model?.companionLeft()
                    return
                }
            }
        }
        // Told to the window server only when it changes: sitting still costs it nothing.
        let corner = NSPoint(x: origin.x.rounded(), y: origin.y.rounded())
        if panel.frame.origin != corner { panel.setFrameOrigin(corner) }
        // Clicks go through, except on the chamois itself.
        let mouse = NSEvent.mouseLocation
        let body = Self.figure.offsetBy(dx: origin.x, dy: origin.y)
        let through = !body.insetBy(dx: 4, dy: 4).contains(mouse)
        if panel.ignoresMouseEvents != through { panel.ignoresMouseEvents = through }
    }

    /// Standing on something: it follows its window when dragged, and falls when the window closes, is covered or moves
    /// away from under it.
    private func holdOn(_ f: NSRect) {
        guard let current = surface else { rescue(f); return }
        if current.id <= 0 {
            // The ground or the Dock: it stays on as long as it stands over it (the Dock grows and shrinks a little).
            if let s = surfaces.first(where: { $0.id == current.id && $0.minX - 30 <= feet.x && feet.x <= $0.maxX + 30 }) {
                feet.x = min(max(feet.x, s.minX), s.maxX)
                feet.y = s.y
                surface = s
            } else {
                rescue(f)
            }
            return
        }
        // Its window, where it is now: dragged, it carries the chamois along.
        let moved = surfaces.filter { $0.id == current.id }.map { (surface: $0, x: feet.x + ($0.left - current.left)) }
        if let m = moved.first(where: { $0.surface.contains($0.x) }) {
            feet.x = m.x
            feet.y = m.surface.y
            surface = m.surface
        } else {
            rescue(f)
        }
    }

    /// It lost its footing: it jumps to the nearest edge, clings to a side of the screen, or hangs from the top; else it
    /// drops to what is below.
    private func rescue(_ f: NSRect) {
        say("Oups !")
        func spot(_ s: RefugeSurface) -> CGPoint { CGPoint(x: min(max(feet.x, s.minX), s.maxX), y: s.y) }
        func distance(_ p: CGPoint) -> CGFloat { hypot(p.x - feet.x, p.y - feet.y) }
        let roll = Int.random(in: 0..<100)
        if roll < 55, let best = surfaces.map({ (s: $0, p: spot($0)) }).min(by: { distance($0.p) < distance($1.p) }) {
            leap(to: best.p, landing: .surface(best.s))
        } else if roll < 80 {
            leanOnSide(f)
        } else {
            leap(to: CGPoint(x: feet.x, y: f.maxY - Self.figure.height), landing: .hang)
        }
    }

    /// Onto the nearest side of the screen, its head peeking in.
    private func leanOnSide(_ f: NSRect) {
        let left = feet.x < f.midX
        let x = left ? f.minX - (Self.figure.maxX - 32) + Self.size.width / 2 : f.maxX - Self.figure.minX - 32 + Self.size.width / 2
        let y = min(max(feet.y + CGFloat.random(in: 40...160), f.minY + 40), f.maxY - 140)
        leap(to: CGPoint(x: x, y: y), landing: .lean(left: left))
    }

    private func startFalling() {
        state.rotation = 0
        surface = nil
        jump = nil
        fallSpeed = 0
        mode = .falling
    }

    /// The highest place to stand under a point.
    private func landing(under p: CGPoint, maxY: CGFloat) -> RefugeSurface? {
        surfaces.filter { $0.contains(p.x) && $0.y <= maxY + 1 }.max { $0.y < $1.y }
    }

    private func land(_ landing: Jump.Landing, f: NSRect) {
        let walkOnAfterLanding = jump?.walkOn ?? false
        jump = nil
        switch landing {
        case .surface(let s):
            // The window may have moved meanwhile: it lands where it still is, or falls.
            if let now = surfaces.first(where: { $0.id == s.id && $0.minX - 30 <= feet.x && feet.x <= $0.maxX + 30 && abs($0.y - feet.y) < 12 }) {
                feet.x = min(max(feet.x, now.minX), now.maxX)
                feet.y = now.y
                surface = now
                if walkOnAfterLanding {
                    mode = .walk
                    ticksLeft = Int.random(in: 30...80)
                } else {
                    mode = .sit
                    ticksLeft = Int.random(in: 16...40)
                    jumpTicks = 2
                }
            } else {
                startFalling()
            }
        case .lean(let left):
            mode = .lean(left: left)
            state.rotation = left ? 90 : -90
            ticksLeft = Int.random(in: 24...48)
            say("Coucou !")
        case .hang:
            mode = .hang
            state.rotation = 180
            ticksLeft = Int.random(in: 24...48)
        }
    }

    private func leap(to point: CGPoint, landing: Jump.Landing, walkOn: Bool = false) {
        state.rotation = 0
        let distance = hypot(point.x - feet.x, point.y - feet.y)
        // A big leap takes longer and goes higher, up to the top of a window under the menu bar.
        jump = Jump(from: feet, to: point, steps: max(4, min(22, Int(distance / 30))), height: 18 + min(120, distance * 0.15), landing: landing,
                    walkOn: walkOn)
        surface = nil
        mode = .jumping
    }

    /// What it does next, as it likes: walk, sit, jump to another edge, lean in from a side, hang from the top; at
    /// night, mostly a nap.
    private func next(_ f: NSRect, night: Bool = false) {
        state.rotation = 0
        if night, Int.random(in: 0..<100) < 55 {
            mode = .sleep
            ticksLeft = Int.random(in: 120...240)
            return
        }
        let roll = Int.random(in: 0..<100)
        let others = surfaces.filter { $0.id != surface?.id }
        switch roll {
        case ..<30:
            mode = .walk
            direction = Bool.random() ? 1 : -1
            ticksLeft = Int.random(in: 40...110)
        case ..<52:
            mode = .sit
            ticksLeft = Int.random(in: 24...60)
        case ..<84:
            // Onto another edge: the top of a window, or down to the bottom of the screen.
            if let s = others.randomElement() {
                let x = CGFloat.random(in: s.minX...max(s.minX, s.maxX))
                leap(to: CGPoint(x: x, y: s.y), landing: .surface(s))
            } else {
                mode = .walk
                ticksLeft = 60
            }
        case ..<93:
            // Onto the side of the screen, its head peeking in.
            leanOnSide(f)
        default:
            // Up to the top of the screen, to hang upside down.
            leap(to: CGPoint(x: feet.x, y: f.maxY - Self.figure.height), landing: .hang)
        }
    }

    // MARK: Where it can stand

    /// Asks for a fresh reading of the windows and the Dock, away from the main thread; it lands at the next frames.
    private func readSurfaces(_ f: NSRect) {
        guard !reading else { return }
        reading = true
        let full = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? f
        let primary = NSScreen.screens.first?.frame.height
        Self.readQueue.async { [weak self] in
            let list = Self.currentSurfaces(full: full, visible: f, primary: primary)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.surfacesRead(list) }
            }
        }
    }

    /// A reading came back: it follows its window if it was dragged, or falls if the window went away.
    private func surfacesRead(_ list: [RefugeSurface]) {
        reading = false
        guard panel != nil, let f = Self.screenFrame else { return }
        let before = surface
        let onWindow = (before?.id ?? 0) != 0
        surfaces = list
        if entering, mode == .walk, (before?.id ?? 0) <= 0 {
            // Still walking in from the right: onto the real ground at that end (beside the Dock, or on it).
            if let ground = list.filter({ $0.id <= 0 }).max(by: { $0.maxX < $1.maxX }) {
                surface = ground
                feet.y = ground.y
            }
        } else if [.walk, .sit, .sleep].contains(mode), !entering {
            holdOn(f)
        }
        following = onWindow && surface?.id == before?.id && surface?.left != before?.left
    }

    /// The bottom of the screen, the Dock and the visible top edges of the windows on it, front to back. Any thread.
    nonisolated private static func currentSurfaces(full: NSRect, visible f: NSRect, primary: CGFloat?) -> [RefugeSurface] {
        let dock = dockRect(full: full, visible: f, primary: primary)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary else { return surfaces(windows: [], full: full, visible: f, dock: dock) }
        var windows: [(id: Int, rect: CGRect)] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            windows.append((w[kCGWindowNumber as String] as? Int ?? 0, CGRect(x: b.minX, y: primary - b.maxY, width: b.width, height: b.height)))
        }
        return surfaces(windows: windows, full: full, visible: f, dock: dock)
    }

    nonisolated(unsafe) private static var dockCache: (rect: CGRect?, at: Date)?

    /// Where the Dock's bar really is when it sits at the bottom (its own window covers the whole screen): read through
    /// accessibility when the app may, else estimated from the Dock's settings. Nil when it hides or sits on a side.
    nonisolated private static func dockRect(full: NSRect, visible: NSRect, primary: CGFloat?) -> CGRect? {
        if let c = dockCache, Date().timeIntervalSince(c.at) < 5 { return c.rect }
        let rect = readDock(full: full, visible: visible, primary: primary)
        dockCache = (rect, Date())
        return rect
    }

    nonisolated private static func readDock(full: NSRect, visible: NSRect, primary: CGFloat?) -> CGRect? {
        let height = visible.minY - full.minY
        guard height > 8 else { return nil }
        if AXIsProcessTrusted(), let primary, let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            let app = AXUIElementCreateApplication(dock.processIdentifier)
            // A Dock busy laying out the screens again answers late: the estimate below will do meanwhile.
            AXUIElementSetMessagingTimeout(app, 0.25)
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success {
                for child in (children as? [AXUIElement]) ?? [] {
                    AXUIElementSetMessagingTimeout(child, 0.25)
                    var pos: CFTypeRef?, size: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &pos) == .success,
                          AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &size) == .success,
                          let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { continue }
                    var p = CGPoint.zero, s = CGSize.zero
                    AXValueGetValue(pos as! AXValue, .cgPoint, &p)
                    AXValueGetValue(size as! AXValue, .cgSize, &s)
                    if s.width > 50 { return CGRect(x: p.x, y: primary - p.y - s.height, width: s.width, height: s.height) }
                }
            }
        }
        // Without accessibility: centred, as wide as its icons.
        let d = UserDefaults(suiteName: "com.apple.dock")
        let apps = (d?.array(forKey: "persistent-apps") as? [[String: Any]]) ?? []
        let ids = Set(apps.compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String })
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !ids.contains($0.bundleIdentifier ?? "") && $0.bundleIdentifier != "com.apple.finder"
        }.count
        let others = d?.array(forKey: "persistent-others")?.count ?? 0
        let tile = (d?.double(forKey: "tilesize")).flatMap { $0 > 0 ? CGFloat($0) : nil } ?? 48
        let width = min(full.width - 40, CGFloat(ids.count + running + others + 2) * (tile + 3) + 20)
        return CGRect(x: full.midX - width / 2, y: full.minY, width: width, height: height - 4)
    }

    /// Where it can stand, from the windows (front to back, in screen coordinates), the screen and the Dock: the bottom of
    /// the screen beside the Dock, the top of the Dock, and each window's top edge minus the parts covered by windows in
    /// front, up to the menu bar.
    nonisolated static func surfaces(windows: [(id: Int, rect: CGRect)], full: CGRect, visible f: CGRect, dock: CGRect?) -> [RefugeSurface] {
        var out: [RefugeSurface] = []
        if let dock, dock.minY < f.minY {
            for (from, to) in [(full.minX, dock.minX - 2), (dock.maxX + 2, full.maxX)] where to - from >= 2 * reach + 10 {
                out.append(RefugeSurface(id: 0, y: full.minY, minX: from + reach, maxX: to - reach, left: full.minX))
            }
            if dock.width >= 2 * reach + 10 {
                out.append(RefugeSurface(id: -1, y: dock.maxY, minX: dock.minX + reach, maxX: dock.maxX - reach, left: dock.minX))
            }
        } else {
            out.append(RefugeSurface(id: 0, y: f.minY, minX: f.minX + reach, maxX: f.maxX - reach, left: f.minX))
        }
        var front: [CGRect] = []
        for w in windows {
            defer { front.append(w.rect) }
            let top = w.rect.maxY
            guard w.rect.width >= 160, w.rect.height >= 80, top >= f.minY + 60, top <= f.maxY + 1 else { continue }
            var segments: [(CGFloat, CGFloat)] = [(max(w.rect.minX, f.minX), min(w.rect.maxX, f.maxX))]
            for r in front where r.minY <= top + 2 && r.maxY >= top - 2 {
                segments = segments.flatMap { s -> [(CGFloat, CGFloat)] in
                    guard r.maxX > s.0, r.minX < s.1 else { return [s] }
                    return [(s.0, r.minX), (r.maxX, s.1)].filter { $0.1 - $0.0 > 0 }
                }
            }
            for s in segments where s.1 - s.0 >= 2 * reach + 30 {
                out.append(RefugeSurface(id: w.id, y: top, minX: s.0 + reach, maxX: s.1 - reach, left: w.rect.minX))
            }
        }
        return out
    }

    static func selfTest() -> [String] {
        var f: [String] = []
        let full = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 795)
        // A window in front, another behind it whose top edge it half covers, a tiny one, one right under the menu bar,
        // one reaching into it.
        let windows: [(id: Int, rect: CGRect)] = [
            (1, CGRect(x: 600, y: 200, width: 500, height: 500)),
            (2, CGRect(x: 100, y: 150, width: 800, height: 400)),
            (3, CGRect(x: 1200, y: 300, width: 100, height: 60)),
            (4, CGRect(x: 0, y: 90, width: 1440, height: 785)),
            (5, CGRect(x: 0, y: 90, width: 1440, height: 805)),
        ]
        let dock = CGRect(x: 400, y: 4, width: 640, height: 76)
        let s = surfaces(windows: windows, full: full, visible: visible, dock: dock)
        let ground = s.filter { $0.id == 0 }
        if ground.count != 2 || ground.contains(where: { $0.y != 0 }) || ground.contains(where: { $0.maxX > 400 && $0.minX < 1040 }) {
            f.append("Compagnon : le sol doit être le bas de l'écran de part et d'autre du Dock")
        }
        if !s.contains(where: { $0.id == -1 && $0.y == 80 && $0.minX == 400 + reach }) { f.append("Compagnon : le dessus du Dock n'est pas une surface") }
        if !s.contains(where: { $0.id == 1 && $0.y == 700 && $0.minX == 600 + reach }) { f.append("Compagnon : le haut de la fenêtre devant manque") }
        let back = s.filter { $0.id == 2 }
        if back.count != 1 || back.first?.maxX != 600 - reach { f.append("Compagnon : la partie cachée d'une fenêtre derrière reste une surface") }
        if s.contains(where: { $0.id == 3 || $0.id == 5 }) { f.append("Compagnon : une fenêtre minuscule ou sous la barre des menus est une surface") }
        if !s.contains(where: { $0.id == 4 && $0.y == 875 }) { f.append("Compagnon : une grande fenêtre sous la barre des menus doit rester une surface") }
        if s.contains(where: { $0.minX > $0.maxX }) { f.append("Compagnon : surface à l'envers") }
        // A Dock hidden or on a side: the whole bottom of the screen.
        let plain = surfaces(windows: [], full: full, visible: CGRect(x: 0, y: 0, width: 1440, height: 875), dock: nil)
        if plain.count != 1 || plain.first?.y != 0 || plain.first?.minX != reach { f.append("Compagnon : sans Dock, tout le bas de l'écran") }
        return f
    }
}

/// The companion itself: its word above it (when it stands), the chamois below, leaning as it does.
private struct RefugeCompanionView: View {
    var state: RefugeCompanionState
    var tap: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Group {
                if let word = state.word, state.rotation == 0 {
                    Text(word).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.card))
                        .overlay(Capsule().strokeBorder(Theme.borderStrong, lineWidth: 1))
                } else {
                    Color.clear
                }
            }
            .frame(height: 18)
            Canvas { ctx, _ in
                RefugeFigure.draw(in: ctx, pixel: RefugeCompanion.pixel, look: state.look, mood: state.mood, frame: state.frame,
                                  blink: state.frame % 18 == 17, lift: state.lift)
            }
            .frame(width: CGFloat(RefugeFigure.cols) * RefugeCompanion.pixel, height: CGFloat(RefugeFigure.rows) * RefugeCompanion.pixel)
            .rotationEffect(.degrees(state.rotation))
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
        }
        .frame(width: RefugeCompanion.size.width, height: RefugeCompanion.size.height, alignment: .bottom)
    }
}
