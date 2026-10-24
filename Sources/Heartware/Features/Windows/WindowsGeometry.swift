import Foundation
import CoreGraphics
import Carbon.HIToolbox

/// Everything the module can do to the front window. The raw value builds the hot key and launcher ids (`win_…`).
enum WindowsAction: String, CaseIterable, Identifiable {
    case leftHalf = "left_half", rightHalf = "right_half", topHalf = "top_half", bottomHalf = "bottom_half"
    case topLeft = "top_left", topRight = "top_right", bottomLeft = "bottom_left", bottomRight = "bottom_right"
    case firstThird = "first_third", centerThird = "center_third", lastThird = "last_third"
    case firstTwoThirds = "first_two_thirds", lastTwoThirds = "last_two_thirds"
    case maximize, almostMaximize = "almost_maximize", center, restore
    case nextDisplay = "next_display", previousDisplay = "previous_display"

    var id: String { rawValue }
    var commandID: String { "win_" + rawValue }

    var title: String {
        switch self {
        case .leftHalf: return "Moitié gauche"
        case .rightHalf: return "Moitié droite"
        case .topHalf: return "Moitié haute"
        case .bottomHalf: return "Moitié basse"
        case .topLeft: return "Quart en haut à gauche"
        case .topRight: return "Quart en haut à droite"
        case .bottomLeft: return "Quart en bas à gauche"
        case .bottomRight: return "Quart en bas à droite"
        case .firstThird: return "Premier tiers"
        case .centerThird: return "Tiers central"
        case .lastThird: return "Dernier tiers"
        case .firstTwoThirds: return "Deux premiers tiers"
        case .lastTwoThirds: return "Deux derniers tiers"
        case .maximize: return "Plein écran"
        case .almostMaximize: return "Presque plein écran"
        case .center: return "Centrer"
        case .restore: return "Taille précédente"
        case .nextDisplay: return "Écran suivant"
        case .previousDisplay: return "Écran précédent"
        }
    }

    var detail: String? {
        switch self {
        case .leftHalf, .rightHalf: return "Appuie encore : ⅔ puis ⅓"
        case .maximize: return "Remplit l'écran, sans le mode plein écran"
        case .almostMaximize: return "90 % de l'écran, centré"
        case .center: return "Garde la taille"
        case .restore: return "Avant le dernier rangement"
        case .nextDisplay, .previousDisplay: return "Même place, autre écran"
        default: return nil
        }
    }

    var keywords: [String] {
        let base = ["fenêtre", "window", "ranger"]
        switch self {
        case .leftHalf: return base + ["gauche", "left", "moitié", "half"]
        case .rightHalf: return base + ["droite", "right", "moitié", "half"]
        case .topHalf: return base + ["haut", "top", "moitié", "half"]
        case .bottomHalf: return base + ["bas", "bottom", "moitié", "half"]
        case .topLeft: return base + ["quart", "haut gauche", "top left"]
        case .topRight: return base + ["quart", "haut droite", "top right"]
        case .bottomLeft: return base + ["quart", "bas gauche", "bottom left"]
        case .bottomRight: return base + ["quart", "bas droite", "bottom right"]
        case .firstThird, .centerThird, .lastThird: return base + ["tiers", "third"]
        case .firstTwoThirds, .lastTwoThirds: return base + ["deux tiers", "two thirds"]
        case .maximize: return base + ["plein écran", "maximiser", "maximize", "agrandir"]
        case .almostMaximize: return base + ["presque", "almost", "maximiser", "agrandir"]
        case .center: return base + ["centrer", "center", "milieu"]
        case .restore: return base + ["restaurer", "restore", "annuler", "précédente"]
        case .nextDisplay: return base + ["écran", "display", "moniteur", "suivant", "next"]
        case .previousDisplay: return base + ["écran", "display", "moniteur", "précédent", "previous"]
        }
    }

    /// SF Symbols available since macOS 13.
    var symbol: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        case .firstThird, .firstTwoThirds: return "rectangle.leftthird.inset.filled"
        case .centerThird: return "rectangle.split.3x1"
        case .lastThird, .lastTwoThirds: return "rectangle.rightthird.inset.filled"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .almostMaximize: return "rectangle.inset.filled"
        case .center: return "rectangle.center.inset.filled"
        case .restore: return "arrow.uturn.backward.square"
        case .nextDisplay: return "arrow.right.square"
        case .previousDisplay: return "arrow.left.square"
        }
    }

    var group: WindowsGroup {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: return .halves
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .quarters
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds: return .thirds
        case .maximize, .almostMaximize, .center, .restore: return .size
        case .nextDisplay, .previousDisplay: return .displays
        }
    }

    /// ⌃⌥ + arrows, letters and ↩ like Rectangle; ⌃⌥⌘ + arrows to change screen.
    var defaultCombo: KeyCombo? {
        let ctrlOpt = UInt32(controlKey | optionKey)
        let key: Int?
        switch self {
        case .leftHalf: key = kVK_LeftArrow
        case .rightHalf: key = kVK_RightArrow
        case .topHalf: key = kVK_UpArrow
        case .bottomHalf: key = kVK_DownArrow
        case .topLeft: key = kVK_ANSI_U
        case .topRight: key = kVK_ANSI_I
        case .bottomLeft: key = kVK_ANSI_J
        case .bottomRight: key = kVK_ANSI_K
        case .firstThird: key = kVK_ANSI_D
        case .centerThird: key = kVK_ANSI_F
        case .lastThird: key = kVK_ANSI_G
        case .firstTwoThirds: key = kVK_ANSI_E
        case .lastTwoThirds: key = kVK_ANSI_T
        case .maximize: key = kVK_Return
        case .almostMaximize: key = nil
        case .center: key = kVK_ANSI_C
        case .restore: key = kVK_Delete
        case .nextDisplay:
            return KeyCombo(keyCode: UInt32(kVK_RightArrow), modifiers: ctrlOpt | UInt32(cmdKey))
        case .previousDisplay:
            return KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: ctrlOpt | UInt32(cmdKey))
        }
        return key.map { KeyCombo(keyCode: UInt32($0), modifiers: ctrlOpt) }
    }

    /// Widths a repeated left/right half goes through.
    static let halfCycle: [CGFloat] = [1 / 2, 2 / 3, 1 / 3]

    /// The share of the screen it covers, in a unit square whose origin is the top left corner
    /// (nil for actions computed from the window itself). Thirds become rows on a portrait screen.
    func unitRect(step: Int, portrait: Bool) -> CGRect? {
        let w = Self.halfCycle[((step % 3) + 3) % 3]
        // Typed constants: with integer literals, `CGRect(x: 1 / 3, …)` would pick the Int initializer.
        let t1: CGFloat = 1 / 3, t2: CGFloat = 2 / 3
        let third: CGRect?
        switch self {
        case .leftHalf: return CGRect(x: 0, y: 0, width: w, height: 1)
        case .rightHalf: return CGRect(x: 1 - w, y: 0, width: w, height: 1)
        case .topHalf: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .firstThird: third = CGRect(x: 0, y: 0, width: t1, height: 1)
        case .centerThird: third = CGRect(x: t1, y: 0, width: t1, height: 1)
        case .lastThird: third = CGRect(x: t2, y: 0, width: t1, height: 1)
        case .firstTwoThirds: third = CGRect(x: 0, y: 0, width: t2, height: 1)
        case .lastTwoThirds: third = CGRect(x: t1, y: 0, width: t2, height: 1)
        case .almostMaximize, .center, .restore, .nextDisplay, .previousDisplay: return nil
        }
        guard let t = third else { return nil }
        return portrait ? CGRect(x: t.minY, y: t.minX, width: t.height, height: t.width) : t
    }
}

enum WindowsGroup: String, CaseIterable, Identifiable {
    case halves, quarters, thirds, size, displays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .halves: return "Moitiés"
        case .quarters: return "Quarts"
        case .thirds: return "Tiers"
        case .size: return "Taille et position"
        case .displays: return "Écrans"
        }
    }

    var symbol: String {
        switch self {
        case .halves: return "rectangle.split.2x1"
        case .quarters: return "rectangle.split.2x2"
        case .thirds: return "rectangle.split.3x1"
        case .size: return "macwindow"
        case .displays: return "display.2"
        }
    }

    var subtitle: String? {
        switch self {
        case .thirds: return "Ils deviennent des lignes sur un écran vertical."
        case .displays: return "Utile avec un second écran ou un iPad en Sidecar."
        default: return nil
        }
    }

    var actions: [WindowsAction] { WindowsAction.allCases.filter { $0.group == self } }
}

/// A screen in Accessibility coordinates: origin at the top left of the main screen, y going down.
struct WindowsScreen: Equatable {
    var frame: CGRect
    var visible: CGRect
}

/// The pure geometry of window placement: no AppKit, no Accessibility, so `--selftest` can check it on fictional screens.
enum WindowsGeometry {
    /// AppKit (origin bottom left of the main screen) ↔ Accessibility (origin top left, y down).
    /// The same formula goes both ways: `primaryMaxY` is the height of the main screen.
    static func flip(_ r: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
    }

    /// The screen holding most of the window (or the nearest one when it is off screen).
    static func screenIndex(for window: CGRect, in screens: [WindowsScreen]) -> Int? {
        guard !screens.isEmpty else { return nil }
        var best: (index: Int, area: CGFloat)?
        for (i, s) in screens.enumerated() {
            let inter = s.frame.intersection(window)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > (best?.area ?? 0) { best = (i, area) }
        }
        if let best { return best.index }
        let c = CGPoint(x: window.midX, y: window.midY)
        return screens.indices.min { distance(c, screens[$0].frame) < distance(c, screens[$1].frame) }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    /// Screens from left to right (then top to bottom), the order of "next" and "previous".
    static func ordered(_ screens: [WindowsScreen]) -> [WindowsScreen] {
        screens.sorted { a, b in
            a.frame.minX != b.frame.minX ? a.frame.minX < b.frame.minX : a.frame.minY < b.frame.minY
        }
    }

    /// A unit rectangle placed in `area`, with `gap` points around the screen edges and between neighbours.
    /// Edges are rounded separately so that two halves always meet exactly.
    static func place(_ unit: CGRect, in area: CGRect, gap: CGFloat) -> CGRect {
        let inner = area.insetBy(dx: gap, dy: gap)
        var x0 = inner.minX + unit.minX * inner.width
        var x1 = inner.minX + unit.maxX * inner.width
        var y0 = inner.minY + unit.minY * inner.height
        var y1 = inner.minY + unit.maxY * inner.height
        if unit.minX > 0.001 { x0 += gap / 2 }
        if unit.maxX < 0.999 { x1 -= gap / 2 }
        if unit.minY > 0.001 { y0 += gap / 2 }
        if unit.maxY < 0.999 { y1 -= gap / 2 }
        let rx0 = x0.rounded(), rx1 = x1.rounded(), ry0 = y0.rounded(), ry1 = y1.rounded()
        return CGRect(x: rx0, y: ry0, width: rx1 - rx0, height: ry1 - ry0)
    }

    /// The window at the same relative place on another screen.
    static func moved(_ window: CGRect, from src: CGRect, to dst: CGRect) -> CGRect {
        guard src.width > 0, src.height > 0 else { return centered(window.size, in: dst) }
        let sx = dst.width / src.width, sy = dst.height / src.height
        var r = CGRect(x: dst.minX + (window.minX - src.minX) * sx, y: dst.minY + (window.minY - src.minY) * sy,
                       width: window.width * sx, height: window.height * sy)
        r.size.width = min(r.width, dst.width)
        r.size.height = min(r.height, dst.height)
        r.origin.x = min(max(r.minX, dst.minX), dst.maxX - r.width)
        r.origin.y = min(max(r.minY, dst.minY), dst.maxY - r.height)
        return CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
    }

    static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        let w = min(size.width, area.width), h = min(size.height, area.height)
        return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w.rounded(), height: h.rounded())
    }

    /// Where the window goes, or nil when the action does not apply (restore, a single screen).
    static func target(for action: WindowsAction, window: CGRect, screens: [WindowsScreen], gap: CGFloat, step: Int = 0) -> CGRect? {
        guard let i = screenIndex(for: window, in: screens) else { return nil }
        let visible = screens[i].visible
        switch action {
        case .restore:
            return nil
        case .center:
            return centered(window.size, in: visible)
        case .almostMaximize:
            return centered(CGSize(width: visible.width * 0.9, height: visible.height * 0.9), in: visible)
        case .nextDisplay, .previousDisplay:
            let list = ordered(screens)
            guard list.count > 1, let pos = list.firstIndex(of: screens[i]) else { return nil }
            let next = (pos + (action == .nextDisplay ? 1 : -1) + list.count) % list.count
            return moved(window, from: visible, to: list[next].visible)
        default:
            guard let unit = action.unitRect(step: step, portrait: visible.height > visible.width) else { return nil }
            return place(unit, in: visible, gap: gap)
        }
    }

    /// When an app refuses the size (a minimum width…), keeps the window against the same screen edges
    /// as the target and inside the screen.
    static func anchored(actual: CGSize, target: CGRect, in area: CGRect, gap: CGFloat) -> CGPoint {
        let tol = gap + 2
        func axis(_ size: CGFloat, _ tMin: CGFloat, _ tMax: CGFloat, _ aMin: CGFloat, _ aMax: CGFloat) -> CGFloat {
            let atStart = tMin - aMin <= tol, atEnd = aMax - tMax <= tol
            var v: CGFloat
            if atEnd && !atStart { v = tMax - size } else if atStart { v = tMin } else { v = (tMin + tMax) / 2 - size / 2 }
            if size <= aMax - aMin { v = min(max(v, aMin), aMax - size) } else { v = aMin }
            return v.rounded()
        }
        return CGPoint(x: axis(actual.width, target.minX, target.maxX, area.minX, area.maxX),
                       y: axis(actual.height, target.minY, target.maxY, area.minY, area.maxY))
    }

    static func approxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// The region an action fills on a fictional 16:10 screen, in unit coordinates (for the page's drawings).
    static func preview(_ action: WindowsAction) -> CGRect? {
        let screen = WindowsScreen(frame: CGRect(x: 0, y: 0, width: 160, height: 100), visible: CGRect(x: 0, y: 0, width: 160, height: 100))
        let window = CGRect(x: 30, y: 22, width: 80, height: 52)
        let r: CGRect?
        switch action {
        case .restore: r = window
        case .nextDisplay, .previousDisplay: r = nil
        default: r = target(for: action, window: window, screens: [screen], gap: 0)
        }
        return r.map { CGRect(x: $0.minX / 160, y: $0.minY / 100, width: $0.width / 160, height: $0.height / 100) }
    }

    // MARK: Self-test

    /// Two fictional screens: a 1440×900 main screen (menu bar 25 pt) and a 1920×1080 screen on its right,
    /// placed 180 pt lower in AppKit terms.
    static func selfTest() -> [String] {
        var f: [String] = []
        func expect(_ got: CGRect?, _ want: CGRect, _ label: String) {
            guard let got, approxEqual(got, want, tolerance: 0.5) else {
                f.append("\(label) : \(got.map { "\($0)" } ?? "rien"), attendu \(want)")
                return
            }
        }
        let primaryMaxY: CGFloat = 900
        let mainAppKit = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let mainVisibleAppKit = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let sideAppKit = CGRect(x: 1440, y: -180, width: 1920, height: 1080)
        let main = WindowsScreen(frame: flip(mainAppKit, primaryMaxY: primaryMaxY), visible: flip(mainVisibleAppKit, primaryMaxY: primaryMaxY))
        let side = WindowsScreen(frame: flip(sideAppKit, primaryMaxY: primaryMaxY), visible: flip(sideAppKit, primaryMaxY: primaryMaxY))
        let screens = [side, main] // deliberately not in left-to-right order

        // Coordinates
        expect(main.visible, CGRect(x: 0, y: 25, width: 1440, height: 875), "écran principal en coordonnées AX")
        expect(side.frame, CGRect(x: 1440, y: 0, width: 1920, height: 1080), "écran secondaire en coordonnées AX")
        let r = CGRect(x: 100, y: 100, width: 400, height: 300)
        expect(flip(flip(r, primaryMaxY: 900), primaryMaxY: 900), r, "aller-retour AppKit ↔ AX")
        expect(flip(r, primaryMaxY: 900), CGRect(x: 100, y: 500, width: 400, height: 300), "conversion AppKit → AX")

        // Which screen
        let onMain = CGRect(x: 200, y: 200, width: 600, height: 400)
        let onSide = CGRect(x: 1300, y: 100, width: 900, height: 600) // straddles, mostly on the side screen
        if screenIndex(for: onMain, in: screens) != 1 { f.append("fenêtre sur l'écran principal mal située") }
        if screenIndex(for: onSide, in: screens) != 0 { f.append("fenêtre à cheval mal attribuée") }
        if screenIndex(for: CGRect(x: 5000, y: 0, width: 100, height: 100), in: screens) != 0 { f.append("fenêtre hors écran : écran le plus proche attendu") }

        // Halves, quarters, thirds
        expect(target(for: .leftHalf, window: onMain, screens: screens, gap: 0), CGRect(x: 0, y: 25, width: 720, height: 875), "moitié gauche")
        expect(target(for: .rightHalf, window: onMain, screens: screens, gap: 0), CGRect(x: 720, y: 25, width: 720, height: 875), "moitié droite")
        let top = target(for: .topHalf, window: onMain, screens: screens, gap: 0)
        let bottom = target(for: .bottomHalf, window: onMain, screens: screens, gap: 0)
        if let top, let bottom, top.maxY != bottom.minY || bottom.maxY != 900 || top.minY != 25 {
            f.append("moitiés haute et basse disjointes : \(top) / \(bottom)")
        }
        expect(target(for: .bottomRight, window: onMain, screens: screens, gap: 0), CGRect(x: 720, y: 463, width: 720, height: 437), "quart en bas à droite")
        expect(target(for: .centerThird, window: onMain, screens: screens, gap: 0), CGRect(x: 480, y: 25, width: 480, height: 875), "tiers central")
        expect(target(for: .lastTwoThirds, window: onSide, screens: screens, gap: 0), CGRect(x: 2080, y: 0, width: 1280, height: 1080), "deux derniers tiers sur l'écran secondaire")
        expect(target(for: .maximize, window: onSide, screens: screens, gap: 0), side.visible, "plein écran sur l'écran secondaire")

        // Repeated presses: ½ → ⅔ → ⅓ → ½
        let widths = (0..<4).compactMap { target(for: .leftHalf, window: onMain, screens: screens, gap: 0, step: $0)?.width }
        if widths != [720, 960, 480, 720] { f.append("cycle de la moitié gauche : \(widths)") }
        expect(target(for: .rightHalf, window: onMain, screens: screens, gap: 0, step: 1), CGRect(x: 480, y: 25, width: 960, height: 875), "⅔ droite")

        // Portrait screen: thirds become rows
        let portrait = WindowsScreen(frame: CGRect(x: 0, y: 0, width: 1080, height: 1920), visible: CGRect(x: 0, y: 0, width: 1080, height: 1920))
        expect(target(for: .firstThird, window: CGRect(x: 10, y: 10, width: 300, height: 300), screens: [portrait], gap: 0),
               CGRect(x: 0, y: 0, width: 1080, height: 640), "premier tiers sur un écran vertical")

        // Gaps: 8 pt around and between
        let l = target(for: .leftHalf, window: onMain, screens: screens, gap: 8)
        let rr = target(for: .rightHalf, window: onMain, screens: screens, gap: 8)
        expect(l, CGRect(x: 8, y: 33, width: 708, height: 859), "moitié gauche avec marge")
        if let l, let rr, rr.minX - l.maxX != 8 { f.append("marge entre deux moitiés : \(rr.minX - l.maxX) au lieu de 8") }

        // Center, almost maximize
        expect(target(for: .center, window: onMain, screens: screens, gap: 0), CGRect(x: 420, y: 263, width: 600, height: 400), "centrer")
        expect(target(for: .center, window: CGRect(x: 0, y: 0, width: 3000, height: 2000), screens: [main], gap: 0), main.visible, "centrer une fenêtre trop grande")
        expect(target(for: .almostMaximize, window: onMain, screens: screens, gap: 0), CGRect(x: 72, y: 69, width: 1296, height: 788), "presque plein écran")

        // Next / previous screen keeps the relative place
        let leftHalf = CGRect(x: 0, y: 25, width: 720, height: 875)
        expect(target(for: .nextDisplay, window: leftHalf, screens: screens, gap: 0), CGRect(x: 1440, y: 0, width: 960, height: 1080), "écran suivant")
        expect(target(for: .previousDisplay, window: leftHalf, screens: screens, gap: 0), CGRect(x: 1440, y: 0, width: 960, height: 1080), "écran précédent (boucle)")
        if target(for: .nextDisplay, window: onMain, screens: [main], gap: 0) != nil { f.append("écran suivant avec un seul écran") }

        // A window that refuses to shrink stays against the right edge
        let p = anchored(actual: CGSize(width: 800, height: 875), target: CGRect(x: 720, y: 25, width: 720, height: 875), in: main.visible, gap: 0)
        if p != CGPoint(x: 640, y: 25) { f.append("fenêtre trop large ancrée en \(p), attendu (640, 25)") }
        let q = anchored(actual: CGSize(width: 500, height: 300), target: CGRect(x: 480, y: 25, width: 480, height: 875), in: main.visible, gap: 0)
        if q.x != 470 || q.y != 25 { f.append("tiers central trop étroit ancré en \(q)") }
        return f
    }
}
