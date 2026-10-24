import SwiftUI
import AppKit

// MARK: - Activities

/// What the pixel mascot does while the app works: each kind of wait gets its own little scene,
/// drawn on a grid of 24 × 14 pixels in the style of `PixelMascot`.
enum MascotActivity: String, CaseIterable, Identifiable {
    /// Storage map: files go from a messy heap to tidy piles.
    case sorting
    /// Cleaning, Trash, uninstalling: it polishes a pile of files with its chamois cloth, the dust flies off.
    case sweeping
    /// Translation: an open book, eyes running along the lines.
    case reading
    /// Smart scan, Protection: a magnifying glass over the files passing by.
    case inspecting
    /// Inventory, security review: a clipboard, one box ticked after the other.
    case checking
    /// Spotlight, file search: a torch sweeps the dark.
    case searching
    /// Updates: an arrow falls from the cloud into a box.
    case downloading
    /// Installing the new version: the box opens and the app comes out.
    case unpacking
    /// Converter: a file goes into a gear machine and comes out in another shape.
    case converting
    /// Assistant: a thought bubble.
    case thinking
    /// Benchmark, boost: dumbbells.
    case lifting
    /// Network: an antenna sends its waves.
    case beaming
    /// Battery: a cell fills up.
    case charging
    /// Any other task in progress: a small computer.
    case typing

    var id: String { rawValue }

    /// Read by VoiceOver, and the caption of the gallery (`--snapshot --page mascotte`).
    var label: String {
        switch self {
        case .sorting: return "Je trie tes fichiers"
        case .sweeping: return "Je fais briller"
        case .reading: return "Je lis et je traduis"
        case .inspecting: return "J'inspecte à la loupe"
        case .checking: return "Je coche ma liste"
        case .searching: return "Je cherche avec ma lampe"
        case .downloading: return "Je télécharge"
        case .unpacking: return "Je déballe la nouvelle version"
        case .converting: return "Je convertis"
        case .thinking: return "Je réfléchis"
        case .lifting: return "Je soulève de la fonte"
        case .beaming: return "J'émets et je reçois"
        case .charging: return "Je recharge"
        case .typing: return "Je travaille"
        }
    }

    var frameCount: Int {
        switch self {
        case .sorting: return 12
        case .converting, .thinking, .lifting, .beaming, .charging: return 6
        case .typing: return 4
        default: return 8
        }
    }

    /// Seconds per frame: a few images a second are enough for pixel art.
    var interval: Double {
        switch self {
        case .sweeping, .typing: return 0.18
        case .reading, .checking, .unpacking: return 0.26
        case .thinking, .lifting, .charging: return 0.3
        default: return 0.22
        }
    }

    /// The frame that tells the most: drawn in snapshots, when motion is reduced and while the window is hidden.
    var stillFrame: Int {
        switch self {
        case .sorting: return 1
        case .sweeping: return 3
        case .reading: return 4
        case .inspecting: return 2
        case .checking: return 5
        case .searching: return 2
        case .downloading: return 4
        case .unpacking: return 5
        case .converting: return 4
        case .thinking: return 2
        case .lifting: return 2
        case .beaming: return 2
        case .charging: return 3
        case .typing: return 3
        }
    }

    func frame(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / interval) % frameCount
    }

    /// Pure checks for `--selftest`: every scene loops on valid frames, a few images a second at most.
    static func selfTest() -> [String] {
        var failures: [String] = []
        for a in allCases {
            if a.label.isEmpty { failures.append("Mascotte \(a.rawValue) : pas de libellé") }
            if !(2...12).contains(a.frameCount) { failures.append("Mascotte \(a.rawValue) : \(a.frameCount) images") }
            if !(0..<a.frameCount).contains(a.stillFrame) { failures.append("Mascotte \(a.rawValue) : image fixe hors de la boucle") }
            // Faster than 6 images a second would redraw for nothing (rule 5 of CLAUDE.md).
            if a.interval < 1.0 / 6 { failures.append("Mascotte \(a.rawValue) : \(a.interval) s par image, trop rapide") }
            let frames = Set((0..<40).map { a.frame(at: Date(timeIntervalSinceReferenceDate: 1_000 + Double($0) * a.interval)) })
            if frames != Set(0..<a.frameCount) { failures.append("Mascotte \(a.rawValue) : la boucle saute des images") }
        }
        return failures
    }
}

// MARK: - View

/// The mascot busy with `activity`, to drop in any wait of the app: `BusyMascot(.sweeping, pixel: 4)` in the waiting
/// card of a page, `BusyMascot(.reading, pixel: 1.5)` in a status line, `BusyMascot(.inspecting, pixel: 1, ink: Theme.onAccent)`
/// in a filled button. A few frames a second, only while it is on screen; a still frame in snapshots and when motion is
/// reduced. Themes without the mascot (Graphite) get a plain spinner.
struct BusyMascot: View {
    static let columns = 24
    /// One row above the scenes (14 rows) for the tall horns of a grown chamois.
    static let rows = 15
    static let sceneRows = 14

    var activity: MascotActivity
    /// One pixel of the scene, in points: 1 in a button, 1.5 in a status line, 3 or 4 in the waiting card of a page.
    var pixel: CGFloat = 3
    /// Draws everything in this single color (on a filled button), the eyes cut out.
    var ink: Color? = nil
    /// A fixed frame instead of the animation (the gallery of `--page mascotte`).
    var frame: Int? = nil

    init(_ activity: MascotActivity, pixel: CGFloat = 3, ink: Color? = nil, frame: Int? = nil) {
        self.activity = activity
        self.pixel = pixel
        self.ink = ink
        self.frame = frame
    }

    /// Fixed origin of the timeline, so a page refresh does not restart the scene.
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = true

    var body: some View {
        Group {
            if Theme.current.spec.mascot {
                scene
            } else {
                MascotSpinner(height: pixel * CGFloat(Self.rows), ink: ink)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(activity.label)
    }

    @ViewBuilder
    private var scene: some View {
        if let frame {
            MascotCanvas(activity: activity, frame: frame, pixel: pixel, ink: ink)
        } else if Snapshot.isActive {
            MascotCanvas(activity: activity, frame: activity.stillFrame, pixel: pixel, ink: ink)
        } else {
            Group {
                if reduceMotion || !onScreen {
                    MascotCanvas(activity: activity, frame: activity.stillFrame, pixel: pixel, ink: ink)
                } else {
                    // A timer-driven timeline redraws this canvas only, a few times a second (no display link).
                    TimelineView(.periodic(from: Self.epoch, by: activity.interval)) { context in
                        MascotCanvas(activity: activity, frame: activity.frame(at: context.date), pixel: pixel, ink: ink)
                    }
                }
            }
            .background(MascotWindowProbe(onScreen: $onScreen))
        }
    }
}

/// What stands in for the mascot in the themes without it: the system spinner (a still arc in snapshots).
private struct MascotSpinner: View {
    var height: CGFloat
    var ink: Color?

    var body: some View {
        let d = min(max(height * 0.8, 11), 30)
        Group {
            if Snapshot.isActive {
                Circle().trim(from: 0, to: 0.7)
                    .stroke(ink ?? Theme.text3, style: StrokeStyle(lineWidth: d > 20 ? 3 : 2, lineCap: .round))
                    .frame(width: d * 0.8, height: d * 0.8)
            } else if d > 20 {
                ProgressView().controlSize(.regular)
            } else {
                ProgressView().controlSize(.small).scaleEffect(d / 16).tint(ink)
            }
        }
        .frame(width: d, height: d)
    }
}

/// The user's own chamois, once adopted in the Refuge: the waiting scenes and the mascot at rest show it, at its stage and
/// in its clothes. Nil: the app's mascot. Set by the Refuge whenever it changes.
enum MascotStyle {
    nonisolated(unsafe) static var look: RefugeLook?
}

/// Tells whether the window holding the mascot is on screen (not minimised, hidden or fully covered),
/// so that the timeline stops when nobody can see it.
struct MascotWindowProbe: NSViewRepresentable {
    @Binding var onScreen: Bool

    func makeNSView(context: Context) -> MascotProbeView {
        let view = MascotProbeView()
        view.report = { visible in onScreen = visible }
        return view
    }

    func updateNSView(_ view: MascotProbeView, context: Context) {
        view.report = { visible in onScreen = visible }
    }
}

final class MascotProbeView: NSView {
    var report: ((Bool) -> Void)?
    private var observer: NSObjectProtocol?
    private var last: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let window {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                              object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
        update()
    }

    private func update() {
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        guard visible != last else { return }
        last = visible
        // Never during SwiftUI's own update of the view.
        DispatchQueue.main.async { [report] in report?(visible) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

// MARK: - Drawing

private struct MascotCanvas: View, Equatable {
    var activity: MascotActivity
    var frame: Int
    var pixel: CGFloat
    var ink: Color?

    static func == (a: MascotCanvas, b: MascotCanvas) -> Bool {
        a.activity == b.activity && a.frame == b.frame && a.pixel == b.pixel && a.ink == b.ink
    }

    var body: some View {
        Canvas { ctx, _ in
            // The mascot's contour first (it only shows on light backgrounds), then the scene: whatever the scene
            // draws next to the mascot covers it, so the contour stays on the empty cells around its head and body.
            var scene = ctx
            scene.translateBy(x: 0, y: pixel)
            if ink == nil {
                var outline = MascotPainter(ctx: scene, pixel: pixel, ink: nil, palette: Theme.palette, contourOnly: true)
                MascotScenes.draw(activity, frame: frame, on: &outline)
            }
            var p = MascotPainter(ctx: scene, pixel: pixel, ink: ink, palette: Theme.palette)
            MascotScenes.draw(activity, frame: frame, on: &p)
        }
        .frame(width: pixel * CGFloat(BusyMascot.columns), height: pixel * CGFloat(BusyMascot.rows))
        .allowsHitTesting(false)
    }
}

/// Paints on the 24 × 14 grid with the theme's colors (or a single ink).
private struct MascotPainter {
    enum Tone { case strong, line, soft, paper, accent, good, warn, fur, cloth, clothShade, chart(Int) }

    var ctx: GraphicsContext
    var pixel: CGFloat
    var ink: Color?
    var palette: [Color]
    /// The first pass of a scene: the mascot's contour only, nothing else.
    var contourOnly = false

    func color(_ tone: Tone) -> Color {
        if let ink {
            switch tone {
            case .strong, .fur, .cloth, .clothShade: return ink
            case .line, .accent, .good, .warn, .chart: return ink.opacity(0.8)
            case .soft: return ink.opacity(0.5)
            case .paper: return ink.opacity(0.35)
            }
        }
        switch tone {
        case .strong: return Theme.text
        case .line: return Theme.text2
        case .soft: return Theme.text3
        case .paper: return Theme.text3.opacity(0.4)
        case .accent: return Theme.accent
        case .good: return Theme.good
        case .warn: return Theme.warn
        case .fur: return Theme.mascot.fur
        case .cloth: return Theme.mascot.cloth
        case .clothShade: return Theme.mascot.clothShade
        case .chart(let i): return palette.isEmpty ? Theme.accent : palette[abs(i) % palette.count]
        }
    }

    func rect(_ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1, _ tone: Tone, alpha: Double = 1) {
        guard !contourOnly, w > 0, h > 0, alpha > 0 else { return }
        let r = CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: CGFloat(w) * pixel, height: CGFloat(h) * pixel)
        ctx.fill(Path(r), with: .color(color(tone).opacity(alpha)))
    }

    func dot(_ x: Int, _ y: Int, _ tone: Tone, alpha: Double = 1) { rect(x, y, 1, 1, tone, alpha: alpha) }

    /// A straight run of pixels (Bresenham).
    func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ tone: Tone, alpha: Double = 1) {
        var x = x0, y = y0
        let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            dot(x, y, tone, alpha: alpha)
            if x == x1 && y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    /// A rectangle drawn as its outline.
    func frame(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ tone: Tone, alpha: Double = 1) {
        rect(x, y, w, 1, tone, alpha: alpha)
        rect(x, y + h - 1, w, 1, tone, alpha: alpha)
        rect(x, y + 1, 1, h - 2, tone, alpha: alpha)
        rect(x + w - 1, y + 1, 1, h - 2, tone, alpha: alpha)
    }

    /// A small file: a colored band on top of a sheet.
    func file(_ x: Int, _ y: Int, w: Int = 2, h: Int = 3, band: Tone, alpha: Double = 1) {
        rect(x, y, w, 1, band, alpha: alpha)
        rect(x, y + 1, w, h - 1, .paper, alpha: alpha)
    }

    /// The mascot, 11 × 12 pixels from (x, y), its feet on row y + 11 (`MascotFigure`).
    func mascot(_ x: Int, _ y: Int, _ pose: MascotFigure.Pose = MascotFigure.Pose()) {
        if let look = MascotStyle.look {
            // The user's own chamois, its feet where the app's mascot has them.
            let origin = CGPoint(x: CGFloat(x - 3) * pixel, y: CGFloat(y + MascotFigure.height - RefugeFigure.rows) * pixel)
            if contourOnly {
                let edge = Theme.mascot.contour
                for c in RefugeFigure.contour(RefugeFigure.pixels(look, pose: pose).body) {
                    ctx.fill(Path(CGRect(x: origin.x + CGFloat(c.x) * pixel, y: origin.y + CGFloat(c.y) * pixel, width: pixel, height: pixel)),
                             with: .color(edge))
                }
            } else {
                RefugeFigure.draw(in: ctx, at: origin, pixel: pixel, look: look, ink: ink, pose: pose, contour: false)
            }
            return
        }
        if contourOnly {
            let edge = Theme.mascot.contour
            for c in MascotFigure.contour(pose) {
                let r = CGRect(x: CGFloat(x + c.x) * pixel, y: CGFloat(y + c.y) * pixel, width: pixel, height: pixel)
                ctx.fill(Path(r), with: .color(edge))
            }
        } else {
            MascotFigure.draw(in: ctx, at: CGPoint(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel), pixel: pixel, pose: pose, ink: ink)
        }
    }

    /// A front leg reaching out of the chest of the mascot standing at (x, y), on its right (or left) side, to (tx, ty).
    /// Drawn before the mascot, it passes behind its head.
    func arm(_ x: Int, _ y: Int, right: Bool = true, to tx: Int, _ ty: Int) {
        line(x + (right ? 9 : 1), y + 9, tx, ty, .fur)
    }

    /// The yellow chamois cloth, 3 × 2 pixels from (x, y).
    func cloth(_ x: Int, _ y: Int) {
        rect(x, y, 2, 1, .cloth)
        rect(x + 2, y, 1, 1, .clothShade)
        rect(x, y + 1, 1, 1, .cloth)
        rect(x + 1, y + 1, 2, 1, .clothShade)
    }
}

// MARK: - Scenes

private enum MascotScenes {
    static func draw(_ activity: MascotActivity, frame: Int, on p: inout MascotPainter) {
        let t = ((frame % activity.frameCount) + activity.frameCount) % activity.frameCount
        switch activity {
        case .sorting: sorting(t, p)
        case .sweeping: sweeping(t, p)
        case .reading: reading(t, p)
        case .inspecting: inspecting(t, p)
        case .checking: checking(t, p)
        case .searching: searching(t, p)
        case .downloading: downloading(t, p)
        case .unpacking: unpacking(t, p)
        case .converting: converting(t, p)
        case .thinking: thinking(t, p)
        case .lifting: lifting(t, p)
        case .beaming: beaming(t, p)
        case .charging: charging(t, p)
        case .typing: typing(t, p)
        }
    }

    /// A heap of mixed files on the left, three tidy piles on the right; one file at a time goes over the head.
    private static func sorting(_ t: Int, _ p: MascotPainter) {
        let cycle = t / 4, step = t % 4
        let heap: [(Int, Int, Int)] = [(0, 13, 0), (1, 13, 1), (2, 13, 2), (3, 13, 1), (4, 13, 0), (5, 13, 2),
                                       (1, 12, 2), (2, 12, 0), (3, 12, 1), (4, 12, 0), (2, 11, 1), (3, 11, 2)]
        for (x, y, c) in heap { p.dot(x, y, .chart(c)) }
        for s in 0..<3 {
            let done = cycle > s || (cycle == s && step == 3)
            let height = [2, 3, 1][s] + (done ? 1 : 0)
            for i in 0..<height { p.rect(18 + s * 2, 13 - i, 2, 1, .chart(s), alpha: i % 2 == 0 ? 1 : 0.75) }
        }
        let c = cycle % 3, x = 6, y = 2
        switch step {
        case 0:
            p.arm(x, y, right: false, to: 7, 11)
            p.mascot(x, y, MascotFigure.Pose(look: -1))
            p.rect(5, 10, 2, 2, .chart(c))
        case 1:
            p.arm(x, y, right: false, to: 9, 1)
            p.arm(x, y, to: 12, 1)
            p.mascot(x, y)
            p.rect(10, 0, 2, 2, .chart(c))
        case 2:
            p.arm(x, y, to: 16, 9)
            p.mascot(x, y, MascotFigure.Pose(look: 1))
            p.rect(17 + c, 7, 2, 2, .chart(c))
        default:
            p.mascot(x, y, MascotFigure.Pose(look: 1, blink: true))
        }
    }

    /// It polishes a pile of files with its chamois cloth: the cloth goes round, the dust flies, the top file shines.
    private static func sweeping(_ t: Int, _ p: MascotPainter) {
        p.file(16, 8, w: 4, h: 3, band: .chart(0))
        p.file(16, 11, w: 4, h: 3, band: .chart(1))
        let spot = [(14, 8), (15, 7), (16, 6), (17, 6), (17, 7), (16, 8), (15, 8), (14, 7)][t]
        p.arm(4, 2, to: spot.0 - 1, spot.1 + 1)
        p.mascot(4, 2, MascotFigure.Pose(look: 1, blink: t == 6))
        p.cloth(spot.0, spot.1)
        // A glint where it has just rubbed, then the dust rising off the top of the pile.
        if t % 4 == 3 {
            p.dot(20, 5, .warn)
            p.dot(19, 5, .warn, alpha: 0.5)
            p.dot(21, 5, .warn, alpha: 0.5)
            p.dot(20, 4, .warn, alpha: 0.5)
        }
        for i in 0..<4 {
            let ph = (t + i * 3) % 8
            let dx = 18 + ph / 2 + (i % 2), dy = 7 - ph / 2 - (i % 3)
            if dx < BusyMascot.columns, dy >= 0 { p.dot(dx, dy, .line, alpha: 0.85 - Double(ph) / 10) }
        }
    }

    /// An open book on the ground: the line being read lights up, a page turns, translated words fly away.
    private static func reading(_ t: Int, _ p: MascotPainter) {
        let bx = 11, by = 9
        p.arm(0, 2, to: 10, 11)
        p.mascot(0, 2, MascotFigure.Pose(look: 1, blink: t == 7))
        // Pages, the spine dipping in the middle, the cover underneath.
        p.rect(bx + 1, by, 5, 1, .paper)
        p.rect(bx + 7, by, 5, 1, .paper)
        p.rect(bx, by + 1, 6, 3, .paper)
        p.rect(bx + 7, by + 1, 6, 3, .paper)
        p.rect(bx + 6, by + 1, 1, 3, .line)
        p.rect(bx, by + 4, 13, 1, .accent)
        let flipping = t == 6
        let lines = [(bx + 1, 4), (bx + 1, 3), (bx + 1, 4), (bx + 8, 3), (bx + 8, 4), (bx + 8, 2)]
        for (i, l) in lines.enumerated() where !(flipping && i >= 3) {
            let reading = i == t % 6 && !flipping
            p.rect(l.0, by + 1 + i % 3, l.1, 1, reading ? .accent : .line, alpha: reading ? 1 : 0.6)
        }
        if flipping {
            // The page standing up while it turns.
            p.rect(bx + 6, by - 4, 1, 4, .paper)
            p.rect(bx + 7, by - 3, 2, 3, .paper)
        }
        for i in 0..<2 {
            let ph = (t + i * 4) % 8
            p.rect(bx + 9 + ph / 2 + i, by - 1 - ph, 2, 1, .chart(i + 1), alpha: 1 - Double(ph) / 9)
        }
    }

    /// A magnifying glass sweeps over files passing by; the one under it shows big in the lens.
    private static func inspecting(_ t: Int, _ p: MascotPainter) {
        // Files on a conveyor, moving left.
        var under: Int?
        let sway = [0, 1, 2, 3, 4, 3, 2, 1][t]
        let lx = 13 + sway, ly = 3
        for i in 0..<3 {
            let x = 12 + ((i * 4 - t) % 12 + 12) % 12
            guard x <= 22 else { continue }
            p.file(x, 11, band: .chart(i))
            if x == lx + 1 || x + 1 == lx + 2 { under = i }
        }
        p.arm(0, 2, to: lx, ly + 4)
        p.mascot(0, 2, MascotFigure.Pose(look: 1, blink: t == 6))
        // The lens: a ring of 5 × 5 without its corners.
        p.rect(lx + 1, ly, 3, 1, .strong)
        p.rect(lx + 1, ly + 4, 3, 1, .strong)
        p.rect(lx, ly + 1, 1, 3, .strong)
        p.rect(lx + 4, ly + 1, 1, 3, .strong)
        if let under {
            p.rect(lx + 1, ly + 1, 3, 1, .chart(under))
            p.rect(lx + 1, ly + 2, 3, 2, .paper)
        } else {
            p.rect(lx + 1, ly + 1, 3, 3, .accent, alpha: 0.2)
            p.dot(lx + 1, ly + 1, .accent, alpha: 0.7)
        }
    }

    /// A clipboard held up, one line ticked after the other.
    private static func checking(_ t: Int, _ p: MascotPainter) {
        p.arm(0, 2, to: 11, 9)
        p.mascot(0, 2, MascotFigure.Pose(look: 1, blink: t == 4))
        p.frame(12, 2, 9, 12, .line)
        p.rect(13, 3, 7, 10, .paper)
        p.rect(15, 1, 3, 2, .strong)
        let current = min(3, t / 2)
        for i in 0..<4 {
            let y = 4 + i * 2 + (i > 1 ? 1 : 0)
            let ticked = i < current || (i == current && t % 2 == 1)
            p.dot(14, y, ticked ? .good : .line, alpha: ticked ? 1 : 0.5)
            p.rect(16, y, 3, 1, .soft, alpha: ticked ? 1 : 0.6)
            if ticked { p.dot(15, y - 1, .good) }
        }
        // The pencil next to the line in progress.
        let py = 4 + current * 2 + (current > 1 ? 1 : 0)
        p.dot(19, py, .strong)
        p.dot(20, py - 1, .accent)
        p.dot(21, py - 2, .accent)
    }

    /// A torch sweeps the dark; the files it lights up show.
    private static func searching(_ t: Int, _ p: MascotPainter) {
        let sweep = [0, -1, -2, -3, -2, -1, 0, 1][t]
        let ox = 13, oy = 11
        let slope = Double(sweep) / 6
        var lit: Set<Int> = []
        for x in (ox + 1)..<BusyMascot.columns {
            let d = Double(x - ox)
            let cy = Double(oy) + slope * d
            let hw = 0.5 + d * 0.33
            let top = Int((cy - hw).rounded()), bottom = Int((cy + hw).rounded())
            for y in max(0, top)...min(BusyMascot.sceneRows - 1, max(top, bottom)) {
                p.dot(x, y, .warn, alpha: 0.6 * (1 - d / 15))
                lit.insert(x * 100 + y)
            }
        }
        let files: [(Int, Int, Int)] = [(17, 4, 0), (20, 8, 1), (21, 2, 2)]
        for (x, y, c) in files {
            let shown = lit.contains(x * 100 + y + 1) || lit.contains((x + 1) * 100 + y + 1)
            p.file(x, y, band: .chart(c), alpha: shown ? 1 : 0.15)
        }
        p.arm(0, 2, to: 10, 11)
        p.mascot(0, 2, MascotFigure.Pose(look: 1, blink: t == 5))
        p.rect(11, 10, 2, 3, .strong)
    }

    /// An arrow falls from the cloud into an open box; the mascot cheers when it lands.
    private static func downloading(_ t: Int, _ p: MascotPainter) {
        p.rect(16, 0, 3, 1, .soft)
        p.rect(14, 1, 7, 1, .soft)
        p.rect(13, 2, 9, 1, .soft)
        if t < 6 {
            let y = 2 + t
            p.rect(17, y, 2, 2, .accent)
            p.rect(16, y + 2, 4, 1, .accent)
            p.rect(17, y + 3, 2, 1, .accent)
        }
        // The box, open, in front of the arrow.
        p.rect(14, 10, 8, 4, .warn)
        p.rect(15, 10, 6, 1, .warn, alpha: 0.45)
        p.dot(13, 9, .warn)
        p.dot(12, 8, .warn)
        p.dot(22, 9, .warn)
        p.dot(23, 8, .warn)
        if t >= 6 {
            let r = t == 6 ? 1 : 2
            p.dot(17 - r * 2, 8 - r, .accent)
            p.dot(18 + r * 2, 8 - r, .accent)
            p.dot(17, 7 - r, .accent, alpha: 0.7)
        }
        let cheer = t == 7, y = cheer ? 1 : 2
        if cheer {
            p.arm(1, y, right: false, to: 0, 6)
            p.arm(1, y, to: 12, 6)
        }
        p.mascot(1, y, MascotFigure.Pose(look: 1, blink: t == 3))
    }

    /// The box opens, the new app rises out of it in sparkles.
    private static func unpacking(_ t: Int, _ p: MascotPainter) {
        let tileY: Int? = [nil, nil, nil, 8, 6, 3, 2, 2][t]
        if let y = tileY {
            p.rect(16, y, 2, 4, .accent)
            p.rect(15, y + 1, 4, 2, .accent)
            p.rect(16, y + 1, 2, 2, .fur)
        }
        p.rect(13, 10, 8, 4, .warn)
        switch t {
        case 0:
            p.rect(13, 9, 8, 1, .warn)
            p.rect(16, 9, 2, 1, .line, alpha: 0.6)
        case 1:
            p.rect(17, 9, 4, 1, .warn)
            p.dot(12, 8, .warn)
            p.dot(13, 9, .warn)
        default:
            p.rect(14, 9, 6, 1, .warn, alpha: 0.45)
            p.dot(13, 9, .warn)
            p.dot(12, 8, .warn)
            p.dot(20, 9, .warn)
            p.dot(21, 8, .warn)
        }
        if t >= 5 {
            let r = t - 4
            p.dot(14 - r, 3, .accent, alpha: t == 7 ? 0.5 : 1)
            p.dot(19 + r, 4, .accent, alpha: t == 7 ? 0.5 : 1)
            p.dot(17, 1 - min(r, 1), .good, alpha: 0.8)
        }
        let cheer = t == 5 || t == 6, y = cheer ? 1 : 2
        if cheer {
            p.arm(1, y, right: false, to: 0, 6)
            p.arm(1, y, to: 12, 6)
        } else if t == 1 || t == 2 {
            p.arm(1, y, to: 12, 9)
        }
        p.mascot(1, y, MascotFigure.Pose(look: 1, blink: t == 7))
    }

    /// A tall file goes into the gear machine and comes out wide, in another color.
    private static func converting(_ t: Int, _ p: MascotPainter) {
        p.rect(12, 7, 9, 7, .soft, alpha: 0.25)
        p.frame(12, 7, 9, 7, .line)
        // The hopper on top.
        p.rect(13, 5, 7, 1, .line, alpha: 0.7)
        p.rect(14, 6, 5, 1, .line)
        gear(15, 10, phase: t % 3, tone: .accent, p)
        gear(18, 11, phase: (3 - t % 3) % 3, tone: .line, p)
        if t == 0 {
            p.arm(0, 2, right: false, to: 7, 1)
            p.arm(0, 2, to: 10, 1)
        }
        p.mascot(0, 2, MascotFigure.Pose(look: 1, blink: t == 4))
        switch t {
        case 0: p.file(8, 0, w: 2, h: 2, band: .chart(0))
        case 1: p.file(11, 1, band: .chart(0))
        case 2: p.file(15, 2, band: .chart(0))
        case 3: p.dot(21, 5, .soft, alpha: 0.7); p.dot(22, 4, .soft, alpha: 0.4)
        default: p.file(t == 4 ? 20 : 21, 12, w: 3, h: 2, band: .chart(2))
        }
    }

    private static func gear(_ cx: Int, _ cy: Int, phase: Int, tone: MascotPainter.Tone, _ p: MascotPainter) {
        p.frame(cx - 1, cy - 1, 3, 3, tone)
        let ring = [(0, -2), (1, -2), (2, -1), (2, 0), (2, 1), (1, 2), (0, 2), (-1, 2), (-2, 1), (-2, 0), (-2, -1), (-1, -2)]
        for k in 0..<4 {
            let (dx, dy) = ring[(phase + k * 3) % ring.count]
            p.dot(cx + dx, cy + dy, tone)
        }
    }

    /// The chin on the hand, eyes up: a thought bubble whose dots light up in turn.
    private static func thinking(_ t: Int, _ p: MascotPainter) {
        p.arm(2, 2, to: 10, 10)
        p.mascot(2, 2, MascotFigure.Pose(look: 1, up: true, blink: t == 4))
        p.dot(13, 8, .soft)
        p.rect(14, 6, 2, 2, .soft)
        p.rect(15, 0, 8, 1, .paper)
        p.rect(14, 1, 10, 3, .paper)
        p.rect(15, 4, 8, 1, .paper)
        for i in 0..<3 {
            let on = t % 3 == i
            p.rect(16 + i * 3, 2, 2, 1, on ? .accent : .soft, alpha: on ? 1 : 0.55)
        }
    }

    /// A barbell up to the chest, in front of the face, overhead; the eyes screwed up at the top.
    private static func lifting(_ t: Int, _ p: MascotPainter) {
        let x = 6, y = 2
        let height = [0, 1, 2, 2, 1, 0][t]
        let bar = [10, 6, 1][height]
        // Legs and barbell first: its head passes in front of them.
        p.arm(x, y, right: false, to: x - 1, bar)
        p.arm(x, y, to: x + 11, bar)
        p.rect(x - 2, bar, 15, 1, .line)
        p.rect(x - 4, bar - 1, 2, 3, .strong)
        p.rect(x + 13, bar - 1, 2, 3, .strong)
        p.mascot(x, y, MascotFigure.Pose(squint: height == 2))
        if t == 3 {
            p.dot(x + 12, y + 4, .chart(1), alpha: 0.8)
            p.dot(x - 2, y + 5, .chart(1), alpha: 0.6)
        }
    }

    /// Holding up an antenna; waves go out, bits come back.
    private static func beaming(_ t: Int, _ p: MascotPainter) {
        let cx = 12, cy = 3
        p.arm(0, 2, to: cx - 1, 9)
        p.mascot(0, 2, MascotFigure.Pose(look: 1, blink: t == 5))
        p.rect(cx, cy + 1, 1, 10, .line)
        p.rect(cx - 1, 13, 3, 1, .line)
        p.dot(cx, cy, .accent, alpha: t % 2 == 0 ? 1 : 0.5)
        let phase = t % 3
        for k in 0..<3 {
            let r = Double(2 + k * 2)
            let alpha = k == phase ? 1 : (k < phase ? 0.45 : 0.15)
            var seen = Set<Int>()
            for step in stride(from: -60.0, through: 60.0, by: 12) {
                let a = step * .pi / 180
                let x = cx + Int((r * cos(a)).rounded()), y = cy + Int((r * sin(a)).rounded())
                guard y >= 0, seen.insert(x * 100 + y).inserted else { continue }
                p.dot(x, y, .accent, alpha: alpha)
            }
        }
        for i in 0..<2 {
            let x = 23 - ((t * 2 + i * 5) % 10)
            if x > cx + 3 { p.rect(x, 10 + i * 2, 2, 1, .chart(1)) }
        }
    }

    /// A battery fills up cell after cell; a little hop when it is full.
    private static func charging(_ t: Int, _ p: MascotPainter) {
        let full = t == 5
        p.frame(12, 7, 10, 6, .line)
        p.rect(22, 9, 1, 2, .line)
        let cells = [0, 1, 2, 3, 4, 4][t]
        for i in 0..<cells { p.rect(13 + i * 2, 8, 2, 4, .good, alpha: i % 2 == 0 ? 1 : 0.8) }
        if !full {
            let a = t % 2 == 0 ? 1 : 0.55
            for (x, y) in [(18, 1), (17, 2), (16, 3), (17, 3), (18, 3), (17, 4), (16, 5)] { p.dot(x, y, .warn, alpha: a) }
        } else {
            p.dot(23, 6, .accent)
            p.dot(21, 4, .accent, alpha: 0.7)
            p.dot(13, 5, .accent, alpha: 0.7)
        }
        let y = full ? 1 : 2
        if full {
            p.arm(0, y, right: false, to: 0, 6)
            p.arm(0, y, to: 11, 6)
        } else {
            p.arm(0, y, to: 11, 10)
        }
        p.mascot(0, y, MascotFigure.Pose(look: 1, blink: t == 2))
    }

    /// Typing on a small computer, the lines of the screen filling in.
    private static func typing(_ t: Int, _ p: MascotPainter) {
        p.frame(12, 4, 10, 8, .line)
        p.rect(13, 5, 8, 6, .soft, alpha: 0.2)
        p.rect(11, 12, 12, 1, .line)
        p.rect(13, 13, 8, 1, .line, alpha: 0.5)
        let lines: [(Int, Int, MascotPainter.Tone)] = [(14, 5, .accent), (15, 4, .soft), (15, 3, .good), (14, 2, .accent)]
        for (i, l) in lines.enumerated() where i <= t {
            p.rect(l.0, 6 + i, l.1, 1, l.2)
        }
        let last = lines[min(t, lines.count - 1)]
        p.dot(last.0 + last.1 + 1, 6 + min(t, lines.count - 1), .strong, alpha: t % 2 == 0 ? 1 : 0.3)
        p.arm(0, 2, to: t % 2 == 0 ? 12 : 14, 12)
        p.mascot(0, 2, MascotFigure.Pose(look: 1, blink: t == 3))
    }
}

// MARK: - Gallery

/// Every scene, frame by frame, at the sizes the app uses: `--snapshot out/ --demo --page mascotte`.
struct MascotGallery: View {
    static let width: CGFloat = 1180

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("La mascotte au travail").font(.serif(26)).foregroundStyle(Theme.text)
            ForEach(MascotActivity.allCases) { a in
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.label).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                        Text("\(a.rawValue) · \(a.frameCount) images · \(Int(a.interval * 1000)) ms").font(.mono(10)).foregroundStyle(Theme.text3)
                        HStack(spacing: 8) {
                            HStack(spacing: 6) {
                                BusyMascot(a, pixel: 1, ink: Theme.onAccent)
                                Text("Analyse…").font(.ui(12, .semibold)).foregroundStyle(Theme.onAccent)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(PillShape().fill(Theme.accent))
                            BusyMascot(a, pixel: 1.5)
                        }
                    }
                    .frame(width: 210, alignment: .leading)
                    HStack(spacing: 6) {
                        ForEach(0..<a.frameCount, id: \.self) { f in
                            BusyMascot(a, pixel: 2.5, frame: f)
                                .padding(3)
                                .background(RoundedRectangle(cornerRadius: Theme.r(6)).fill(f == a.stillFrame ? Theme.hover : Theme.card))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(24)
        .frame(width: Self.width, alignment: .leading)
        .background(Theme.bg)
    }
}
