import SwiftUI

/// The shapes a crop or a background can take.
enum WheelRatio: String, CaseIterable, Identifiable, Sendable {
    case free, original, square, wide, tall, classic, portrait, social

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Libre"
        case .original: return "Original"
        case .square: return "1:1"
        case .wide: return "16:9"
        case .tall: return "9:16"
        case .classic: return "4:3"
        case .portrait: return "3:4"
        case .social: return "4:5"
        }
    }

    /// Width over height; nil for free (and the original, which depends on the picture).
    var value: CGFloat? {
        switch self {
        case .free, .original: return nil
        case .square: return 1
        case .wide: return 16 / 9
        case .tall: return 9 / 16
        case .classic: return 4 / 3
        case .portrait: return 3 / 4
        case .social: return 4 / 5
        }
    }

    static let crop: [WheelRatio] = [.free, .original, .square, .wide, .tall, .classic, .portrait]
    static let backdrop: [WheelRatio] = [.free, .square, .wide, .social, .tall]
}

/// The handles of the crop frame.
enum WheelCropHandle: Equatable {
    case move, top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight
}

/// The crop frame's rules, from 0 to 1 across the picture (y going down). `ratio` is width over height in those units
/// (a pixel ratio times the picture's height over its width). Pure: `selfTest` checks it.
enum WheelCropMath {
    static let minSide: CGFloat = 0.03

    /// A pixel ratio in the picture's units.
    static func unitRatio(_ pixels: CGFloat, image: CGSize) -> CGFloat {
        pixels * image.height / max(1, image.width)
    }

    static func moved(_ r: CGRect, by d: CGSize) -> CGRect {
        var o = r.offsetBy(dx: d.width, dy: d.height)
        o.origin.x = min(max(0, o.minX), 1 - o.width)
        o.origin.y = min(max(0, o.minY), 1 - o.height)
        return o
    }

    /// The largest frame of that ratio in the picture, centered on `around`.
    static func fitted(_ ratio: CGFloat, around c: CGPoint) -> CGRect {
        var w: CGFloat = 1, h: CGFloat = 1 / ratio
        if h > 1 { h = 1; w = ratio }
        let x = min(max(0, c.x - w / 2), 1 - w), y = min(max(0, c.y - h / 2), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The frame `r` with `handle` dragged by `d`, kept in the picture, at least `minSide`, and of `ratio` when given.
    static func resized(_ r: CGRect, handle: WheelCropHandle, by d: CGSize, ratio: CGFloat?) -> CGRect {
        if handle == .move { return moved(r, by: d) }
        var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
        switch handle {
        case .left, .topLeft, .bottomLeft: x0 = min(max(0, x0 + d.width), x1 - minSide)
        case .right, .topRight, .bottomRight: x1 = max(min(1, x1 + d.width), x0 + minSide)
        default: break
        }
        switch handle {
        case .top, .topLeft, .topRight: y0 = min(max(0, y0 + d.height), y1 - minSide)
        case .bottom, .bottomLeft, .bottomRight: y1 = max(min(1, y1 + d.height), y0 + minSide)
        default: break
        }
        guard let ratio else { return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) }
        var w = x1 - x0, h = y1 - y0
        switch handle {
        case .left, .right:
            // The width leads; the height follows around the middle.
            h = w / ratio
            let maxH = 2 * min(r.midY, 1 - r.midY)
            if h > maxH { h = maxH; w = h * ratio }
            let x = handle == .left ? r.maxX - w : r.minX
            return CGRect(x: x, y: r.midY - h / 2, width: w, height: h)
        case .top, .bottom:
            w = h * ratio
            let maxW = 2 * min(r.midX, 1 - r.midX)
            if w > maxW { w = maxW; h = w / ratio }
            let y = handle == .top ? r.maxY - h : r.minY
            return CGRect(x: r.midX - w / 2, y: y, width: w, height: h)
        default:
            // A corner: the side that moved most leads, the opposite corner stays.
            if w / ratio > h { h = w / ratio } else { w = h * ratio }
            let left = handle == .topLeft || handle == .bottomLeft
            let up = handle == .topLeft || handle == .topRight
            let ax = left ? r.maxX : r.minX, ay = up ? r.maxY : r.minY
            let maxW = left ? ax : 1 - ax, maxH = up ? ay : 1 - ay
            if w > maxW { w = maxW; h = w / ratio }
            if h > maxH { h = maxH; w = h * ratio }
            return CGRect(x: left ? ax - w : ax, y: up ? ay - h : ay, width: w, height: h)
        }
    }

    /// The handle under a point of the frame's view (`r` in view points), nil outside the frame.
    static func handle(at p: CGPoint, frame r: CGRect, reach: CGFloat = 12) -> WheelCropHandle? {
        let nearL = abs(p.x - r.minX) <= reach, nearR = abs(p.x - r.maxX) <= reach
        let nearT = abs(p.y - r.minY) <= reach, nearB = abs(p.y - r.maxY) <= reach
        let inX = p.x >= r.minX - reach && p.x <= r.maxX + reach, inY = p.y >= r.minY - reach && p.y <= r.maxY + reach
        if nearL && nearT { return .topLeft }
        if nearR && nearT { return .topRight }
        if nearL && nearB { return .bottomLeft }
        if nearR && nearB { return .bottomRight }
        if nearL && inY { return .left }
        if nearR && inY { return .right }
        if nearT && inX { return .top }
        if nearB && inX { return .bottom }
        return r.contains(p) ? .move : nil
    }
}

/// « Recadrer » : the frame on the picture, its ratio, its size in pixels; the cropped copy keeps the format and metadata.
struct WheelCropEditor: View {
    let context: WheelEditorContext
    @State private var preview: WheelPreview
    @State private var rect: CGRect
    @State private var ratio: WheelRatio = .free
    @State private var drag: (handle: WheelCropHandle, start: CGRect)?

    init(context: WheelEditorContext) {
        self.context = context
        _preview = State(initialValue: WheelPreview(context.file.url))
        _rect = State(initialValue: DemoData.isEnabled ? CGRect(x: 0.12, y: 0.1, width: 0.62, height: 0.72) : CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    var body: some View {
        WheelWindowChrome(title: "Recadrer l'image", subtitle: context.file.name, close: context.close) {
            VStack(alignment: .leading, spacing: 14) {
                WheelPictureView(preview: preview) { size in
                    overlay(size)
                }
                .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    WheelFieldLabel(text: "Format")
                    WheelChips(options: WheelRatio.crop, selection: $ratio, label: \.title)
                }
                HStack(spacing: 8) {
                    WheelFieldLabel(text: "Taille")
                    WheelNumberField(value: pixelWidth)
                    Text("×").font(.ui(11.5)).foregroundStyle(Theme.text3)
                    WheelNumberField(value: pixelHeight)
                    Text("px").font(.ui(11)).foregroundStyle(Theme.text3)
                    Spacer()
                }
            }
        } footer: {
            Button("Réinitialiser") { reset() }.buttonStyle(SoftButtonStyle())
            Spacer()
            Button { save() } label: { Text("Enregistrer la copie") }
                .buttonStyle(SoftButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(preview.picture == nil)
        }
        .onAppear { preview.start() }
        .onChange(of: ratio) { _, r in applyRatio(r) }
    }

    private var full: CGSize { preview.fullSize ?? preview.picture?.size ?? CGSize(width: 1, height: 1) }

    private var unitRatio: CGFloat? {
        switch ratio {
        case .free: return nil
        case .original: return 1
        default: return ratio.value.map { WheelCropMath.unitRatio($0, image: full) }
        }
    }

    private func applyRatio(_ r: WheelRatio) {
        guard let u = unitRatio else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            rect = WheelCropMath.fitted(u, around: CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    private func reset() {
        ratio = .free
        withAnimation(.easeOut(duration: 0.18)) { rect = CGRect(x: 0, y: 0, width: 1, height: 1) }
    }

    /// The width in pixels: typing it changes the frame around its middle (the height follows a fixed ratio).
    private var pixelWidth: Binding<Int> {
        Binding(get: { Int((rect.width * full.width).rounded()) }, set: { v in
            let w = min(1, max(WheelCropMath.minSide, CGFloat(v) / full.width))
            var h = rect.height
            if let u = unitRatio { h = min(1, w / u) }
            let ww = unitRatio.map { min(w, h * $0) } ?? w
            rect = WheelCropMath.moved(CGRect(x: rect.midX - ww / 2, y: rect.midY - h / 2, width: ww, height: h), by: .zero)
        })
    }

    private var pixelHeight: Binding<Int> {
        Binding(get: { Int((rect.height * full.height).rounded()) }, set: { v in
            let h = min(1, max(WheelCropMath.minSide, CGFloat(v) / full.height))
            var w = rect.width
            if let u = unitRatio { w = min(1, h * u) }
            let hh = unitRatio.map { min(h, w / $0) } ?? h
            rect = WheelCropMath.moved(CGRect(x: rect.midX - w / 2, y: rect.midY - hh / 2, width: w, height: hh), by: .zero)
        })
    }

    private func overlay(_ size: CGSize) -> some View {
        let frame = CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
        return ZStack {
            Canvas { ctx, s in
                var dim = Path(CGRect(origin: .zero, size: s))
                dim.addRect(frame)
                ctx.fill(dim, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                // Thirds, faint.
                var thirds = Path()
                for i in 1...2 {
                    let x = frame.minX + frame.width * CGFloat(i) / 3, y = frame.minY + frame.height * CGFloat(i) / 3
                    thirds.move(to: CGPoint(x: x, y: frame.minY)); thirds.addLine(to: CGPoint(x: x, y: frame.maxY))
                    thirds.move(to: CGPoint(x: frame.minX, y: y)); thirds.addLine(to: CGPoint(x: frame.maxX, y: y))
                }
                ctx.stroke(thirds, with: .color(.white.opacity(0.35)), lineWidth: 0.75)
                ctx.stroke(Path(frame), with: .color(.white.opacity(0.95)), lineWidth: 1.25)
                // The corners and the middle of the sides, in the accent, just inside the frame (whole at the picture's edge).
                var marks = Path()
                let k: CGFloat = 14
                let m = frame.insetBy(dx: 2, dy: 2)
                for (x, y, dx, dy) in [(m.minX, m.minY, 1.0, 1.0), (m.maxX, m.minY, -1.0, 1.0),
                                       (m.minX, m.maxY, 1.0, -1.0), (m.maxX, m.maxY, -1.0, -1.0)] {
                    marks.move(to: CGPoint(x: x + k * dx, y: y)); marks.addLine(to: CGPoint(x: x, y: y)); marks.addLine(to: CGPoint(x: x, y: y + k * dy))
                }
                for (a, b) in [(CGPoint(x: m.midX - 9, y: m.minY), CGPoint(x: m.midX + 9, y: m.minY)),
                               (CGPoint(x: m.midX - 9, y: m.maxY), CGPoint(x: m.midX + 9, y: m.maxY)),
                               (CGPoint(x: m.minX, y: m.midY - 9), CGPoint(x: m.minX, y: m.midY + 9)),
                               (CGPoint(x: m.maxX, y: m.midY - 9), CGPoint(x: m.maxX, y: m.midY + 9))] {
                    marks.move(to: a); marks.addLine(to: b)
                }
                ctx.stroke(marks, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { v in
                    if drag == nil {
                        if let h = WheelCropMath.handle(at: v.startLocation, frame: frame) {
                            drag = (h, rect)
                        } else {
                            // Outside the frame: a new one, drawn from there.
                            let start = CGPoint(x: v.startLocation.x / size.width, y: v.startLocation.y / size.height)
                            drag = (.bottomRight, CGRect(origin: start, size: CGSize(width: WheelCropMath.minSide, height: WheelCropMath.minSide)))
                        }
                    }
                    guard let d = drag else { return }
                    let delta = CGSize(width: v.translation.width / size.width, height: v.translation.height / size.height)
                    rect = WheelCropMath.resized(d.start, handle: d.handle, by: delta, ratio: unitRatio)
                }.onEnded { _ in drag = nil })
        }
    }

    private func save() {
        let url = context.file.url
        let r = rect
        context.save { folder, control in
            control.progress(nil)
            return try WheelImageEngine.crop(url, rect: r, quarterTurns: 0, folder: folder)
        }
    }
}
