import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Card

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    /// The one card of a screen that deserves the eye (at most one): lit by the accent.
    var featured = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(.horizontal, padding)
            .padding(.vertical, padding > 8 ? padding - 2 : padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .raisedSurface(radius: 12, featured: featured)
    }
}

/// A capsule that follows the theme's corners: a capsule in the round themes, a plain rectangle in the square ones.
struct PillShape: InsettableShape {
    var scale: CGFloat = Theme.current.radiusScale
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        if scale >= 1 { return Capsule().path(in: r) }
        return RoundedRectangle(cornerRadius: min(r.width, r.height) / 2 * scale, style: .continuous).path(in: r)
    }

    func inset(by amount: CGFloat) -> PillShape {
        var s = self
        s.inset += amount
        return s
    }
}

extension View {
    /// A drop shadow, left out by the flat themes. Always neutral: a colored glow under a surface is not light.
    func themedShadow(color: Color = .black.opacity(0.25), radius: CGFloat, y: CGFloat = 0) -> some View {
        shadow(color: Theme.current.spec.elevation == .flat ? .clear : Theme.shadowFar, radius: radius, y: y)
    }
}

/// A card with a title row.
struct Panel<Content: View, Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var tint: Color = Theme.accent
    /// The one card of the screen that deserves the eye (see `Card.featured`).
    var featured = false
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        Card(featured: featured) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let symbol, Theme.icons != .hidden {
                        Image(systemName: symbol)
                            .font(.ui(12, .medium))
                            .foregroundStyle(Theme.icons == .tinted ? tint : Theme.text3)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.ui(13, .semibold))
                            .tracking(-0.06)
                            .foregroundStyle(Theme.text)
                        if let subtitle {
                            Text(subtitle)
                                .font(.ui(12))
                                .foregroundStyle(Theme.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                content
            }
        }
    }
}

extension Panel where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String? = nil, tint: Color = Theme.accent, featured: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.featured = featured
        self.trailing = EmptyView()
        self.content = content()
    }
}

// MARK: - Equal-height row

/// A row whose cells all share the height of the tallest one.
struct TileRow<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: spacing) { content }
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Stat tile

struct StatTile: View {
    var symbol: String
    var value: String
    var label: String
    var detail: String? = nil
    var tint: Color = Theme.accent

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    if Theme.icons == .tinted {
                        IconBadge(symbol: symbol, tint: tint)
                    } else if Theme.icons == .mono {
                        Image(systemName: symbol).font(.ui(12)).foregroundStyle(Theme.text3)
                    }
                    Text(label)
                        .font(.ui(12))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                }
                Text(value)
                    .font(.figure(26))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if let detail {
                    Text(detail)
                        .font(.ui(12))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct IconBadge: View {
    var symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 22

    var body: some View {
        switch Theme.icons {
        case .tinted:
            Image(systemName: symbol)
                .font(.ui(size * 0.5, .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(PillShape().fill(tint.opacity(0.14)))
        case .mono:
            // A neutral vignette: never a background tinted by category.
            Image(systemName: symbol)
                .font(.ui(size * 0.5, .medium))
                .foregroundStyle(Theme.text2)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Theme.r(min(8, size * 0.3)), style: .continuous).fill(Theme.fill2))
        case .hidden:
            EmptyView()
        }
    }
}

// MARK: - Headers

/// The top of every section: icon, serif title, one short line and actions. What takes longer to explain goes in
/// `tip`: its « ? » sits next to the title and opens by itself the first time.
struct PageHero<Trailing: View>: View {
    var symbol: String
    var title: String
    var subtitle: String
    var tint: Color = Theme.accent
    var seed: UInt64 = 3
    var tip: HelpTip? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
                // The page's icon is already lit in the sidebar: only the tinted themes repeat it here.
                if Theme.icons == .tinted {
                    Image(systemName: symbol)
                        .font(.ui(22, .medium))
                        .foregroundStyle(tint)
                        .frame(width: 52, height: 52)
                        .background(RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous).fill(tint.opacity(0.14)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous).strokeBorder(tint.opacity(0.22)))
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(title)
                            .font(.serif(28))
                            .tracking(-0.6)
                            .foregroundStyle(Theme.text)
                        if let tip { HelpTipButton(tip: tip, size: 14) }
                    }
                    Text(subtitle)
                        .font(.ui(13))
                        .foregroundStyle(Theme.text2)
                        .frame(maxWidth: 720, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.top, 2)
            .padding(.bottom, 6)
            // The dust spills under what follows instead of pushing it down.
            .background(alignment: .topLeading) {
                DustBackdrop(seed: seed, opacity: 0.4)
                    .frame(height: 130)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                    .offset(y: -12)
                    .allowsHitTesting(false)
            }
    }
}

extension PageHero where Trailing == EmptyView {
    init(symbol: String, title: String, subtitle: String, tint: Color = Theme.accent, seed: UInt64 = 3, tip: HelpTip? = nil) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.seed = seed
        self.tip = tip
        self.trailing = EmptyView()
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.ui(11, .semibold))
            .tracking(0.66)
            .foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }
}

// MARK: - Tags and status

struct Tag: View {
    var text: String
    var symbol: String? = nil
    var tint: Color = Theme.text2
    var filled = false

    var body: some View {
        // Never a solid colored background: a neutral tag, its color in the icon and the text of a real state.
        HStack(spacing: 4) {
            if let symbol, Theme.icons != .hidden { Image(systemName: symbol).font(.ui(9.5, .semibold)) }
            Text(text).font(.ui(11, .medium)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(minHeight: 20)
        .background(RoundedRectangle(cornerRadius: Theme.r(6), style: .continuous)
            .fill(filled && Theme.icons == .tinted ? tint.opacity(0.14) : Theme.fill2))
    }
}

enum Status: Int, Comparable {
    case ok, info, warn, bad, unknown

    static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }

    var color: Color {
        switch self {
        case .ok: return Theme.good
        // Information is not a state: neutral, the accent stays for what is chosen or under way.
        case .info: return Theme.text2
        case .warn: return Theme.warn
        case .bad: return Theme.bad
        case .unknown: return Theme.text3
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .ok: return "OK"
        case .info: return "Info"
        case .warn: return "À vérifier"
        case .bad: return "À corriger"
        case .unknown: return "Inconnu"
        }
    }
}

/// A label whose decorative symbol goes away in the themes without icons.
struct ThemedLabel: View {
    var title: String
    var symbol: String

    var body: some View {
        if Theme.icons == .hidden { Text(title) } else { Label(title, systemImage: symbol) }
    }
}

struct StatusBadge: View {
    var status: Status
    var text: String? = nil

    var body: some View {
        Tag(text: text ?? status.label, symbol: status.symbol, tint: status.color, filled: true)
    }
}

// MARK: - Rows and bars

struct UsageBar: View {
    var fraction: Double
    var tint: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                PillShape().fill(Theme.track)
                PillShape().fill(tint)
                    .frame(width: max(fraction > 0 ? 4 : 0, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// A bar split in colored segments (memory breakdown, disk usage…).
struct SegmentedBar: View {
    var segments: [(value: Double, color: Color)]
    var total: Double
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    if s.value > 0 && total > 0 {
                        RoundedRectangle(cornerRadius: Theme.r(3))
                            .fill(s.color)
                            .frame(width: max(2, (g.size.width - CGFloat(segments.count) * 2) * CGFloat(s.value / total)))
                    }
                }
                Spacer(minLength: 0)
            }
            .background(RoundedRectangle(cornerRadius: Theme.r(4)).fill(Theme.track))
            .clipShape(RoundedRectangle(cornerRadius: Theme.r(4)))
        }
        .frame(height: height)
    }
}

struct LegendDot: View {
    var color: Color
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 6) {
            PillShape().fill(color).frame(width: 8, height: 8)
            Text(label).font(.ui(11.5)).foregroundStyle(Theme.text2)
            Text(value).font(.ui(11.5, .medium)).foregroundStyle(Theme.text).monospacedDigit()
        }
    }
}

struct RankRow: View {
    var symbol: String? = nil
    var name: String
    var value: String
    var fraction: Double
    var tint: Color = Theme.accent
    var detail: String? = nil

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.ui(11))
                        .foregroundStyle(tint)
                        .frame(width: 16)
                }
                Text(name)
                    .font(.ui(12.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.ui(11))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(value)
                    .font(.ui(12, .medium))
                    .foregroundStyle(Theme.text2)
                    .monospacedDigit()
            }
            UsageBar(fraction: fraction, tint: tint.opacity(hovering ? 1 : 0.85), height: 5)
                .padding(.leading, symbol != nil ? 24 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct EmptyHint: View {
    var text: String
    var symbol: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.ui(20)).foregroundStyle(Theme.text3)
            }
            Text(text)
                .font(.ui(12))
                .foregroundStyle(Theme.text3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 70)
    }
}

/// A hoverable row background.
struct HoverRow<Content: View>: View {
    var selected = false
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        // A selected row: the faint accent and a thin accent edge on its left.
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous).fill(selected ? Theme.accentSoft : (hovering ? Theme.fill1 : .clear)))
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(Theme.accent).frame(width: 2).padding(.vertical, 6) }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Callout

struct Callout: View {
    var symbol: String = "lightbulb"
    var title: String
    var text: String
    var tint: Color = Theme.accent

    var body: some View {
        let tinted = Theme.icons == .tinted
        HStack(alignment: .top, spacing: 12) {
            if Theme.icons != .hidden {
                Image(systemName: symbol)
                    .font(.ui(13, .medium))
                    .foregroundStyle(tinted ? tint : Theme.text2)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(tinted ? tint.opacity(0.14) : .clear))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.ui(12.5, .semibold))
                    .foregroundStyle(Theme.text)
                Text(text)
                    .font(.ui(12))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).fill(tinted ? tint.opacity(0.07) : Theme.fill1))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous)
            .strokeBorder(tinted ? tint.opacity(0.18) : Theme.border, lineWidth: tinted ? 1 : max(1, Theme.line)))
    }
}

// MARK: - Segmented pills

struct PillPicker<T: Hashable & Identifiable>: View {
    var options: [T]
    @Binding var selection: T
    var label: (T) -> String
    var badge: ((T) -> String?)? = nil

    var body: some View {
        // The segment chosen carries the glass bubble; no accent on a segmented control.
        GlassGroup(selection: selection, axis: .horizontal, radius: 6, pick: { selection = $0 }) {
            HStack(spacing: 0) {
                ForEach(options) { o in
                    let on = o == selection
                    Button {
                        selection = o
                    } label: {
                        HStack(spacing: 5) {
                            Text(label(o))
                                .font(.ui(12, .medium))
                            if let b = badge?(o) {
                                Text(b)
                                    .font(.ui(10.5, .semibold))
                                    .foregroundStyle(Theme.text3)
                                    .monospacedDigit()
                            }
                        }
                        .foregroundStyle(on ? Theme.text : Theme.text2)
                        .animation(.easeOut(duration: 0.2), value: on)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .glassItem(o)
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous).fill(Theme.fill1))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
    }
}

// MARK: - Rings and gauges

struct ProgressRing: View {
    var progress: Double
    var tint: Color = Theme.accent
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)
        }
    }
}

/// A ring with its value in the middle.
struct Gauge: View {
    var value: Double
    var text: String
    var caption: String? = nil
    var tint: Color = Theme.accent
    var size: CGFloat = 64
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            ProgressRing(progress: value, tint: tint, lineWidth: lineWidth)
            VStack(spacing: 0) {
                Text(text)
                    .font(.serif(size * 0.27))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let caption {
                    Text(caption)
                        .font(.ui(size * 0.13))
                        .foregroundStyle(Theme.text3)
                }
            }
            .padding(lineWidth + 4)
        }
        .frame(width: size, height: size)
    }
}

/// A small line chart drawn with a Canvas (cheap enough for the menu bar).
struct Sparkline: View {
    var values: [Double]
    var maxValue: Double? = nil
    var tint: Color = Theme.accent
    var fill = true

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let top = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: size.height - size.height * CGFloat(min(1, v / top)))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            if fill {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.32), tint.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Checkbox

enum CheckState { case on, off, mixed }

struct CheckBox: View {
    var state: CheckState
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.r(4.5), style: .continuous)
                    .fill(state == .off ? Theme.fill3 : Theme.accent)
                RoundedRectangle(cornerRadius: Theme.r(4.5), style: .continuous)
                    .strokeBorder(state == .off ? Theme.borderStrong : Theme.accent, lineWidth: 1)
                if state == .on {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.onAccent)
                } else if state == .mixed {
                    Image(systemName: "minus").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.onAccent)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

// MARK: - Buttons

struct SoftButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        let filled = prominent || destructive
        let shape = RoundedRectangle(cornerRadius: Theme.r(small ? 7 : 8), style: .continuous)
        configuration.label
            .font(.ui(small ? 12 : 13, .medium))
            .foregroundStyle(destructive ? Theme.onBad : (prominent ? Theme.onAccent : Theme.text))
            .padding(.horizontal, small ? 10 : 14)
            .frame(minHeight: small ? 24 : 30)
            .background {
                if filled {
                    // A solid button, lit from above.
                    shape.fill(destructive ? Theme.bad : Theme.accent)
                        .overlay { SpecularRim(shape: shape, color: .white.opacity(0.22), fade: 8) }
                        .shadow(color: Theme.shadowNear, radius: 1, y: 1)
                } else {
                    // A glass button: a neutral fill, a hairline and the reflection on top.
                    shape.fill(Theme.fill2)
                        .overlay { shape.strokeBorder(Theme.border, lineWidth: Theme.line) }
                        .overlay { SpecularRim(shape: shape, fade: 8) }
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// The big "Analyser" button of each section. While it runs, the mascot works inside it.
struct ScanButton: View {
    var title: String
    var symbol: String = "sparkle.magnifyingglass"
    var running = false
    var runningTitle = "Analyse…"
    /// What the mascot does while it runs.
    var activity: MascotActivity = .inspecting
    var action: () -> Void

    var body: some View {
        // While it runs it ignores clicks without looking disabled: the mascot inside stays bright.
        Button { if !running { action() } } label: {
            HStack(spacing: 8) {
                if running {
                    BusyMascot(activity, pixel: 1, ink: Theme.onAccent)
                } else if Theme.icons != .hidden {
                    Image(systemName: symbol).font(.ui(13, .semibold))
                }
                Text(running ? runningTitle : title).font(.ui(13, .semibold))
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 16)
            .frame(minHeight: 32)
            .background {
                let shape = RoundedRectangle(cornerRadius: Theme.r(9), style: .continuous)
                shape.fill(Theme.accent)
                    .overlay { SpecularRim(shape: shape, color: .white.opacity(0.22), fade: 8) }
                    .shadow(color: Theme.shadowNear, radius: 1, y: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!running)
    }
}

// MARK: - Icons

/// The Finder icon of a file or app. In demo mode nothing is looked up on disk: fictional apps get a drawn icon,
/// everything else the generic icon of its type.
struct FileIcon: View {
    var path: String
    var size: CGFloat = 24
    /// The file's own icon once read in the background (a file on a slow disk never holds the main thread).
    @State private var loaded: (path: String, image: CGImage)?

    var body: some View {
        Group {
            if DemoData.isEnabled, let icon = DemoData.icon(for: path) {
                DrawnAppIcon(icon: icon, size: size)
            } else if let cg = image {
                Image(decorative: cg, scale: 2).resizable().interpolation(.high)
            } else {
                Image(systemName: "doc").resizable().scaledToFit().foregroundStyle(Theme.text3)
            }
        }
        .frame(width: size, height: size)
        .task(id: path) {
            guard !DemoData.isEnabled, !Snapshot.isActive, IconCache.cached(path) == nil else { return }
            let target = path
            let cg = await DiskQueue.read { IconCache.icon(for: target) } ?? nil
            if let cg, !Task.isCancelled { loaded = (target, cg) }
        }
    }

    /// Snapshots draw at once, without the background read; otherwise the icon of the type stands in until the file's own.
    private var image: CGImage? {
        if DemoData.isEnabled { return IconCache.genericIcon(for: path) }
        if Snapshot.isActive { return IconCache.icon(for: path) }
        if let loaded, loaded.path == path { return loaded.image }
        return IconCache.cached(path) ?? IconCache.genericIcon(for: path)
    }
}

/// An app icon made of a gradient tile and a symbol, for the fictional apps of the demo.
struct DrawnAppIcon: View {
    var icon: DemoData.Icon
    var size: CGFloat

    var body: some View {
        // Like real icons, the tile leaves a margin around it.
        let s = size * 0.84
        let tile = RoundedRectangle(cornerRadius: s * 0.23, style: .continuous)
        ZStack {
            tile.fill(LinearGradient(colors: [Color(hex: icon.top), Color(hex: icon.bottom)], startPoint: .top, endPoint: .bottom))
            tile.strokeBorder(.white.opacity(0.14), lineWidth: max(0.5, s * 0.012))
            if icon.brand {
                BrandMark(size: s * 0.66, ornament: false)
            } else {
                Image(systemName: icon.symbol)
                    .font(.system(size: s * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: s, height: s)
        .shadow(color: .black.opacity(0.25), radius: s * 0.03, y: s * 0.02)
        .frame(width: size, height: size)
    }
}

/// Finder icons, flattened to bitmaps once (lazy icon images do not render well off screen).
enum IconCache {
    nonisolated(unsafe) private static var cache: [String: CGImage] = [:]
    private static let lock = NSLock()

    static func icon(for path: String) -> CGImage? {
        flattened(path) { NSWorkspace.shared.icon(forFile: path) }
    }

    /// The icon of `path` if it was already read, without touching the disk.
    static func cached(_ path: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache[path]
    }

    /// The icon macOS gives a type of file (or a folder), guessed from the extension without opening anything.
    static func genericIcon(for path: String) -> CGImage? {
        let ext = (path as NSString).pathExtension
        var type = UTType(filenameExtension: ext).flatMap { $0.isDynamic ? nil : $0 }
        if type == nil {
            switch FileKind(ext: ext.lowercased()) {
            case .video: type = .movie
            case .archive: type = .archive
            case .diskImage: type = .diskImage
            case .audio: type = .audio
            case .image: type = .image
            case .document: type = .pdf
            case .all, .other: type = .folder
            }
        }
        let t = type ?? .folder
        return flattened("type:" + t.identifier) { NSWorkspace.shared.icon(for: t) }
    }

    private static func flattened(_ key: String, _ make: () -> NSImage) -> CGImage? {
        if let img = cached(key) { return img }
        // Read and drawn without the lock: a slow file (a network disk) never holds up the icons of the others.
        // Redrawn into a plain sRGB bitmap: icons may come in wide color spaces that skew off-screen renders.
        let side = 128
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let icon = make()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // The app lives for weeks in the menu bar: thousands of files must not keep their icons forever.
        if cache.count > 600 { cache.removeAll(keepingCapacity: true) }
        cache[key] = cg
        return cg
    }
}

// MARK: - Snapshot stand-ins

// `ImageRenderer` draws AppKit-backed controls as yellow boxes and leaves scroll views empty.
// While `--snapshot` renders, these swap them for plain SwiftUI drawings that look the same at rest.

/// A scroll view, or just its content (top-aligned and clipped) in snapshots.
struct ScrollArea<Content: View>: View {
    var axes: Axis.Set = .vertical
    var showsIndicators = true
    @ViewBuilder var content: Content

    var body: some View {
        if !Snapshot.isActive {
            ScrollView(axes, showsIndicators: showsIndicators) { content }
        } else if axes == .horizontal {
            content.fixedSize().frame(maxWidth: .infinity, alignment: .leading).clipped()
        } else {
            content.fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
        }
    }
}

/// A borderless pop-up menu, or just its label in snapshots.
struct BorderlessMenu<Items: View, Label: View>: View {
    var indicator = true
    @ViewBuilder var items: Items
    @ViewBuilder var label: Label

    var body: some View {
        if Snapshot.isActive {
            HStack(spacing: 4) {
                label
                if indicator {
                    Image(systemName: "chevron.down").font(.ui(8.5, .bold)).foregroundStyle(Theme.text3)
                }
            }
            .fixedSize()
        } else {
            Menu { items } label: { label }
                .menuStyle(.borderlessButton)
                .menuIndicator(indicator ? .visible : .hidden)
                .fixedSize()
        }
    }
}

/// A switch drawn with shapes.
struct DrawnSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
            Spacer(minLength: 8)
            PillShape()
                .fill(configuration.isOn ? Theme.accent : Theme.fill3)
                .frame(width: 30, height: 17)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    PillShape().fill(configuration.isOn ? Theme.onAccent : .white).padding(2).frame(width: 17, height: 17)
                }
                .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

extension View {
    /// `.toggleStyle(.switch)`, drawn by hand in snapshots.
    @ViewBuilder
    func switchToggles() -> some View {
        if Snapshot.isActive { toggleStyle(DrawnSwitchStyle()) } else { toggleStyle(.switch) }
    }
}

// MARK: - Flow layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width && x > 0 { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
        return CGSize(width: width, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += lineH + lineSpacing; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}

// MARK: - Helpers

extension View {
    /// Shows a native confirmation alert before running a destructive action.
    func confirmAction(_ title: String, message: String, button: String, isPresented: Binding<Bool>,
                       destructive: Bool = true, action: @escaping () -> Void) -> some View {
        alert(title, isPresented: isPresented) {
            Button(button, role: destructive ? .destructive : nil, action: action)
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

enum Finder {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}
