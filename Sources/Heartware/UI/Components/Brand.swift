import SwiftUI
import AppKit

/// The mascot: Chamois, a little chamois seen from the front, hooked horns, cream face and soft mask, 11 × 12 pixels.
/// One drawing for every place it appears: the mascot at rest with its yellow chamois cloth (`PixelMascot`), its head
/// beside the app's name and in the menu bar (`BrandMark`), and the waiting scenes (`BusyMascot`).
enum MascotFigure {
    static let width = 11
    static let height = 12
    /// The head alone, from the tips of the horns to the chin: the brand mark and the menu bar icon.
    static let headHeight = 9

    enum Part { case horn, fur, furShade, mask, face, eye, nose, cheek, hoof, cloth, clothShade }

    /// How it holds itself in one frame.
    struct Pose: Equatable {
        /// -1 looks left, 0 ahead, 1 right.
        var look = 0
        /// Eyes raised (thinking).
        var up = false
        var blink = false
        /// Eyes screwed up with effort.
        var squint = false
    }

    struct Pixel {
        let x: Int
        let y: Int
        let part: Part
    }

    // n = horn, f = fur, F = darker fur (the ears), m = mask, w = face, k = hoof. The eyes, nose and cheeks go on top.
    private static let body = [
        ".nn.....nn.",
        "...n...n...",
        "ff.n...n.ff",
        ".fFwwwwwFf.",
        ".fmwwwwwmf.",
        ".fmwwwwwmf.",
        ".fmwwwwwmf.",
        "..fwwwwwf..",
        "...fwwwf...",
        "..ffwwwff..",
        "..ff...ff..",
        "..kk...kk..",
    ]
    private static let parts: [Character: Part] = ["n": .horn, "f": .fur, "F": .furShade, "m": .mask, "w": .face, "k": .hoof]

    /// Every pixel of the figure in `pose`, the face last (it covers the fur).
    static func pixels(_ pose: Pose = Pose()) -> [Pixel] {
        var out: [Pixel] = []
        for (y, line) in body.enumerated() {
            for (x, ch) in line.enumerated() { if let part = parts[ch] { out.append(Pixel(x: x, y: y, part: part)) } }
        }
        let look = max(-1, min(1, pose.look))
        let eyeY = pose.up ? 4 : 5
        for ex in [3 + look, 7 + look] {
            if pose.squint {
                let outward = ex < 5 + look ? -1 : 1
                out.append(Pixel(x: ex, y: eyeY + 1, part: .eye))
                out.append(Pixel(x: ex + outward, y: eyeY + 1, part: .eye))
            } else {
                if !pose.blink { out.append(Pixel(x: ex, y: eyeY, part: .eye)) }
                out.append(Pixel(x: ex, y: eyeY + 1, part: .eye))
            }
        }
        out.append(Pixel(x: 3 + look, y: 7, part: .cheek))
        out.append(Pixel(x: 7 + look, y: 7, part: .cheek))
        out.append(Pixel(x: 5 + look, y: 7, part: .nose))
        return out
    }

    /// The yellow chamois cloth held at its right side, from (x, y): the paw, then the folded cloth.
    static func cloth(_ x: Int = 9, _ y: Int = 8) -> [Pixel] {
        [Pixel(x: x, y: y + 1, part: .fur),
         Pixel(x: x + 1, y: y, part: .cloth), Pixel(x: x + 2, y: y, part: .cloth), Pixel(x: x + 3, y: y, part: .clothShade),
         Pixel(x: x + 1, y: y + 1, part: .cloth), Pixel(x: x + 2, y: y + 1, part: .clothShade), Pixel(x: x + 3, y: y + 1, part: .clothShade)]
    }

    /// The empty cells around its head and body: drawn on light backgrounds so its cream face stays readable.
    static func contour(_ pose: Pose = Pose(), headOnly: Bool = false, extra: [Pixel] = []) -> [(x: Int, y: Int)] {
        let all = pixels(pose).filter { !headOnly || $0.y < headHeight } + extra
        let taken = Set(all.map { $0.y * 100 + $0.x })
        var seen = Set<Int>()
        var out: [(x: Int, y: Int)] = []
        for p in all where p.part != .horn && p.part != .hoof {
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let key = (p.y + dy) * 100 + p.x + dx
                if !taken.contains(key), seen.insert(key).inserted { out.append((p.x + dx, p.y + dy)) }
            }
        }
        return out
    }

    static func color(_ part: Part) -> Color {
        let c = Theme.mascot
        switch part {
        case .horn: return c.horn
        case .fur: return c.fur
        case .furShade: return c.furShade
        case .mask: return c.mask
        case .face: return c.face
        case .eye: return c.eye
        case .nose: return c.nose
        case .cheek: return c.cheek
        case .hoof: return c.hoof
        case .cloth: return c.cloth
        case .clothShade: return c.clothShade
        }
    }

    /// Draws the figure (or its head alone) from `origin`, one pixel of the figure being `pixel` points, with `extra`
    /// pixels (its cloth). With `ink`, everything is that single color and the eyes and nose are cut out (on a filled
    /// button, in the menu bar).
    static func draw(in ctx: GraphicsContext, at origin: CGPoint = .zero, pixel: CGFloat, pose: Pose = Pose(), headOnly: Bool = false,
                     extra: [Pixel] = [], ink: Color? = nil, contour withContour: Bool = false) {
        func cell(_ x: Int, _ y: Int) -> Path {
            Path(CGRect(x: origin.x + CGFloat(x) * pixel, y: origin.y + CGFloat(y) * pixel, width: pixel, height: pixel))
        }
        if withContour, ink == nil {
            let line = Theme.mascot.contour
            for c in contour(pose, headOnly: headOnly, extra: extra) { ctx.fill(cell(c.x, c.y), with: .color(line)) }
        }
        var cut = ctx
        cut.blendMode = .destinationOut
        for p in pixels(pose) + extra where !headOnly || p.y < headHeight {
            if let ink {
                if p.part == .eye || p.part == .nose {
                    cut.fill(cell(p.x, p.y), with: .color(.black))
                } else {
                    ctx.fill(cell(p.x, p.y), with: .color(ink))
                }
            } else {
                ctx.fill(cell(p.x, p.y), with: .color(color(p.part)))
            }
        }
    }

    /// The pixel size that fits `cols` × `rows` cells in a square of `side` points, on whole half-points so the edges
    /// stay sharp on a Retina screen.
    static func pixel(fitting side: CGFloat, cols: Int, rows: Int) -> CGFloat {
        max(0.5, (min(side / CGFloat(cols), side / CGFloat(rows)) * 2).rounded() / 2)
    }

    /// Pure checks for `--selftest`.
    static func selfTest() -> [String] {
        var failures: [String] = []
        if body.contains(where: { $0.count != width }) || body.count != height { failures.append("Mascotte : grille de travers") }
        for pose in [Pose(), Pose(look: 1, up: true), Pose(look: -1, squint: true), Pose(blink: true)] {
            let px = pixels(pose)
            let eyes = px.filter { $0.part == .eye }.count
            if eyes != (pose.blink ? 2 : 4) { failures.append("Mascotte : \(eyes) pixels d'yeux") }
            if px.contains(where: { $0.x < 0 || $0.x >= width || $0.y < 0 || $0.y >= height }) { failures.append("Mascotte : pixel hors de la figure") }
            // The face stays inside the head, the contour never covers the figure.
            if px.contains(where: { [.eye, .nose, .cheek].contains($0.part) && $0.y >= headHeight }) { failures.append("Mascotte : visage hors de la tête") }
            let taken = Set((px + cloth()).map { $0.y * 100 + $0.x })
            if contour(pose, extra: cloth()).contains(where: { taken.contains($0.y * 100 + $0.x) }) { failures.append("Mascotte : contour sur la figure") }
        }
        return failures
    }
}

/// The brand mark: the chamois' head, beside the app's name and wherever the app speaks for itself.
/// Themes without ornaments leave it out, unless it is content rather than decoration (the drawn app icon).
struct BrandMark: View {
    /// The side of the square it fits in, in points.
    var size: CGFloat = 28
    /// One color instead of the mascot's own, the eyes and nose cut out.
    var ink: Color? = nil
    var ornament = true

    var body: some View {
        if ornament, Theme.current.spec.mascot, let look = MascotStyle.look {
            // The user's own chamois, with what it wears.
            Canvas { ctx, _ in RefugeFigure.drawHead(in: ctx, side: size, look: look, ink: ink) }
                .frame(width: size, height: size)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else if !ornament || Theme.current.spec.mascot {
            let cols = MascotFigure.width + 2, rows = MascotFigure.headHeight + 1
            let pixel = MascotFigure.pixel(fitting: size, cols: cols, rows: rows)
            Canvas { ctx, _ in
                MascotFigure.draw(in: ctx, at: CGPoint(x: pixel, y: pixel), pixel: pixel, headOnly: true, ink: ink, contour: true)
            }
            .frame(width: pixel * CGFloat(cols), height: pixel * CGFloat(rows))
            .frame(width: size, height: size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The chamois' head as a template image for the menu bar: one ink, the eyes and nose cut out. Pixels of 2 points
    /// give 22 × 18 points, the height of the system's own icons, with sharp edges on a Retina screen.
    static func templateImage(pixel: CGFloat = 2) -> NSImage {
        let size = NSSize(width: CGFloat(MascotFigure.width) * pixel, height: CGFloat(MascotFigure.headHeight) * pixel)
        let img = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            for p in MascotFigure.pixels() where p.y < MascotFigure.headHeight && p.part != .eye && p.part != .nose {
                NSRect(x: CGFloat(p.x) * pixel, y: CGFloat(p.y) * pixel, width: pixel, height: pixel).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// The mascot at rest, its chamois cloth in hand, blinking now and then. At work (scanning, cleaning, translating…),
/// `BusyMascot` shows it busy.
struct PixelMascot: View {
    var pixel: CGFloat = 4
    @State private var blink = false
    @Environment(\.mainWindowOnScreen) private var onScreen

    var body: some View {
        if Theme.current.spec.mascot { figure }
    }

    private var figure: some View {
        let look = MascotStyle.look
        return Canvas { ctx, _ in
            if let look {
                // The user's own chamois, its cloth in its paw.
                RefugeFigure.draw(in: ctx, pixel: pixel, look: look, pose: MascotFigure.Pose(blink: blink))
                let right = (RefugeFigure.pixels(look).body.filter { $0.y >= 10 && $0.y <= 14 && $0.part != .prop }.map(\.x).max() ?? 12) + 1
                let m = Theme.mascot
                for (dx, dy, shade) in [(0, 1, false), (1, 0, false), (2, 0, true), (1, 1, true), (2, 1, true)] {
                    ctx.fill(Path(CGRect(x: CGFloat(right + dx) * pixel, y: CGFloat(11 + dy) * pixel, width: pixel, height: pixel)),
                             with: .color(dx == 0 ? m.fur : (shade ? m.clothShade : m.cloth)))
                }
            } else {
                MascotFigure.draw(in: ctx, at: CGPoint(x: pixel, y: pixel), pixel: pixel, pose: MascotFigure.Pose(blink: blink),
                                  extra: MascotFigure.cloth(), contour: true)
            }
        }
        .frame(width: pixel * CGFloat(look == nil ? MascotFigure.width + 4 : RefugeFigure.cols + 3),
               height: pixel * CGFloat(look == nil ? MascotFigure.height + 1 : RefugeFigure.rows))
        .allowsHitTesting(false)
        .task(id: onScreen) {
            // Blinks now and then: two tiny updates every few seconds, nothing per frame, and nothing at all while the
            // main window is off screen.
            guard onScreen else {
                if blink { blink = false }
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_200_000_000)
                // Gone off screen during the wait: no last blink.
                guard !Task.isCancelled else { break }
                blink = true
                try? await Task.sleep(nanoseconds: 140_000_000)
                blink = false
            }
        }
    }
}

/// Faint dust and a few glints in a header, as if the mascot had just polished it: denser at the top, fading downward.
/// Drawn once, nothing moves.
struct DustBackdrop: View {
    var seed: UInt64 = 7
    var opacity: Double = 0.5

    var body: some View {
        // Equatable: SwiftUI skips redrawing the specks each time the page around it refreshes.
        if Theme.current.spec.backdrop {
            DustCanvas(seed: seed, opacity: opacity, color: Theme.matrix).equatable()
        }
    }
}

private struct DustCanvas: View, Equatable {
    var seed: UInt64
    var opacity: Double
    var color: Color

    /// A small four-pointed glint.
    private static let glint = [".#.", "###", ".#."]

    var body: some View {
        Canvas { ctx, size in
            var rng = SplitMix(seed: seed)
            let grid: CGFloat = 3
            let cols = max(1, Int(size.width / grid)), rows = max(1, Int(size.height / grid))
            func fade(_ y: CGFloat) -> Double { max(0, 1 - Double(y / max(size.height, 1))) }
            // Specks of dust, one or two pixels.
            for _ in 0..<(cols * rows / 60) {
                let x = CGFloat(rng.next() % UInt64(cols)) * grid
                let y = CGFloat(Double(rng.next() % 1000) / 1000 * Double(rng.next() % 1000) / 1000) * size.height
                let strength = Double(rng.next() % 100) / 100
                let side = strength > 0.85 ? grid * 2 : grid
                ctx.opacity = opacity * fade(y) * (0.25 + 0.75 * strength)
                ctx.fill(Path(CGRect(x: x, y: (y / grid).rounded(.down) * grid, width: side, height: side)), with: .color(color))
            }
            // A few glints where it has polished.
            for _ in 0..<max(1, cols / 60) {
                let x = CGFloat(rng.next() % UInt64(cols)) * grid
                let y = CGFloat(rng.next() % UInt64(max(1, rows / 2))) * grid
                ctx.opacity = opacity * fade(y) * 0.9
                for (r, line) in Self.glint.enumerated() {
                    for (c, ch) in line.enumerated() where ch == "#" {
                        ctx.fill(Path(CGRect(x: x + CGFloat(c) * grid, y: y + CGFloat(r) * grid, width: grid, height: grid)),
                                 with: .color(color))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
