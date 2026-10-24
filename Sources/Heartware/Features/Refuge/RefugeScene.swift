import SwiftUI

/// How its room is decorated: the wall, the floor, the window and the lamp chosen at the shop (nil: the room's own), and
/// the things put in it.
struct RefugeDecor: Equatable {
    var wall: String?
    var floor: String?
    var window: String?
    var lamp: String?
    var objects: Set<String> = []

    /// The decoration with one more thing of the shop tried on (the mirror of the stall).
    func trying(_ id: String) -> RefugeDecor {
        guard let item = RefugeStyle.item(id) else { return self }
        var d = self
        switch item.slot {
        case .wall: d.wall = id
        case .floor: d.floor = id
        case .window: d.window = id
        case .lamp: d.lamp = id
        case .room: d.objects.insert(id)
        case .head, .face: break
        }
        return d
    }
}

/// Its room, in pixels: a wall, a window on the mountains that follows the seasons (stars at night), the shelves of its
/// badges, its bed of straw, the lamp, all of it to decorate at the shop, and what the Mac puts in it: dust bunnies for
/// the junk, moths for the threats.
struct RefugeScene {
    static let cols = 64
    static let rows = 24
    /// Where its box stands: its feet on the floor, in the middle of the room.
    static let figure = (x: 20, y: 3)

    var look: RefugeLook
    var mood: RefugeMood
    var frame: Int
    var night: Bool
    var dust: Int
    var moths: Int
    var trophies: [RefugeMetal]
    var decor = RefugeDecor()
    var season: RefugeSeason = .automne
    var cake = false
    /// The step of a meal (berries flying to its mouth), nil when it is not eating.
    var feeding: Int? = nil
    var lift = 0

    private static let bunnies = [(1, 18), (11, 19), (36, 18), (56, 19), (46, 18)]
    private static let mothSpots = [(36, 11), (12, 14), (39, 1)]

    /// The pixel size that fits the room in `size`, on whole half-points.
    static func pixel(fitting size: CGSize) -> CGFloat {
        max(1, (min(size.width / CGFloat(cols), size.height / CGFloat(rows)) * 2).rounded(.down) / 2)
    }

    /// The room's top left corner in `size`.
    static func origin(in size: CGSize, pixel p: CGFloat) -> CGPoint {
        CGPoint(x: ((size.width - p * CGFloat(cols)) / 2).rounded(), y: ((size.height - p * CGFloat(rows)) / 2).rounded())
    }

    func draw(in ctx: GraphicsContext, size: CGSize) {
        let p = Self.pixel(fitting: size)
        let o = Self.origin(in: size, pixel: p)
        func fill(_ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1, _ color: Color) {
            ctx.fill(Path(CGRect(x: o.x + CGFloat(x) * p, y: o.y + CGFloat(y) * p, width: CGFloat(w) * p, height: CGFloat(h) * p)),
                     with: .color(color))
        }
        func sprite(_ rows: [String], _ x: Int, _ y: Int, _ colors: [Character: Color]) {
            for (dy, line) in rows.enumerated() {
                for (dx, ch) in line.enumerated() { if let c = colors[ch] { fill(x + dx, y + dy, 1, 1, c) } }
            }
        }
        let c = Theme.mascot
        func prop(_ name: String) -> Color { c.prop(name) }

        // The wall.
        switch decor.wall {
        case "rondins":
            for y in 0..<18 { fill(0, y, Self.cols, 1, y % 3 == 2 ? c.woodShade : (y % 3 == 0 ? c.wood : c.strawShade.opacity(0.9))) }
            for y in stride(from: 0, to: 18, by: 3) { fill(0, y, 1, 2, c.straw); fill(Self.cols - 1, y, 1, 2, c.straw) }
        case "pierre":
            // Soft stones, the mortar in the wall's own color.
            fill(0, 0, Self.cols, 18, Theme.track)
            for (row, y) in stride(from: 0, to: 18, by: 3).enumerated() {
                for x in stride(from: row % 2 == 0 ? 0 : -3, to: Self.cols, by: 6) {
                    fill(max(0, x), y, x < 0 ? 5 + x : 5, 2, c.mountain.opacity((x / 6 + row) % 3 == 0 ? 0.42 : 0.3))
                }
            }
        case "fleuri":
            // Small faded flowers, far apart.
            fill(0, 0, Self.cols, 18, prop("creme"))
            for (row, y) in stride(from: 2, to: 17, by: 5).enumerated() {
                for x in stride(from: row % 2 == 0 ? 3 : 7, to: Self.cols, by: 8) {
                    fill(x, y, 1, 1, prop("rose-clair").opacity(0.7))
                    fill(x - 1, y + 1, 1, 1, prop("vert").opacity(0.35))
                }
            }
        case "raye":
            for x in stride(from: 0, to: Self.cols, by: 3) { fill(x, 0, 3, 18, (x / 3) % 2 == 0 ? prop("creme") : prop("creme-ombre")) }
        default:
            fill(0, 0, Self.cols, 18, Theme.track)
            for x in stride(from: 4, to: Self.cols, by: 8) { fill(x, 0, 1, 18, Theme.border) }
        }

        // The floor.
        switch decor.floor {
        case "tomettes":
            fill(0, 18, Self.cols, 6, prop("terre"))
            for (row, y) in (18..<24).enumerated() where row % 2 == 1 { fill(0, y, Self.cols, 1, prop("orange-fonce").opacity(0.5)) }
            for y in 18..<24 { for x in stride(from: (y % 4 < 2) ? 1 : 3, to: Self.cols, by: 4) { fill(x, y, 1, 1, prop("orange-fonce").opacity(0.5)) } }
        case "moquette":
            fill(0, 18, Self.cols, 6, prop("violet"))
            for y in 18..<24 { for x in stride(from: (y * 3) % 5, to: Self.cols, by: 5) { fill(x, y, 1, 1, prop("violet-clair").opacity(0.6)) } }
        case "dallage":
            fill(0, 18, Self.cols, 6, c.mountain.opacity(0.8))
            for y in [20, 22] { fill(0, y, Self.cols, 1, Theme.border) }
            for y in 18..<24 { for x in stride(from: (y / 2) % 2 == 0 ? 3 : 7, to: Self.cols, by: 8) { fill(x, y, 1, 1, Theme.border) } }
        default:
            fill(0, 18, Self.cols, 6, c.wood)
            for (i, y) in [20, 22].enumerated() {
                for x in stride(from: 3 + i * 6, to: Self.cols, by: 12) { fill(x, y, 2, 1, c.woodShade) }
            }
        }
        fill(0, 18, Self.cols, 1, c.woodShade)

        // The window on the mountains, its shape, and its season.
        let glass: (Int, Int) -> Bool = switch decor.window {
        case "hublot": { x, y in let dx = Double(x) - 11.5, dy = Double(y) - 7.5; return dx * dx + dy * dy <= 22 }
        case "arche": { x, y in
            guard (6...17).contains(x), (4...11).contains(y) else { return false }
            let dx = Double(x) - 11.5, dy = Double(y) - 7.5
            return y >= 7 || dx * dx + dy * dy <= 36
        }
        default: { x, y in (6...17).contains(x) && (4...11).contains(y) }
        }
        func pane(_ x: Int, _ y: Int, _ color: Color) { if glass(x, y) { fill(x, y, 1, 1, color) } }
        for y in 2...13 {
            for x in 4...19 where !glass(x, y) {
                if (-1...1).contains(where: { dy in (-1...1).contains { dx in glass(x + dx, y + dy) } }) { fill(x, y, 1, 1, c.woodShade) }
            }
        }
        for y in 2...12 { for x in 5...18 { pane(x, y, night ? c.night : c.sky) } }
        if night {
            for dx in 0...1 { for dy in 0...1 { pane(15 + dx, 5 + dy, c.star) } }
            for (i, s) in [(7, 5), (10, 4), (12, 6), (8, 7)].enumerated() where (frame / 3 + i) % 4 != 0 { pane(s.0, s.1, c.star.opacity(0.85)) }
        } else if season == .ete {
            for dx in 0...1 { for dy in 0...1 { pane(15 + dx, 5 + dy, prop("jaune")) } }
        } else {
            for x in 7...9 { pane(x, 5, c.snow) }
            pane(8, 4, c.snow)
        }
        for x in 6...17 {
            let h = max(0, 4 - abs(x - 9), 5 - abs(x - 14))
            guard h > 0 else { continue }
            for y in (12 - h)...11 { pane(x, y, y == 12 - h && h >= 3 ? c.snow : c.mountain) }
        }
        switch season {
        case .hiver:
            for (i, x) in [7, 9, 12, 14, 16].enumerated() { pane(x, 4 + (frame / 2 + i * 3) % 8, c.snow) }
        case .automne:
            let step = (frame / 2) % 8
            pane(16 - step, 4 + step, prop("orange"))
        default:
            break
        }
        switch decor.window {
        case "vitrail":
            // Coloured panes, lead between them.
            for y in 4...11 { for x in 6...17 { pane(x, y, prop(["rose", "jaune", "bleu", "vert"][((x - 6) / 3 + (y - 4) / 4) % 4]).opacity(0.3)) } }
            for x in [8, 11, 14] { for y in 4...11 { pane(x, y, Theme.text3.opacity(0.8)) } }
            for x in 6...17 { pane(x, 7, Theme.text3.opacity(0.8)) }
        case "hublot":
            break
        default:
            for y in 2...12 { pane(11, y, c.woodShade) }
            for x in 5...18 { pane(x, 7, c.woodShade) }
        }
        fill(4, 13, 16, 1, c.wood)
        if season == .hiver { fill(4, 12, 16, 1, c.snow) }
        if season == .printemps { for (x, col) in [(6, "rose"), (8, "jaune"), (13, "rose"), (16, "jaune")] { fill(x, 12, 1, 1, prop(col)) } }

        // The things of the shop on the wall.
        let objects = decor.objects
        if objects.contains("toile") {
            // A spider's web in the corner, its spider.
            for i in 0...6 { fill(i, 0, 1, 1, Theme.text3.opacity(0.55)); fill(0, i, 1, 1, Theme.text3.opacity(0.55)); fill(i, i, 1, 1, Theme.text3.opacity(0.55)) }
            for (x, y) in [(3, 1), (2, 2), (1, 3), (5, 2), (4, 4), (2, 5), (6, 1), (1, 6)] { fill(x, y, 1, 1, Theme.text3.opacity(0.4)) }
            fill(4, 3 + (frame / 4) % 2, 1, 1, prop("fonte"))
        }
        if objects.contains("cadre") {
            sprite(["fffff", "fFwFf", "fwewf", "fffff"], 39, 14, ["f": prop("monture"), "F": c.fur, "w": c.face, "e": c.eye])
        }
        if objects.contains("guirlande") {
            fill(0, 0, 43, 1, Theme.text3.opacity(0.6))
            fill(52, 0, Self.cols - 52, 1, Theme.text3.opacity(0.6))
            for (i, x) in stride(from: 2, to: Self.cols, by: 4).enumerated() where !(43...51).contains(x) {
                let col = ["rose", "jaune", "bleu", "vert"][i % 4]
                fill(x, 1, 1, 1, prop(col).opacity((frame + i) % 3 == 0 ? 1 : 0.55))
            }
        }
        if objects.contains("tableau") {
            sprite(["fffffff", "fsswssf", "fsmmmsf", "fffffff"], 25, 0, ["f": prop("monture"), "s": c.sky, "w": c.snow, "m": c.mountain])
        }
        if objects.contains("coucou") {
            let swing = (frame / 2) % 2 == 0 ? 0 : 1
            sprite(["..h..", ".hHh.", "hhhhh", ".cec.", ".ccc."], 53, 0, ["h": c.woodShade, "H": c.wood, "c": prop("creme"), "e": c.eye])
            fill(54 + swing, 5, 1, 2, prop("jaune"))
        }
        if objects.contains("poele") {
            fill(2, 0, 2, 14, prop("fonte-claire"))
            let flame = frame % 2 == 0 ? "flamme" : "jaune"
            sprite(["kkkkkk", "kyyyyk", "kyooyk", "kyOOyk", "kkkkkk", "k....k"], 0, 14,
                   ["k": prop("fonte"), "y": prop("fonte-claire"), "o": prop(flame), "O": prop("jaune")])
        }

        // The shelves, its badges standing on them, an empty place for each one still to win.
        fill(38, 9, 25, 1, c.wood)
        fill(39, 10, 1, 1, c.woodShade)
        fill(61, 10, 1, 1, c.woodShade)
        fill(46, 14, 13, 1, c.wood)
        fill(47, 15, 1, 1, c.woodShade)
        fill(57, 15, 1, 1, c.woodShade)
        for i in 0..<RefugeRules.badges.count {
            let (x, y) = i < 12 ? (39 + i * 2, 7) : (47 + (i - 12) * 2, 12)
            guard i < trophies.count else { fill(x, y + 1, 1, 1, Theme.border); continue }
            let (main, light): (Color, Color) = switch trophies[i] {
            case .bronze: (c.bronze, c.bronzeLight)
            case .silver: (c.silver, c.silverLight)
            case .gold: (c.goldFurShade, c.goldRing)
            }
            fill(x, y, 1, 1, light)
            fill(x, y + 1, 1, 1, main)
        }
        if objects.contains("confiture") {
            sprite(["rwr", "gbg", "gbg"], 18, 10, ["r": prop("rose"), "w": prop("creme"), "g": prop("verre"), "b": prop("violet")])
        }
        if objects.contains("chaussettes") {
            for x in [41, 44] { sprite(["w.", "r.", "rr"], x, 10, ["w": prop("creme"), "r": prop("rouge")]) }
        }

        // Its bed of straw, a soft heap with a few strands sticking out.
        sprite(["....s...s.s....",
                "..SsssSsssssS..",
                ".sssSsssssSsss.",
                "SSSSSSSSSSSSSSS"], 44, 17, ["s": c.straw, "S": c.strawShade])

        // The things of the shop on the floor.
        if objects.contains("tapis") {
            for x in 18...38 { fill(x, 19, 1, 1, prop("rose")); fill(x, 20, 1, 1, prop("creme")); fill(x, 21, 1, 1, prop("rose")) }
            for y in 19...21 { fill(17, y, 1, 1, prop("creme-ombre")); fill(39, y, 1, 1, prop("creme-ombre")) }
        }
        if objects.contains("plante") {
            sprite([".vv.", "vVvv", "vvVv", ".vv.", "tttt", ".tt."], 59, 14, ["v": prop("vert"), "V": prop("vert-fonce"), "t": prop("terre")])
        }
        if objects.contains("luge") {
            sprite([".rrrrrrr.", ".rRRRRRr.", "..h...h..", "hhhhhhhhh"], 9, 19, ["r": prop("rose"), "R": prop("rose-clair"), "h": prop("monture")])
        }
        if objects.contains("citrouille") {
            sprite(["..v.", "oOoo", "oooO", ".oo."], 39, 16, ["v": prop("vert-fonce"), "o": prop("orange"), "O": prop("orange-fonce")])
        }
        if objects.contains("bouquet") {
            sprite(["r.j.", ".v.r", ".vv.", ".bb.", ".bb."], 16, 14, ["r": prop("rose"), "j": prop("jaune"), "v": prop("vert"), "b": prop("bleu")])
        }
        if objects.contains("sapin") {
            sprite(["....j....", "....v....", "...vVv...", "..vrvvv..", "...vvv...", "..vvvbv..", ".vvVvvvv.", "..vjvvv..", ".vvvvvrv.",
                    "vvvVvvvvv", "....t....", "...ttt..."], 7, 8,
                   ["j": prop(frame % 4 == 0 ? "creme" : "jaune"), "v": prop("vert-fonce"), "V": prop("vert"), "r": prop("rose"), "b": prop("bleu"), "t": prop("terre")])
        }
        if cake {
            fill(14, 15, 1, 1, prop(frame % 2 == 0 ? "flamme" : "jaune"))
            fill(14, 16, 1, 1, prop("creme"))
            sprite(["rcrcr", "ccccc"], 12, 17, ["r": prop("rose"), "c": prop("creme")])
        }

        // The dust bunnies under the furniture, wiggling a little.
        for (i, spot) in Self.bunnies.prefix(dust).enumerated() {
            let shift = ((frame + i * 3) / 4) % 2
            sprite(["..d.d..", ".ddddd.", "ddededd", "ddddddd", ".DDDDD."], spot.0 + shift, spot.1, ["d": c.dust, "D": c.dustShade, "e": c.eye])
        }

        // The night dims the room; the lamp stays lit.
        if night { fill(0, 0, Self.cols, Self.rows, Color.black.opacity(0.22)) }
        switch decor.lamp {
        case "lanterne":
            fill(47, 0, 1, 2, Theme.text3)
            sprite([".k.", "kyk", "kyk", "kkk"], 46, 2, ["k": prop("fonte"), "y": prop(frame % 6 == 0 ? "flamme" : "jaune")])
        case "lampion":
            fill(47, 0, 1, 2, Theme.text3)
            sprite([".rrr.", "rcrcr", "rcrcr", ".rrr."], 45, 2, ["r": prop("rose"), "c": prop("rose-clair")])
        case "lustre":
            fill(47, 0, 1, 2, Theme.text3)
            fill(44, 2, 7, 1, c.woodShade)
            for x in [44, 47, 50] {
                fill(x, 1, 1, 1, prop("creme"))
                fill(x, 0, 1, 1, prop((frame + x) % 3 == 0 ? "flamme" : "jaune"))
            }
        default:
            fill(47, 0, 1, 2, Theme.text3)
            fill(46, 2, 3, 1, c.woodShade)
            fill(47, 3, 1, 1, c.star)
        }

        // The chamois.
        let blink = frame % 18 == 17
        let fx = Self.figure.x, fy = Self.figure.y
        RefugeFigure.draw(in: ctx, at: CGPoint(x: o.x + CGFloat(fx) * p, y: o.y + CGFloat(fy) * p), pixel: p,
                          look: look, mood: feeding != nil ? .happy : mood, frame: frame, blink: blink, eating: feeding != nil, lift: lift)

        // A meal: three berries hopping from the straw to its mouth.
        if let step = feeding {
            let mouth = RefugeFigure.mouth(look.stage)
            let target = (x: fx + mouth.x, y: fy + mouth.y - lift)
            for k in 0..<3 {
                let t = Double((step + k * 3) % 9) / 8
                let x = Int((46 + (Double(target.x) - 46) * t).rounded())
                let y = Int((17 + (Double(target.y) - 17) * t - 4 * sin(t * .pi)).rounded())
                if t < 1 { fill(x, y, 1, 1, k == 1 ? c.berryShine : c.berry) }
            }
        }

        // A little hunger: it dreams of a blueberry.
        if mood == .hungry, feeding == nil {
            fill(35, 8, 1, 1, Theme.card)
            fill(36, 6, 1, 1, Theme.card)
            sprite([".ccc.", "ccbcc", ".ccc."], 37, 2, ["c": Theme.card, "b": c.berry])
        }

        // The things of Halloween that move: a little ghost floating, two bats.
        if objects.contains("fantome") {
            let bob = (frame / 3) % 2
            sprite([".www.", "wwwww", "wewew", "wwwww", "wwwww", "w.w.w"], 12, 11 + bob, ["w": prop("creme").opacity(0.9), "e": c.eye])
        }
        if objects.contains("chauves-souris") {
            for (i, spot) in [(33, 1), (41, 3)].enumerated() {
                let up = (frame + i) % 2 == 0
                sprite(up ? ["bb.bb", "..b.."] : ["..b..", "bbbbb"], spot.0, spot.1 + (up ? 0 : 1), ["b": prop("violet")])
            }
        }

        // The moths, fluttering around.
        for (i, spot) in Self.mothSpots.prefix(moths).enumerated() {
            let orbit = [(0, 0), (1, -1), (2, 0), (1, 1)][(frame + i) % 4]
            let up = (frame + i) % 2 == 0
            sprite(up ? ["..b.b..", "ww.b.ww", "wwebeww", ".w.b.w."] : ["..b.b..", "...b...", "wwebeww", "ww.b.ww"],
                   spot.0 + orbit.0, spot.1 + orbit.1, ["w": c.mothWing, "b": c.moth, "e": c.sparkle])
        }

        // Its dreams.
        if mood == .sleepy, feeding == nil {
            for k in 0..<2 {
                let phase = (frame + k * 6) % 12
                let alpha = 1 - Double(phase) / 12
                // Above its head, clear of the horns and the shelf.
                let x = k == 0 ? 34 + phase / 6 : 38 + phase / 6
                let y = k == 0 ? 4 - phase / 4 : 2 - phase / 6
                sprite(["####", "..#.", ".#..", "####"], x, y, ["#": Theme.text2.opacity(alpha)])
            }
        }
    }

    /// Where its mouth and the left side of its head are, in points (the bubble it speaks in).
    func speaker(in size: CGSize) -> (mouth: CGPoint, headLeft: CGFloat, headTop: CGFloat) {
        let p = Self.pixel(fitting: size)
        let o = Self.origin(in: size, pixel: p)
        let m = RefugeFigure.mouth(look.stage)
        let body = RefugeFigure.pixels(look).body
        let head = body.filter { $0.y <= m.y && $0.part != .horn && $0.part != .hornRing && $0.part != .prop }
        let left = head.map(\.x).min() ?? m.x
        let top = body.filter { $0.part == .face }.map(\.y).min() ?? m.y
        return (CGPoint(x: o.x + CGFloat(Self.figure.x + m.x) * p, y: o.y + CGFloat(Self.figure.y + m.y - lift) * p + p / 2),
                o.x + CGFloat(Self.figure.x + left) * p, o.y + CGFloat(Self.figure.y + top) * p)
    }

    /// Whether a point of the room is on the chamois.
    func touches(_ point: CGPoint, in size: CGSize) -> Bool {
        let p = Self.pixel(fitting: size)
        let o = Self.origin(in: size, pixel: p)
        let x = Int(((point.x - o.x) / p).rounded(.down)) - Self.figure.x
        let y = Int(((point.y - o.y) / p).rounded(.down)) - Self.figure.y + lift
        return RefugeFigure.touches(look, x: x, y: y)
    }
}

/// The room on the page, alive a few times a second while it is on screen. It speaks in a bubble coming out of its
/// mouth; a click on it is a caress.
struct RefugeRoomView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = true
    @State private var lift = 0

    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)
    private static let step = 0.25

    var body: some View {
        let animated = !(Snapshot.isActive || reduceMotion || !onScreen)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if animated {
                    TimelineView(.periodic(from: Self.epoch, by: Self.step)) { context in
                        room(frame: Int(context.date.timeIntervalSince(Self.epoch) / Self.step), date: context.date)
                    }
                } else {
                    room(frame: 4, date: Date())
                }
                bubble(in: geo.size)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                guard scene(frame: 0, date: Date()).touches(tap.location, in: geo.size) else { return }
                app.refuge.pet()
                lift = 1
                Task {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    lift = 0
                }
            })
        }
        .background { if !Snapshot.isActive { MascotWindowProbe(onScreen: $onScreen) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("La pièce de \(app.refuge.name)")
        .accessibilityAction(named: "Une caresse") { app.refuge.pet() }
    }

    private func scene(frame: Int, date: Date) -> RefugeScene {
        let m = app.refuge
        let look = m.scene(now: date)
        return RefugeScene(look: m.look(now: date), mood: look.mood, frame: frame, night: look.night, dust: look.dust, moths: look.moths,
                           trophies: m.trophies, decor: m.decor, season: RefugeSeason.of(m.previewDate ?? date),
                           cake: m.events(now: date).contains(.anniversaire), feeding: m.feedingStep(now: date),
                           lift: lift + (m.dancing(now: date) && frame % 2 == 0 ? 1 : 0))
    }

    private func room(frame: Int, date: Date) -> some View {
        let scene = scene(frame: frame, date: date)
        return Canvas { ctx, size in scene.draw(in: ctx, size: size) }
    }

    /// Its words, in a bubble on the left of its head (the shelves on its right keep what is bought in view), the tail
    /// stopping at the edge of its head, level with its mouth: the words come out of it.
    private func bubble(in size: CGSize) -> some View {
        let spot = scene(frame: 0, date: Date()).speaker(in: size)
        let right = spot.headLeft - 10
        let bottom = spot.headTop + 6
        return RefugeBubble(text: app.refuge.line(), maxWidth: min(230, max(110, right - 30)),
                            tip: CGPoint(x: spot.headLeft + 3 - right, y: spot.mouth.y - bottom), tailRight: true)
            .alignmentGuide(.top) { d in d[.bottom] - bottom }
            .alignmentGuide(.leading) { d in d[.trailing] - right }
            .allowsHitTesting(false)
            .id(app.refuge.line())
            .transition(.opacity)
    }
}
