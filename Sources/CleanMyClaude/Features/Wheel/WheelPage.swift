import SwiftUI
import AppKit

/// Le Convertisseur: the wheel of each kind of file and when it opens. Everything else happens around the files
/// themselves (the wheel, its small windows, the Convertisseur's window).
struct WheelPage: View {
    @Environment(AppModel.self) private var app

    static let tip = HelpTip(
        id: "wheel.page", title: "La roue du Convertisseur",
        text: "Pas besoin d'ouvrir l'app : tout part d'un fichier que tu glisses.",
        steps: ["Glisse un fichier, depuis le Finder ou une autre app : la roue s'ouvre sous ton pointeur.",
                "Lâche-le sur une action : la copie apparaît à côté de l'original, qui ne change pas.",
                "Lâche-le au centre : toutes les opérations, avec leurs réglages et un aperçu.",
                "Éloigne-toi de la roue pour simplement déplacer ton fichier."])

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHero(symbol: Page.wheel.symbol, title: Page.wheel.title, subtitle: "Glisse un fichier : sa roue s'ouvre sous ton pointeur.",
                     tint: Theme.brand, seed: 53, tip: Self.tip) {
                WheelDestinationMenu()
            }
            HStack(alignment: .top, spacing: 14) {
                WheelDesigner()
                WheelGesturesPanel()
                    .frame(width: 320)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Where the copies go, as a small menu: « Copies : À côté de l'original ▾ ».
struct WheelDestinationMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.wheel
        HStack(spacing: 5) {
            if Theme.icons != .hidden {
                Image(systemName: m.destinationSymbol).font(.ui(11.5, .medium)).foregroundStyle(Theme.text3)
            }
            Text("Copies").font(.ui(11.5)).foregroundStyle(Theme.text3)
            BorderlessMenu {
                Button("À côté de l'original") { m.setDestination(.beside) }
                Button("Dans Téléchargements") { m.setDestination(.downloads) }
                Button("Dans un dossier choisi…") { m.chooseFolder() }
                if m.settings.destination != .beside {
                    Divider()
                    Button("Ouvrir ce dossier") {
                        if let folder = m.copiesFolder { NSWorkspace.shared.open(folder) }
                    }
                }
            } label: {
                Text(m.destinationTitle).font(.ui(11.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
            }
        }
        .help("Où vont les copies")
    }
}

// MARK: - The wheel of each kind of file

/// The wheel of a kind of file, live (point at a segment to read what it does), and what sits on its two rings.
struct WheelDesigner: View {
    @Environment(AppModel.self) private var app
    @State private var preview = WheelOverlayState()
    /// The pill clicked in a ring: moved or taken off with the buttons of that ring.
    @State private var picked: WheelAction?

    static let scale: CGFloat = 0.8

    var body: some View {
        let m = app.wheel
        let family = m.family
        let file = WheelModel.sample(family)
        let menu = m.menu(for: [file])
        let chosen = m.actions(for: family)
        let pool = family.pool
        Panel(title: "Ta roue", symbol: "dial.medium", tint: Theme.brand) {
            Button("Rétablir") {
                m.resetLayout(family)
                picked = nil
            }
            .buttonStyle(SoftButtonStyle(small: true))
            .disabled(m.settings.layouts[family.rawValue] == nil)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                WheelChips(options: WheelFamily.allCases.filter { $0 != .folder }, selection: Binding(get: { m.family }, set: { m.family = $0; picked = nil }),
                           label: \.title, symbol: { $0.symbol })
                HStack(alignment: .top, spacing: 18) {
                    wheel
                    VStack(alignment: .leading, spacing: 16) {
                        WheelRingEditor(title: "Anneau intérieur", limit: WheelMenu.maxFormats, family: family,
                                        chosen: chosen.filter(\.isFormat), aside: pool.filter { $0.isFormat && !chosen.contains($0) },
                                        picked: $picked)
                        WheelRingEditor(title: "Anneau extérieur", limit: WheelMenu.maxTools, family: family,
                                        chosen: chosen.filter { !$0.isFormat }, aside: pool.filter { !$0.isFormat && !chosen.contains($0) },
                                        picked: $picked)
                        about(preview.action(at: preview.hovered) ?? picked)
                    }
                }
            }
        }
        .onAppear { refresh(menu, file) }
        .onChange(of: menu) { _, new in refresh(new, file) }
    }

    private var wheel: some View {
        let s = WheelGeometry.side * Self.scale
        return ZStack {
            WheelWallpaper()
            WheelView(state: preview, inWindow: true)
                .scaleEffect(Self.scale)
                .frame(width: s, height: s)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let hit = preview.geometry.hit(CGPoint(x: (p.x - s / 2) / Self.scale, y: (p.y - s / 2) / Self.scale))
                        if preview.hovered != hit { preview.hovered = hit }
                    case .ended:
                        preview.hovered = nil
                    }
                }
        }
        .frame(width: s + 16, height: s + 16)
        .clipShape(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous))
        // A clip only cuts the drawing: without this, what overflows the frame still takes the clicks around it.
        .contentShape(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous))
    }

    /// What the action pointed at (or picked) does, in one line.
    private func about(_ a: WheelAction?) -> some View {
        Group {
            if let a {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(a.title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                        if a.opensWindow { Image(systemName: "macwindow").font(.ui(10)).foregroundStyle(Theme.text3).help("Ouvre une petite fenêtre") }
                        if a.needsFFmpeg && !app.wheel.capabilities.ffmpeg { Tag(text: "demande ffmpeg", tint: Theme.text3) }
                    }
                    Text(a.detail).font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Le centre de la roue ouvre toutes les opérations.").font(.ui(11.5)).foregroundStyle(Theme.text3)
            }
        }
        .frame(minHeight: 40, alignment: .topLeading)
    }

    private func refresh(_ menu: WheelMenu, _ file: WheelFile) {
        preview.files = [file]
        preview.menu = menu
        preview.shown = true
        if Snapshot.isActive && preview.hovered == nil && !menu.tools.isEmpty { preview.hovered = .tool(0) }
    }
}

/// A desktop of colors behind the settings' wheel, so that its glass shows.
struct WheelWallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.brand.opacity(0.75), Theme.accent.opacity(0.55), Theme.palette[5].opacity(0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Theme.palette[2].opacity(0.55)).frame(width: 260).blur(radius: 60).offset(x: -170, y: -90)
            Circle().fill(Theme.palette[4].opacity(0.5)).frame(width: 220).blur(radius: 60).offset(x: 190, y: 110)
        }
        // Its blurred circles reach past the frame (over the kinds of file above it): they are only a picture.
        .allowsHitTesting(false)
    }
}

/// One ring of a family's wheel: its actions in their order (click one to move it or take it off), and « Ajouter ».
struct WheelRingEditor: View {
    @Environment(AppModel.self) private var app
    var title: String
    var limit: Int
    var family: WheelFamily
    var chosen: [WheelAction]
    var aside: [WheelAction]
    @Binding var picked: WheelAction?

    var body: some View {
        let m = app.wheel
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title.uppercased()).font(.ui(10.5, .semibold)).tracking(0.8).foregroundStyle(Theme.text3)
                Text("\(min(chosen.count, limit))/\(limit)").font(.ui(10.5).monospacedDigit()).foregroundStyle(Theme.text3)
                Spacer(minLength: 4)
                if let p = picked, let i = chosen.firstIndex(of: p) {
                    WheelIconButton(symbol: "chevron.left", help: "Plus tôt sur la roue") { m.move(p, in: family, by: -1) }
                        .disabled(i == 0).opacity(i == 0 ? 0.35 : 1)
                    WheelIconButton(symbol: "chevron.right", help: "Plus tard sur la roue") { m.move(p, in: family, by: 1) }
                        .disabled(i == chosen.count - 1).opacity(i == chosen.count - 1 ? 0.35 : 1)
                    WheelIconButton(symbol: "minus", help: "Retirer de la roue") {
                        m.toggle(p, in: family)
                        picked = nil
                    }
                }
            }
            .frame(height: 24)
            GlassGroup(selection: picked, axis: .horizontal, radius: 7) {
            FlowLayout(spacing: 5, lineSpacing: 5) {
                ForEach(Array(chosen.enumerated()), id: \.element) { i, a in
                    pill(a, overflow: i >= limit).glassItem(a)
                }
                if !aside.isEmpty {
                    BorderlessMenu(indicator: false) {
                        ForEach(aside) { a in
                            Button(a.title + (a.needsFFmpeg && !m.capabilities.ffmpeg ? " (demande ffmpeg)" : "")) { m.toggle(a, in: family) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.ui(10, .semibold))
                            Text("Ajouter").font(.ui(11.5, .medium))
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .help("Mettre une autre action sur la roue")
                }
            }
            }
        }
    }

    private func pill(_ a: WheelAction, overflow: Bool) -> some View {
        let on = picked == a
        return Button { picked = on ? nil : a } label: {
            HStack(spacing: 4) {
                if Theme.icons != .hidden { Image(systemName: a.symbol).font(.ui(10, .semibold)) }
                Text(a.title).font(.ui(11.5, .medium)).lineLimit(1)
            }
            .foregroundStyle(on ? Theme.text : Theme.text2)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .chipGround(on)
            .contentShape(Rectangle())
            .opacity(overflow ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .help(overflow ? "Plus de place sur la roue : remonte-la ou retire une autre action" : a.detail)
    }
}

// MARK: - When it opens

struct WheelGesturesPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.wheel
        let instant = m.settings.instant
        Panel(title: "Quand elle s'ouvre", symbol: "hand.draw", tint: Theme.brand) {
            VStack(alignment: .leading, spacing: 12) {
                WheelChips(options: [true, false], selection: Binding(get: { m.settings.instant }, set: { m.settings.instant = $0 }),
                           label: { $0 ? "Dès que le fichier bouge" : "Avec un geste" })
                if !instant {
                    Toggle(isOn: Binding(get: { m.settings.hold }, set: { m.settings.hold = $0 })) { label("Maintenir puis glisser") }
                    if m.settings.hold {
                        row("Pause") {
                            WheelChips(options: [0.3, 0.45, 0.7], selection: Binding(get: { m.settings.holdDelay }, set: { m.settings.holdDelay = $0 }),
                                       label: { String(format: "%g s", $0).replacingOccurrences(of: ".", with: ",") })
                        }
                    }
                }
                row("Disparaît à") {
                    WheelChips(options: [2.0, 3.5, 5.0], selection: Binding(get: { m.settings.leaveDistance }, set: { m.settings.leaveDistance = $0 }),
                               label: { "\(String(format: "%g", $0).replacingOccurrences(of: ".", with: ",")) cm" })
                }
                Toggle(isOn: Binding(get: { m.settings.shake }, set: { m.settings.shake = $0 })) {
                    label(instant ? "Revenir en secouant le fichier" : "Secouer le fichier")
                }
                Toggle(isOn: Binding(get: { m.settings.shift }, set: { m.settings.shift = $0 })) {
                    label(instant ? "Revenir avec ⇧" : "Glisser avec ⇧")
                }
                Divider().overlay(Theme.border)
                VStack(alignment: .leading, spacing: 6) {
                    label("Raccourci : la sélection du Finder")
                    ShortcutRecorder(combo: m.combo) { m.setCombo($0) }
                }
            }
            .switchToggles()
            .disabled(!m.settings.enabled)
            .opacity(m.settings.enabled ? 1 : 0.55)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.ui(12, .medium)).foregroundStyle(Theme.text2)
            Spacer(minLength: 4)
            content()
        }
    }
}

// MARK: - Bottom bar

struct WheelBottomBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.wheel
        let running = m.runner.running
        ActionBar {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.isActive ? "Roue active" : "Roue en pause").font(.serif(17)).foregroundStyle(Theme.text)
                Text(running > 0 ? Fmt.plural(running, "action en cours", "actions en cours")
                     : (m.isActive ? (m.settings.instant ? "Elle s'ouvre dès que tu glisses un fichier" : "Glisse un fichier avec un geste pour l'ouvrir")
                        : "Les fichiers que tu glisses ne l'ouvrent plus"))
                    .font(.ui(11)).foregroundStyle(Theme.text3)
            }
            Spacer()
            Button("Créer un QR code") { app.converter.present(focus: .qrGenerate) }
                .buttonStyle(SoftButtonStyle())
            Button("Choisir des fichiers…") { choose() }
                .buttonStyle(SoftButtonStyle())
            Button(m.settings.enabled ? "Mettre en pause" : "Activer") { m.setEnabled(!m.settings.enabled) }
                .buttonStyle(SoftButtonStyle(prominent: !m.settings.enabled))
        }
    }

    /// The Convertisseur's window without dragging anything.
    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Choisir"
        if panel.runModal() == .OK, !panel.urls.isEmpty { app.converter.present(panel.urls) }
    }
}
