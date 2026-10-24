import SwiftUI
import AppKit

// The matter of the design system (Graphite · Arc × macOS 27): the glass of the window, the raised surfaces lit from
// above, the floating ones, and the glass bubble that marks the selection of a group.

// MARK: - Light

/// The reflection along the top edge of a raised surface: the light comes from above. It follows the top corners
/// and fades down the sides.
struct SpecularRim<S: InsettableShape>: View {
    var shape: S
    var color: Color = Theme.rim
    var fade: CGFloat = 14

    var body: some View {
        shape.strokeBorder(color, lineWidth: 1)
            .mask(alignment: .top) {
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: fade)
            }
            .allowsHitTesting(false)
    }
}

extension View {
    /// A raised surface (a card, a tile): its fill, a hairline, the reflection on top and a soft two-step shadow.
    /// `featured` lights the one card of a screen that deserves it: an accent reflection and a faint accent glow
    /// from its top-left corner.
    func raisedSurface(radius: CGFloat = 12, featured: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.r(radius), style: .continuous)
        return background {
            shape.fill(LinearGradient(colors: [Theme.cardTop, Theme.card], startPoint: .top, endPoint: .bottom))
                .overlay {
                    if featured {
                        shape.fill(RadialGradient(colors: [Theme.accentSoft, .clear], center: .topLeading, startRadius: 0, endRadius: 420))
                    }
                }
                .shadow(color: Theme.shadowNear, radius: 1, y: 1)
                .shadow(color: Theme.shadowFar, radius: 12, y: 8)
        }
        .overlay { shape.strokeBorder(Theme.border, lineWidth: Theme.line) }
        .overlay { SpecularRim(shape: shape, color: featured ? Theme.accentRim : Theme.rim, fade: max(8, Theme.r(radius))) }
    }

    /// A surface floating above the others (a panel in the middle of the window, a popover, the launcher): frosted
    /// glass, a hairline, the reflection on top and a deep shadow. `ownWindow`: the surface is a window of its own
    /// (the launcher, a small panel), its glass blurs the desktop and the apps behind it, and macOS draws its shadow.
    func floatingSurface(radius: CGFloat = 14, shadow: Bool = true, ownWindow: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.r(radius), style: .continuous)
        return background {
            ZStack {
                // Snapshots cannot draw a material: the same surface, opaque.
                if Snapshot.isActive {
                    shape.fill(Theme.cardRaised)
                } else {
                    if ownWindow { PanelGlass(radius: Theme.r(radius)) } else { shape.fill(.regularMaterial) }
                    shape.fill(Theme.floating)
                }
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Theme.border, lineWidth: Theme.line) }
        .overlay { SpecularRim(shape: shape, fade: max(10, Theme.r(radius))) }
        .shadow(color: shadow ? Theme.shadowDeep : .clear, radius: 28, y: 18)
    }

    /// The translucent bars of the stage (its toolbar, the action bar at the bottom): the page blurs as it passes under.
    func barGlass() -> some View {
        background {
            if Snapshot.isActive {
                Theme.bg.opacity(0.96)
            } else {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Theme.bg.opacity(0.72)
                }
            }
        }
    }
}

// MARK: - The window's glass

/// The material of the whole window, under the sidebar and around the stage: the desktop shows through, blurred.
struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The glass of a window of its own (the launcher, a small panel): what lies behind the window shows through, blurred,
/// cut to the window's rounded corners.
struct PanelGlass: NSViewRepresentable {
    var radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.cornerRadius = radius
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.layer?.cornerRadius = radius
    }
}

// MARK: - The glass bubble

/// Where the items of a `GlassGroup` are, by id.
struct GlassItemsKey: PreferenceKey {
    static let defaultValue: [AnyHashable: Anchor<CGRect>] = [:]
    static func reduce(value: inout [AnyHashable: Anchor<CGRect>], nextValue: () -> [AnyHashable: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// An item of the enclosing `GlassGroup`: the bubble rests on it while it is the selection.
    func glassItem<ID: Hashable>(_ id: ID) -> some View {
        anchorPreference(key: GlassItemsKey.self, value: .bounds) { [AnyHashable(id): $0] }
    }
}

/// The selection of a group (segments, sidebar, chips) as a single bubble of glass that slides from one item to the
/// next, like the bar of Apple Music: a springy move that starts as a stretched droplet, a bubble that lifts when
/// held, follows the pointer, magnifies the titles under it and lands on the nearest item. A click stays a click: the
/// items are ordinary buttons, and the bubble only moves once the click has done its work.
struct GlassGroup<ID: Hashable, Content: View>: View {
    var selection: ID?
    var axis: Axis
    /// The corner radius of the items: 6 for segments, 7 for chips, 8 for rows.
    var radius: CGFloat
    /// Selects the item the bubble was dropped on; without it, the bubble cannot be grabbed.
    var pick: ((ID) -> Void)?
    var content: Content

    /// The item the bubble shows: it follows `selection` once the new page or tab is drawn.
    @State private var shown: ID?
    @State private var frames: [ID: CGRect] = [:]
    @State private var hold: Hold?
    /// Bumped for each landing, to play the droplet.
    @State private var drops = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(selection: ID?, axis: Axis = .horizontal, radius: CGFloat = 6, pick: ((ID) -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.selection = selection
        self.axis = axis
        self.radius = radius
        self.pick = pick
        self.content = content()
        _shown = State(initialValue: selection)
    }

    private struct Hold: Equatable {
        var point: CGPoint
        var lifted: Bool
        /// Along the axis, in points per second.
        var speed: CGFloat
        /// The item under the bubble, for the haptic tick when it changes.
        var near: ID?
    }

    private static var lift: CGFloat { 4 }
    private var spring: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.66)
    }

    var body: some View {
        content
            .backgroundPreferenceValue(GlassItemsKey.self) { anchors in
                GeometryReader { proxy in
                    let rects = resolve(anchors, proxy)
                    ZStack(alignment: .topLeading) {
                        if hold?.lifted != true, let id = shown, let r = rects[id] {
                            bubble(r, lifted: false)
                        }
                        Color.clear
                            .onAppear { frames = rects }
                            .onChange(of: rects) { _, now in frames = now }
                    }
                }
            }
            .overlay {
                if let hold, hold.lifted, let r = liftedRect(hold) {
                    lens(r, hold)
                }
            }
            // An enclosing group must not take these items for its own.
            .transformPreference(GlassItemsKey.self) { $0 = [:] }
            .simultaneousGesture(drag, including: pick == nil || Snapshot.isActive ? .subviews : .all)
            .onChange(of: selection) { _, now in settle(on: now) }
    }

    private func resolve(_ anchors: [AnyHashable: Anchor<CGRect>], _ proxy: GeometryProxy) -> [ID: CGRect] {
        var out: [ID: CGRect] = [:]
        for (key, anchor) in anchors {
            if let id = key.base as? ID { out[id] = proxy[anchor] }
        }
        return out
    }

    // MARK: Drawing

    private func bubble(_ r: CGRect, lifted: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.r(radius) + (lifted ? Self.lift : 0), style: .continuous)
        return shape.fill(lifted ? Theme.bubble.opacity(0.45) : Theme.bubble)
            // A hairline keeps it visible on a white card.
            .overlay { shape.strokeBorder(Theme.border, lineWidth: Theme.line) }
            .overlay { SpecularRim(shape: shape, color: Theme.bubbleRim, fade: max(6, r.height / 2)) }
            .shadow(color: Theme.shadowFar, radius: lifted ? 4 : 1.5, y: lifted ? 4 : 1.5)
            .frame(width: r.width, height: r.height)
            .modifier(GlassDroplet(trigger: drops, axis: axis, enabled: !reduceMotion && !lifted))
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
    }

    /// The held bubble: above the items, the labels under it blurred by the glass and drawn again, magnified around
    /// the pointer and cut to its shape.
    private func lens(_ r: CGRect, _ hold: Hold) -> some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(cornerRadius: Theme.r(radius) + Self.lift, style: .continuous)
            ZStack(alignment: .topLeading) {
                if !reduceMotion {
                    shape.fill(.regularMaterial)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                    content
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(1.2, anchor: UnitPoint(x: hold.point.x / max(1, proxy.size.width),
                                                            y: hold.point.y / max(1, proxy.size.height)))
                        .mask(alignment: .topLeading) {
                            shape.frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                        }
                }
                bubble(r, lifted: true)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    // MARK: Moving

    /// The new page or tab is drawn first, the bubble moves right after: an animation started in the frame that
    /// builds a page would freeze halfway.
    private func settle(on id: ID?) {
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                guard shown != id, hold == nil else { return }
                withAnimation(spring) { shown = id }
                drops += 1
            }
        }
    }

    private func mid(_ r: CGRect) -> CGFloat { axis == .horizontal ? r.midX : r.midY }

    private func item(at p: CGPoint) -> ID? {
        frames.first { $0.value.contains(p) }?.key
    }

    private func nearest(to p: CGPoint) -> ID? {
        let along = axis == .horizontal ? p.x : p.y
        return frames.min { abs(mid($0.value) - along) < abs(mid($1.value) - along) }?.key
    }

    /// Centred on the pointer along the axis, the size of the two items it is between, grown by the lift and
    /// stretched by its speed.
    private func liftedRect(_ hold: Hold) -> CGRect? {
        let items = frames.values.sorted { mid($0) < mid($1) }
        guard let first = items.first, let last = items.last else { return nil }
        let along = min(max(axis == .horizontal ? hold.point.x : hold.point.y, mid(first)), mid(last))
        var base = first
        for (a, b) in zip(items, items.dropFirst()) where along >= mid(a) && along <= mid(b) {
            let t = mid(b) == mid(a) ? 0 : (along - mid(a)) / (mid(b) - mid(a))
            func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
            base = CGRect(x: lerp(a.minX, b.minX), y: lerp(a.minY, b.minY), width: lerp(a.width, b.width), height: lerp(a.height, b.height))
            break
        }
        if items.count == 1 { base = first }
        let stretch = reduceMotion ? 0 : min(0.2, abs(hold.speed) / 3000)
        var size = CGSize(width: base.width + Self.lift * 2, height: base.height + Self.lift * 2)
        var center = CGPoint(x: base.midX, y: base.midY)
        if axis == .horizontal {
            size.width *= 1 + stretch
            size.height *= 1 - 0.4 * stretch
            center.x = along
        } else {
            size.height *= 1 + stretch
            size.width *= 1 - 0.4 * stretch
            center.y = along
        }
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                var h = hold ?? Hold(point: v.startLocation, lifted: false, speed: 0, near: shown)
                if !h.lifted {
                    // Held on the selection, it lifts at once; elsewhere, only once the pointer has really moved.
                    guard let under = item(at: v.startLocation),
                          under == shown || hypot(v.translation.width, v.translation.height) >= 4 else {
                        hold = h
                        return
                    }
                    h.lifted = true
                }
                h.point = v.location
                h.speed = axis == .horizontal ? v.velocity.width : v.velocity.height
                let near = nearest(to: v.location)
                if near != h.near {
                    h.near = near
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.78)) { hold = h }
            }
            .onEnded { v in
                guard let h = hold, h.lifted, let target = nearest(to: v.location) else {
                    hold = nil
                    return
                }
                withAnimation(spring) {
                    hold = nil
                    shown = target
                }
                drops += 1
                if target != selection { pick?(target) }
            }
    }
}

/// The landing of the bubble: stretched along its way for an instant, then back to its shape on a bouncy spring.
private struct GlassDroplet: ViewModifier {
    var trigger: Int
    var axis: Axis
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyframeAnimator(initialValue: CGSize(width: 1, height: 1), trigger: trigger) { view, scale in
                view.scaleEffect(x: scale.width, y: scale.height)
            } keyframes: { _ in
                let along: CGFloat = 1.16, across: CGFloat = 1 - 0.4 * 0.16
                KeyframeTrack(\.width) {
                    CubicKeyframe(axis == .horizontal ? along : across, duration: 0.12)
                    SpringKeyframe(1, duration: 0.45, spring: .bouncy(duration: 0.45, extraBounce: 0.2))
                }
                KeyframeTrack(\.height) {
                    CubicKeyframe(axis == .vertical ? along : across, duration: 0.12)
                    SpringKeyframe(1, duration: 0.45, spring: .bouncy(duration: 0.45, extraBounce: 0.2))
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Chips

/// The bubble standing still on one chosen item, for a choice drawn outside a `GlassGroup`.
struct StillBubble: View {
    var radius: CGFloat = 7

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.r(radius), style: .continuous)
        shape.fill(Theme.bubble)
            .overlay { shape.strokeBorder(Theme.border, lineWidth: Theme.line) }
            .overlay { SpecularRim(shape: shape, color: Theme.bubbleRim, fade: 8) }
            .shadow(color: Theme.shadowFar, radius: 1.5, y: 1.5)
    }
}

extension View {
    /// The ground of a chip among choices: a neutral fill and a hairline, given up by the chosen one for the glass
    /// bubble (drawn by its `GlassGroup`, or here when `still` because the chip has no group).
    func chipGround(_ chosen: Bool, radius: CGFloat = 7, still: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.r(radius), style: .continuous)
        return background {
            if chosen {
                if still { StillBubble(radius: radius) }
            } else {
                shape.fill(Theme.fill1)
                    .overlay { shape.strokeBorder(Theme.border, lineWidth: Theme.line) }
            }
        }
    }
}

/// A row of chips where one is chosen (a limit, a size, a kind of file): the chosen one carries the glass bubble,
/// which slides to the next choice. `wraps` lets the chips run on several lines.
struct ChipPicker<T: Hashable>: View {
    var options: [T]
    @Binding var selection: T
    var label: (T) -> String
    var symbol: ((T) -> String?)? = nil
    var wraps = false
    var spacing: CGFloat = 5

    var body: some View {
        GlassGroup(selection: selection, axis: .horizontal, radius: 7, pick: wraps ? nil : { selection = $0 }) {
            if wraps {
                FlowLayout(spacing: spacing, lineSpacing: spacing) { chips }
            } else {
                HStack(spacing: spacing) { chips }
            }
        }
    }

    private var chips: some View {
        ForEach(options, id: \.self) { o in
            let on = o == selection
            Button { selection = o } label: {
                HStack(spacing: 4) {
                    if let s = symbol?(o), Theme.icons != .hidden { Image(systemName: s).font(.ui(10, .semibold)) }
                    Text(label(o)).font(.ui(11.5, .medium)).lineLimit(1)
                }
                .foregroundStyle(on ? Theme.text : Theme.text2)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .chipGround(on)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassItem(o)
        }
    }
}
