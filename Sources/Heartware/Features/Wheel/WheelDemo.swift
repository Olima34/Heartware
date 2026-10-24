import SwiftUI

/// Made-up content for `--demo` and the snapshots: a mountain photo drawn here, pages, marks.
@MainActor
enum WheelDemo {
    static var desktop: String { DemoData.home + "/Desktop" }

    static func file(_ name: String, _ kind: ConverterKind) -> WheelFile {
        WheelFile(url: URL(fileURLWithPath: desktop + "/" + name), kind: kind)
    }

    static let photoInfo = WheelPhotoInfo(rows: [
        .init(label: "Prise le", value: "14 juil. 2026 à 18:32", symbol: "calendar", personal: true),
        .init(label: "Appareil", value: "iPhone 15 Pro", symbol: "camera", personal: true),
        .init(label: "Réglages", value: "f/1,8 · 1/640 s · ISO 50 · 6,9 mm", symbol: "dial.medium", personal: false),
        .init(label: "Position", value: "45,833° N, 6,865° E · 1 035 m", symbol: "location.fill", personal: true),
        .init(label: "Logiciel", value: "18.0", symbol: "app.badge", personal: true),
        .init(label: "Dimensions", value: "4 032 × 2 688 px", symbol: "aspectratio", personal: false),
    ], latitude: 45.8326, longitude: 6.8652)

    nonisolated static func marks(redacting: Bool) -> [WheelMark] {
        if redacting {
            return [
                WheelMark(kind: .redact, points: [CGPoint(x: 0.06, y: 0.08), CGPoint(x: 0.36, y: 0.2)], redaction: .black),
                WheelMark(kind: .redact, points: [CGPoint(x: 0.6, y: 0.24), CGPoint(x: 0.8, y: 0.52)], redaction: .pixels),
            ]
        }
        return [
            WheelMark(kind: .arrow, points: [CGPoint(x: 0.2, y: 0.78), CGPoint(x: 0.44, y: 0.42)], color: 0, width: 0.007),
            WheelMark(kind: .oval, points: [CGPoint(x: 0.4, y: 0.22), CGPoint(x: 0.62, y: 0.48)], color: 0, width: 0.006),
            WheelMark(kind: .text, points: [CGPoint(x: 0.08, y: 0.8)], color: 7, width: 0.008, text: "Le sommet !"),
            WheelMark(kind: .step, points: [CGPoint(x: 0.7, y: 0.62)], color: 4, width: 0.007, number: 1),
            WheelMark(kind: .highlight, points: [CGPoint(x: 0.66, y: 0.14), CGPoint(x: 0.92, y: 0.24)], color: 2, width: 0.006),
        ]
    }

    // MARK: Pictures

    private static var photos: [String: CGImage] = [:]

    /// A mountain at sunset, drawn: the picture of every window in the demo.
    static func photo(width: Int, height: Int) -> CGImage {
        let key = "\(width)x\(height)"
        if let p = photos[key] { return p }
        let w = CGFloat(width), h = CGFloat(height)
        let ctx = WheelImageEngine.context(width: width, height: height, alpha: false)!
        // Core Graphics' y goes up.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let sky = CGGradient(colorsSpace: space, colors: [WheelRGB(0xF7C59F).cg, WheelRGB(0xEFA6A0).cg, WheelRGB(0x7FA7D9).cg] as CFArray,
                             locations: [0, 0.35, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h * 0.3), end: CGPoint(x: 0, y: h), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.setFillColor(WheelRGB(0xFFF1C9).cg)
        ctx.setShadow(offset: .zero, blur: w * 0.06, color: WheelRGB(0xFFE2A0).cg)
        ctx.fillEllipse(in: CGRect(x: w * 0.68, y: h * 0.56, width: w * 0.1, height: w * 0.1))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        func ridge(_ points: [(CGFloat, CGFloat)], _ color: UInt32) {
            ctx.setFillColor(WheelRGB(color).cg)
            ctx.move(to: CGPoint(x: 0, y: 0))
            for (x, y) in points { ctx.addLine(to: CGPoint(x: x * w, y: y * h)) }
            ctx.addLine(to: CGPoint(x: w, y: 0))
            ctx.closePath()
            ctx.fillPath()
        }
        ridge([(0, 0.42), (0.14, 0.55), (0.26, 0.47), (0.4, 0.62), (0.55, 0.5), (0.7, 0.58), (0.86, 0.46), (1, 0.52)], 0x9AA8C7)
        ridge([(0, 0.3), (0.12, 0.38), (0.3, 0.5), (0.46, 0.72), (0.6, 0.48), (0.78, 0.4), (1, 0.33)], 0x5E6E8F)
        // Snow on the main peak.
        ctx.setFillColor(WheelRGB(0xF4F7FB).cg)
        ctx.move(to: CGPoint(x: 0.46 * w, y: 0.72 * h))
        ctx.addLine(to: CGPoint(x: 0.4 * w, y: 0.62 * h))
        ctx.addLine(to: CGPoint(x: 0.44 * w, y: 0.64 * h))
        ctx.addLine(to: CGPoint(x: 0.47 * w, y: 0.6 * h))
        ctx.addLine(to: CGPoint(x: 0.51 * w, y: 0.63 * h))
        ctx.addLine(to: CGPoint(x: 0.54 * w, y: 0.6 * h))
        ctx.closePath()
        ctx.fillPath()
        let meadow = CGGradient(colorsSpace: space, colors: [WheelRGB(0x3F7D4A).cg, WheelRGB(0x7DB46C).cg] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.move(to: .zero)
        ctx.addLine(to: CGPoint(x: 0, y: h * 0.2))
        ctx.addCurve(to: CGPoint(x: w, y: h * 0.16), control1: CGPoint(x: w * 0.3, y: h * 0.3), control2: CGPoint(x: w * 0.7, y: h * 0.08))
        ctx.addLine(to: CGPoint(x: w, y: 0))
        ctx.closePath()
        ctx.clip()
        ctx.drawLinearGradient(meadow, start: .zero, end: CGPoint(x: 0, y: h * 0.3), options: [])
        ctx.restoreGState()
        let image = ctx.makeImage()!
        photos[key] = image
        return image
    }

    /// A page of a made-up document (title, lines, a picture block on some).
    static func page(_ n: Int) -> CGImage {
        let w = 160, h = 220
        let ctx = WheelImageEngine.context(width: w, height: h, alpha: false)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(WheelRGB([0x5B8DEF, 0xE8577A, 0x5FB86A, 0xF08A2E][n % 4]).cg)
        ctx.fill(CGRect(x: 14, y: h - 30, width: 80, height: 9))
        ctx.setFillColor(CGColor(gray: 0.78, alpha: 1))
        var y = h - 48
        var line = 0
        while y > 18 {
            if n % 3 == 1 && line == 3 {
                ctx.setFillColor(CGColor(gray: 0.88, alpha: 1))
                ctx.fill(CGRect(x: 14, y: CGFloat(y - 50), width: CGFloat(w - 28), height: 54))
                ctx.setFillColor(CGColor(gray: 0.78, alpha: 1))
                y -= 62
            }
            let len = CGFloat(w - 28) * (line % 5 == 4 ? 0.55 : 1)
            ctx.fill(CGRect(x: 14, y: CGFloat(y), width: len, height: 4))
            y -= 10
            line += 1
        }
        return ctx.makeImage()!
    }

    // MARK: Snapshots

    /// The panels `--snapshot --demo --page wheel` draws besides the page: the wheel over a desktop, the Convertisseur's
    /// window (`--tab pdf`, `video`, `renommer`, `qr`, `vide`… for another scene), a few more of its scenes, the small
    /// windows and the toast.
    static func panels(_ app: AppModel) -> [(name: String, view: AnyView, width: CGFloat)] {
        let m = app.wheel
        let photo = file("Sommet.jpg", .image)
        func editor(_ kind: WheelEditorKind, _ action: WheelAction, _ files: [WheelFile]) -> (String, AnyView, CGFloat) {
            let size = WheelEditors.size(kind)
            let context = WheelEditorContext(action: action, files: files, point: .zero, model: m)
            return ("wheel-\(action.rawValue)-panel",
                    AnyView(WheelEditors.view(kind, context: context).frame(width: size.width, height: size.height)
                        .padding(36).background(WheelSnapshotDesktop())),
                    size.width + 72)
        }
        let wheel = AnyView(WheelSnapshotWheel().frame(width: 640, height: 520))
        m.runner.loadDemo()
        let toast = AnyView(WheelToastView(runner: m.runner, toast: m.runner.toast).padding(30).background(WheelSnapshotDesktop()))
        func hub(_ model: ConverterModel) -> AnyView {
            AnyView(ConverterHubView(model: model, close: {})
                .frame(width: ConverterHub.size.width, height: ConverterHub.size.height)
                .padding(36).background(WheelSnapshotDesktop()))
        }
        let hubWidth = ConverterHub.size.width + 72
        var out: [(String, AnyView, CGFloat)] = [("wheel-panel", wheel, 640), ("wheel-toast-panel", toast, WheelToast.width + 60),
                                                 ("wheel-hub-panel", hub(app.converter), hubWidth)]
        if DemoData.isEnabled {
            for (name, scene) in [("merge", ConverterDemo.Scene.pdf), ("rename", .rename), ("qr", .qr), ("cutout", .cutout)] {
                let other = ConverterModel()
                ConverterDemo.fill(other, scene: scene)
                out.append(("wheel-hub-\(name)-panel", hub(other), hubWidth))
            }
        }
        out.append(editor(.crop, .crop, [photo]))
        out.append(editor(.backdrop, .backdrop, [photo]))
        out.append(editor(.annotate, .annotate, [photo]))
        out.append(editor(.redact, .redact, [photo]))
        out.append(editor(.shrink, .compress, [photo]))
        out.append(editor(.metadata, .metadata, [photo]))
        out.append(editor(.pages, .pdfPages, [file("Contrat.pdf", .pdf)]))
        out.append(editor(.trim, .trim, [file("Vacances.mov", .video)]))
        out.append(editor(.videoCompress, .videoCompress, [file("Vacances.mov", .video)]))
        return out.map { (name: $0.0, view: $0.1, width: $0.2) }
    }
}

/// The wheel over a desktop, for the family of `--tab` (read when drawn: the tab is applied after the panels are listed).
struct WheelSnapshotWheel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.wheel
        let sample = m.family == .image ? WheelDemo.file("Sommet.jpg", .image) : WheelModel.sample(m.family)
        let state = WheelOverlayState()
        state.files = [sample]
        state.menu = m.menu(for: [sample])
        state.shown = true
        state.hint = true
        state.hovered = state.menu.tools.isEmpty ? .format(0) : .tool(0)
        return ZStack {
            WheelSnapshotDesktop()
            WheelView(state: state)
        }
    }
}

/// A desktop behind the wheel in the snapshots: the demo photo, a little darker.
struct WheelSnapshotDesktop: View {
    var body: some View {
        ZStack {
            Image(decorative: WheelDemo.photo(width: 1280, height: 853), scale: 1).resizable().aspectRatio(contentMode: .fill)
            Color.black.opacity(0.08)
        }
        .clipped()
    }
}
