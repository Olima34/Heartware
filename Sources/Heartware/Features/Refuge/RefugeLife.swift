import SwiftUI

// Its daily life, drawn: the trail of its round, the wall where it grows, its scarves on a line, its path.

// MARK: - The trail of the daily round

/// A little trail with a basket of blueberries at the end, and today's missions beside it. The trail counts what is done,
/// not in which order: one step per mission, its flag planted when reached, the chamois at the last one.
struct RefugeRoundTrail: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.refuge
        let tasks = m.roundTasks
        let progress = RefugeRoundProgress(tasks.map(\.done))
        VStack(alignment: .leading, spacing: 12) {
            RefugeSectionTitle(title: "Sa tournée du jour", subtitle: "Trois missions, dans l'ordre que tu veux.") {
                if progress.finished { Tag(text: "Finie : +10 dans ton panier", symbol: "checkmark", tint: Theme.good, filled: true) }
                else if !tasks.isEmpty { Text("\(progress.steps) sur \(progress.count)").font(.ui(12, .semibold)).foregroundStyle(Theme.text3) }
            }
            if tasks.isEmpty {
                Text("Sa tournée arrive avec ton premier passage de la journée.").font(.ui(12.5)).foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                HStack(alignment: .center, spacing: 28) {
                    GeometryReader { geo in trail(progress, width: geo.size.width, m: m) }
                        .frame(height: 92)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(tasks, id: \.task.id) { mission($0.task, done: $0.done, m: m) }
                    }
                    .frame(width: 370)
                }
            }
        }
    }

    // MARK: The trail

    /// Where the flag of step `index` (0 for the first) of `count` stands along the trail (0…1).
    private static func flag(_ index: Int, of count: Int) -> CGFloat {
        count <= 1 ? 0.47 : 0.2 + 0.54 * CGFloat(index) / CGFloat(count - 1)
    }

    /// The trail's height at a point along it (0…1), in points.
    private static func trailY(_ f: CGFloat) -> CGFloat { 50 + 9 * sin(f * .pi * 3) }

    private func trail(_ p: RefugeRoundProgress, width w: CGFloat, m: RefugeModel) -> some View {
        // The chamois: at the start, just past the last flag planted, or by the basket once the round is done.
        let walker: CGFloat = p.finished ? w - 104 : (p.steps == 0 ? 26 : w * Self.flag(p.steps - 1, of: p.count) + 44)
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, size in drawTrail(ctx, size: size, upTo: p.finished ? size.width : (p.steps == 0 ? 0 : walker)) }
            ForEach(0..<p.count, id: \.self) { i in
                let x = w * Self.flag(i, of: p.count)
                let planted = p.planted(i)
                Image(systemName: planted ? "flag.fill" : "flag")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(planted ? Theme.good : Theme.text3.opacity(0.7))
                    .position(x: x + 7, y: Self.trailY(x / w) - 13)
            }
            VStack(spacing: 1) {
                RefugeBasketIcon(count: p.finished ? 60 : 12, pixel: 3)
                Text(p.finished ? "+10 reçues" : "+10").font(.ui(11.5, .bold)).foregroundStyle(p.finished ? Theme.good : RefugePage.tint)
            }
            .position(x: w - 40, y: Self.trailY(1) + 4)
            RefugeAvatar(look: m.look(), pixel: 2.5)
                .offset(y: p.finished && m.dancing(now: Date()) ? -4 : 0)
                .position(x: walker, y: Self.trailY(min(1, walker / max(1, w))) - 21)
        }
    }

    private func drawTrail(_ ctx: GraphicsContext, size: CGSize, upTo reached: CGFloat) {
        var x: CGFloat = 8
        let end = size.width - 60
        while x < end {
            ctx.fill(Path(roundedRect: CGRect(x: x, y: Self.trailY(x / size.width) + 2, width: 7, height: 4), cornerRadius: 2),
                     with: .color(x <= reached ? RefugePage.tint.opacity(0.8) : Theme.borderStrong))
            x += 13
        }
        // A few tufts of grass beside the trail.
        for (i, f) in stride(from: 0.08, to: 0.9, by: 0.11).enumerated() {
            let gx = size.width * f, gy = Self.trailY(f) + (i % 2 == 0 ? 14 : -10)
            for dx in [-3.0, 0, 3] {
                ctx.fill(Path(CGRect(x: gx + dx, y: gy - abs(dx), width: 2, height: 5 + abs(dx) / 2)), with: .color(Theme.mascot.leaf.opacity(0.55)))
            }
        }
    }

    // MARK: The missions

    /// A mission ticked off when done, whatever its place in the list; else its way there.
    private func mission(_ task: RefugeTask, done: Bool, m: RefugeModel) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.r(4.5)).fill(done ? Theme.good : Color.clear)
                RoundedRectangle(cornerRadius: Theme.r(4.5)).strokeBorder(done ? Theme.good : Theme.borderStrong, lineWidth: 1.2)
                if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.ink(on: Theme.good)) }
            }
            .frame(width: 16, height: 16)
            Text(task.title).font(.ui(12.5, done ? .regular : .medium)).foregroundStyle(done ? Theme.text3 : Theme.text)
                .strikethrough(done, color: Theme.text3)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if !done {
                if task.id == "feed" {
                    // Feeding happens right here: the button gives it what it can eat, like the basket's.
                    let left = RefugeRules.appetiteLeft(m.state, now: Date())
                    Button("Lui en donner \(max(1, min(10, left, m.state.basket)))") { m.feed(10) }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .disabled(m.state.basket == 0 || left == 0)
                } else if let page = task.page {
                    Button("Y aller") { app.page = page }
                        .buttonStyle(SoftButtonStyle(small: true))
                }
            }
        }
        .frame(minHeight: 28)
    }
}

// MARK: - The growth wall

/// Its six stages side by side against the wall, like the height marks of a child: the ones it reached in color with the
/// day of their mue, the next one as a shadow with what is left to eat, the others as shadows.
struct RefugeGrowthWall: View {
    @Environment(AppModel.self) private var app
    private static let pixel: CGFloat = 6

    var body: some View {
        let m = app.refuge
        let s = m.state
        VStack(alignment: .leading, spacing: 12) {
            RefugeSectionTitle(title: "Il grandit", subtitle: "Six stades où il change vraiment. Les traits au mur gardent le jour de chaque mue.")
            ZStack(alignment: .bottom) {
                // The wall and its floor.
                RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous).fill(Theme.track)
                Canvas { ctx, size in
                    for x in stride(from: 0, to: size.width, by: 64) {
                        ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height - 34)), with: .color(Theme.border))
                    }
                    ctx.fill(Path(CGRect(x: 0, y: size.height - 34, width: size.width, height: 34)), with: .color(Theme.mascot.wood))
                    ctx.fill(Path(CGRect(x: 0, y: size.height - 34, width: size.width, height: 3)), with: .color(Theme.mascot.woodShade))
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous))
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(RefugeStage.allCases, id: \.rawValue) { stage in
                        column(stage, s: s, m: m)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 236)
            HStack(alignment: .top, spacing: 14) {
                RefugeScarfLine()
                RefugePathCard()
                    .frame(width: 400)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func column(_ stage: RefugeStage, s: RefugeState, m: RefugeModel) -> some View {
        let reached = s.stage >= stage
        let current = s.stage == stage
        let next = s.stage.next == stage
        var look = m.look()
        look.stage = stage
        look.scarf = stage == .grand ? .bronze : (stage == .gold ? .laine : nil)
        if !current { look.head = nil; look.face = nil; look.path = stage >= .beau ? look.path : nil }
        let body = RefugeFigure.pixels(look).body
        let headTop = body.map(\.y).min() ?? 0
        let leftEdge = body.map(\.x).min() ?? 0
        let p = Self.pixel
        let c = Theme.mascot
        return VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if current {
                    Circle().fill(RefugePage.tint.opacity(0.2)).frame(width: 110, height: 110).blur(radius: 18)
                        .offset(x: -14, y: -10)
                }
                Canvas { ctx, _ in
                    RefugeFigure.draw(in: ctx, pixel: p, look: look, ink: reached ? nil : Theme.text3.opacity(next ? 0.45 : 0.22))
                }
                .frame(width: p * CGFloat(RefugeFigure.cols), height: p * CGFloat(RefugeFigure.rows))
                if reached {
                    // The pencil mark at the height of its head, the day written beside it, on its left.
                    HStack(spacing: 3) {
                        Text(day(stage, s: s, m: m)).font(.ui(9.5, .semibold)).foregroundStyle(Theme.text2)
                        Rectangle().fill(Theme.text2).frame(width: 14, height: 2)
                    }
                    .fixedSize()
                    .frame(width: 70, alignment: .trailing)
                    .offset(x: CGFloat(leftEdge) * p - 72, y: CGFloat(headTop) * p - 6)
                }
            }
            .frame(height: p * CGFloat(RefugeFigure.rows) + 12, alignment: .bottom)
            // Written on the floorboards, in chalk.
            VStack(spacing: 2) {
                Text(stage.title).font(.ui(12, current ? .bold : .medium)).foregroundStyle(c.face.opacity(reached ? 1 : 0.6))
                if next {
                    Text("encore \(Fmt.int(max(0, stage.threshold - s.eaten)))").font(.ui(10.5, .semibold)).foregroundStyle(c.star)
                } else {
                    Text(stage.threshold == 0 ? "le premier jour" : "\(Fmt.int(stage.threshold)) mangées").font(.ui(10.5)).foregroundStyle(c.face.opacity(0.6))
                }
            }
            .padding(.top, 8)
            .frame(height: 40, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .help(reached ? "\(stage.title) : \(stage.change)" : "\(stage.title), à \(Fmt.int(stage.threshold)) myrtilles mangées : \(stage.change)")
    }

    /// The day of a stage's mue, read in its notebook.
    private func day(_ stage: RefugeStage, s: RefugeState, m: RefugeModel) -> String {
        if stage == .cabri { return "jour 1" }
        if let e = s.journal.first(where: { $0.kind == "mue" && $0.text.contains("me voilà \(stage.title) !") }) {
            return "jour \(RefugeRules.dayNumber(s, now: e.date))"
        }
        return "✓"
    }
}

// MARK: - The scarves on a line

/// The eight scarves hung on a line by clothes pegs: the ones it won in their material, the others as outlines. The
/// Chamois d'or picks the one it wears.
private struct RefugeScarfLine: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.refuge
        let s = m.state
        let won = s.stage >= .grand ? RefugeScarf.won(level: s.level) : []
        let worn = m.look().scarf
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ses écharpes").font(.serif(17)).foregroundStyle(Theme.text)
                Text(s.stage == .gold ? "Chamois d'or : choisis celle qu'il porte." : "Une nouvelle matière tous les 1 200 myrtilles mangées, dès le Grand Chamois.")
                    .font(.ui(11.5)).foregroundStyle(Theme.text3)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    // The line, sagging a little.
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 8))
                        p.addQuadCurve(to: CGPoint(x: w, y: 8), control: CGPoint(x: w / 2, y: 26))
                    }
                    .stroke(Theme.text3.opacity(0.6), lineWidth: 1.5)
                    ForEach(RefugeScarf.allCases, id: \.rawValue) { scarf in
                        let f = (CGFloat(scarf.rawValue) + 0.5) / CGFloat(RefugeScarf.allCases.count)
                        let sag = 8 + 18 * 4 * f * (1 - f) * 0.5
                        Button {
                            if s.stage == .gold { m.chooseScarf(scarf) }
                        } label: {
                            VStack(spacing: 4) {
                                RefugeScarfIcon(scarf: scarf, won: won.contains(scarf), worn: worn == scarf && s.stage >= .grand)
                                Text(scarf.title).font(.ui(10, .semibold)).foregroundStyle(won.contains(scarf) ? Theme.text : Theme.text3)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                Text(won.contains(scarf) ? (worn == scarf && s.stage >= .grand ? "portée" : "gagnée") : Fmt.int(scarf.threshold))
                                    .font(.ui(9.5)).foregroundStyle(Theme.text3)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(s.stage != .gold || !won.contains(scarf))
                        .help(won.contains(scarf) ? "Écharpe \(scarf.title.lowercased())" : "À \(Fmt.int(scarf.threshold)) myrtilles mangées")
                        .position(x: w * f, y: sag + 34)
                    }
                }
            }
            .frame(height: 96)
        }
    }
}

/// A scarf hung by a peg, two tails and a fringe.
struct RefugeScarfIcon: View {
    var scarf: RefugeScarf
    var won: Bool
    var worn = false

    var body: some View {
        Canvas { ctx, _ in
            let p: CGFloat = 4
            let colors = Theme.mascot.scarves[scarf.rawValue]
            let rows = ["..k..k..", "SsSSsSSs", ".SsSSsS.", ".S....S.", ".s....s.", ".S....S."]
            for (y, line) in rows.enumerated() {
                for (x, ch) in line.enumerated() {
                    let color: Color? = switch ch {
                    case "k": Theme.mascot.wood
                    case "S": won ? colors.main : Theme.borderStrong
                    case "s": won ? (scarf == .laine ? Theme.mascot.goldThread : colors.light) : Theme.border
                    default: nil
                    }
                    if let color { ctx.fill(Path(CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: p, height: p)), with: .color(color)) }
                }
            }
            if worn { ctx.fill(Path(CGRect(x: 7 * p, y: 0, width: p, height: p)), with: .color(Theme.mascot.star)) }
        }
        .frame(width: 32, height: 24)
    }
}

// MARK: - Its path

/// The four paths, each chamois with its accessory: the one it took stands out.
private struct RefugePathCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.refuge
        let s = m.state
        let chosen = s.path.flatMap(RefugePath.init(rawValue:))
        let open = s.stage >= .beau
        let canChange = open && RefugeStyle.canChangePath(s, on: m.clock)
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(open ? "Sa voie : \(chosen?.title ?? "…")" : "Sa voie").font(.serif(17)).foregroundStyle(Theme.text)
                Text(open ? (canChange ? "Il peut en changer une fois cette saison : clique sur une autre." : "Il garde sa voie jusqu'à la saison prochaine.")
                     : "Au stade Beau Chamois, il choisira selon les outils que tu utilises le plus.")
                    .font(.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(RefugePath.allCases, id: \.rawValue) { path in
                    let mine = path == chosen
                    Button { m.changePath(path) } label: {
                        VStack(spacing: 3) {
                            Canvas { ctx, _ in
                                var look = RefugeLook(stage: .beau, coat: m.look().coat, path: path)
                                look.head = nil
                                RefugeFigure.draw(in: ctx, pixel: 3.5, look: look, ink: open ? nil : Theme.text3.opacity(0.3))
                            }
                            .frame(width: 3.5 * CGFloat(RefugeFigure.cols), height: 3.5 * CGFloat(RefugeFigure.rows))
                            .opacity(open && !mine ? 0.55 : 1)
                            Text(path.title).font(.ui(10.5, mine ? .bold : .medium)).foregroundStyle(mine ? Theme.text : Theme.text3)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: Theme.r(10)).fill(mine ? RefugePage.tint.opacity(0.14) : .clear))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canChange || mine)
                    .help("\(path.title) : \(path.accessory). \(path.who)")
                }
            }
        }
    }
}
