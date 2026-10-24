import SwiftUI
import AppKit

// MARK: - Colors

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }

    /// A color that follows the light / dark appearance.
    static func adaptive(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: alpha)
                : NSColor(hex: light, alpha: alpha)
        })
    }
}

/// The colors, type and shapes of the active theme (see `ThemeStore`). Every view reads them here,
/// so switching themes in the settings redraws the whole app.
enum Theme {
    static var current: ThemeResolved { ThemeStore.shared.resolved }

    // Surfaces
    static var bg: Color { current.bg }
    static var sidebar: Color { current.sidebar }
    static var card: Color { current.card }
    static var cardRaised: Color { current.cardRaised }
    static var hover: Color { current.hover }
    static var selected: Color { current.selected }
    static var border: Color { current.border }
    static var borderStrong: Color { current.borderStrong }
    static var track: Color { current.track }

    // Text
    static var text: Color { current.text }
    static var text2: Color { current.text2 }
    static var text3: Color { current.text3 }

    // Accent, and what reads on top of it
    static var accent: Color { current.accent }
    static var onAccent: Color { current.onAccent }
    /// The theme's signature color (an orange in Atelier): a few keys and highlights.
    static var brand: Color { current.brand }
    static var onBrand: Color { current.onBrand }
    /// Claude's own orange, the default of the color picker.
    static let brandHex: UInt32 = 0xD97757
    /// The faint specks of the header backdrops.
    static var matrix: Color { current.matrix }
    /// The mascot's fur, face, horns and cloth (see `MascotFigure`).
    static var mascot: MascotColors { current.mascot }

    // Matter and light (the design system: Arc × macOS 27), drawn from the colors above

    /// The window itself, under the glass of the sidebar and around the stage.
    static var window: Color { current.window }
    /// The tint laid on the sidebar's glass.
    static var glass: Color { current.glass }
    /// Neutral fills of the controls, tracks and hovers, from the faintest.
    static var fill1: Color { current.fill1 }
    static var fill2: Color { current.fill2 }
    static var fill3: Color { current.fill3 }
    /// The 1-point reflection along the top edge of every raised surface: the light comes from above.
    static var rim: Color { current.rim }
    /// The top of a card: a touch lighter than its bottom in the dark.
    static var cardTop: Color { current.cardTop }
    /// Popovers, menus, the launcher: a surface floating above the others.
    static var floating: Color { current.floating }
    /// The veil and the reflection of the glass bubble that marks a selection.
    static var bubble: Color { current.bubble }
    static var bubbleRim: Color { current.bubbleRim }
    /// The accent, faint (a focus halo, a selected row) and as an outline.
    static var accentSoft: Color { current.accentSoft }
    static var accentRim: Color { current.accentRim }
    /// The neutral of the charts: the data, while the accent marks the insight.
    static var chartNeutral: Color { current.chartNeutral }
    /// The two shadows of a card (contact, then depth), and the deep one of the stage and the floating surfaces.
    static var shadowNear: Color { current.shadowNear }
    static var shadowFar: Color { current.shadowFar }
    static var shadowDeep: Color { current.shadowDeep }

    // Status
    static var good: Color { current.good }
    static var warn: Color { current.warn }
    static var bad: Color { current.bad }
    static var onBad: Color { current.onBad }

    /// Palette for categorical charts, led by the accent.
    static var palette: [Color] { current.palette }

    static func color(index: Int) -> Color { palette[abs(index) % palette.count] }

    /// Accent → ochre → red as a load goes up (0…1).
    static func load(_ v: Double) -> Color {
        if v < 0.6 { return accent }
        if v < 0.85 { return warn }
        return bad
    }

    // Shapes

    /// A corner radius of the original design, scaled by the theme (0 in the square themes).
    static func r(_ radius: CGFloat) -> CGFloat { radius * current.radiusScale }
    /// Width of card and control outlines.
    static var line: CGFloat { current.line }
    static var icons: ThemeIconStyle { current.spec.icons }

    /// White or near-black, whichever reads better on a fill of the current theme (chart colors, tints).
    @MainActor
    static func ink(on fill: Color) -> Color {
        var ink = ThemeColor.white
        (NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance {
            if let c = ThemeColor(fill) { ink = c.readableInk }
        }
        return ink.color
    }
}

/// The mascot's colors, drawn from the theme: its horns, its fur (and the darker fur of its ears), the mask around its
/// eyes, its cream face, its eyes, nose and cheeks, its hooves, its yellow chamois cloth, and the contour drawn only on light
/// backgrounds. Then what it grows into in the Refuge (the rings of its horns, its collar, its bell, its scarves, the golden
/// coat of its last stage, the metals of its badges) and its room (the sky, the mountains, the wood and straw, the dust
/// bunnies and the moths).
struct MascotColors {
    let horn, fur, furShade, mask, face, eye, nose, cheek, hoof, cloth, clothShade, contour: Color
    let hornRing, collar, bell, bellShade, sparkle, glasses, glassShine, sweat, tongue: Color
    let goldHorn, goldRing, goldFur, goldFurShade, goldMask, goldCollar: Color
    let bronze, bronzeLight, silver, silverLight, ruby, rubyLight: Color
    let sky, night, mountain, snow, star, wood, woodShade, straw, strawShade, dust, dustShade, moth, mothWing: Color
    /// The eight scarves, bronze to sacred wool, then the golden thread of the last one.
    let scarves: [(main: Color, light: Color)]
    let goldThread: Color
    /// The coats: the winter one and those of the shop, by name.
    let coats: [String: MascotCoat]
    /// Its blueberry bush, the berries, and the colors of the shop's things (hats, glasses, the objects of its room).
    let leaf, leafShade, berry, berryShine: Color
    let props: [String: Color]

    func prop(_ name: String) -> Color { props[name] ?? horn }
}

/// A coat of the chamois: its fur, the darker fur of its ears and the mask around its eyes.
struct MascotCoat {
    let fur, furShade, mask: Color
}

/// A theme turned into ready-to-draw values, once per change (views read them hundreds of times per frame).
final class ThemeResolved: @unchecked Sendable {
    let spec: ThemeSpec
    let bg, sidebar, card, cardRaised, hover, selected, border, borderStrong, track: Color
    let text, text2, text3: Color
    let accent, onAccent, brand, onBrand, matrix: Color
    let good, warn, bad, onBad: Color
    let window, glass, fill1, fill2, fill3, rim, cardTop, floating, bubble, bubbleRim: Color
    let accentSoft, accentRim, chartNeutral, shadowNear, shadowFar, shadowDeep: Color
    let palette: [Color]
    let mascot: MascotColors
    let radiusScale: CGFloat
    let line: CGFloat
    let textScale: CGFloat
    let titleDesign: Font.Design
    let titleWeight: Font.Weight
    let bodyDesign: Font.Design

    init(_ spec: ThemeSpec) {
        self.spec = spec
        func make(_ l: ThemeColor, _ d: ThemeColor) -> Color {
            switch spec.appearance {
            case .system: return .adaptive(light: l.hex, dark: d.hex)
            case .light: return Color(hex: l.hex)
            case .dark: return Color(hex: d.hex)
            }
        }
        func c(_ k: ThemeColorKey) -> Color { make(spec.light[k], spec.dark[k]) }
        bg = c(.bg); sidebar = c(.sidebar); card = c(.card); cardRaised = c(.cardRaised); hover = c(.hover)
        selected = c(.selected); border = c(.border); borderStrong = c(.borderStrong); track = c(.track)
        text = c(.text); text2 = c(.text2); text3 = c(.text3)
        accent = c(.accent); onAccent = c(.onAccent); brand = c(.brand); matrix = c(.matrix)
        onBrand = make(spec.light[.brand].readableInk, spec.dark[.brand].readableInk)
        good = c(.good); warn = c(.warn); bad = c(.bad)
        onBad = make(spec.light[.bad].readableInk, spec.dark[.bad].readableInk)
        // The same color at another opacity in light and dark.
        func veil(_ l: ThemeColor, _ la: CGFloat, _ d: ThemeColor, _ da: CGFloat) -> Color {
            switch spec.appearance {
            case .light: return Color(hex: l.hex, alpha: la)
            case .dark: return Color(hex: d.hex, alpha: da)
            case .system:
                return Color(nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: d.hex, alpha: da) : NSColor(hex: l.hex, alpha: la)
                })
            }
        }
        let (l, d) = (spec.light, spec.dark)
        let bright = ThemeColor.white, night = ThemeColor(0x000000)
        window = make(l[.bg].mixed(with: l[.text], 0.06), d[.bg].mixed(with: night, 0.4))
        glass = veil(l[.sidebar], 0.62, d[.sidebar], 0.55)
        fill1 = veil(l[.text], 0.04, d[.text], 0.05)
        fill2 = veil(l[.text], 0.06, d[.text], 0.08)
        fill3 = veil(l[.text], 0.08, d[.text], 0.11)
        rim = veil(bright, 0.9, bright, 0.1)
        cardTop = make(l[.card], d[.card].mixed(with: bright, 0.02))
        floating = veil(l[.cardRaised], 0.8, d[.cardRaised], 0.78)
        bubble = veil(bright, 0.55, d[.text], 0.08)
        bubbleRim = veil(bright, 0.9, bright, 0.18)
        accentSoft = veil(l[.accent], 0.14, d[.accent], 0.14)
        accentRim = veil(l[.accent], 0.55, d[.accent], 0.55)
        chartNeutral = veil(l[.text], 0.22, d[.text], 0.26)
        // Flat themes draw no shadow at all, raised ones a deeper one.
        let depth: CGFloat = spec.elevation == .flat ? 0 : (spec.elevation == .raised ? 1.6 : 1)
        shadowNear = veil(night, 0.04 * depth, night, 0.25 * depth)
        shadowFar = veil(night, 0.07 * depth, night, 0.32 * depth)
        shadowDeep = veil(night, 0.14 * depth, night, 0.45 * depth)
        palette = (0..<ThemePalette.chartCount).map { make(spec.light.chart[$0], spec.dark.chart[$0]) }
        // The mascot keeps the bright warm color of the dark appearance everywhere, turned into a chamois' tawny fur;
        // on a light background only, a contour keeps its cream face readable.
        let gold = spec.dark[.warn], red = spec.dark[.bad], black = ThemeColor(0x000000)
        let fur = gold.mixed(with: ThemeColor(0x9A5A3A), 0.4)
        let goldCoat = gold.mixed(with: ThemeColor(0xF2C14E), 0.6)
        func fixed(_ c: ThemeColor) -> Color { Color(hex: c.hex) }
        func onLight(_ c: ThemeColor) -> Color {
            switch spec.appearance {
            case .light: return Color(hex: c.hex)
            case .dark: return .clear
            case .system:
                return Color(nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .clear : NSColor(hex: c.hex)
                })
            }
        }
        mascot = MascotColors(
            horn: fixed(fur.mixed(with: black, 0.8)), fur: fixed(fur), furShade: fixed(fur.mixed(with: black, 0.22)),
            mask: fixed(fur.mixed(with: black, 0.12)), face: fixed(gold.mixed(with: .white, 0.8)), eye: fixed(.ink),
            nose: fixed(red.mixed(with: .white, 0.2)), cheek: fixed(red.mixed(with: .white, 0.45)),
            hoof: fixed(fur.mixed(with: black, 0.68)), cloth: fixed(gold.mixed(with: .white, 0.25)), clothShade: fixed(gold),
            contour: onLight(fur.mixed(with: black, 0.5)),
            hornRing: fixed(fur.mixed(with: black, 0.5)), collar: fixed(gold.mixed(with: .white, 0.7).mixed(with: fur, 0.12)),
            bell: fixed(gold.mixed(with: .white, 0.15)), bellShade: fixed(gold.mixed(with: black, 0.25)), sparkle: fixed(.white),
            glasses: fixed(ThemeColor(0x1A1D24)), glassShine: fixed(ThemeColor(0x8FA3BF)), sweat: fixed(ThemeColor(0x9AD6FF)),
            tongue: fixed(red.mixed(with: black, 0.1)),
            goldHorn: fixed(goldCoat.mixed(with: black, 0.55)), goldRing: fixed(goldCoat.mixed(with: .white, 0.5)),
            goldFur: fixed(goldCoat), goldFurShade: fixed(goldCoat.mixed(with: black, 0.18)), goldMask: fixed(goldCoat.mixed(with: black, 0.1)),
            goldCollar: fixed(goldCoat.mixed(with: .white, 0.7)),
            bronze: fixed(ThemeColor(0xB8732E)), bronzeLight: fixed(ThemeColor(0xE3A465)),
            silver: fixed(ThemeColor(0x9DA8B5)), silverLight: fixed(ThemeColor(0xE6ECF2)),
            ruby: fixed(red.mixed(with: ThemeColor(0xA0103A), 0.5)), rubyLight: fixed(red.mixed(with: .white, 0.35)),
            sky: fixed(ThemeColor(0x8CC8F2)), night: fixed(ThemeColor(0x1F2A44)), mountain: fixed(ThemeColor(0x5C6F8A)),
            snow: fixed(ThemeColor(0xF4F7FB)), star: fixed(ThemeColor(0xFFF3B0)),
            wood: fixed(fur.mixed(with: black, 0.45)), woodShade: fixed(fur.mixed(with: black, 0.6)),
            straw: fixed(gold.mixed(with: .white, 0.35)), strawShade: fixed(gold.mixed(with: black, 0.1)),
            dust: fixed(ThemeColor(0xA9A9B2)), dustShade: fixed(ThemeColor(0x7D7D88)),
            moth: fixed(ThemeColor(0x6B6157)), mothWing: fixed(ThemeColor(0xB9AE9F)),
            scarves: [(0xB8732E, 0xE3A465), (0x9DA8B5, 0xE6ECF2), (0xE3A91C, 0xFFE27A), (0xB9C7D6, 0xF4F8FC),
                      (0x6FCFEA, 0xE6FBFF), (0x179A5C, 0x6EE0A0), (0xC81E4A, 0xFF7895), (0xF3E9D6, 0xFFFFFF)]
                .map { (fixed(ThemeColor($0.0)), fixed(ThemeColor($0.1))) },
            goldThread: fixed(ThemeColor(0xFFD24A)),
            coats: [
                "hiver": (0x6A4E3B, 0x4A3528, 0x2E211A), "chocolat": (0x7A4E32, 0x5A3622, 0x4A2E1E),
                "neige": (0xEDE7DE, 0xCFC6BA, 0xBDB3A6), "roux": (0xD9733A, 0xA9522A, 0x8A4020),
                "gris-perle": (0xA9A4B4, 0x858094, 0x6E697D), "nuit": (0x2E3560, 0x1E2444, 0x161A33),
            ].mapValues { MascotCoat(fur: fixed(ThemeColor($0.0)), furShade: fixed(ThemeColor($0.1)), mask: fixed(ThemeColor($0.2))) },
            leaf: fixed(ThemeColor(0x4E9A5B)), leafShade: fixed(ThemeColor(0x2F6B3C)),
            berry: fixed(ThemeColor(0x4B5BB5)), berryShine: fixed(ThemeColor(0x9AA8FF)),
            props: [
                "bleu": 0x5B8DEF, "bleu-clair": 0x9DBDFF, "creme": 0xF6EFE6, "creme-ombre": 0xD9D0C2, "rose": 0xE8577A,
                "rose-clair": 0xFF8FA6, "jaune": 0xFFD24A, "vert": 0x5FB86A, "vert-fonce": 0x2F6B3C, "orange": 0xF08A2E,
                "orange-fonce": 0xC0601C, "terre": 0xB5653A, "violet": 0x5B4FB0, "violet-clair": 0x9A8CFF, "verre": 0xBFD3E6,
                "monture": 0x9C6B47, "verre-bleu": 0x9FD3FF, "fonte": 0x3D3550, "fonte-claire": 0x5A5070, "flamme": 0xFF8A3D,
                "argent": 0xC9D2DC, "rouge": 0xC8344A, "aile": 0xE9F4FF, "paille": 0xE9C46A, "paille-ombre": 0xC79A3A,
            ].mapValues { fixed(ThemeColor($0)) })
        radiusScale = CGFloat(spec.radius)
        line = CGFloat(spec.borderWidth)
        textScale = CGFloat(spec.textScale)
        titleDesign = spec.titleFont.design
        titleWeight = spec.titleWeight.weight
        bodyDesign = spec.bodyFont.design
    }
}

// MARK: - Typography

extension Font {
    /// Titles and big numbers: serif in Atelier, the theme's title font otherwise, always with tabular figures.
    /// A title left at the regular weight takes the theme's title weight.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let t = Theme.current
        return Font.system(size: size * t.textScale, weight: weight == .regular ? t.titleWeight : weight, design: t.titleDesign)
            .monospacedDigit()
    }
    /// A figure (a KPI, a big number): the title font one step lighter than the titles when they are bold.
    static func figure(_ size: CGFloat) -> Font {
        let t = Theme.current
        let weight: Font.Weight = t.titleWeight == .bold ? .semibold : t.titleWeight
        return Font.system(size: size * t.textScale, weight: weight, design: t.titleDesign).monospacedDigit()
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let t = Theme.current
        return .system(size: size * t.textScale, weight: weight, design: t.bodyDesign)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * Theme.current.textScale, weight: weight, design: .monospaced)
    }
}

// MARK: - Formatting

enum Fmt {
    static let fr = Locale(identifier: "fr_FR")

    private static let intF: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = fr
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static let decF: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = fr
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        return f
    }()

    static func int(_ v: Int) -> String { intF.string(from: NSNumber(value: v)) ?? "\(v)" }
    static func int(_ v: Double) -> String { intF.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v))" }
    static func dec(_ v: Double) -> String {
        if abs(v) >= 100 { return int(v) }
        return decF.string(from: NSNumber(value: v)) ?? String(format: "%.1f", v)
    }

    /// Uppercases only the first letter.
    static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    static func pct(_ v: Double) -> String {
        if v > 0 && v < 0.01 { return "< 1 %" }
        return int(v * 100) + " %"
    }

    /// Sizes in the decimal units Finder uses (1 Go = 10⁹ octets).
    static func bytes(_ b: Int64) -> String {
        let v = Double(max(0, b))
        if v < 1000 { return "\(Int(v)) o" }
        let units = ["Ko", "Mo", "Go", "To", "Po"]
        var x = v / 1000
        var i = 0
        // 999,6 Ko shows as "1 Mo", not "1 000 Ko".
        while x >= 999.5 && i < units.count - 1 { x /= 1000; i += 1 }
        return "\(dec(x)) \(units[i])"
    }

    static func bytes(_ b: UInt64) -> String { bytes(Int64(clamping: b)) }
    static func bytes(_ b: Int) -> String { bytes(Int64(b)) }

    static func speed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1000 { return "\(Int(bytesPerSecond)) o/s" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func duration(_ s: Double) -> String {
        if s < 60 { return "\(Int(s)) s" }
        let m = Int(s / 60)
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        if h < 24 { return r == 0 ? "\(h) h" : "\(h) h \(String(format: "%02d", r))" }
        let d = h / 24, rh = h % 24
        return rh == 0 ? "\(d) j" : "\(d) j \(rh) h"
    }

    private static func df(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = fr
        f.setLocalizedDateFormatFromTemplate(format)
        return f
    }
    private static let dayMonthYear = df("d MMM yyyy")
    private static let time = df("HH:mm")

    static func day(_ d: Date) -> String { dayMonthYear.string(from: d) }
    static func clock(_ d: Date) -> String { time.string(from: d) }

    static func relative(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "à l'instant" }
        if s < 3600 { return "il y a \(Int(s / 60)) min" }
        if s < 86400 { return "il y a \(Int(s / 3600)) h" }
        let days = Int(s / 86400)
        if days < 60 { return "il y a \(days) j" }
        if days < 730 { return "il y a \(days / 30) mois" }
        return "il y a \(days / 365) ans"
    }

    static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        "\(int(n)) \(n > 1 ? many : one)"
    }

    static func greeting(name: String) -> String {
        let h = Calendar.current.component(.hour, from: Date())
        let who = name.isEmpty ? "" : ", \(name)"
        switch h {
        case 5..<12: return "Bonjour\(who)"
        case 12..<18: return "Bon après-midi\(who)"
        case 18..<23: return "Bonsoir\(who)"
        default: return "Belle nuit\(who)"
        }
    }

    /// The user's first name, from the macOS account.
    static var firstName: String {
        if DemoData.isEnabled { return DemoData.firstName }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
    }
}
