import SwiftUI

/// The Refuge: its room and its basket on top, then its life in little scenes rather than boxes of figures: the trail of
/// its daily round, the height marks of its growth, its scarves on a line, the market stall, the chalet whose windows
/// light up, its notebook, its medals, a polaroid.
struct RefugePage: View {
    @Environment(AppModel.self) private var app
    static var tint: Color { Theme.warn }

    var body: some View {
        let m = app.refuge
        VStack(alignment: .leading, spacing: 22) {
            PageHero(symbol: Page.refuge.symbol, title: m.isAdopted ? "Le Refuge de \(m.name)" : "Le Refuge",
                     subtitle: m.isAdopted
                        ? "Prends soin de ton Mac : il y cueille des myrtilles. Donne-les-lui, il grandit ; ou fais-lui plaisir à la boutique."
                        : "Un petit chamois est né dans un buisson de myrtilles.",
                     tint: Self.tint, seed: 97) {
                if m.isAdopted { Tag(text: "Jour \(m.day)", symbol: "sun.max", tint: Self.tint) }
            }
            if !m.isAdopted {
                if m.state.awaitingAdoption && !m.showsOverlay {
                    Card { RefugeCeremonyPanel(framed: false) }
                } else {
                    RefugeBushCard()
                }
            } else {
                if let ceremony = m.ceremony, ceremony != .birth, !m.playful {
                    Card { RefugeCeremonyPanel(framed: false) }
                }
                ForEach(m.events(), id: \.self) { RefugeEventRibbon(event: $0) }
                HStack(alignment: .top, spacing: 14) {
                    RefugeHomeCard()
                    VStack(spacing: 14) {
                        RefugeBasketCard()
                        RefugeMoodCard()
                    }
                    .frame(width: 330)
                }
                .fixedSize(horizontal: false, vertical: true)
                RefugeRoundTrail()
                RefugeGrowthWall()
                RefugeStall()
                HStack(alignment: .top, spacing: 22) {
                    RefugeChalet()
                    VStack(alignment: .leading, spacing: 26) {
                        RefugePolaroid()
                        RefugeBerryGuide()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                RefugeMedals()
                RefugeFooter()
            }
        }
        .onAppear {
            m.observe()
            m.ensureRound()
        }
    }
}

/// No action bar: everything happens on the page.
struct RefugeBottomBar: View {
    var body: some View { EmptyView() }
}

/// A section title in the voice of the page: a serif title and a light line, no box.
struct RefugeSectionTitle<Trailing: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.serif(21)).foregroundStyle(Theme.text)
                Text(subtitle).font(.ui(12)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension RefugeSectionTitle where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = EmptyView()
    }
}

// MARK: - Not adopted

/// Said no at its birth: it waits in its bush, two eyes showing between the leaves.
private struct RefugeBushCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.refuge
        Card(padding: 24) {
            HStack(spacing: 28) {
                Canvas { ctx, _ in
                    let p: CGFloat = 9
                    RefugeFigure.drawBush(in: ctx, at: CGPoint(x: 0, y: p * 2), pixel: p, berries: false)
                    // Its eyes and its ears, peeking out between the leaves.
                    let m = Theme.mascot
                    for (x, y, color) in [(5, 5, m.face), (6, 5, m.eye), (7, 5, m.face), (8, 5, m.face), (9, 5, m.eye), (10, 5, m.face),
                                          (6, 6, m.face), (7, 6, m.face), (8, 6, m.nose), (9, 6, m.face), (4, 4, m.fur), (11, 4, m.fur)] {
                        ctx.fill(Path(CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: p, height: p)), with: .color(color))
                    }
                }
                .frame(width: 9 * CGFloat(RefugeFigure.bushCols), height: 9 * CGFloat(RefugeFigure.bushRows + 2))
                VStack(alignment: .leading, spacing: 10) {
                    Text(m.state.declined ? "Il t'attend dans son buisson" : "Il naîtra bientôt").font(.serif(24)).foregroundStyle(Theme.text)
                    Text(m.state.declined
                         ? "Pas de souci : rien ne presse. Le jour où tu veux t'occuper de lui, il sortira de son buisson de myrtilles et tu pourras lui donner un prénom."
                         : "Il sortira de son buisson de myrtilles à la fin de l'accueil.")
                        .font(.ui(13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    if m.state.declined {
                        Button("Je veux m'occuper de lui") { m.reconsider() }
                            .buttonStyle(SoftButtonStyle(prominent: true))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - The event of the day

private struct RefugeEventRibbon: View {
    var event: RefugeEvent

    var body: some View {
        HStack(spacing: 12) {
            if Theme.icons != .hidden {
                Image(systemName: event.symbol).font(.ui(15, .semibold)).foregroundStyle(Theme.onAccent)
                    .frame(width: 30, height: 30).background(Circle().fill(RefugePage.tint))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.serif(17)).foregroundStyle(Theme.text)
                Text(event.line).font(.ui(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(PillShape().fill(RefugePage.tint.opacity(0.13)))
        .overlay(PillShape().strokeBorder(RefugePage.tint.opacity(0.35), style: StrokeStyle(lineWidth: max(1, Theme.line), dash: [5, 4])))
    }
}

// MARK: - The room and its name

private struct RefugeHomeCard: View {
    @Environment(AppModel.self) private var app
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let m = app.refuge
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                RefugeRoomView()
                    .aspectRatio(CGFloat(RefugeScene.cols) / CGFloat(RefugeScene.rows), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.r(14), topTrailingRadius: Theme.r(14), style: .continuous))
                HStack(alignment: .center, spacing: 12) {
                    if editing && !Snapshot.isActive {
                        TextField("Son prénom", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.serif(22))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(Theme.bg))
                            .overlay(RoundedRectangle(cornerRadius: Theme.r(8)).strokeBorder(Theme.borderStrong, lineWidth: max(1, Theme.line)))
                            .onSubmit(save)
                            .frame(maxWidth: 280)
                        Button("Garder", action: save).buttonStyle(SoftButtonStyle(prominent: true, small: true))
                        Button("Annuler") { editing = false }.buttonStyle(SoftButtonStyle(small: true))
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.name).font(.serif(24)).foregroundStyle(Theme.text)
                            Text("\(m.stage.title) · \(m.look().path.map { "voie \($0.title)" } ?? m.stage.change)")
                                .font(.ui(12)).foregroundStyle(Theme.text3)
                        }
                        Button {
                            draft = m.name
                            editing = true
                        } label: {
                            Label("Changer son prénom", systemImage: "pencil").labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .help("Tu peux le renommer quand tu veux")
                    }
                    Spacer()
                    Text("Clique sur lui pour une caresse").font(.ui(11)).foregroundStyle(Theme.text3)
                }
                .padding(16)
            }
        }
        .task(id: m.reaction) {
            // A reaction stays a few seconds, then it goes back to saying how it feels.
            guard m.reaction != nil else { return }
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if !Task.isCancelled { m.reaction = nil }
        }
    }

    private func save() {
        app.refuge.rename(draft)
        editing = false
    }
}

// MARK: - Its basket

/// The basket of blueberries picked by taking care of the Mac: a click gives it one, the buttons give more.
private struct RefugeBasketCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.refuge
        let s = m.state
        let p = RefugeRules.progress(s)
        let left = RefugeRules.appetiteLeft(s, now: Date())
        Card {
            HStack(alignment: .center, spacing: 14) {
                Button { m.feed(1) } label: {
                    RefugeBasketIcon(count: s.basket, pixel: 5)
                }
                .buttonStyle(.plain)
                .disabled(s.basket == 0)
                .help(s.basket == 0 ? "Le panier est vide : prends soin du Mac pour en cueillir" : (left == 0 ? "Il a bien mangé pour aujourd'hui" : "Lui donner une myrtille"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Le panier").font(.ui(12)).foregroundStyle(Theme.text2)
                    Text(Fmt.int(s.basket)).font(.serif(32)).foregroundStyle(Theme.text).contentTransition(.numericText())
                    Text(s.basket == 0 ? "Vide pour l'instant : prends soin du Mac pour en cueillir." : "myrtilles à lui donner ou à dépenser")
                        .font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button("Lui en donner \(max(1, min(10, left, s.basket)))") { m.feed(10) }
                    .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                    .disabled(s.basket == 0 || left == 0)
                Button("Tout ce qu'il peut") { m.feed(s.basket) }
                    .buttonStyle(SoftButtonStyle(small: true))
                    .disabled(s.basket == 0 || left == 0)
            }
            Text(left == 0 ? "Il a bien mangé pour aujourd'hui : il aura de nouveau faim demain." : "Il peut encore en manger \(left) aujourd'hui.")
                .font(.ui(11)).foregroundStyle(left == 0 ? Theme.good : Theme.text3)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(Fmt.int(s.eaten)) mangées").font(.ui(12, .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    if let next = p.next { Text("\(next) dans \(Fmt.int(p.left))").font(.ui(11.5)).foregroundStyle(Theme.text3) }
                }
                UsageBar(fraction: p.fraction, tint: RefugePage.tint, height: 8)
                Text(p.next == nil ? "Il a atteint le dernier stade. Bravo à vous deux !" : "Plus il mange, plus il grandit. Ce qu'il a mangé ne se perd jamais.")
                    .font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A wicker basket, its heap of blueberries growing with the count.
struct RefugeBasketIcon: View {
    var count: Int
    var pixel: CGFloat = 5

    var body: some View {
        Canvas { ctx, _ in
            let c = Theme.mascot
            func fill(_ x: Int, _ y: Int, _ color: Color) {
                ctx.fill(Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel)), with: .color(color))
            }
            // The heap: up to 3 rows of berries over the rim.
            let heap = count == 0 ? 0 : count < 10 ? 1 : count < 50 ? 2 : 3
            let rows = [(2, 9), (3, 8), (4, 7)]
            for r in 0..<heap {
                let (from, to) = rows[r]
                for x in from...to { fill(x, 4 - r, (x + r) % 3 == 0 ? c.berryShine : c.berry) }
            }
            // The handle and the wicker.
            for (x, y) in [(2, 1), (3, 0), (4, 0), (5, 0), (6, 0), (7, 0), (8, 1), (1, 2), (9, 2), (1, 3), (9, 3)] where heap < 3 || y > 1 {
                fill(x, y, c.strawShade)
            }
            for y in 5...8 {
                let inset = y == 8 ? 2 : (y == 7 ? 1 : 0)
                for x in (1 + inset)...(10 - inset) { fill(x, y, (x + y) % 2 == 0 ? c.straw : c.strawShade) }
            }
            for x in 0...11 { fill(x, 5, c.strawShade) }
        }
        .frame(width: pixel * 12, height: pixel * 9)
        .accessibilityLabel("Panier : \(count) myrtilles")
    }
}

// MARK: - Its mood

private struct RefugeMoodCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.refuge
        let look = m.scene()
        let s = m.signals()
        Card {
            HStack(spacing: 8) {
                IconBadge(symbol: symbol(look.mood), tint: RefugePage.tint)
                Text("Humeur : \(look.mood.title.lowercased())").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
            }
            VStack(alignment: .leading, spacing: 6) {
                row("Moutons de poussière", look.dust == 0 ? "aucun" : "\(look.dust)", detail: s.junk > 0 ? Fmt.bytes(s.junk) : nil, page: .cleanup)
                row("Mites", look.moths == 0 ? "aucune" : "\(look.moths)", detail: nil, page: .protection)
                row("Boost", s.boost ? "actif" : "au repos", detail: nil, page: .performance)
            }
        }
    }

    private func symbol(_ mood: RefugeMood) -> String {
        switch mood {
        case .happy: return "face.smiling"
        case .sleepy: return "moon.zzz"
        case .sneezy: return "wind"
        case .hot: return "thermometer.sun"
        case .boosted: return "bolt"
        case .worried: return "ant"
        case .hungry: return "fork.knife"
        case .sad: return "drop"
        }
    }

    private func row(_ title: String, _ value: String, detail: String?, page: Page) -> some View {
        Button { app.page = page } label: {
            HStack {
                Text(title).font(.ui(12)).foregroundStyle(Theme.text2)
                Spacer()
                if let detail { Text(detail).font(.ui(11)).foregroundStyle(Theme.text3) }
                Text(value).font(.ui(12, .semibold)).foregroundStyle(Theme.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ouvrir \(page.title)")
    }
}

// MARK: - The footer

/// What reassures, and its few switches, quietly at the bottom.
private struct RefugeFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.refuge
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Il ne lui arrive jamais rien").font(.serif(17)).foregroundStyle(Theme.text)
                    Text("Il ne tombe pas malade et ne perd rien de ce qu'il a gagné : si tu t'absentes, il fait la sieste et t'attend. Ses myrtilles, ses affaires et ses médailles restent sur ce Mac, nulle part ailleurs. Les myrtilles ne s'achètent jamais.")
                        .font(.ui(12)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    if AppEdition.isLab {
                        Button("Revoir la naissance (Labo)") { m.replayBirth() }
                            .buttonStyle(SoftButtonStyle(small: true))
                            .padding(.top, 4)
                            .help("Rejoue la naissance sans rien changer à \(m.name)")
                    }
                }
                Spacer(minLength: 10)
                VStack(alignment: .leading, spacing: 10) {
                    toggle("Compagnon de bureau", "Il se promène sur ton écran ; trois tapes sur lui pour qu'il parte, la barre des menus pour le rappeler",
                           isOn: m.state.companion) { m.setCompanion($0) }
                    toggle("Pelage des saisons", "Fauve l'été, brun sombre l'hiver", isOn: m.state.seasons) { m.setSeasons($0) }
                    toggle("Mode sobre", "Ni mue ni message : l'app sans le jeu", isOn: m.state.sober) { m.setSober($0) }
                }
                .frame(width: 330)
            }
        }
    }

    private func toggle(_ title: String, _ detail: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                Text(detail).font(.ui(11)).foregroundStyle(Theme.text3)
            }
        }
        .switchToggles()
    }
}
