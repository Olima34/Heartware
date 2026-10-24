import SwiftUI

/// What the wheel shows: the files, their two rings, and what is under the pointer.
@Observable
@MainActor
final class WheelOverlayState {
    var files: [WheelFile] = []
    var menu = WheelMenu(formats: [], tools: [], family: .other, count: 0)
    var hovered: WheelGeometry.Hit?
    /// Drives the opening and closing.
    var shown = false
    /// The chosen segment flashes once the file is dropped on it.
    var chosen: WheelGeometry.Hit?
    /// The first few times: a hint in the hub.
    var hint = false
    /// Opened by a shortcut or a click (not during a drag): the hub says "click" rather than "drop".
    var clicking = false
    /// The hub takes a drop (every action in a list) once the pointer has been on a segment: a drag that only started
    /// is dropped on nothing.
    var hubArmed = false

    var geometry: WheelGeometry { WheelGeometry(formats: menu.formats.count, tools: menu.tools.count) }

    func action(at hit: WheelGeometry.Hit?) -> WheelAction? {
        switch hit {
        case .format(let i): return menu.formats.indices.contains(i) ? menu.formats[i] : nil
        case .tool(let i): return menu.tools.indices.contains(i) ? menu.tools[i] : nil
        case .hub, nil: return nil
        }
    }
}

/// The wheel: frosted glass with the formats on the inner ring and the tools on the outer one. The segment under the
/// pointer lights up in the theme's accent and its name shows in the hub.
struct WheelView: View {
    let state: WheelOverlayState
    /// The settings' wheel, inside the app's window.
    var inWindow = false

    var body: some View {
        let side = WheelGeometry.side
        let R = WheelGeometry.radius
        ZStack {
            WheelGlass(veil: inWindow ? 0.3 : 0.42, inWindow: inWindow)
                .frame(width: 2 * R, height: 2 * R)
                .themedShadow(color: .black.opacity(0.3), radius: 22, y: 10)
            WheelRings(state: state)
            WheelHub(state: state)
        }
        .frame(width: side, height: side)
        .scaleEffect(state.shown ? 1 : 0.84)
        .opacity(state.shown ? 1 : 0)
        .animation(.spring(response: 0.26, dampingFraction: 0.78), value: state.shown)
    }
}

/// The segments of both rings, and their labels.
private struct WheelRings: View {
    let state: WheelOverlayState

    var body: some View {
        let g = state.geometry
        let menu = state.menu
        ZStack {
            if let band = g.formatBand {
                ForEach(Array(menu.formats.enumerated()), id: \.offset) { i, action in
                    WheelSegment(action: action, index: i, count: menu.formats.count, band: band, compact: g.toolBand != nil,
                                 hovered: state.hovered == .format(i), chosen: state.chosen == .format(i))
                }
            }
            if let band = g.toolBand {
                ForEach(Array(menu.tools.enumerated()), id: \.offset) { i, action in
                    WheelSegment(action: action, index: i, count: menu.tools.count, band: band, compact: false,
                                 hovered: state.hovered == .tool(i), chosen: state.chosen == .tool(i))
                }
            }
        }
        .frame(width: WheelGeometry.side, height: WheelGeometry.side)
        .animation(.easeOut(duration: 0.12), value: state.hovered)
    }
}

/// One segment: its shape, filled with the accent while the pointer is on it, and its label (with an icon on the outer ring).
private struct WheelSegment: View {
    var action: WheelAction
    var index: Int
    var count: Int
    var band: (CGFloat, CGFloat)
    /// The narrow inner ring: the label alone.
    var compact: Bool
    var hovered: Bool
    var chosen: Bool

    var body: some View {
        let side = WheelGeometry.side
        let center = CGPoint(x: side / 2, y: side / 2)
        let shape = WheelSectorShape(index: index, count: count, inner: band.0, outer: band.1)
        let lit = hovered || chosen
        let angle = WheelGeometry.centerAngle(index, of: count)
        // One segment alone is a whole ring: its label goes at the top.
        let labelAt = WheelGeometry.point(angle, (band.0 + band.1) / 2, around: center)
        ZStack {
            shape.fill(lit ? Theme.accent : Theme.cardRaised.opacity(0.5), style: FillStyle(eoFill: true))
            if !lit {
                shape.fill(RadialGradient(colors: [action.tint.opacity(0.16), action.tint.opacity(0.04)],
                                          center: .init(x: labelAt.x / side, y: labelAt.y / side), startRadius: 0, endRadius: 70),
                           style: FillStyle(eoFill: true))
            }
            shape.stroke(lit ? Color.white.opacity(0.35) : Color.white.opacity(0.14), lineWidth: 0.75)
            WheelSegmentLabel(action: action, compact: compact, lit: lit)
                .position(labelAt)
        }
        .frame(width: side, height: side)
        .compositingGroup()
        .themedShadow(color: lit ? Theme.accent.opacity(0.45) : .clear, radius: 12)
        .scaleEffect(lit ? 1.035 : 1)
    }
}

private struct WheelSegmentLabel: View {
    var action: WheelAction
    var compact: Bool
    var lit: Bool

    var body: some View {
        VStack(spacing: 4) {
            if !compact && Theme.icons != .hidden {
                Image(systemName: action.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(lit ? Theme.onAccent : (Theme.icons == .tinted ? action.tint : Theme.text2))
            }
            Text(action.label)
                .font(.ui(compact ? 10.5 : 9, .bold))
                .tracking(compact ? 0.4 : 0.7)
                .foregroundStyle(lit ? Theme.onAccent : Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: compact ? 62 : 92)
    }
}

/// The middle of the wheel: the name of the action under the pointer, else what was picked up.
private struct WheelHub: View {
    let state: WheelOverlayState

    var body: some View {
        let r = WheelGeometry.hub
        let action = state.action(at: state.hovered ?? state.chosen)
        let onHub = state.hovered == .hub && state.hubArmed
        ZStack {
            Circle().fill(onHub ? Theme.accent.opacity(0.9) : Theme.card.opacity(0.82))
            Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.75)
            VStack(spacing: 3) {
                if let action {
                    Text(action.title(count: state.menu.count, family: state.menu.family))
                        .font(.ui(11, .semibold))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                } else if onHub {
                    Text("Toutes les actions")
                        .font(.ui(10.5, .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .multilineTextAlignment(.center)
                } else {
                    Text(summary)
                        .font(.ui(10.5, .semibold))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if state.hint || state.menu.isEmpty {
                        Text(state.menu.isEmpty ? "rien à proposer" : (state.clicking ? "clique une action" : "lâche sur une action, ou éloigne-toi"))
                            .font(.ui(9))
                            .foregroundStyle(Theme.text3)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(9)
        }
        .frame(width: 2 * r, height: 2 * r)
        .animation(.easeOut(duration: 0.12), value: state.hovered)
    }

    private var summary: String {
        let files = state.files
        if files.count == 1 { return files[0].name }
        let family = state.menu.family
        return family == .other ? Fmt.plural(files.count, "élément", "éléments") : "\(Fmt.int(files.count)) \(family.title.lowercased())"
    }
}

/// A segment of the wheel, as a shape (its frame is the wheel's whole panel).
struct WheelSectorShape: Shape {
    var index: Int
    var count: Int
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        WheelGeometry.sector(index, of: count, inner: inner, outer: outer, center: CGPoint(x: rect.midX, y: rect.midY), corner: Theme.r(9))
    }
}
