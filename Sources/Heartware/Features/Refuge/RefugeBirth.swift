import SwiftUI

/// The steps of its birth: it comes out of its bush, the user picks the ten blueberries, names it, gives it its first
/// meal. Or says no for now (`decline`, the second window, with its tear).
enum RefugeBirthStep: Equatable {
    case intro, pick, name, feed, fed, decline
}

/// Its birth, in the middle of the window: a blueberry bush rustles, a little cabri pops out of it and hops beside it.
struct RefugeBirthPanel: View {
    @Environment(AppModel.self) private var app

    @State private var step: RefugeBirthStep = .intro
    /// Where « Finalement, je m'occupe de lui » goes back to.
    @State private var before: RefugeBirthStep = .pick
    /// The step of the intro's animation, ten per second, and a slow one afterwards (blinks, the tear, the meal).
    @State private var tick = 0
    @State private var slow = 0
    @State private var picked: Set<Int> = []
    @State private var name = RefugeRules.defaultName
    @State private var eaten = 0

    static let cols = 56
    static let rows = 17
    static let pixel: CGFloat = 9
    /// Where things stand in the scene, in cells: the bush, the cabri's box once out, the basket.
    private static let bush = (x: 4, y: 7)
    private static let standing = (x: 17, y: -1)
    private static let basket = (x: 40, y: 12)
    private static let introLength = 36

    var body: some View {
        let m = app.refuge
        VStack(alignment: .center, spacing: 14) {
            Text(kicker.uppercased())
                .font(.ui(10.5, .semibold)).tracking(0.8).foregroundStyle(RefugePage.tint)
            Text(title)
                .font(.serif(25)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            scene
                .frame(width: Self.pixel * CGFloat(Self.cols), height: Self.pixel * CGFloat(Self.rows))
            controls(m)
                .frame(minHeight: 64)
            HStack {
                if step == .intro || step == .pick || step == .name {
                    Button("Je ne souhaite pas m'occuper de \(RefugeRules.defaultName)") {
                        before = step == .intro ? .pick : step
                        step = .decline
                    }
                    .buttonStyle(.plain)
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.text3)
                    .help("Ce n'est pas définitif : tu pourras l'adopter plus tard")
                }
                Spacer()
            }
        }
        .onAppear {
            if let first = m.previewBirthStep {
                step = first
                tick = Self.introLength
                if first != .pick { picked = Set(0..<RefugeFigure.berries.count) }
                if first == .fed { eaten = RefugeRules.welcomeGift }
            }
        }
        .task(id: step) { await play() }
    }

    private var kicker: String {
        switch step {
        case .intro, .pick, .name: return "Il est né"
        case .feed, .fed: return "Son premier repas"
        case .decline: return "Vraiment ?"
        }
    }

    private var title: String {
        switch step {
        case .intro, .pick: return "Un petit chamois sort du buisson"
        case .name: return "Comment veux-tu l'appeler ?"
        case .feed, .fed: return "Des myrtilles pour \(RefugeRules.cleanName(name))"
        case .decline: return "Tu ne veux pas t'occuper de lui ?"
        }
    }

    // MARK: The scene

    private var scene: some View {
        let speech = line
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in draw(ctx) }
            if let speech, tick >= Self.introLength || step != .intro {
                bubble(speech)
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { tap in pickBerry(at: tap.location) })
    }

    /// What it says, at each step.
    private var line: String? {
        switch step {
        case .intro: return nil
        case .pick:
            let gift = app.refuge.returningUser ? "Tu en as déjà gagné quelques-unes en utilisant l'app" : "Voici un cadeau de bienvenue"
            return "Coucou ! Je suis né dans ce buisson de myrtilles, et je grandis en les mangeant. \(gift) : cueille-les !"
        case .name: return "Merci ! Et moi, comment veux-tu m'appeler ?"
        case .feed: return eaten == 0 ? "\(RefugeRules.cleanName(name)), j'adore ! Tu me donnes mes premières myrtilles ?" : "Miam… miam…"
        case .fed: return "Miam ! Merci. Plus je mange, plus je grandis. À tout de suite au Refuge !"
        case .decline: return "Tu ne veux vraiment pas t'occuper de moi ?"
        }
    }

    private func bubble(_ text: String) -> some View {
        let p = Self.pixel
        let mouth = RefugeFigure.mouth(.cabri)
        // The tail stops at the edge of its head, level with its mouth.
        let mouthY = CGFloat(Self.standing.y + mouth.y) * p + p / 2
        let headRight = CGFloat(Self.standing.x + 3 + 10) * p
        let left = headRight + 2 * p
        let bottom = CGFloat(Self.standing.y + 7) * p + 4
        return RefugeBubble(text: text, maxWidth: CGFloat(Self.cols) * p - left - 30,
                            tip: CGPoint(x: headRight - 2 - left, y: mouthY - bottom))
            .alignmentGuide(.top) { d in d[.bottom] - bottom }
            .alignmentGuide(.leading) { _ in -left }
            .allowsHitTesting(false)
    }

    /// Where the cabri's box is, and whether it is still behind the bush, at this point of the intro.
    private var cabri: (x: Double, y: Double, behind: Bool, mood: RefugeMood) {
        guard step == .intro, tick < Self.introLength else {
            let mood: RefugeMood = step == .decline ? .sad : (slow % 15 == 14 ? .sleepy : .happy)
            return (Double(Self.standing.x), Double(Self.standing.y), false, mood)
        }
        let hidden = (x: Double(Self.bush.x) - 2, y: 9.0)
        switch tick {
        case ..<10: return (hidden.x, hidden.y, true, .sleepy)
        case 10..<18: return (hidden.x, max(-4, hidden.y - Double(tick - 9) * 1.6), true, .sleepy)
        case 18..<21: return (hidden.x, -4, true, tick < 19 ? .sleepy : .happy)
        case 21..<29:
            let u = Double(tick - 20) / 8
            return (hidden.x + (Double(Self.standing.x) - hidden.x) * u, -4 + 3 * u - 4 * sin(u * .pi), u < 0.35, .happy)
        default: return (Double(Self.standing.x), Double(Self.standing.y), false, .happy)
        }
    }

    private func draw(_ ctx: GraphicsContext) {
        let p = Self.pixel
        let c = Theme.mascot
        func fill(_ x: Int, _ y: Int, _ color: Color) {
            ctx.fill(Path(CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: p, height: p)), with: .color(color))
        }
        let ground = Self.rows - 1
        let pose = cabri
        let look = RefugeLook(stage: .cabri)
        func drawCabri() {
            var clipped = ctx
            clipped.clip(to: Path(CGRect(x: 0, y: 0, width: CGFloat(Self.cols) * p, height: CGFloat(ground) * p)))
            RefugeFigure.draw(in: clipped, at: CGPoint(x: (pose.x * Double(p)).rounded(), y: (pose.y * Double(p)).rounded()), pixel: p,
                              look: look, mood: pose.mood, frame: slow, eating: step == .feed && eaten > 0 && eaten < RefugeRules.welcomeGift)
        }
        let rustle = step == .intro && tick < 18 ? [0, 1, 0, -1][tick % 4] : 0
        if pose.behind { drawCabri() }
        RefugeFigure.drawBush(in: ctx, at: CGPoint(x: CGFloat(Self.bush.x) * p, y: CGFloat(Self.bush.y) * p), pixel: p,
                              rustle: rustle, picked: picked)
        if !pose.behind { drawCabri() }

        // A few leaves flying off the rustling bush.
        if step == .intro, tick < 12 {
            for (i, x) in [7, 12, 15].enumerated() {
                let y = Self.bush.y - 1 - (tick + i * 2) / 3
                if y >= 0 { fill(Self.bush.x + x - 4, y, c.leaf.opacity(1 - Double(tick) / 12)) }
            }
        }
        // A heart, once it has landed.
        if step == .intro, (29..<Self.introLength).contains(tick) {
            fill(Self.standing.x + 8, 4 - (tick - 29) / 3, c.prop("rose"))
        }

        // The ground.
        for x in 0..<Self.cols { fill(x, ground, x % 5 == 0 ? c.leafShade : c.leaf) }

        // The basket the berries go into (from the moment there is something to pick).
        if step != .intro || tick >= Self.introLength {
            let b = Self.basket
            let inBasket = max(0, picked.count - (step == .feed || step == .fed ? eaten : 0))
            for (dx, dy) in [(0, 1), (6, 1), (0, 2), (1, 2), (2, 2), (3, 2), (4, 2), (5, 2), (6, 2), (1, 3), (2, 3), (3, 3), (4, 3), (5, 3)] {
                fill(b.x + dx, b.y + dy, dy == 3 ? c.strawShade : c.straw)
            }
            fill(b.x, b.y, c.strawShade)
            fill(b.x + 6, b.y, c.strawShade)
            for i in 0..<inBasket {
                fill(b.x + 1 + i % 5, b.y + 1 - i / 5, i % 3 == 0 ? c.berryShine : c.berry)
            }
            // The berry on its way to its mouth.
            if step == .feed, eaten > 0, eaten <= RefugeRules.welcomeGift, slow % 2 == 0 {
                let mouth = RefugeFigure.mouth(.cabri)
                fill((b.x + Self.standing.x + mouth.x) / 2, Self.standing.y + mouth.y - 2, c.berry)
            }
        }
    }

    // MARK: Picking

    private func pickBerry(at point: CGPoint) {
        guard step == .pick else { return }
        let x = Int(point.x / Self.pixel), y = Int(point.y / Self.pixel)
        let near = RefugeFigure.berries.enumerated()
            .filter { !picked.contains($0.offset) && abs(Self.bush.x + $0.element.0 - x) <= 1 && abs(Self.bush.y + $0.element.1 - y) <= 1 }
            .min { abs(Self.bush.x + $0.element.0 - x) + abs(Self.bush.y + $0.element.1 - y) < abs(Self.bush.x + $1.element.0 - x) + abs(Self.bush.y + $1.element.1 - y) }
        if let near { picked.insert(near.offset) }
        if picked.count == RefugeFigure.berries.count { advanceAfterPicking() }
    }

    private func advanceAfterPicking() {
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            if step == .pick { step = .name }
        }
    }

    // MARK: The answers

    @ViewBuilder
    private func controls(_ m: RefugeModel) -> some View {
        switch step {
        case .intro:
            Text(tick < 10 ? "Le buisson bouge…" : "Oh !").font(.ui(12.5)).foregroundStyle(Theme.text3)
        case .pick:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    RefugeBerry(size: 14)
                    Text("Cueillies : \(picked.count) sur \(RefugeFigure.berries.count)").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                }
                HStack(spacing: 10) {
                    Text("Clique sur les myrtilles du buisson").font(.ui(12)).foregroundStyle(Theme.text3)
                    Button("Tout cueillir") {
                        picked = Set(0..<RefugeFigure.berries.count)
                        advanceAfterPicking()
                    }
                    .buttonStyle(SoftButtonStyle(small: true))
                }
            }
        case .name:
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    if Snapshot.isActive {
                        Text(name).font(.serif(18)).foregroundStyle(Theme.text)
                            .frame(width: 220, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: Theme.r(9)).fill(Theme.bg))
                            .overlay(RoundedRectangle(cornerRadius: Theme.r(9)).strokeBorder(Theme.borderStrong, lineWidth: max(1, Theme.line)))
                    } else {
                        TextField("Son prénom", text: $name)
                            .textFieldStyle(.plain)
                            .font(.serif(18))
                            .foregroundStyle(Theme.text)
                            .frame(width: 220)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: Theme.r(9)).fill(Theme.bg))
                            .overlay(RoundedRectangle(cornerRadius: Theme.r(9)).strokeBorder(Theme.borderStrong, lineWidth: max(1, Theme.line)))
                            .onSubmit(adopt)
                    }
                    Button("Bienvenue, \(RefugeRules.cleanName(name)) !", action: adopt)
                        .buttonStyle(SoftButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
                Text("Tu pourras changer son prénom quand tu veux, dans le Refuge.").font(.ui(11)).foregroundStyle(Theme.text3)
            }
        case .feed:
            HStack(spacing: 10) {
                Button("Lui donner les \(RefugeRules.welcomeGift) myrtilles") { eaten = 1 }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(eaten > 0)
                Button("Plus tard") { m.finishBirth() }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(eaten > 0)
            }
        case .fed:
            Button("À tout de suite") {
                m.finishBirth()
                if m.previewCeremony == nil { app.page = .refuge }
            }
            .buttonStyle(SoftButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
        case .decline:
            VStack(spacing: 10) {
                Text("Ce n'est pas définitif : il retourne dans son buisson et t'attendra au Refuge, rangé dans « Autres outils ». Tu pourras l'adopter quand tu veux, aussi depuis le lanceur (« adopter chamois »).")
                    .font(.ui(12)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Finalement, je m'occupe de lui") { step = before }
                        .buttonStyle(SoftButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                    Button("Non, merci") { m.decline() }
                        .buttonStyle(SoftButtonStyle())
                }
            }
        }
    }

    private func adopt() {
        app.refuge.adopt(name: name)
        step = .feed
    }

    /// The intro plays once; then a slow beat for its blinks, its tear, and its first meal.
    private func play() async {
        guard !Snapshot.isActive else { return }
        if step == .intro {
            while tick < Self.introLength, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                tick += 1
            }
            if step == .intro, !Task.isCancelled { step = .pick }
            return
        }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 220_000_000)
            slow += 1
            if step == .feed, eaten > 0 {
                if eaten < RefugeRules.welcomeGift {
                    if slow % 2 == 0 { eaten += 1 }
                } else {
                    // A replay of the birth (the Labo) changes nothing.
                    if app.refuge.previewCeremony == nil { app.refuge.feed(RefugeRules.welcomeGift) }
                    step = .fed
                }
            }
        }
    }
}
