import SwiftUI
import AppKit

/// Réglages › Apparence: the five built-in themes, the user's own ones, and an editor for every setting of a theme.
/// Drawn with the app's own components, so the pane itself previews the theme.
struct AppearanceSettings: View {
    static let width: CGFloat = 760

    @State private var importFailed = false
    private var store: ThemeStore { .shared }

    var body: some View {
        ScrollArea {
            VStack(alignment: .leading, spacing: 16) {
                header
                SectionLabel(text: "Thèmes de base")
                grid(ThemeSpec.builtIns, addCard: false)
                SectionLabel(text: "Mes thèmes")
                grid(store.customs, addCard: true)
                if store.active.isBuiltIn {
                    customizeHint
                } else {
                    ThemeEditor()
                        .id(store.active.id)
                }
            }
            .padding(24)
        }
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Thème").font(.serif(24)).foregroundStyle(Theme.text)
                Text("Les couleurs, les polices et les formes de toute l'app. Le changement est immédiat.")
                    .font(.ui(12.5)).foregroundStyle(Theme.text2)
                if importFailed {
                    Text("Le presse-papiers ne contient pas de thème : copie d'abord un thème en JSON.")
                        .font(.ui(11.5)).foregroundStyle(Theme.warn)
                }
            }
            Spacer(minLength: 8)
            Button("Coller un thème") {
                importFailed = !store.importJSON(NSPasteboard.general.string(forType: .string) ?? "")
            }
            .buttonStyle(SoftButtonStyle(small: true))
            .help("Ajoute un thème copié en JSON (par toi ou par quelqu'un d'autre)")
        }
    }

    private func grid(_ specs: [ThemeSpec], addCard: Bool) -> some View {
        let cells: [ThemeSpec?] = specs.map { $0 } + (addCard ? [nil] : [])
        let rows = stride(from: 0, to: cells.count, by: 3).map { Array(cells[$0..<min($0 + 3, cells.count)]) }
        return VStack(spacing: 12) {
            ForEach(rows.indices, id: \.self) { i in
                TileRow(spacing: 12) {
                    ForEach(0..<3, id: \.self) { j in
                        if j < rows[i].count {
                            if let spec = rows[i][j] {
                                ThemeCard(spec: spec, selected: spec.id == store.active.id) { store.select(spec.id) }
                            } else {
                                NewThemeCard { store.duplicate(store.active) }
                            }
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private var customizeHint: some View {
        Card {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Envie de retoucher « \(store.active.displayName) » ?").font(.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                    Text("Les thèmes de base restent tels quels. Crée ta version pour régler chaque couleur, les polices, la taille du texte, les angles, les bordures, les ombres, les icônes et les ornements.")
                        .font(.ui(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Créer mon thème") { store.duplicate(store.active) }
                    .buttonStyle(SoftButtonStyle(prominent: true))
            }
        }
    }
}

// MARK: - Gallery

/// A theme in the gallery: its miniature, its name and what it is like.
struct ThemeCard: View {
    var spec: ThemeSpec
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ThemeThumbnail(spec: spec).frame(height: 96)
                HStack(spacing: 6) {
                    Text(spec.displayName).font(.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 4)
                    if selected {
                        Tag(text: "Actif", symbol: "checkmark", tint: Theme.accent, filled: true)
                    } else {
                        Text(appearanceLabel).font(.ui(10.5)).foregroundStyle(Theme.text3)
                    }
                }
                Text(spec.summary.isEmpty ? "Thème personnalisé." : spec.summary)
                    .font(.ui(11)).foregroundStyle(Theme.text3)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous)
                .strokeBorder(selected ? Theme.accent : (hovering ? Theme.borderStrong : Theme.border), lineWidth: selected ? 2 : max(1, Theme.line)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var appearanceLabel: String {
        switch spec.appearance {
        case .system: return "Clair et sombre"
        case .light: return "Clair"
        case .dark: return "Sombre"
        }
    }
}

/// The last cell of "Mes thèmes": a copy of the active theme to start from.
struct NewThemeCard: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.ui(18, .light)).foregroundStyle(hovering ? Theme.accent : Theme.text3)
                Text("Nouveau thème").font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                Text("À partir de « \(ThemeStore.shared.active.displayName) »").font(.ui(11)).foregroundStyle(Theme.text3)
            }
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).fill(hovering ? Theme.hover.opacity(0.5) : .clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous)
                .strokeBorder(hovering ? Theme.accent : Theme.borderStrong, style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A miniature of the app drawn with a theme's own colors, fonts and corners (whatever the active theme is).
struct ThemeThumbnail: View {
    var spec: ThemeSpec
    /// Forces a palette; by default the one macOS would show.
    var variant: ThemeVariant? = nil
    @Environment(\.colorScheme) private var scheme

    private static let bars: [CGFloat] = [16, 26, 11, 21, 14]

    var body: some View {
        let v = variant ?? (spec.appearance == .system ? (scheme == .dark ? .dark : .light) : (spec.appearance == .dark ? .dark : .light))
        let p = spec.palette(v)
        let r = CGFloat(spec.radius)
        let line = CGFloat(spec.borderWidth)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    HStack(spacing: 4) {
                        if spec.icons != .hidden {
                            RoundedRectangle(cornerRadius: 1.5 * r).fill(p[.text2].color.opacity(0.7)).frame(width: 5, height: 5)
                        }
                        RoundedRectangle(cornerRadius: 1.5 * r).fill(p[i == 1 ? .text : .text3].color).frame(width: [22, 18, 26, 15, 20][i], height: 3)
                    }
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, minHeight: 10, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 3 * r).fill(i == 1 ? p[.selected].color : .clear))
                }
            }
            .padding(5)
            .frame(width: 52)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(p[.sidebar].color)
            Rectangle().fill(p[.border].color).frame(width: max(0.5, line))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text("Aa")
                        .font(.system(size: 18, weight: spec.titleWeight.weight, design: spec.titleFont.design))
                        .foregroundStyle(p[.text].color)
                    Text("Bonjour")
                        .font(.system(size: 9, design: spec.bodyFont.design))
                        .foregroundStyle(p[.text2].color)
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        ForEach([ThemeColorKey.good, .warn, .bad], id: \.self) { k in
                            RoundedRectangle(cornerRadius: 3 * r).fill(p[k].color).frame(width: 5, height: 5)
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5 * r).fill(p.chart[i].color).frame(width: 7, height: Self.bars[i])
                    }
                    Spacer(minLength: 4)
                    Text("OK")
                        .font(.system(size: 8, weight: .semibold, design: spec.bodyFont.design))
                        .foregroundStyle(p[.onAccent].color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4 * r).fill(p[.accent].color))
                }
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 7 * r).fill(p[.card].color)
                        .shadow(color: .black.opacity(spec.elevation == .raised ? 0.12 : 0), radius: 4, y: 1.5)
                )
                .overlay(RoundedRectangle(cornerRadius: 7 * r).strokeBorder(p[.border].color, lineWidth: line))
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(p[.bg].color)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - Editor

/// Every setting of the active custom theme. Each change applies at once to the whole app.
struct ThemeEditor: View {
    @State private var variant: ThemeVariant?
    @State private var confirmDelete = false
    @Environment(\.colorScheme) private var scheme

    private var store: ThemeStore { .shared }
    private var spec: ThemeSpec { store.active }

    /// The palette being edited: the only one of a light or dark theme, the chosen one otherwise.
    private var editing: ThemeVariant {
        switch spec.appearance {
        case .light: return .light
        case .dark: return .dark
        case .system: return variant ?? (scheme == .dark ? .dark : .light)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Personnaliser « \(spec.displayName) »")
            identity
            colors
            typography
            shapes
            ornaments
        }
        .confirmAction("Supprimer « \(spec.displayName) » ?", message: "Il disparaît de tes thèmes et Atelier reprend sa place. Pense à le copier en JSON si tu veux le garder.",
                       button: "Supprimer", isPresented: $confirmDelete) {
            store.delete(spec.id)
        }
    }

    // MARK: Sections

    private var identity: some View {
        Panel(title: "Nom et mode", subtitle: "Un thème peut suivre macOS ou rester toujours clair ou toujours sombre.", symbol: "character.cursor.ibeam") {
            VStack(alignment: .leading, spacing: 12) {
                row("Nom") {
                    ThemeTextField(text: binding(\.name), placeholder: "Nom du thème").frame(maxWidth: 260)
                }
                row("Mode") {
                    PillPicker(options: ThemeAppearance.allCases, selection: binding(\.appearance), label: \.title)
                }
                HStack(spacing: 8) {
                    Button("Copier en JSON") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.exportJSON(spec), forType: .string)
                        HUD.show("Thème copié")
                    }
                    .help("Pour le sauvegarder ou le partager : « Coller un thème » le recrée")
                    Button("Dupliquer") { store.duplicate(spec) }
                    Spacer()
                    Button("Supprimer…") { confirmDelete = true }
                        .buttonStyle(SoftButtonStyle(destructive: true, small: true))
                }
                .buttonStyle(SoftButtonStyle(small: true))
            }
        }
    }

    private var colors: some View {
        Panel(title: "Couleurs", subtitle: "Choisis le fond, le texte et l'accent, puis harmonise : l'app calcule les autres nuances. Tout reste retouchable une par une.", symbol: "paintpalette") {
            VStack(alignment: .leading, spacing: 12) {
                if spec.appearance == .system {
                    HStack(spacing: 10) {
                        PillPicker(options: ThemeVariant.allCases, selection: Binding(get: { editing }, set: { variant = $0 }), label: \.title)
                        Text(editing == (scheme == .dark ? .dark : .light) ? "C'est celle que macOS affiche en ce moment." : "macOS l'affichera en mode \(editing == .dark ? "sombre" : "clair").")
                            .font(.ui(11.5)).foregroundStyle(Theme.text3)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    ThemeThumbnail(spec: spec, variant: editing).frame(width: 230, height: 120)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Aperçu de la \(editing.title.lowercased())").font(.ui(12, .semibold)).foregroundStyle(Theme.text)
                        Text("« Harmoniser » recalcule les surfaces, les bordures, les textes secondaires, le texte sur l'accent et le motif à partir du fond, du texte et de l'accent.")
                            .font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        Button("Harmoniser les nuances") {
                            store.edit { s in
                                if editing == .light { s.light.harmonize(dark: false) } else { s.dark.harmonize(dark: true) }
                            }
                        }
                        .buttonStyle(SoftButtonStyle(small: true))
                    }
                }
                ForEach(ThemeColorKey.groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title).font(.ui(11.5, .semibold)).foregroundStyle(Theme.text3)
                        let pairs = stride(from: 0, to: group.keys.count, by: 2).map { Array(group.keys[$0..<min($0 + 2, group.keys.count)]) }
                        ForEach(pairs, id: \.first) { pair in
                            HStack(spacing: 18) {
                                ForEach(pair) { key in
                                    ThemeColorRow(title: key.title, color: palette[key]) { c in setColor(key, c) }
                                }
                                if pair.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Graphiques").font(.ui(11.5, .semibold)).foregroundStyle(Theme.text3)
                    HStack(spacing: 8) {
                        ForEach(0..<ThemePalette.chartCount, id: \.self) { i in
                            ThemeColorWell(color: palette.chart[i]) { c in setChart(i, c) }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var typography: some View {
        Panel(title: "Typographie", symbol: "textformat") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bonjour, \(Fmt.firstName)").font(.serif(24)).foregroundStyle(Theme.text)
                    Text("Le texte courant de l'app ressemble à ceci : 12,4 Go à récupérer sans risque.")
                        .font(.ui(12.5)).foregroundStyle(Theme.text2)
                }
                .padding(.bottom, 2)
                row("Titres") { PillPicker(options: ThemeFontDesign.allCases, selection: binding(\.titleFont), label: \.title) }
                row("Graisse des titres") { PillPicker(options: ThemeTitleWeight.allCases, selection: binding(\.titleWeight), label: \.title) }
                row("Texte") { PillPicker(options: ThemeFontDesign.allCases, selection: binding(\.bodyFont), label: \.title) }
                row("Taille du texte") {
                    ThemeSlider(value: binding(\.textScale), range: ThemeSpec.textScaleRange, step: 0.05) { Fmt.pct($0) }
                }
            }
        }
    }

    private var shapes: some View {
        Panel(title: "Formes", symbol: "square.on.circle") {
            VStack(alignment: .leading, spacing: 12) {
                row("Arrondi des angles") {
                    ThemeSlider(value: binding(\.radius), range: ThemeSpec.radiusRange, step: 0.1) { $0 == 0 ? "Angles droits" : Fmt.pct($0) }
                }
                row("Bordures") {
                    ThemeSlider(value: binding(\.borderWidth), range: ThemeSpec.borderRange, step: 0.5) { $0 == 0 ? "Aucune" : "\(Fmt.dec($0)) pt" }
                }
                row("Ombres") { PillPicker(options: ThemeElevation.allCases, selection: binding(\.elevation), label: \.title) }
            }
        }
    }

    private var ornaments: some View {
        Panel(title: "Icônes et ornements", symbol: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                row("Icônes décoratives") { PillPicker(options: ThemeIconStyle.allCases, selection: binding(\.icons), label: \.title) }
                Toggle(isOn: binding(\.backdrop)) {
                    label("Poussière derrière les titres", "Quelques grains de poussière et de petits éclats, en haut des pages.")
                }
                .switchToggles()
                Toggle(isOn: binding(\.mascot)) {
                    label("Mascotte", "Le petit chamois : au repos, sa tête à côté du nom de l'app, et au travail pendant les analyses.")
                }
                .switchToggles()
            }
        }
    }

    // MARK: Helpers

    private var palette: ThemePalette { spec.palette(editing) }

    private func setColor(_ key: ThemeColorKey, _ c: ThemeColor) {
        let v = editing
        store.edit { s in if v == .light { s.light[key] = c } else { s.dark[key] = c } }
    }

    private func setChart(_ i: Int, _ c: ThemeColor) {
        let v = editing
        store.edit { s in if v == .light { s.light.chart[i] = c } else { s.dark.chart[i] = c } }
    }

    private func binding<T>(_ kp: WritableKeyPath<ThemeSpec, T>) -> Binding<T> {
        Binding(get: { ThemeStore.shared.active[keyPath: kp] },
                set: { v in ThemeStore.shared.edit { $0[keyPath: kp] = v } })
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.ui(12.5)).foregroundStyle(Theme.text2).frame(width: 150, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func label(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.ui(12.5)).foregroundStyle(Theme.text)
            Text(detail).font(.ui(11)).foregroundStyle(Theme.text3)
        }
    }
}

// MARK: - Controls

/// A color: the swatch (macOS color picker) and its hexadecimal code, editable.
struct ThemeColorRow: View {
    var title: String
    var color: ThemeColor
    var onChange: (ThemeColor) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ThemeColorWell(color: color, onChange: onChange)
            Text(title).font(.ui(12)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 6)
            ThemeHexField(color: color, onChange: onChange)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The macOS color well, or a drawn swatch in snapshots (AppKit controls come out as yellow boxes there).
struct ThemeColorWell: View {
    var color: ThemeColor
    var onChange: (ThemeColor) -> Void

    var body: some View {
        if Snapshot.isActive {
            RoundedRectangle(cornerRadius: Theme.r(5), style: .continuous)
                .fill(color.color)
                .overlay(RoundedRectangle(cornerRadius: Theme.r(5), style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: 1))
                .frame(width: 34, height: 22)
        } else {
            ColorPicker("", selection: Binding(get: { color.color }, set: { c in
                if let t = ThemeColor(c), t != color { onChange(t) }
            }), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 38, height: 22)
        }
    }
}

/// "#RRGGBB", applied as soon as six digits are typed (three with ⏎).
struct ThemeHexField: View {
    var color: ThemeColor
    var onChange: (ThemeColor) -> Void
    @State private var text = ""

    var body: some View {
        Group {
            if Snapshot.isActive {
                Text(color.string)
            } else {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .onSubmit(commit)
                    .onAppear { text = color.string }
                    .onChange(of: color) { _, c in if ThemeColor(string: text) != c { text = c.string } }
                    .onChange(of: text) { _, t in
                        let digits = t.filter(\.isHexDigit)
                        if digits.count == 6, let c = ThemeColor(string: t), c != color { onChange(c) }
                    }
            }
        }
        .font(.mono(11))
        .foregroundStyle(Theme.text2)
        .frame(width: 66, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: Theme.r(5)).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(5)).strokeBorder(Theme.border, lineWidth: max(1, Theme.line)))
    }

    private func commit() {
        if let c = ThemeColor(string: text) { onChange(c); text = c.string } else { text = color.string }
    }
}

/// A one-line text field in the app's style (just its text in snapshots).
struct ThemeTextField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        Group {
            if Snapshot.isActive {
                Text(text).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text).textFieldStyle(.plain)
            }
        }
        .font(.ui(12.5))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(8)).strokeBorder(Theme.border, lineWidth: max(1, Theme.line)))
    }
}

/// A drawn slider: the value follows the drag and is applied when the mouse is released
/// (redrawing the whole app at every pixel of a drag would be wasteful).
struct ThemeSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String
    @State private var dragged: Double?

    var body: some View {
        let v = dragged ?? value
        let span = range.upperBound - range.lowerBound
        let f = span > 0 ? (v - range.lowerBound) / span : 0
        HStack(spacing: 12) {
            GeometryReader { g in
                let knob: CGFloat = 14
                let x = (g.size.width - knob) * f
                ZStack(alignment: .leading) {
                    PillShape().fill(Theme.track).frame(height: 4)
                    PillShape().fill(Theme.accent).frame(width: x + knob / 2, height: 4)
                    PillShape(scale: max(0.3, Theme.current.radiusScale))
                        .fill(Theme.cardRaised)
                        .overlay(PillShape(scale: max(0.3, Theme.current.radiusScale)).strokeBorder(Theme.borderStrong, lineWidth: 1))
                        .frame(width: knob, height: knob)
                        .themedShadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                        .offset(x: x)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { d in dragged = snap(Double((d.location.x - knob / 2) / max(1, g.size.width - knob)), span: span) }
                    .onEnded { _ in
                        if let d = dragged { value = d }
                        dragged = nil
                    })
            }
            .frame(width: 220, height: 18)
            Text(format(v)).font(.ui(12, .medium)).foregroundStyle(Theme.text).monospacedDigit().frame(minWidth: 90, alignment: .leading)
        }
    }

    private func snap(_ fraction: Double, span: Double) -> Double {
        let raw = range.lowerBound + min(1, max(0, fraction)) * span
        let stepped = (raw / step).rounded() * step
        return min(range.upperBound, max(range.lowerBound, stepped))
    }
}
