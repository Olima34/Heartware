import SwiftUI

/// Its birth, a mue or its path, in the middle of the window: the window darkens behind it.
/// Shown only on the dashboard or the Refuge, never in the middle of a task, never in sober mode.
struct RefugeCeremonyModal: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            // The only fixed color: a veil that darkens whatever theme is behind it.
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture {
                    // The birth waits for an answer; a mue or a path can be closed by clicking beside it.
                    if let c = app.refuge.ceremony, c != .birth { app.refuge.acknowledge() }
                }
            if app.refuge.ceremony != nil {
                RefugeCeremonyPanel()
                    .themedShadow(color: .black.opacity(0.35), radius: 30, y: 12)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
    }
}

/// The card of the ceremony waiting (its birth by default).
struct RefugeCeremonyPanel: View {
    static let width: CGFloat = 580
    @Environment(AppModel.self) private var app
    var framed = true

    var body: some View {
        let content = Group {
            switch app.refuge.ceremony ?? .birth {
            case .birth: RefugeBirthPanel()
            case .mue(let mue): RefugeMuePanel(mue: mue)
            case .path(let path): RefugePathPanel(path: path)
            }
        }
        if framed {
            content
                .padding(26)
                .frame(width: Self.width)
                .background(RoundedRectangle(cornerRadius: Theme.r(18), style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.r(18), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
        } else {
            content.frame(maxWidth: .infinity)
        }
    }
}

/// A mue: the old stage trembles, a flash, the new one appears; or its scarf flies off and comes back in its new material.
private struct RefugeMuePanel: View {
    @Environment(AppModel.self) private var app
    var mue: RefugeRules.Mue

    /// 0: before, 1: the flash (or the scarf in the air), 2: after.
    @State private var phase = 2
    @State private var shake = false
    @State private var lift = 0

    var body: some View {
        let m = app.refuge
        VStack(spacing: 14) {
            Text(kicker.uppercased()).font(.ui(10.5, .semibold)).tracking(0.8).foregroundStyle(RefugePage.tint)
            Text(title(m.name)).font(.serif(25)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            ZStack(alignment: .topLeading) {
                figure(m)
                    .frame(width: 10 * CGFloat(RefugeFigure.cols), height: 10 * CGFloat(RefugeFigure.rows))
                if phase == 2 {
                    RefugeBubble(text: line, maxWidth: 220, tip: CGPoint(x: -38, y: 40))
                        .offset(x: 10 * CGFloat(RefugeFigure.cols) + 18, y: 6)
                }
            }
            .frame(width: 10 * CGFloat(RefugeFigure.cols) + 260, height: 10 * CGFloat(RefugeFigure.rows), alignment: .leading)
            Text(gain).font(.ui(12)).foregroundStyle(Theme.text3)
            HStack(spacing: 10) {
                Button("Trop beau !") { m.acknowledge() }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                if app.page != .refuge {
                    Button("Voir le Refuge") {
                        m.acknowledge()
                        app.page = .refuge
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            }
        }
        .task(id: mue) { await play() }
    }

    private var kicker: String {
        switch mue {
        case .stage: return "Il a mué"
        case .scarf: return "Nouvelle écharpe"
        }
    }

    private func title(_ name: String) -> String {
        switch mue {
        case .stage(let stage): return "\(name) est devenu un \(stage.title) !"
        case .scarf(let scarf): return "Une écharpe en \(scarf.title.lowercased()) pour \(name)"
        }
    }

    private var line: String {
        switch mue {
        case .stage(let stage): return stage.line
        case .scarf(let scarf): return scarf == .laine ? "De la laine sacrée… Je n'ai jamais rien porté d'aussi doux." : "Elle brille ! Regarde comme elle me va bien."
        }
    }

    private var gain: String {
        switch mue {
        case .stage(let stage): return "Il y gagne \(stage.change)."
        case .scarf(let scarf):
            guard let next = RefugeScarf(rawValue: scarf.rawValue + 1) else { return "Prochaine étape : le Chamois d'or, à 12 000 myrtilles mangées." }
            return "Prochaine écharpe : \(next.title.lowercased()), à \(Fmt.int(next.threshold)) myrtilles mangées."
        }
    }

    private func figure(_ m: RefugeModel) -> some View {
        var look = m.look()
        switch mue {
        case .stage(let stage):
            look.stage = phase == 0 ? (RefugeStage(rawValue: max(0, stage.rawValue - 1)) ?? .cabri) : stage
            if look.stage < .grand { look.scarf = nil } else if look.scarf == nil { look.scarf = .bronze }
        case .scarf(let scarf):
            look.stage = .grand
            look.scarf = phase == 0 ? RefugeScarf(rawValue: max(0, scarf.rawValue - 1)) : scarf
            look.scarfLift = lift
        }
        return ZStack {
            RefugeAvatar(look: look, pixel: 10, animated: phase == 2)
                .offset(x: phase == 0 && shake ? 3 : 0)
                .opacity(phase == 1 && { if case .stage = mue { return true } else { return false } }() ? 0.35 : 1)
            if phase == 1, case .stage = mue {
                Circle().fill(Theme.mascot.star.opacity(0.55)).frame(width: 150, height: 150).blur(radius: 24)
            }
        }
    }

    /// A few seconds, once.
    private func play() async {
        guard !Snapshot.isActive else { phase = 2; return }
        phase = 0
        switch mue {
        case .stage:
            for _ in 0..<12 where !Task.isCancelled {
                shake.toggle()
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
            withAnimation(.easeIn(duration: 0.25)) { phase = 1 }
            try? await Task.sleep(nanoseconds: 450_000_000)
        case .scarf:
            try? await Task.sleep(nanoseconds: 500_000_000)
            // The scarf flies up…
            for l in 1...8 where !Task.isCancelled {
                lift = l
                try? await Task.sleep(nanoseconds: 70_000_000)
            }
            phase = 1
            // …and comes back in its new material.
            for l in stride(from: 8, through: 0, by: -1) where !Task.isCancelled {
                lift = l
                try? await Task.sleep(nanoseconds: 70_000_000)
            }
        }
        withAnimation(.easeOut(duration: 0.35)) { phase = 2 }
    }
}

/// The path it chose at the Beau Chamois, with its accessory.
private struct RefugePathPanel: View {
    @Environment(AppModel.self) private var app
    var path: RefugePath

    var body: some View {
        let m = app.refuge
        var look = m.look()
        look.path = path
        return VStack(spacing: 14) {
            Text("SA VOIE").font(.ui(10.5, .semibold)).tracking(0.8).foregroundStyle(RefugePage.tint)
            Text("\(m.name) a trouvé sa voie : \(path.title)").font(.serif(25)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            ZStack(alignment: .topLeading) {
                RefugeAvatar(look: look, pixel: 10)
                RefugeBubble(text: path.line, maxWidth: 220, tip: CGPoint(x: -38, y: 40))
                    .offset(x: 10 * CGFloat(RefugeFigure.cols) + 18, y: 6)
            }
            .frame(width: 10 * CGFloat(RefugeFigure.cols) + 260, height: 10 * CGFloat(RefugeFigure.rows), alignment: .leading)
            Text("Avec \(path.accessory). \(path.who) Il pourra changer de voie une fois par saison.")
                .font(.ui(12)).foregroundStyle(Theme.text3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Bravo, \(m.name) !") { m.acknowledge() }
                .buttonStyle(SoftButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
        }
    }
}
