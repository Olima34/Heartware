import SwiftUI
import AppKit

// MARK: - Color

/// A color of a theme, saved as "#RRGGBB".
struct ThemeColor: Hashable {
    var hex: UInt32

    init(_ hex: UInt32) { self.hex = hex & 0xFFFFFF }

    /// "#RRGGBB", "RRGGBB" or "#RGB".
    init?(string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let v = UInt32(s, radix: 16) else { return nil }
        hex = v
    }

    init(r: Double, g: Double, b: Double) {
        func byte(_ v: Double) -> UInt32 { UInt32((min(1, max(0, v)) * 255).rounded()) }
        hex = byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    /// The sRGB value of a SwiftUI color (from the color picker).
    init?(_ color: Color) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
    }

    var string: String { String(format: "#%06X", hex) }
    var color: Color { Color(hex: hex) }

    var r: Double { Double((hex >> 16) & 0xFF) / 255 }
    var g: Double { Double((hex >> 8) & 0xFF) / 255 }
    var b: Double { Double(hex & 0xFF) / 255 }

    /// Moves toward `other`: 0 keeps this color, 1 gives `other`.
    func mixed(with other: ThemeColor, _ t: Double) -> ThemeColor {
        ThemeColor(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    /// Relative luminance, as WCAG defines it.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio, from 1 (none) to 21 (black on white).
    static func contrast(_ a: ThemeColor, _ b: ThemeColor) -> Double {
        let (l1, l2) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (l1 + 0.05) / (l2 + 0.05)
    }

    static let white = ThemeColor(0xFFFFFF)
    static let ink = ThemeColor(0x111111)

    /// White or near-black, whichever reads better on this color.
    var readableInk: ThemeColor {
        ThemeColor.contrast(self, .white) >= ThemeColor.contrast(self, .ink) ? .white : .ink
    }
}

extension ThemeColor: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        guard let v = ThemeColor(string: try c.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Couleur invalide (attendu #RRGGBB)")
        }
        self = v
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(string)
    }
}

// MARK: - Palette

/// Every color a theme sets, in the order the editor shows them.
enum ThemeColorKey: String, CaseIterable, Identifiable {
    case bg, sidebar, card, cardRaised, hover, selected, track
    case border, borderStrong
    case text, text2, text3
    case accent, onAccent
    case good, warn, bad
    case brand, matrix

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bg: return "Fond"
        case .sidebar: return "Barre latérale"
        case .card: return "Cartes"
        case .cardRaised: return "Cartes en relief"
        case .hover: return "Survol"
        case .selected: return "Sélection"
        case .track: return "Rails des jauges"
        case .border: return "Bordures"
        case .borderStrong: return "Bordures marquées"
        case .text: return "Texte"
        case .text2: return "Texte secondaire"
        case .text3: return "Texte discret"
        case .accent: return "Accent"
        case .onAccent: return "Texte sur l'accent"
        case .good: return "Succès"
        case .warn: return "Attention"
        case .bad: return "Erreur"
        case .brand: return "Logo et touches"
        case .matrix: return "Motif de fond"
        }
    }

    /// The groups of the editor.
    static let groups: [(title: String, keys: [ThemeColorKey])] = [
        ("Essentiel", [.bg, .text, .accent, .onAccent]),
        ("Surfaces", [.sidebar, .card, .cardRaised, .hover, .selected, .track]),
        ("Traits et textes", [.border, .borderStrong, .text2, .text3]),
        ("Signaux et ornements", [.good, .warn, .bad, .brand, .matrix])
    ]
}

/// The colors of one appearance (light or dark) of a theme.
struct ThemePalette: Hashable {
    private var values: [ThemeColorKey: ThemeColor]
    /// The categorical colors of the charts, always ten.
    var chart: [ThemeColor] {
        didSet { chart = Self.tenColors(chart) }
    }

    static let chartCount = 10

    init(_ values: [ThemeColorKey: ThemeColor], chart: [ThemeColor]) {
        self.values = values
        self.chart = Self.tenColors(chart)
    }

    subscript(key: ThemeColorKey) -> ThemeColor {
        get { values[key] ?? ThemeColor(0xFF00FF) }
        set { values[key] = newValue }
    }

    private static func tenColors(_ list: [ThemeColor]) -> [ThemeColor] {
        guard !list.isEmpty else { return Array(repeating: ThemeColor(0x888888), count: chartCount) }
        return (0..<chartCount).map { list[$0 % list.count] }
    }

    /// Recomputes every shade from the background, the text and the accent (the three colors one picks first).
    mutating func harmonize(dark: Bool) {
        let bg = self[.bg], text = self[.text], accent = self[.accent]
        self[.sidebar] = dark ? bg.mixed(with: ThemeColor(0x000000), 0.25) : bg.mixed(with: text, 0.04)
        self[.card] = dark ? bg.mixed(with: text, 0.035) : bg.mixed(with: .white, 0.65)
        self[.cardRaised] = dark ? bg.mixed(with: text, 0.07) : bg.mixed(with: .white, 0.9)
        self[.hover] = bg.mixed(with: text, 0.07)
        self[.selected] = bg.mixed(with: text, 0.11)
        self[.track] = bg.mixed(with: text, 0.08)
        self[.border] = bg.mixed(with: text, 0.11)
        self[.borderStrong] = bg.mixed(with: text, 0.2)
        self[.text2] = text.mixed(with: bg, 0.3)
        self[.text3] = text.mixed(with: bg, 0.48)
        self[.onAccent] = accent.readableInk
        self[.matrix] = bg.mixed(with: text, 0.35)
    }
}

extension ThemePalette: Codable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Missing or broken colors (a theme pasted by hand) fall back on Graphite.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let fallback = decoder.codingPath.last?.stringValue == "dark" ? ThemeSpec.base.dark : ThemeSpec.base.light
        var values: [ThemeColorKey: ThemeColor] = [:]
        for k in ThemeColorKey.allCases {
            values[k] = (try? c.decodeIfPresent(ThemeColor.self, forKey: Key(k.rawValue))) ?? fallback[k]
        }
        let chart = (try? c.decodeIfPresent([ThemeColor].self, forKey: Key("chart"))) ?? fallback.chart
        self.init(values, chart: chart)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for k in ThemeColorKey.allCases { try c.encode(self[k], forKey: Key(k.rawValue)) }
        try c.encode(chart, forKey: Key("chart"))
    }
}

// MARK: - Options

enum ThemeAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Comme macOS"
        case .light: return "Clair"
        case .dark: return "Sombre"
        }
    }
}

/// Which of the two palettes is shown or edited.
enum ThemeVariant: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var title: String { self == .light ? "Variante claire" : "Variante sombre" }
}

enum ThemeFontDesign: String, Codable, CaseIterable, Identifiable {
    case serif, sans, rounded, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .serif: return "Serif"
        case .sans: return "Sans"
        case .rounded: return "Arrondie"
        case .mono: return "Mono"
        }
    }
    var design: Font.Design {
        switch self {
        case .serif: return .serif
        case .sans: return .default
        case .rounded: return .rounded
        case .mono: return .monospaced
        }
    }
}

enum ThemeTitleWeight: String, Codable, CaseIterable, Identifiable {
    case light, regular, medium, semibold, bold
    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: return "Fine"
        case .regular: return "Normale"
        case .medium: return "Moyenne"
        case .semibold: return "Demi-grasse"
        case .bold: return "Grasse"
        }
    }
    var weight: Font.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

/// How the decorative icons (section headers, badges, sidebar) are drawn.
enum ThemeIconStyle: String, Codable, CaseIterable, Identifiable {
    case tinted, mono, hidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tinted: return "En couleur"
        case .mono: return "Monochromes"
        case .hidden: return "Masquées"
        }
    }
}

enum ThemeElevation: String, Codable, CaseIterable, Identifiable {
    case flat, subtle, raised
    var id: String { rawValue }
    var title: String {
        switch self {
        case .flat: return "Aucune"
        case .subtle: return "Discrètes"
        case .raised: return "Marquées"
        }
    }
}

// MARK: - Theme

/// A complete look: colors for light and dark, typography, shapes and ornaments.
/// Saved as JSON for the user's own themes, so a theme can be copied and pasted.
struct ThemeSpec: Hashable, Identifiable {
    var id: String
    var name: String
    var summary: String
    var appearance: ThemeAppearance
    var light: ThemePalette
    var dark: ThemePalette
    var titleFont: ThemeFontDesign
    var titleWeight: ThemeTitleWeight
    var bodyFont: ThemeFontDesign
    /// Multiplies every text size (0.85…1.25).
    var textScale: Double
    /// Multiplies every corner radius: 0 gives square corners, 1 the original look (0…2).
    var radius: Double
    /// Width of the card and control outlines, in points (0…2).
    var borderWidth: Double
    var elevation: ThemeElevation
    var icons: ThemeIconStyle
    /// The faint columns of characters behind the page titles.
    var backdrop: Bool
    /// The pixel mascot, at rest, at work and as the brand mark.
    var mascot: Bool

    var isBuiltIn: Bool { ThemeSpec.builtIns.contains { $0.id == id } }

    func palette(_ v: ThemeVariant) -> ThemePalette { v == .light ? light : dark }

    /// The palettes this theme actually shows.
    var variants: [ThemeVariant] {
        switch appearance {
        case .system: return [.light, .dark]
        case .light: return [.light]
        case .dark: return [.dark]
        }
    }

    static let textScaleRange = 0.85...1.25
    static let radiusRange = 0.0...2.0
    static let borderRange = 0.0...2.0

    /// Keeps the numbers of a hand-edited theme within what the interface can draw.
    mutating func clamp() {
        textScale = min(Self.textScaleRange.upperBound, max(Self.textScaleRange.lowerBound, textScale))
        radius = min(Self.radiusRange.upperBound, max(Self.radiusRange.lowerBound, radius))
        borderWidth = min(Self.borderRange.upperBound, max(Self.borderRange.lowerBound, borderWidth))
    }

    /// The name to show (a field being retyped can be empty for a moment).
    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Sans nom" : n
    }
}

extension ThemeSpec: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, summary, appearance, light, dark, titleFont, titleWeight, bodyFont
        case textScale, radius, borderWidth, elevation, icons, backdrop, mascot
    }

    /// Every missing field falls back on Graphite: a theme written by hand only needs what it changes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = ThemeSpec.base
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        self.init(id: value(.id, "custom"), name: value(.name, "Thème importé"), summary: value(.summary, ""),
                  appearance: value(.appearance, base.appearance), light: value(.light, base.light), dark: value(.dark, base.dark),
                  titleFont: value(.titleFont, base.titleFont), titleWeight: value(.titleWeight, base.titleWeight),
                  bodyFont: value(.bodyFont, base.bodyFont), textScale: value(.textScale, base.textScale),
                  radius: value(.radius, base.radius), borderWidth: value(.borderWidth, base.borderWidth),
                  elevation: value(.elevation, base.elevation), icons: value(.icons, base.icons),
                  backdrop: value(.backdrop, base.backdrop), mascot: value(.mascot, base.mascot))
        clamp()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(summary, forKey: .summary)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(light, forKey: .light)
        try c.encode(dark, forKey: .dark)
        try c.encode(titleFont, forKey: .titleFont)
        try c.encode(titleWeight, forKey: .titleWeight)
        try c.encode(bodyFont, forKey: .bodyFont)
        try c.encode(textScale, forKey: .textScale)
        try c.encode(radius, forKey: .radius)
        try c.encode(borderWidth, forKey: .borderWidth)
        try c.encode(elevation, forKey: .elevation)
        try c.encode(icons, forKey: .icons)
        try c.encode(backdrop, forKey: .backdrop)
        try c.encode(mascot, forKey: .mascot)
    }
}

// MARK: - The six built-in themes

extension ThemePalette {
    fileprivate static func make(bg: UInt32, sidebar: UInt32, card: UInt32, cardRaised: UInt32, hover: UInt32,
                                 selected: UInt32, track: UInt32, border: UInt32, borderStrong: UInt32,
                                 text: UInt32, text2: UInt32, text3: UInt32, accent: UInt32, onAccent: UInt32,
                                 good: UInt32, warn: UInt32, bad: UInt32, brand: UInt32, matrix: UInt32,
                                 chart: [UInt32]) -> ThemePalette {
        let pairs: [(ThemeColorKey, UInt32)] = [
            (.bg, bg), (.sidebar, sidebar), (.card, card), (.cardRaised, cardRaised), (.hover, hover),
            (.selected, selected), (.track, track), (.border, border), (.borderStrong, borderStrong),
            (.text, text), (.text2, text2), (.text3, text3), (.accent, accent), (.onAccent, onAccent),
            (.good, good), (.warn, warn), (.bad, bad), (.brand, brand), (.matrix, matrix)
        ]
        return ThemePalette(Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, ThemeColor($0.1)) }), chart: chart.map(ThemeColor.init))
    }
}

extension ThemeSpec {
    static let builtIns: [ThemeSpec] = [graphite, graphitePur, atelier, phosphore, sorbet, minuit]
    /// The default look, and what a theme written by hand starts from.
    static let base = graphite

    /// The design system shared by all of the author's apps (Graphite · Arc × macOS 27): cold neutral greys for more than 90 %
    /// of the screen, one accent (the steel blue of the icon's mountain), depth from glass and light rather than color.
    static let graphite = ThemeSpec(
        id: "graphite", name: "Graphite",
        summary: "Le thème de Chamois : gris froids, verre et lumière, un seul accent bleu acier. Suit le mode clair ou sombre de macOS.",
        appearance: .system,
        light: .make(bg: 0xF5F5F7, sidebar: 0xF0F0F3, card: 0xFFFFFF, cardRaised: 0xFFFFFF, hover: 0xEBEBED,
                     selected: 0xE1E1E3, track: 0xE9E9EB, border: 0xE4E4E6, borderStrong: 0xD8D8DA,
                     text: 0x1D1D1E, text2: 0x676768, text3: 0x86868A, accent: 0x3773EB, onAccent: 0xFFFFFF,
                     good: 0x2F9563, warn: 0xB07A1E, bad: 0xD0493E, brand: 0x3773EB, matrix: 0xC9C9CD,
                     chart: [0x3773EB, 0x5E7697, 0x6E8A68, 0xA8925F, 0x8371A0, 0x56606B, 0x7D8899, 0x9AA0A8, 0x4A5058, 0xC2C4C8]),
        dark: .make(bg: 0x121215, sidebar: 0x1C1D21, card: 0x1A1A1D, cardRaised: 0x1F1F21, hover: 0x1D1E20,
                    selected: 0x2C2C2E, track: 0x202023, border: 0x222225, borderStrong: 0x2E2E31,
                    text: 0xF1F1F1, text2: 0xA5A5A6, text3: 0x717172, accent: 0x5B8DEF, onAccent: 0xFFFFFF,
                    good: 0x4CB782, warn: 0xE0A443, bad: 0xE5675C, brand: 0x5B8DEF, matrix: 0x3A3A3E,
                    chart: [0x5B8DEF, 0x7F95B2, 0x8FA58A, 0xC2AE8C, 0xA190B8, 0x6F7A86, 0x5A6B85, 0x9AA1AB, 0x4E545C, 0x3D3D41]),
        titleFont: .sans, titleWeight: .bold, bodyFont: .sans, textScale: 1, radius: 1, borderWidth: 1,
        elevation: .subtle, icons: .mono, backdrop: false, mascot: true)

    /// The same greys without any accent (the selection in ink), square corners, no ornament and no decorative icon.
    static let graphitePur = ThemeSpec(
        id: "graphite-pur", name: "Graphite pur",
        summary: "Le gris de Graphite sans aucun accent : une seule encre, angles droits, ni icônes décoratives ni mascotte.",
        appearance: .system,
        light: .make(bg: 0xF5F5F7, sidebar: 0xF0F0F3, card: 0xFFFFFF, cardRaised: 0xFFFFFF, hover: 0xEBEBED,
                     selected: 0xE1E1E3, track: 0xE9E9EB, border: 0xE0E0E2, borderStrong: 0xC4C4C7,
                     text: 0x1D1D1E, text2: 0x5E5E60, text3: 0x7E7E82, accent: 0x1D1D1E, onAccent: 0xFFFFFF,
                     good: 0x2F6B4C, warn: 0x86651B, bad: 0xA3372D, brand: 0x1D1D1E, matrix: 0xC9C9CD,
                     chart: [0x1D1D1E, 0x5E5E60, 0x8F8F92, 0xB9B9BC, 0x373739, 0x747477, 0xA4A4A7, 0x2A2A2C, 0xCDCDD0, 0x4B4B4E]),
        dark: .make(bg: 0x121215, sidebar: 0x1C1D21, card: 0x1A1A1D, cardRaised: 0x1F1F21, hover: 0x1D1E20,
                    selected: 0x2C2C2E, track: 0x202023, border: 0x2A2A2D, borderStrong: 0x454549,
                    text: 0xF1F1F1, text2: 0xA5A5A6, text3: 0x7C7C7E, accent: 0xF1F1F1, onAccent: 0x121215,
                    good: 0x7DB894, warn: 0xCCA75E, bad: 0xDB7A6F, brand: 0xF1F1F1, matrix: 0x3A3A3E,
                    chart: [0xF1F1F1, 0xA5A5A6, 0x737376, 0x4F4F52, 0xCACACC, 0x8C8C8F, 0x5E5E61, 0xDCDCDE, 0x404043, 0xB8B8BA]),
        titleFont: .sans, titleWeight: .semibold, bodyFont: .sans, textScale: 1, radius: 0, borderWidth: 1,
        elevation: .flat, icons: .hidden, backdrop: false, mascot: false)

    /// The original look, shared with ClaudeStats: warm paper, serif titles, Claude blue.
    static let atelier = ThemeSpec(
        id: "atelier", name: "Atelier",
        summary: "Le thème d'origine : papier chaud, titres à empattements et bleu Claude. Suit le mode clair ou sombre de macOS.",
        appearance: .system,
        light: .make(bg: 0xF4F3EF, sidebar: 0xEBE9E2, card: 0xFCFBF9, cardRaised: 0xFFFFFF, hover: 0xE2E0D8,
                     selected: 0xDCD9D0, track: 0xE6E3DA, border: 0xDEDBD1, borderStrong: 0xCCC8BC,
                     text: 0x1F1E1D, text2: 0x5F5D57, text3: 0x8C897F, accent: 0x2C84DB, onAccent: 0xFFFFFF,
                     good: 0x3F8F68, warn: 0xB07F17, bad: 0xC2453D, brand: 0xD97757, matrix: 0x9A9488,
                     chart: [0x2C84DB, 0x5BA3A0, 0x8DA47E, 0xD4A27F, 0x9B87C4, 0xC46686, 0x7C83D6, 0xCBB26A, 0x8E8B82, 0xB0856A]),
        dark: .make(bg: 0x141413, sidebar: 0x0F0F0E, card: 0x1B1B1A, cardRaised: 0x222221, hover: 0x222221,
                    selected: 0x2A2A28, track: 0x252523, border: 0x2A2A28, borderStrong: 0x3A3A37,
                    text: 0xF4F2EC, text2: 0xB4B1A7, text3: 0x7F7C73, accent: 0x4C9AE6, onAccent: 0xFFFFFF,
                    good: 0x6BBF8E, warn: 0xE0B355, bad: 0xE5736A, brand: 0xD97757, matrix: 0x4F6577,
                    chart: [0x4C9AE6, 0x5BA3A0, 0x8DA47E, 0xD4A27F, 0x9B87C4, 0xC46686, 0x7C83D6, 0xCBB26A, 0x8E8B82, 0xB0856A]),
        titleFont: .serif, titleWeight: .regular, bodyFont: .sans, textScale: 1, radius: 1, borderWidth: 1,
        elevation: .subtle, icons: .tinted, backdrop: true, mascot: true)

    /// An old green-phosphor terminal: black glass, monospaced type, ANSI colors.
    static let phosphore = ThemeSpec(
        id: "phosphore", name: "Phosphore",
        summary: "Un vieux terminal : verre noir, lettres vertes, tout en chasse fixe et des angles droits. Toujours sombre.",
        appearance: .dark,
        light: .make(bg: 0xEEF3E8, sidebar: 0xE4EBDC, card: 0xF7FAF3, cardRaised: 0xFFFFFF, hover: 0xDCE6D2,
                     selected: 0xD0DEC3, track: 0xDDE6D3, border: 0xC6D6B8, borderStrong: 0x9DB78A,
                     text: 0x0F2A12, text2: 0x2F5A33, text3: 0x5E7F5C, accent: 0x14873A, onAccent: 0xFFFFFF,
                     good: 0x14873A, warn: 0x9A6A00, bad: 0xC0362C, brand: 0x14873A, matrix: 0x9DB78A,
                     chart: [0x14873A, 0x9A6A00, 0x0F7C82, 0x5E7F5C, 0xC0612C, 0x3559B5, 0x7A8F00, 0x0B5E27, 0x8A4FB0, 0xC0362C]),
        dark: .make(bg: 0x070B07, sidebar: 0x040704, card: 0x0C140C, cardRaised: 0x111B11, hover: 0x132013,
                    selected: 0x1A2D1A, track: 0x142214, border: 0x1D361D, borderStrong: 0x2E5A2E,
                    text: 0xB4F5AA, text2: 0x78C270, text3: 0x5B9455, accent: 0x4DFF88, onAccent: 0x04140A,
                    good: 0x4DFF88, warn: 0xFFC24D, bad: 0xFF5F56, brand: 0x4DFF88, matrix: 0x2E8C3F,
                    chart: [0x4DFF88, 0xFFC24D, 0x3DD6D0, 0xB4F5AA, 0xFF8F4D, 0x7AA8FF, 0xD6FF4D, 0x2BC466, 0xC58CFF, 0xFF5F56]),
        titleFont: .mono, titleWeight: .semibold, bodyFont: .mono, textScale: 0.94, radius: 0, borderWidth: 1,
        elevation: .subtle, icons: .mono, backdrop: true, mascot: true)

    /// Pastel and playful: rounded type, very round corners, candy colors and soft shadows under the cards.
    static let sorbet = ThemeSpec(
        id: "sorbet", name: "Sorbet",
        summary: "Pastel et joueur : police arrondie, angles très ronds, couleurs acidulées et ombres douces sous les cartes. Toujours clair.",
        appearance: .light,
        light: .make(bg: 0xFFF5EF, sidebar: 0xFFEBE1, card: 0xFFFFFF, cardRaised: 0xFFFFFF, hover: 0xFFE4D8,
                     selected: 0xFFD7C9, track: 0xFBE4DA, border: 0xF7E3D9, borderStrong: 0xE8BBA8,
                     text: 0x3B2340, text2: 0x6B5371, text3: 0x8E7894, accent: 0xE5326B, onAccent: 0xFFFFFF,
                     good: 0x13875F, warn: 0xB86E00, bad: 0xD6303A, brand: 0xF26B3A, matrix: 0xF2B8C6,
                     chart: [0xE5326B, 0x7C6CF2, 0x1FB5A8, 0xFFB020, 0x4DA3FF, 0xA35CFF, 0xFF8A5C, 0x4CC25B, 0xF25CC8, 0x8C9EFF]),
        dark: .make(bg: 0x231726, sidebar: 0x1C121E, card: 0x2D1F31, cardRaised: 0x36263A, hover: 0x3A2A3F,
                    selected: 0x45324B, track: 0x3A2A3F, border: 0x45324B, borderStrong: 0x5C4463,
                    text: 0xFDEFF4, text2: 0xD4BCD9, text3: 0xA58DAB, accent: 0xFF6F9C, onAccent: 0x231726,
                    good: 0x4FD6A1, warn: 0xFFC163, bad: 0xFF6B70, brand: 0xFF9466, matrix: 0x5C4463,
                    chart: [0xFF6F9C, 0x9C8FFF, 0x3FD6C8, 0xFFC140, 0x6DB6FF, 0xBA85FF, 0xFFA07A, 0x6DDB7A, 0xFF7FD9, 0xA9B6FF]),
        titleFont: .rounded, titleWeight: .bold, bodyFont: .rounded, textScale: 1, radius: 1.6, borderWidth: 1,
        elevation: .raised, icons: .tinted, backdrop: false, mascot: true)

    /// Deep navy night with violet and teal highlights, thin titles and soft corners.
    static let minuit = ThemeSpec(
        id: "minuit", name: "Minuit",
        summary: "Bleu nuit profond, reflets violets et turquoise, titres fins et angles adoucis. Toujours sombre.",
        appearance: .dark,
        light: .make(bg: 0xF3F3FB, sidebar: 0xE9E9F6, card: 0xFBFBFF, cardRaised: 0xFFFFFF, hover: 0xE3E3F3,
                     selected: 0xD9D8F0, track: 0xE2E2F1, border: 0xD8D8EC, borderStrong: 0xBDBCDB,
                     text: 0x1B1C33, text2: 0x4D4F75, text3: 0x7D7FA3, accent: 0x6D4AE0, onAccent: 0xFFFFFF,
                     good: 0x0E8A7A, warn: 0xA8641A, bad: 0xC9344F, brand: 0xC0508A, matrix: 0xB9B8DA,
                     chart: [0x6D4AE0, 0x0E9A88, 0x3D6FE0, 0xC9344F, 0xC77A1F, 0x5E9C2E, 0xC0508A, 0x1C8FC0, 0x8D5BD6, 0xA8781F]),
        dark: .make(bg: 0x13141F, sidebar: 0x0E0F18, card: 0x1A1B2A, cardRaised: 0x212236, hover: 0x24253A,
                    selected: 0x2C2E48, track: 0x24263B, border: 0x292B42, borderStrong: 0x3D405F,
                    text: 0xE4E6F7, text2: 0xA9ADCF, text3: 0x7F84AD, accent: 0xA78BFA, onAccent: 0x13141F,
                    good: 0x5EEAD4, warn: 0xFBBF77, bad: 0xF7768E, brand: 0xF0A6CA, matrix: 0x3D4270,
                    chart: [0xA78BFA, 0x5EEAD4, 0x7AA2F7, 0xF7768E, 0xFBBF77, 0x9ECE6A, 0xF0A6CA, 0x7DCFFF, 0xBB9AF7, 0xE0AF68]),
        titleFont: .sans, titleWeight: .light, bodyFont: .sans, textScale: 1, radius: 1.3, borderWidth: 1,
        elevation: .subtle, icons: .tinted, backdrop: true, mascot: true)
}

// MARK: - Self-test

/// Pure checks run by `--selftest`: readable built-in themes, JSON round trip, color math.
enum ThemeChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures.append("Thèmes : " + message()) } }

        expect(Set(ThemeSpec.builtIns.map(\.id)).count == ThemeSpec.builtIns.count, "identifiants en double")
        expect(ThemeSpec.builtIns.count == 6, "il faut six thèmes de base")
        expect(ThemeSpec.builtIns.first == .base, "le thème par défaut doit ouvrir la liste")
        for t in ThemeSpec.builtIns {
            for v in t.variants {
                let p = t.palette(v)
                let name = "\(t.name) (\(v.title.lowercased()))"
                expect(ThemeColor.contrast(p[.text], p[.bg]) >= 7, "\(name) : texte peu lisible sur le fond")
                expect(ThemeColor.contrast(p[.text2], p[.card]) >= 4.5, "\(name) : texte secondaire peu lisible")
                expect(ThemeColor.contrast(p[.text3], p[.card]) >= 3, "\(name) : texte discret illisible")
                // The original Claude blue of Atelier sits right at 3:1 under white labels.
                expect(ThemeColor.contrast(p[.onAccent], p[.accent]) >= 2.9, "\(name) : texte sur l'accent peu lisible")
                expect(ThemeColor.contrast(p[.accent], p[.bg]) >= 3, "\(name) : accent trop pâle sur le fond")
                for k in [ThemeColorKey.good, .warn, .bad] {
                    expect(ThemeColor.contrast(p[k], p[.card]) >= 3, "\(name) : \(k.title.lowercased()) trop pâle")
                }
                expect(p.chart.count == ThemePalette.chartCount, "\(name) : dix couleurs de graphique attendues")
            }
            expect(ThemeSpec.radiusRange.contains(t.radius) && ThemeSpec.textScaleRange.contains(t.textScale), "\(t.name) : réglages hors limites")
        }

        // At least one theme without any of the AI-app clichés.
        expect(ThemeSpec.builtIns.contains { $0.radius == 0 && $0.icons == .hidden && !$0.mascot && !$0.backdrop && $0.elevation == .flat },
               "aucun thème sobre (angles droits, sans icônes ni ornements)")

        // JSON round trip, and a theme pasted by hand with only a few fields.
        for t in ThemeSpec.builtIns {
            let back = (try? JSONEncoder().encode(t)).flatMap { try? JSONDecoder().decode(ThemeSpec.self, from: $0) }
            expect(back == t, "\(t.name) ne survit pas à l'export JSON")
        }
        let partial = ##"{"name":"Mini","radius":9,"light":{"accent":"#f60"},"icons":"inconnu"}"##
        if let t = try? JSONDecoder().decode(ThemeSpec.self, from: Data(partial.utf8)) {
            expect(t.name == "Mini" && t.radius == ThemeSpec.radiusRange.upperBound, "un thème partiel n'est pas complété ni borné")
            expect(t.light[.accent] == ThemeColor(0xFF6600) && t.light[.bg] == ThemeSpec.base.light[.bg], "couleurs partielles mal complétées")
            expect(t.icons == ThemeSpec.base.icons, "une valeur inconnue devrait revenir au réglage de Graphite")
        } else {
            expect(false, "un thème partiel devrait se charger")
        }

        // Color math.
        expect(ThemeColor(string: "#abc")?.hex == 0xAABBCC, "lecture de #abc")
        expect(ThemeColor(string: "12345G") == nil && ThemeColor(string: "#1234") == nil, "une couleur invalide est acceptée")
        expect(ThemeColor(0x000000).mixed(with: .white, 0.5).hex == 0x808080, "mélange à 50 %")
        expect(abs(ThemeColor.contrast(.white, ThemeColor(0x000000)) - 21) < 0.01, "contraste noir sur blanc")
        expect(ThemeColor(0xFFDD00).readableInk == .ink && ThemeColor(0x1F3A8A).readableInk == .white, "choix de l'encre lisible")

        // The store: a theme change reaches the views, custom themes can be made, edited, shared and removed.
        let shared = ThemeStore.shared
        let previous = shared.active.id
        let changed = CancelFlag()
        withObservationTracking { _ = Theme.accent } onChange: { changed.cancel() }
        shared.select(previous == "graphite-pur" ? "sorbet" : "graphite-pur")
        expect(changed.isCancelled, "changer de thème ne redessinerait pas les vues")
        shared.select(previous)

        let store = ThemeStore()
        store.select("phosphore")
        store.edit { $0.radius = 1 }
        expect(store.active == .phosphore, "un thème de base a été modifié")
        let mine = store.duplicate(store.active)
        expect(!mine.isBuiltIn && store.customs.count == 1 && store.active.id == mine.id, "duplication d'un thème")
        store.edit { $0.radius = 5; $0.light[.accent] = ThemeColor(0x123456) }
        expect(store.active.radius == ThemeSpec.radiusRange.upperBound && store.resolved.radiusScale == 2, "réglage d'un thème perso non appliqué ou non borné")
        expect(store.importJSON(store.exportJSON(store.active)) && store.customs.count == 2, "un thème copié en JSON ne se recolle pas")
        expect(store.active.light[.accent] == ThemeColor(0x123456) && store.active.name != mine.name, "le thème recollé diffère ou porte le même nom")
        expect(!store.importJSON("pas du JSON"), "un texte quelconque est accepté comme thème")
        store.delete(store.active.id)
        store.delete(mine.id)
        expect(store.customs.isEmpty && store.active == .base, "suppression d'un thème perso")

        // Harmonizing Atelier from its three base colors lands close to the hand-made shades.
        for (v, p) in [(ThemeVariant.light, ThemeSpec.atelier.light), (.dark, ThemeSpec.atelier.dark)] {
            var h = p
            h.harmonize(dark: v == .dark)
            for k in [ThemeColorKey.border, .text2, .text3, .card] {
                let d = max(abs(h[k].r - p[k].r), abs(h[k].g - p[k].g), abs(h[k].b - p[k].b))
                expect(d < 0.08, "nuance « \(k.title) » harmonisée trop loin de l'originale (\(v.title.lowercased()))")
            }
        }
        return failures
    }
}
