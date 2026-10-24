import SwiftUI

// Its house and its memories: the chalet whose windows light up, the medals, where blueberries grow.

// MARK: - The chalet

/// Its house, seen in cross-section: every tool is a room, its window lit the first time the user goes in. A click on a
/// window opens the tool.
struct RefugeChalet: View {
    @Environment(AppModel.self) private var app
    @State private var hovered: Page?

    static let size = CGSize(width: 540, height: 462)

    /// Where each room's window is, in the chalet's coordinates.
    private static let windows: [(page: Page, rect: CGRect)] = {
        var out: [(Page, CGRect)] = [
            (.menubar, CGRect(x: 251, y: 62, width: 38, height: 32)),
            (.wheel, CGRect(x: 401, y: 38, width: 30, height: 30)),
            (.storage, CGRect(x: 176, y: 136, width: 76, height: 42)),
            (.media, CGRect(x: 288, y: 136, width: 76, height: 42)),
        ]
        let floor2: [Page] = [.hotkeys, .toolbox]
        let floor1: [Page] = [.dashboard, .assistant, .performance, .protection]
        // Four windows a floor, centred where six used to be.
        for (i, p) in floor2.enumerated() { out.append((p, CGRect(x: 147 + CGFloat(i) * 63, y: 196, width: 54, height: 44))) }
        for (i, p) in floor1.enumerated() { out.append((p, CGRect(x: 147 + CGFloat(i) * 63, y: 262, width: 54, height: 44))) }
        out += [
            (.cleanup, CGRect(x: 92, y: 330, width: 64, height: 46)),
            (.phone, CGRect(x: 170, y: 330, width: 56, height: 46)),
            (.updates, CGRect(x: 318, y: 346, width: 30, height: 26)),
            (.automation, CGRect(x: 478, y: 344, width: 52, height: 40)),
            (.battery, CGRect(x: 140, y: 408, width: 74, height: 38)),
            (.apps, CGRect(x: 326, y: 408, width: 74, height: 38)),
        ]
        return out
    }()

    var body: some View {
        let m = app.refuge
        let lit = Set(RefugeRules.discovered(m.state).map(\.page))
        VStack(alignment: .leading, spacing: 10) {
            RefugeSectionTitle(title: "Sa maison", subtitle: "Chaque outil est une pièce. Sa fenêtre s'allume la première fois que tu y entres (+5 myrtilles).") {
                Text("\(lit.count) sur \(RefugeRules.rooms.count)").font(.ui(12, .semibold)).foregroundStyle(Theme.text3)
            }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in Self.drawHouse(ctx) }
                ForEach(Self.windows, id: \.page) { w in
                    window(w.page, rect: w.rect, lit: lit.contains(w.page))
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .frame(maxWidth: .infinity)
            caption(lit: lit)
        }
        .frame(width: Self.size.width + 20)
    }

    private func window(_ page: Page, rect: CGRect, lit: Bool) -> some View {
        let room = RefugeRules.room(page)
        let c = Theme.mascot
        return Button { app.page = page } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(lit ? AnyShapeStyle(LinearGradient(colors: [c.star, Theme.warn], startPoint: .top, endPoint: .bottom))
                                                          : AnyShapeStyle(c.night))
                RoundedRectangle(cornerRadius: 3).strokeBorder(c.woodShade, lineWidth: 3)
                if rect.width > 40 {
                    // The window's cross.
                    Rectangle().fill(c.woodShade.opacity(0.7)).frame(width: 2)
                }
                Image(systemName: lit ? page.symbol : "questionmark")
                    .font(.system(size: min(rect.height * 0.42, 17), weight: .semibold))
                    .foregroundStyle(lit ? c.horn : Color.white.opacity(0.35))
                    .padding(3)
                    .background(lit && rect.width > 40 ? Circle().fill(c.star.opacity(0.65)) : nil)
            }
            .frame(width: rect.width, height: rect.height)
            .scaleEffect(hovered == page ? 1.08 : 1)
            .shadow(color: lit ? Theme.warn.opacity(hovered == page ? 0.8 : 0.45) : .clear, radius: lit ? 8 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? page : (hovered == page ? nil : hovered) }
        .help(room.map { "\($0.name) · \(page.title)" } ?? page.title)
        .position(x: rect.midX, y: rect.midY)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func caption(lit: Set<Page>) -> some View {
        let text: (String, String)
        if let hovered, let room = RefugeRules.room(hovered) {
            text = ("\(room.name) · \(hovered.title)", lit.contains(hovered) ? hovered.pitch : "Pas encore visitée : \(hovered.pitch)")
        } else {
            text = (lit.count == RefugeRules.rooms.count ? "Toutes les fenêtres sont allumées" : "\(lit.count) fenêtres allumées",
                    "Survole une fenêtre pour savoir ce qu'il y a derrière, clique pour y entrer.")
        }
        return VStack(spacing: 2) {
            Text(text.0).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
            Text(text.1).font(.ui(11.5)).foregroundStyle(Theme.text3).multilineTextAlignment(.center).lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
    }

    /// The chalet itself: its roof and chimney, its wooden walls and floors, its door, the veranda, the garden, the cellar.
    private static func drawHouse(_ ctx: GraphicsContext) {
        let c = Theme.mascot
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
            ctx.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(color))
        }
        // The cellar, in stone, under the ground.
        rect(90, 396, 360, 60, c.mountain.opacity(0.55))
        for (i, y) in stride(from: 400.0, to: 452, by: 13).enumerated() {
            for x in stride(from: 90.0 + Double(i % 2) * 18, to: 450, by: 36) { rect(x, y, 30, 9, c.mountain.opacity(0.35)) }
        }
        // The ground.
        rect(0, 386, size.width, 10, c.leaf)
        rect(0, 392, size.width, 4, c.leafShade)
        // The chimney, a wisp of smoke.
        rect(118, 50, 20, 56, c.woodShade)
        rect(114, 46, 28, 8, c.woodShade)
        for (i, d) in [(0.0, 34.0), (8, 22), (2, 10)].enumerated() {
            ctx.fill(Path(ellipseIn: CGRect(x: 120 + d.0, y: d.1, width: 14 - CGFloat(i) * 2, height: 10 - CGFloat(i) * 2)), with: .color(Theme.text3.opacity(0.25)))
        }
        // The walls, in planks.
        rect(72, 128, 396, 260, c.wood)
        for x in stride(from: 72.0, to: 468, by: 22) { rect(x, 128, 1, 260, c.woodShade.opacity(0.35)) }
        // The floors.
        for y in [184.0, 250, 316] { rect(72, y, 396, 5, c.woodShade) }
        // The roof, its eaves over the walls.
        var roof = Path()
        roof.move(to: CGPoint(x: 270, y: 14))
        roof.addLine(to: CGPoint(x: 494, y: 130))
        roof.addLine(to: CGPoint(x: 46, y: 130))
        roof.closeSubpath()
        ctx.fill(roof, with: .color(c.woodShade))
        for i in 1..<6 {
            let y = 14 + CGFloat(i) * 20
            let half = (y - 14) / 116 * 224
            rect(270 - half, y, half * 2, 2, c.horn.opacity(0.35))
        }
        // The antenna of the radio tower.
        rect(414, 66, 3, 30, c.horn)
        // The door, its knob.
        ctx.fill(Path(roundedRect: CGRect(x: 238, y: 326, width: 58, height: 62), cornerRadii: RectangleCornerRadii(topLeading: 24, topTrailing: 24)),
                 with: .color(c.woodShade))
        ctx.fill(Path(ellipseIn: CGRect(x: 282, y: 356, width: 6, height: 6)), with: .color(c.bell))
        // The mailbox's post.
        rect(331, 372, 4, 14, c.woodShade)
        // The veranda, glazed, against the left wall.
        rect(10, 304, 62, 82, c.sky.opacity(0.35))
        rect(10, 300, 62, 5, c.woodShade)
        // The garden, a blueberry bush and a few flowers.
        for (x, y, r) in [(486.0, 360.0, 14.0), (504, 352, 16), (522, 362, 13)] {
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r + 10, width: r * 2, height: r * 2)), with: .color(c.leafShade))
        }
        for (x, y) in [(480.0, 366.0), (500, 358), (514, 368), (526, 360)] {
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 5, height: 5)), with: .color(c.berry))
        }
    }
}

// MARK: - The medals

/// Its medals, hanging from two strings by their ribbons: the ones won shine in their metal, the others wait as outlines.
struct RefugeMedals: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = app.refuge.state
        let badges = RefugeRules.badges
        let won = badges.filter { s.badges[$0.id] != nil }.count
        VStack(alignment: .leading, spacing: 10) {
            RefugeSectionTitle(title: "Ses médailles", subtitle: "Les bons gestes, la régularité et la curiosité. Deux sont secrètes.") {
                Text("\(won) sur \(badges.count)").font(.ui(12, .semibold)).foregroundStyle(Theme.text3)
            }
            VStack(spacing: 18) {
                ForEach([0, 9], id: \.self) { start in
                    ZStack(alignment: .top) {
                        Rectangle().fill(Theme.text3.opacity(0.5)).frame(height: 1.5)
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(badges[start..<min(start + 9, badges.count)]) { b in
                                medal(b, date: s.badges[b.id]).frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func medal(_ b: RefugeBadge, date: Date?) -> some View {
        let c = Theme.mascot
        let hidden = b.secret && date == nil
        let (main, light, ribbon): (Color, Color, Color) = switch b.metal {
        case .bronze: (c.bronze, c.bronzeLight, c.prop("rouge"))
        case .silver: (c.silver, c.silverLight, c.prop("bleu"))
        case .gold: (c.goldFurShade, c.goldRing, c.prop("vert"))
        }
        return VStack(spacing: 0) {
            // The ribbon, in a V.
            HStack(spacing: 2) {
                Rectangle().fill(date == nil ? Theme.border : ribbon).frame(width: 7, height: 20).rotationEffect(.degrees(16))
                Rectangle().fill(date == nil ? Theme.border : ribbon.opacity(0.8)).frame(width: 7, height: 20).rotationEffect(.degrees(-16))
            }
            ZStack {
                if date == nil {
                    Circle().strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                } else {
                    Circle().fill(LinearGradient(colors: [light, main], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().strokeBorder(main, lineWidth: 2)
                }
                Image(systemName: hidden ? "questionmark" : b.symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(date == nil ? Theme.text3 : c.horn)
            }
            .frame(width: 42, height: 42)
            .offset(y: -3)
            Text(hidden ? "Secrète" : b.title).font(.ui(10.5, .semibold)).foregroundStyle(date == nil ? Theme.text3 : Theme.text)
                .multilineTextAlignment(.center).lineLimit(2).frame(height: 28, alignment: .top)
            Text(hidden ? "à toi de la trouver" : (date.map { "le \(Fmt.day($0))" } ?? b.detail))
                .font(.ui(9.5)).foregroundStyle(Theme.text3).multilineTextAlignment(.center).lineLimit(2)
        }
        .padding(.horizontal, 3)
        .help(hidden ? "Une médaille secrète" : b.detail)
    }
}

// MARK: - Where blueberries grow

/// What earns blueberries, as a bush and little tags rather than a table.
struct RefugeBerryGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RefugeSectionTitle(title: "Où cueillir des myrtilles", subtitle: "En prenant soin du Mac. Jamais selon ce que tu supprimes : personne n'efface pour le faire grandir.")
            HStack(alignment: .top, spacing: 16) {
                Canvas { ctx, _ in
                    RefugeFigure.drawBush(in: ctx, at: .zero, pixel: 6)
                }
                .frame(width: 6 * CGFloat(RefugeFigure.bushCols), height: 6 * CGFloat(RefugeFigure.bushRows))
                FlowLayout(spacing: 8) {
                    ForEach(RefugeSource.allCases.filter { $0 != .welcome }, id: \.rawValue) { src in
                        HStack(spacing: 6) {
                            RefugeBerry(size: 11)
                            Text("+\(src.amount)").font(.ui(11.5, .bold)).foregroundStyle(RefugePage.tint)
                            Text(src.what).font(.ui(11.5)).foregroundStyle(Theme.text)
                            Text(src.limit).font(.ui(10.5)).foregroundStyle(Theme.text3)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(PillShape().fill(Theme.track.opacity(0.8)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
