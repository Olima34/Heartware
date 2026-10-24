import SwiftUI
import AppKit

/// How it looks: its stage, its coat, its scarf, what it wears and the accessory of its path.
struct RefugeLook: Equatable {
    var stage: RefugeStage
    var coat: RefugeCoat = .caramel
    /// Shown from the Grand Chamois on.
    var scarf: RefugeScarf? = nil
    var head: String? = nil
    var face: String? = nil
    var path: RefugePath? = nil
    /// The scarf flying off during its mue, in cells.
    var scarfLift = 0

    init(stage: RefugeStage, coat: RefugeCoat = .caramel, scarf: RefugeScarf? = nil, head: String? = nil, face: String? = nil,
         path: RefugePath? = nil) {
        self.stage = stage
        self.coat = coat
        self.scarf = scarf ?? (stage == .grand ? .bronze : stage == .gold ? .laine : nil)
        self.head = head
        self.face = face
        self.path = path
    }

    static func of(_ s: RefugeState, on date: Date = Date()) -> RefugeLook {
        let stage = s.stage
        let scarf: RefugeScarf? = switch stage {
        case .grand: RefugeRules.scarf(forLevel: s.level) ?? .bronze
        case .gold: s.scarf.flatMap(RefugeScarf.init(rawValue:)) ?? .laine
        default: nil
        }
        let worn = RefugeStyle.items.filter { s.worn.contains($0.id) && s.owned.contains($0.id) }
        return RefugeLook(stage: stage, coat: RefugeStyle.coat(s, on: date), scarf: scarf,
                          head: worn.first { $0.slot == .head }?.id, face: worn.first { $0.slot == .face }?.id,
                          path: stage >= .beau ? s.path.flatMap(RefugePath.init(rawValue:)) : nil)
    }
}

/// The chamois of the Refuge at each of its six stages (the drawings of the universe's notebook), and what its moods do
/// to its face: closed eyes when it sleeps, screwed up when it sneezes, its tongue out when it is hot, its racing glasses
/// during the Boost, its eyes raised to the moth, its mouth open when hungry or eating, a tear when it is sad. Every stage
/// fits in a 17 × 17 box, its feet on the bottom row. Also its blueberry bush.
enum RefugeFigure {
    static let cols = 17
    static let rows = 17

    enum Part {
        case horn, hornRing, fur, furShade, mask, face, collar, eye, nose, cheek, hoof, bell, bellShade
        case sparkle, glasses, glassShine, sweat, tongue, prop
    }

    struct Pixel {
        var x: Int
        var y: Int
        var part: Part
        var alpha: Double = 1
        /// An accessory's own color (`prop`).
        var tint: Color? = nil
    }

    // n = horn, N = its ring, f = fur, F = darker fur, m = mask, w = face, W = collar, e = eye, p = nose, c = cheek,
    // k = hoof, g / G = the bell.
    private static let codes: [Character: Part] = [
        "n": .horn, "N": .hornRing, "f": .fur, "F": .furShade, "m": .mask, "w": .face, "W": .collar, "e": .eye,
        "p": .nose, "c": .cheek, "k": .hoof, "g": .bell, "G": .bellShade,
    ]

    static func grid(_ stage: RefugeStage) -> [String] {
        switch stage {
        case .cabri:
            // A round baby: no horns yet, big ears, thin legs.
            return ["ff.......ff",
                    ".fFwwwwwFf.",
                    "..fmwwwmf..",
                    "..fewwwef..",
                    "..fewwwef..",
                    "..fcwpwcf..",
                    "...fwwwf...",
                    "...fffff...",
                    "...f...f...",
                    "...k...k..."]
        case .eterlou:
            // One year old: two little straight horns.
            return ["....n...n....",
                    "ff..n...n..ff",
                    ".fFfwwwwwfFf.",
                    "..fmwwwwwmf..",
                    "..fmewwwemf..",
                    "..fmewwwemf..",
                    "...fcwpwcf...",
                    "....fwwwf....",
                    "....fffff....",
                    "...ffwwwff...",
                    "...ff...ff...",
                    "...kk...kk..."]
        case .chamois:
            // The hooked horns of the grown-ups.
            return ["..nn.....nn..",
                    "....n...n....",
                    "ff..n...n..ff",
                    ".fFfwwwwwfFf.",
                    "..fmwwwwwmf..",
                    "..fmewwwemf..",
                    "..fmewwwemf..",
                    "...fcwpwcf...",
                    "....fwwwf....",
                    "....fffff....",
                    "...ffwwwff...",
                    "...ff...ff...",
                    "...kk...kk..."]
        case .beau:
            // A little taller, a bell at its neck.
            return [".nn.......nn.",
                    "...n.....n...",
                    "....n...n....",
                    "ff..n...n..ff",
                    ".fFfwwwwwfFf.",
                    "..fmwwwwwmf..",
                    "..fmewwwemf..",
                    "..fmewwwemf..",
                    "...fcwpwcf...",
                    "....fwwwf....",
                    "....ffgff....",
                    "...ffwGwff...",
                    "...ffwwwff...",
                    "...ff...ff...",
                    "...kk...kk..."]
        case .grand, .gold:
            // Long ringed horns, a tuft, a collar, broader; the scarf goes on top.
            return ["nn.........nn",
                    "..n.......n..",
                    "...N.....N...",
                    "...n.FFF.n...",
                    "fff.nFFFn.fff",
                    ".ffFwwwwwFff.",
                    ".ffmwwwwwmff.",
                    "..fmewwwemf..",
                    "..fmewwwemf..",
                    "..ffcwpwcff..",
                    "..WfwwwwwfW..",
                    ".WWWwwwwwWWW.",
                    "..ffwwwwwff..",
                    "..fff...fff..",
                    "..kkk...kkk.."]
        }
    }

    /// The scarf of the Grand Chamois, in the coordinates of its grid: around the neck, the knot, the end that hangs.
    private static func scarfCells() -> [(x: Int, y: Int, light: Bool)] {
        var px: [(Int, Int, Bool)] = []
        for x in 2...10 { px.append((x, 11, x % 3 == 0)) }
        for x in 3...9 { px.append((x, 12, false)) }
        px += [(8, 13, false), (9, 13, true), (9, 14, false), (10, 14, true)]
        return px.map { (x: $0.0, y: $0.1, light: $0.2) }
    }

    /// Where the grid of `stage` sits in the box: centred, its feet on the bottom row.
    static func offset(_ stage: RefugeStage) -> (x: Int, y: Int) {
        let g = grid(stage)
        return ((cols - (g.first?.count ?? cols)) / 2, rows - g.count)
    }

    /// Every pixel of the chamois in `look` and `mood`, in its box. `frame` is the step of the animation (4 per second),
    /// `blink` closes its eyes for that frame, `eating` makes it chew.
    static func pixels(_ look: RefugeLook, mood: RefugeMood = .happy, frame: Int = 0, blink: Bool = false,
                       eating: Bool = false, pose: MascotFigure.Pose? = nil) -> (body: [Pixel], glow: [Pixel]) {
        let stage = look.stage
        let (ox, oy) = offset(stage)
        var cells: [Int: Pixel] = [:]
        func put(_ p: Pixel) {
            guard p.x >= 0, p.x < cols, p.y >= 0, p.y < rows else { return }
            cells[p.y * 100 + p.x] = p
        }
        func at(_ x: Int, _ y: Int) -> Pixel? { cells[y * 100 + x] }
        func prop(_ x: Int, _ y: Int, _ color: String, alpha: Double = 1) {
            put(Pixel(x: x, y: y, part: .prop, alpha: alpha, tint: Theme.mascot.prop(color)))
        }
        for (y, line) in grid(stage).enumerated() {
            for (x, ch) in line.enumerated() { if let part = codes[ch] { put(Pixel(x: x + ox, y: y + oy, part: part)) } }
        }
        var glow: [Pixel] = []

        // Its geometry: the forehead, the face's middle, the body's sides.
        let faces = cells.values.filter { $0.part == .face }
        let faceTop = faces.map(\.y).min() ?? 0
        let topRow = faces.filter { $0.y == faceTop }.map(\.x)
        let cx = ((topRow.min() ?? 0) + (topRow.max() ?? 0)) / 2
        let lower = cells.values.filter { $0.y >= rows - 5 && $0.y < rows - 1 }
        let bodyMin = lower.map(\.x).min() ?? 0, bodyMax = lower.map(\.x).max() ?? cols - 1

        // The scarf (it flies off and comes back at its mue).
        if let scarf = look.scarf, stage >= .grand {
            let colors = Theme.mascot.scarves[scarf.rawValue]
            for c in scarfCells() {
                let p = Pixel(x: c.x + ox, y: c.y + oy - look.scarfLift, part: .prop,
                              tint: scarf == .laine && c.x % 4 == 1 ? Theme.mascot.goldThread : (c.light ? colors.light : colors.main))
                if look.scarfLift == 0 { put(p) } else if p.y >= 0 { glow.append(p) }
            }
            if scarf.sparkle, look.scarfLift == 0 {
                glow.append(Pixel(x: 4 + ox, y: 11 + oy, part: .sparkle, alpha: frame % 4 == 0 ? 1 : 0.5))
                glow.append(Pixel(x: 11 + ox, y: 10 + oy, part: .sparkle, alpha: frame % 4 == 2 ? 0.9 : 0.3))
            }
        }
        if stage == .gold {
            glow += [(0, 4, 0.8), (16, 3, 0.9), (1, 11, 0.5), (15, 10, 0.6), (8, 0, 0.6), (3, 1, 0.5), (13, 0, 0.5)]
                .map { Pixel(x: $0.0, y: $0.1, part: .sparkle, alpha: (frame / 2 + $0.0) % 4 == 0 ? 1 : $0.2) }
        }
        if look.coat == .nuit {
            // A starry coat: a few stars in its fur.
            let fur = cells.values.filter { $0.part == .fur }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            for (i, p) in fur.enumerated() where i % 7 == 3 {
                glow.append(Pixel(x: p.x, y: p.y, part: .sparkle, alpha: (frame + i) % 6 == 0 ? 1 : 0.55))
            }
        }

        // The face: its eyes as columns of two pixels, its nose.
        let eyes = cells.values.filter { $0.part == .eye }
        let columns = Dictionary(grouping: eyes, by: \.x).map { (x: $0.key, top: $0.value.map(\.y).min() ?? 0, bottom: $0.value.map(\.y).max() ?? 0) }
            .sorted { $0.x < $1.x }
        let nose = cells.values.first { $0.part == .nose }
        let middle = columns.isEmpty ? cols / 2 : columns.map(\.x).reduce(0, +) / columns.count
        func face(_ x: Int, _ y: Int) { put(Pixel(x: x, y: y, part: .face)) }
        func mouth() {
            if let nose, at(nose.x, nose.y + 1)?.part == .face { put(Pixel(x: nose.x, y: nose.y + 1, part: .eye)) }
        }

        switch mood {
        case .happy:
            if blink { for c in columns { face(c.x, c.top) } }
        case .sleepy:
            // Closed: a little line, low on the face.
            for c in columns {
                face(c.x, c.top)
                put(Pixel(x: c.x + (c.x < middle ? 1 : -1), y: c.bottom, part: .eye))
            }
        case .sneezy:
            // Screwed up (\ /), and now and then the sneeze itself.
            let sneezing = frame % 10 < 2
            for c in columns {
                face(c.x, c.top)
                if !sneezing { put(Pixel(x: c.x + (c.x < middle ? -1 : 1), y: c.top, part: .eye)) }
            }
            if sneezing, let nose {
                glow += [(-2, 1), (2, 1), (-3, 2), (3, 2), (0, 2)].map { Pixel(x: nose.x + $0.0, y: nose.y + $0.1, part: .sparkle, alpha: 0.85) }
            }
        case .hot:
            if blink { for c in columns { face(c.x, c.top) } }
            if let nose, at(nose.x, nose.y + 1)?.part == .face { put(Pixel(x: nose.x, y: nose.y + 1, part: .tongue)) }
            if let right = columns.last {
                let drop = (frame / 3) % 3
                glow += [Pixel(x: right.x + 4, y: right.top - 1 + drop, part: .sweat), Pixel(x: right.x + 4, y: right.top + drop, part: .sweat)]
            }
        case .boosted:
            for c in columns {
                for x in (c.x - 1)...(c.x + 1) { for y in c.top...c.bottom { put(Pixel(x: x, y: y, part: .glasses)) } }
                put(Pixel(x: c.x - 1, y: c.top, part: .glassShine))
            }
            if columns.count == 2, columns[0].x + 2 < columns[1].x - 1 {
                for x in (columns[0].x + 2)..<(columns[1].x - 1) { put(Pixel(x: x, y: columns[0].top, part: .glasses)) }
            }
        case .worried:
            // Its eyes raised, following the moth.
            for c in columns {
                face(c.x, c.bottom)
                if !blink { put(Pixel(x: c.x, y: c.top - 1, part: .eye)) }
            }
        case .hungry:
            if blink { for c in columns { face(c.x, c.top) } }
            mouth()
        case .sad:
            // Eyes lowered, and a tear running down its cheek.
            for c in columns { face(c.x, c.top) }
            if let left = columns.first {
                let fall = (frame / 2) % 4
                glow.append(Pixel(x: left.x, y: left.bottom + 1 + fall, part: .sweat, alpha: fall == 3 ? 0.5 : 1))
            }
        }
        if eating, frame % 2 == 0 { mouth() }

        // A pose of the waiting scenes (the same as the app's mascot): eyes to the side, raised, closed or screwed up.
        if let pose {
            for c in columns { for y in c.top...c.bottom { face(c.x, y) } }
            let look = max(-1, min(1, pose.look)), lift = pose.up ? 1 : 0
            for c in columns {
                let x = c.x + look
                if pose.squint {
                    let outward = c.x < middle ? -1 : 1
                    put(Pixel(x: x, y: c.bottom - lift, part: .eye))
                    put(Pixel(x: x + outward, y: c.bottom - lift, part: .eye))
                } else {
                    if !pose.blink { put(Pixel(x: x, y: c.top - lift, part: .eye)) }
                    put(Pixel(x: x, y: c.bottom - lift, part: .eye))
                }
            }
        }

        // What it wears on its face: round glasses (the racing ones of the Boost win).
        if look.face == "lunettes", mood != .boosted {
            // The frame goes round the eyes, never over them.
            func rim(_ x: Int, _ y: Int) { if at(x, y)?.part != .eye { prop(x, y, "monture") } }
            for c in columns {
                for y in c.top...c.bottom { rim(c.x - 1, y); rim(c.x + 1, y) }
                rim(c.x, c.top - 1)
            }
            if columns.count == 2, columns[0].x + 2 <= columns[1].x - 2 {
                for x in (columns[0].x + 2)...(columns[1].x - 2) { rim(x, columns[0].top) }
            }
        }

        // On its head: a thing of the shop, else the beret or the goggles of its path.
        let head = look.head ?? (look.path == .artiste ? "beret" : look.path == .guide ? "aviateur" : nil)
        switch head {
        case "bonnet":
            prop(cx, faceTop - 3, "creme")
            for x in (cx - 2)...(cx + 2) { prop(x, faceTop - 2, x == cx ? "bleu-clair" : "bleu") }
            for x in (cx - 3)...(cx + 3) { prop(x, faceTop - 1, x == cx - 1 || x == cx + 2 ? "bleu-clair" : "bleu") }
            for x in (cx - 3)...(cx + 3) { prop(x, faceTop, x % 2 == 0 ? "creme" : "creme-ombre") }
        case "paille":
            for x in (cx - 2)...(cx + 2) { prop(x, faceTop - 2, "paille") }
            for x in (cx - 2)...(cx + 2) { prop(x, faceTop - 1, "rouge") }
            for x in (cx - 4)...(cx + 4) { prop(x, faceTop, "paille-ombre") }
        case "fleurs":
            let colors = ["rose", "vert", "jaune", "vert", "rose", "vert", "jaune"]
            for (i, x) in ((cx - 3)...(cx + 3)).enumerated() { prop(x, faceTop - 1, colors[i]) }
        case "beret":
            for x in (cx - 1)...(cx + 1) { prop(x, faceTop - 2, "rouge") }
            for x in (cx - 3)...(cx + 2) { prop(x, faceTop - 1, "rouge") }
            prop(cx + 1, faceTop - 3, "rouge")
        case "aviateur":
            for x in (cx - 4)...(cx + 4) { prop(x, faceTop, "monture") }
            for x in [cx - 2, cx - 1, cx + 1, cx + 2] { prop(x, faceTop, "verre-bleu") }
        default:
            break
        }

        // The accessory of its path, beside it.
        let side = rows - 6
        switch look.path {
        case .gardien:
            let shield: [(Int, Int, String)] = [(0, 0, "argent"), (1, 0, "argent"), (2, 0, "argent"), (0, 1, "argent"), (1, 1, "jaune"),
                                                (2, 1, "argent"), (0, 2, "argent"), (1, 2, "argent"), (2, 2, "argent"), (1, 3, "argent")]
            for (dx, dy, color) in shield { prop(bodyMin - 3 + dx, side + dy, color) }
        case .artiste:
            prop(bodyMax + 1, side - 1, "rose")
            for y in side...(side + 2) { prop(bodyMax + 1, y, "monture") }
        case .fee:
            // Little wings at its shoulders, against its sides, and its wand.
            let wing = ["ww..", "wWw.", ".www", "..ww"]
            let top = side - 4
            for (dy, line) in wing.enumerated() {
                let y = top + dy
                let row = cells.values.filter { $0.y == y && $0.part != .prop }.map(\.x)
                guard let left = row.min(), let right = row.max() else { continue }
                for (dx, ch) in line.enumerated() where ch != "." {
                    let shade = ch == "W" ? "bleu-clair" : "verre-bleu"
                    let lx = left - 4 + dx, rx = right + 4 - dx
                    if at(lx, y) == nil { prop(lx, y, shade, alpha: 0.8) }
                    if at(rx, y) == nil { prop(rx, y, shade, alpha: 0.8) }
                }
            }
            prop(bodyMax + 2, side + 1, "jaune")
            for y in (side + 2)...(side + 4) where y < rows - 1 { prop(bodyMax + 2, y, "monture") }
        case .guide, .none:
            break
        }
        return (Array(cells.values), glow)
    }

    /// The empty cells around its head and body: drawn on light backgrounds so its cream face stays readable.
    static func contour(_ body: [Pixel]) -> [(x: Int, y: Int)] {
        let taken = Set(body.map { $0.y * 100 + $0.x })
        var seen = Set<Int>()
        var out: [(x: Int, y: Int)] = []
        for p in body where p.part != .horn && p.part != .hornRing && p.part != .hoof && p.part != .prop {
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let key = (p.y + dy) * 100 + p.x + dx
                if !taken.contains(key), seen.insert(key).inserted { out.append((p.x + dx, p.y + dy)) }
            }
        }
        return out
    }

    static func color(_ p: Pixel, look: RefugeLook) -> Color {
        if let tint = p.tint { return tint }
        let c = Theme.mascot
        let gold = look.stage == .gold && look.coat == .caramel
        let coat = look.coat == .caramel ? nil : c.coats[look.coat.rawValue]
        switch p.part {
        case .horn: return gold ? c.goldHorn : c.horn
        case .hornRing: return gold ? c.goldRing : c.hornRing
        case .fur: return coat?.fur ?? (gold ? c.goldFur : c.fur)
        case .furShade: return coat?.furShade ?? (gold ? c.goldFurShade : c.furShade)
        case .mask: return coat?.mask ?? (gold ? c.goldMask : c.mask)
        case .face: return c.face
        case .collar: return gold ? c.goldCollar : c.collar
        case .eye: return c.eye
        case .nose: return c.nose
        case .cheek: return c.cheek
        case .hoof: return c.hoof
        case .bell: return c.bell
        case .bellShade: return c.bellShade
        case .sparkle: return c.sparkle
        case .glasses: return c.glasses
        case .glassShine: return c.glassShine
        case .sweat: return c.sweat
        case .tongue: return c.tongue
        case .prop: return c.horn
        }
    }

    /// Draws the chamois from `origin` (the top left corner of its box), one cell being `pixel` points. With `ink`,
    /// everything is that single color and the eyes and nose are cut out (a silhouette, a filled button).
    static func draw(in ctx: GraphicsContext, at origin: CGPoint = .zero, pixel: CGFloat, look: RefugeLook,
                     mood: RefugeMood = .happy, frame: Int = 0, blink: Bool = false, eating: Bool = false, lift: Int = 0,
                     ink: Color? = nil, pose: MascotFigure.Pose? = nil, contour withContour: Bool = true) {
        let (body, glow) = pixels(look, mood: mood, frame: frame, blink: blink, eating: eating, pose: pose)
        func cell(_ x: Int, _ y: Int) -> Path {
            Path(CGRect(x: origin.x + CGFloat(x) * pixel, y: origin.y + CGFloat(y - lift) * pixel, width: pixel, height: pixel))
        }
        if let ink {
            var cut = ctx
            cut.blendMode = .destinationOut
            for p in body {
                if p.part == .eye || p.part == .nose { cut.fill(cell(p.x, p.y), with: .color(.black)) } else { ctx.fill(cell(p.x, p.y), with: .color(ink)) }
            }
            return
        }
        if withContour {
            let line = Theme.mascot.contour
            for c in contour(body) { ctx.fill(cell(c.x, c.y), with: .color(line)) }
        }
        for p in body { ctx.fill(cell(p.x, p.y), with: .color(color(p, look: look).opacity(p.alpha))) }
        for p in glow { ctx.fill(cell(p.x, p.y), with: .color(color(p, look: look).opacity(p.alpha))) }
    }

    /// Where its mouth is in its box (the bubble it speaks in starts there).
    static func mouth(_ stage: RefugeStage) -> (x: Int, y: Int) {
        let (ox, oy) = offset(stage)
        for (y, line) in grid(stage).enumerated() {
            if let i = line.firstIndex(of: "p") { return (line.distance(from: line.startIndex, to: i) + ox, y + oy + 1) }
        }
        return (cols / 2, rows / 2)
    }

    /// Its head alone, with what it wears on it (the brand mark, the launcher): down to its chin, without the scarf
    /// or the accessories beside its body.
    static func headPixels(_ look: RefugeLook) -> [Pixel] {
        var head = look
        head.head = look.head ?? (look.path == .artiste ? "beret" : look.path == .guide ? "aviateur" : nil)
        head.path = nil
        head.scarf = nil
        let chin = mouth(look.stage).y
        return pixels(head).body.filter { $0.y <= chin }
    }

    /// Draws its head centred in a square of `side` points. With `ink`, one color and the eyes and nose cut out.
    static func drawHead(in ctx: GraphicsContext, side: CGFloat, look: RefugeLook, ink: Color? = nil, contour withContour: Bool = true) {
        let head = headPixels(look)
        guard let minX = head.map(\.x).min(), let maxX = head.map(\.x).max(),
              let minY = head.map(\.y).min(), let maxY = head.map(\.y).max() else { return }
        let cols = maxX - minX + 3, rows = maxY - minY + 2
        let p = MascotFigure.pixel(fitting: side, cols: cols, rows: rows)
        let origin = CGPoint(x: ((side - CGFloat(cols) * p) / 2).rounded() + p - CGFloat(minX) * p,
                             y: ((side - CGFloat(rows) * p) / 2).rounded() + p / 2 - CGFloat(minY) * p)
        func cell(_ x: Int, _ y: Int) -> Path { Path(CGRect(x: origin.x + CGFloat(x) * p, y: origin.y + CGFloat(y) * p, width: p, height: p)) }
        if let ink {
            var cut = ctx
            cut.blendMode = .destinationOut
            for px in head {
                if px.part == .eye || px.part == .nose { cut.fill(cell(px.x, px.y), with: .color(.black)) } else { ctx.fill(cell(px.x, px.y), with: .color(ink)) }
            }
            return
        }
        if withContour {
            for c in contour(head) where c.y <= maxY { ctx.fill(cell(c.x, c.y), with: .color(Theme.mascot.contour)) }
        }
        for px in head { ctx.fill(cell(px.x, px.y), with: .color(color(px, look: look).opacity(px.alpha))) }
    }

    /// Whether a cell of its box is on it (or right beside it): a click there is a caress.
    static func touches(_ look: RefugeLook, x: Int, y: Int) -> Bool {
        pixels(look).body.contains { abs($0.x - x) <= 1 && abs($0.y - y) <= 1 }
    }

    // MARK: Its bush

    static let bushCols = 15
    static let bushRows = 9
    private static let bush = [".....lll.lll...",
                               "...llLlllLlll..",
                               "..lLllllllLlll.",
                               ".llllLllllllLl.",
                               "lLlllllLlllllll",
                               "llllLllllllLlll",
                               ".lllllllLllllL.",
                               "..lllLllllllll.",
                               "....kk...kk...."]
    /// Its ten blueberries, in the bush's coordinates.
    static let berries = [(4, 2), (8, 1), (11, 3), (2, 4), (6, 4), (10, 5), (13, 4), (5, 6), (9, 7), (12, 6)]

    /// The bush, its top rows `rustle` cells to the side, with the berries not picked yet.
    static func drawBush(in ctx: GraphicsContext, at origin: CGPoint, pixel: CGFloat, rustle: Int = 0, picked: Set<Int> = [],
                         berries shown: Bool = true) {
        let c = Theme.mascot
        func fill(_ x: Int, _ y: Int, _ color: Color) {
            let shift = y < 4 ? rustle : 0
            ctx.fill(Path(CGRect(x: origin.x + CGFloat(x + shift) * pixel, y: origin.y + CGFloat(y) * pixel, width: pixel, height: pixel)),
                     with: .color(color))
        }
        for (y, line) in bush.enumerated() {
            for (x, ch) in line.enumerated() {
                switch ch {
                case "l": fill(x, y, c.leaf)
                case "L": fill(x, y, c.leafShade)
                case "k": fill(x, y, c.woodShade)
                default: break
                }
            }
        }
        guard shown else { return }
        for (i, b) in berries.enumerated() where !picked.contains(i) {
            fill(b.0, b.1, i % 3 == 0 ? c.berryShine : c.berry)
        }
    }

    // MARK: The menu bar

    /// Its head in the menu bar, one ink, the eyes and nose cut out: asleep at night, racing glasses during the Boost,
    /// screwed up in the dust, eyes raised to a moth. Drawn once per mood, never per frame.
    static func menuImage(_ mood: RefugeMood, pixel: CGFloat = 2) -> NSImage {
        let size = NSSize(width: CGFloat(MascotFigure.width) * pixel, height: CGFloat(MascotFigure.headHeight) * pixel)
        let pose: MascotFigure.Pose = switch mood {
        case .sleepy: MascotFigure.Pose(blink: true)
        case .sneezy: MascotFigure.Pose(squint: true)
        case .worried: MascotFigure.Pose(up: true)
        default: MascotFigure.Pose()
        }
        let img = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            let head = MascotFigure.pixels(pose).filter { $0.y < MascotFigure.headHeight }
            var holes = Set(head.filter { $0.part == .eye || $0.part == .nose }.map { $0.y * 100 + $0.x })
            if mood == .boosted {
                // Racing glasses: two dark lenses, their outline cut out around them.
                holes = Set([4, 7].flatMap { y in (2...8).map { y * 100 + $0 } })
                holes.formUnion([501, 601, 509, 609])
                holes.formUnion(head.filter { $0.part == .nose }.map { $0.y * 100 + $0.x })
            }
            for p in head where !holes.contains(p.y * 100 + p.x) {
                NSRect(x: CGFloat(p.x) * pixel, y: CGFloat(p.y) * pixel, width: pixel, height: pixel).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: Self-test

    static func selfTest() -> [String] {
        var f: [String] = []
        for stage in RefugeStage.allCases {
            let g = grid(stage)
            if g.contains(where: { $0.count != g[0].count }) { f.append("Refuge : grille de \(stage.title) de travers") }
            if g.count > rows || g[0].count > cols { f.append("Refuge : \(stage.title) dépasse sa boîte") }
            let looks = [RefugeLook(stage: stage), RefugeLook(stage: stage, coat: .nuit, head: "bonnet", face: "lunettes", path: .gardien),
                         RefugeLook(stage: stage, head: "paille", path: .fee), RefugeLook(stage: stage, head: "fleurs", path: .artiste),
                         RefugeLook(stage: stage, path: .guide), RefugeLook(stage: stage, path: .artiste)]
            let noseY = pixels(RefugeLook(stage: stage)).body.first { $0.part == .nose }?.y ?? rows
            for look in looks {
                for mood in RefugeMood.allCases {
                    for frame in [0, 1, 5, 9] {
                        let (body, glow) = pixels(look, mood: mood, frame: frame, blink: frame == 5, eating: frame == 0)
                        if (body + glow).contains(where: { $0.x < 0 || $0.x >= cols || $0.y < 0 || $0.y >= rows }) {
                            f.append("Refuge : \(stage.title) \(mood.title) sort de sa boîte")
                        }
                        let keys = body.map { $0.y * 100 + $0.x }
                        if Set(keys).count != keys.count { f.append("Refuge : deux pixels au même endroit (\(stage.title))") }
                        // The eyes, not the open mouth below the nose.
                        let eyes = body.filter { $0.part == .eye && $0.y < noseY }
                        switch mood {
                        case .boosted: if !eyes.isEmpty { f.append("Refuge : des yeux derrière les lunettes de \(stage.title)") }
                        case .sleepy:
                            if eyes.count != 4 || Set(eyes.map(\.y)).count != 1 { f.append("Refuge : \(stage.title) dort les yeux ouverts") }
                        default: if eyes.isEmpty { f.append("Refuge : \(stage.title) \(mood.title) sans yeux") }
                        }
                        let feet = body.filter { $0.part == .hoof }
                        if feet.isEmpty || feet.contains(where: { $0.y != rows - 1 }) { f.append("Refuge : \(stage.title) ne touche pas le sol") }
                    }
                }
            }
            let m = mouth(stage)
            if !touches(RefugeLook(stage: stage), x: m.x, y: m.y) || touches(RefugeLook(stage: stage), x: 0, y: rows - 1) {
                f.append("Refuge : caresse mal placée sur \(stage.title)")
            }
        }
        if pixels(RefugeLook(stage: .cabri)).body.contains(where: { $0.part == .horn }) { f.append("Refuge : le cabri a des cornes") }
        if !pixels(RefugeLook(stage: .beau)).body.contains(where: { $0.part == .bell }) { f.append("Refuge : le Beau Chamois sans clochette") }
        if pixels(RefugeLook(stage: .beau)).body.contains(where: { $0.part == .prop })
            || !pixels(RefugeLook(stage: .grand)).body.contains(where: { $0.part == .prop }) {
            f.append("Refuge : l'écharpe arrive au Grand Chamois, pas avant")
        }
        if !pixels(RefugeLook(stage: .chamois), mood: .hot).body.contains(where: { $0.part == .tongue }) { f.append("Refuge : il a chaud sans tirer la langue") }
        if !pixels(RefugeLook(stage: .cabri), mood: .sad).glow.contains(where: { $0.part == .sweat }) { f.append("Refuge : triste sans larme") }
        if berries.count != RefugeRules.welcomeGift || bush.contains(where: { $0.count != bushCols }) || bush.count != bushRows
            || berries.contains(where: { b in Array(bush[b.1])[b.0] == "." }) {
            f.append("Refuge : le buisson n'a pas ses 10 myrtilles sur ses feuilles")
        }
        return f
    }
}

/// The chamois alone, as it looks and in its mood, blinking now and then (the dashboard, the stage strip, the ceremonies).
struct RefugeAvatar: View {
    var look: RefugeLook
    var mood: RefugeMood = .happy
    var pixel: CGFloat = 4
    var animated = true
    @State private var blink = false

    var body: some View {
        Canvas { ctx, _ in
            RefugeFigure.draw(in: ctx, pixel: pixel, look: look, mood: mood, blink: blink)
        }
        .frame(width: pixel * CGFloat(RefugeFigure.cols), height: pixel * CGFloat(RefugeFigure.rows))
        .accessibilityElement()
        .accessibilityLabel("\(look.stage.title), \(mood.title.lowercased())")
        .task(id: animated) {
            guard animated, !Snapshot.isActive else { return }
            // Two tiny updates every few seconds, nothing per frame.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000)
                blink = true
                try? await Task.sleep(nanoseconds: 150_000_000)
                blink = false
            }
        }
    }
}

/// A speech bubble whose tail goes from its bottom left corner (or its bottom right one, `tailRight`) to `tip`,
/// relative to that corner: its mouth.
struct RefugeBubble: View {
    var text: String
    var maxWidth: CGFloat = 250
    var tip = CGPoint(x: -6, y: 12)
    var tailRight = false

    var body: some View {
        // The text wraps within `maxWidth` and the bubble hugs it; the frame around is only room, never drawn.
        Text(text)
            .font(.ui(12.5, .medium))
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RefugeBubbleShape(tip: tip, right: tailRight).fill(Theme.card))
            .overlay(RefugeBubbleShape(tip: tip, right: tailRight).stroke(Theme.borderStrong, lineWidth: max(1, Theme.line)))
            .themedShadow(color: .black.opacity(0.15), radius: 5, y: 2)
            .frame(width: maxWidth + 24, alignment: tailRight ? .bottomTrailing : .bottomLeading)
    }
}

/// A rounded box with a tail from its bottom edge to `tip`.
struct RefugeBubbleShape: Shape {
    var tip = CGPoint(x: -6, y: 12)
    /// The tail leaves from the bottom right corner.
    var right = false

    func path(in rect: CGRect) -> Path {
        let r = min(Theme.r(12), rect.height / 2)
        let box = Path(roundedRect: rect, cornerRadius: r, style: .continuous)
        let corner = right ? rect.maxX : rect.minX
        let side: CGFloat = right ? -1 : 1
        var tail = Path()
        tail.move(to: CGPoint(x: corner + side * 12, y: rect.maxY - 1))
        tail.addLine(to: CGPoint(x: corner + tip.x, y: rect.maxY + tip.y))
        tail.addLine(to: CGPoint(x: corner + side * 26, y: rect.maxY - 1))
        tail.closeSubpath()
        return box.union(tail)
    }
}

/// A blueberry, in pixels: the currency of the Refuge.
struct RefugeBerry: View {
    var size: CGFloat = 12

    var body: some View {
        Canvas { ctx, s in
            let p = s.width / 5
            let rows = ["..g..", ".bgb.", "bBbbb", "bbbbb", ".bbb."]
            let c = Theme.mascot
            let colors: [Character: Color] = ["g": c.leaf, "b": c.berry, "B": c.berryShine]
            for (y, line) in rows.enumerated() {
                for (x, ch) in line.enumerated() {
                    if let col = colors[ch] { ctx.fill(Path(CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: p, height: p)), with: .color(col)) }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
