import SwiftUI
import AppKit

// MARK: - Glass

/// The frosted glass of the wheel and its little windows: what is behind shows through, blurred, under a veil of the
/// theme's own colors (its card, a breath of accent and brand), so it stays in the app's world rather than plain grey.
/// Snapshots cannot draw the blur: they get the veil alone, more opaque.
struct WheelGlass: View {
    /// nil: a circle.
    var corner: CGFloat?
    /// How much of the theme's card covers the blur (0…1).
    var veil: Double = 0.5
    /// Drawn inside a window of the app (the settings' wheel): it blurs the window's own content, not the desktop.
    var inWindow = false

    var body: some View {
        if let corner {
            layers(RoundedRectangle(cornerRadius: corner, style: .continuous))
        } else {
            layers(Circle())
        }
    }

    private func layers<S: InsettableShape>(_ shape: S) -> some View {
        ZStack {
            if Snapshot.isActive {
                shape.fill(Theme.cardRaised.opacity(inWindow ? 0.7 : 0.96))
            } else if inWindow {
                shape.fill(.ultraThinMaterial)
            } else {
                WheelBlur(corner: corner)
            }
            shape.fill(LinearGradient(colors: [Theme.card.opacity(veil), Theme.card.opacity(veil * 0.55)],
                                      startPoint: .top, endPoint: .bottom))
            shape.fill(LinearGradient(colors: [Theme.accent.opacity(0.10), .clear, Theme.brand.opacity(0.09)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            // The edge catches the light at the top, like a pane of glass.
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.42), Color.white.opacity(0.06)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
            shape.inset(by: 0.5).strokeBorder(Theme.borderStrong.opacity(0.55), lineWidth: Theme.line)
        }
    }
}

/// The blur itself, cut to its shape by a mask (a clipped visual effect view would still blur its whole square).
private struct WheelBlur: NSViewRepresentable {
    var corner: CGFloat?

    func makeNSView(context: Context) -> WheelBlurView {
        let v = WheelBlurView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.corner = corner
        return v
    }

    func updateNSView(_ v: WheelBlurView, context: Context) {
        if v.corner != corner {
            v.corner = corner
            v.needsLayout = true
        }
    }
}

final class WheelBlurView: NSVisualEffectView {
    var corner: CGFloat?
    private var maskedSize: NSSize = .zero

    override func layout() {
        super.layout()
        guard bounds.size != maskedSize, bounds.width > 0, bounds.height > 0 else { return }
        maskedSize = bounds.size
        let size = bounds.size
        let radius = corner ?? min(size.width, size.height) / 2
        maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }
}

// MARK: - Windows

/// The small windows of the wheel: borderless, they float above the other apps without bringing Heartware to the front,
/// take the keyboard (sizes, text) and stay until closed (× or Esc), even when the user clicks elsewhere.
final class WheelWindow: NSPanel {
    var onClose: (() -> Void)?

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        // Moved by its title bar only: a drag in the picture draws, crops or moves a shape.
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func close() {
        super.close()
        onClose?()
    }

    func setContent<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        contentView = host
    }

    /// Next to where the file was dropped, whole on its screen.
    func present(near point: NSPoint) {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: point.x - frame.width / 2, y: point.y - frame.height / 2)
        if let f = screen?.visibleFrame {
            origin.x = min(max(origin.x, f.minX + 12), f.maxX - frame.width - 12)
            origin.y = min(max(origin.y, f.minY + 12), f.maxY - frame.height - 12)
        }
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
    }
}

/// A strip that moves its window when dragged (the title bar of the wheel's windows).
struct WheelMoveArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WheelMoveView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WheelMoveView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override var mouseDownCanMoveWindow: Bool { true }
}

/// The frame of every window of the wheel: glass, a title bar with × on the left, the content, and its buttons at the bottom.
struct WheelWindowChrome<Content: View, Footer: View>: View {
    var title: String
    var subtitle: String?
    var close: () -> Void
    /// Its « ? » on the right of the title bar, open by itself the first time.
    var tip: HelpTip? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Snapshots cannot draw an AppKit view (a yellow box).
                if !Snapshot.isActive { WheelMoveArea() }
                VStack(spacing: 1) {
                    Text(title).font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                    if let subtitle {
                        Text(subtitle).font(.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 48)
                .allowsHitTesting(false)
                HStack {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.ui(9.5, .bold))
                            .foregroundStyle(Theme.text2)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Theme.track.opacity(0.8)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Fermer sans rien enregistrer (Échap)")
                    Spacer()
                    if let tip { HelpTipButton(tip: tip, size: 13) }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: subtitle == nil ? 42 : 48)
            content
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            HStack(spacing: 10) { footer }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
        .background(WheelGlass(corner: Theme.r(18), veil: 0.72))
        .clipShape(RoundedRectangle(cornerRadius: Theme.r(18), style: .continuous))
    }
}

/// A small label above a group of controls in the wheel's windows.
struct WheelFieldLabel: View {
    var text: String

    var body: some View {
        Text(text).font(.ui(11, .medium)).foregroundStyle(Theme.text2)
    }
}

/// Little pills for a choice among a few (ratios, formats, tools), drawn with shapes so snapshots show them.
struct WheelChips<T: Hashable>: View {
    var options: [T]
    @Binding var selection: T
    var label: (T) -> String
    var symbol: ((T) -> String?)? = nil

    var body: some View {
        ChipPicker(options: options, selection: $selection, label: label, symbol: symbol, spacing: 3)
    }
}

/// A slider drawn with shapes (the AppKit one comes out as a yellow box in snapshots), with its value on the right.
struct WheelSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var text: String

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { g in
                let w = g.size.width
                let f = (value - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    PillShape().fill(Theme.track).frame(height: 4)
                    PillShape().fill(Theme.accent).frame(width: max(4, w * f), height: 4)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .themedShadow(color: .black.opacity(0.2), radius: 2, y: 1)
                        .offset(x: max(0, min(w - 14, w * f - 7)))
                }
                .frame(height: g.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let x = min(max(0, v.location.x), w) / max(1, w)
                    value = range.lowerBound + x * (range.upperBound - range.lowerBound)
                })
            }
            .frame(height: 18)
            Text(text).font(.ui(11).monospacedDigit()).foregroundStyle(Theme.text3).frame(width: 54, alignment: .trailing)
        }
    }
}
