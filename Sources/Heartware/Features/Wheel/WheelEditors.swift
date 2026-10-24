import SwiftUI
import AppKit

/// What every window of the wheel gets: its files, a way to close, and a way to start the work it prepared.
@MainActor
final class WheelEditorContext {
    let action: WheelAction
    let files: [WheelFile]
    let point: NSPoint
    weak var model: WheelModel?
    var close: () -> Void = {}

    init(action: WheelAction, files: [WheelFile], point: NSPoint, model: WheelModel?) {
        self.action = action
        self.files = files
        self.point = point
        self.model = model
    }

    var file: WheelFile { files[0] }

    /// Closes the window and runs `work` in the toast (where the copy goes is decided there).
    func save(_ work: @escaping @Sendable (_ folder: URL?, _ control: ConverterControl) async throws -> URL) {
        saveMany { folder, control in [try await work(folder, control)] }
    }

    func saveMany(_ work: @escaping @Sendable (_ folder: URL?, _ control: ConverterControl) async throws -> [URL]) {
        guard let model else { return }
        guard !DemoData.isEnabled else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        let destination = model.settings.destination, custom = model.settings.folder
        let input = file.url
        close()
        model.runner.run(action, files: files, at: point) { control, _ in
            let place = WheelJobs.folder(for: input, destination: destination, custom: custom)
            let outputs = try await work(place.folder, control)
            return WheelResult(outputs: outputs, note: place.note)
        }
    }
}

/// Opens the small windows of the wheel next to where the files were dropped, and keeps them alive while they are open.
@MainActor
final class WheelEditors {
    private var windows: [ObjectIdentifier: WheelWindow] = [:]

    var openCount: Int { windows.count }

    func open(_ kind: WheelEditorKind, action: WheelAction, files: [WheelFile], at point: NSPoint, model: WheelModel) {
        guard !files.isEmpty else { return }
        let context = WheelEditorContext(action: action, files: files, point: point, model: model)
        let size = Self.size(kind)
        let window = WheelWindow(size: size)
        let id = ObjectIdentifier(window)
        window.onClose = { [weak self] in
            DispatchQueue.main.async { self?.windows[id] = nil }
        }
        context.close = { [weak window] in window?.close() }
        window.setContent(Self.view(kind, context: context).frame(width: size.width, height: size.height))
        windows[id] = window
        window.present(near: point)
    }

    func closeAll() {
        for w in windows.values { w.close() }
        windows.removeAll()
    }

    static func size(_ kind: WheelEditorKind) -> NSSize {
        switch kind {
        case .crop: return NSSize(width: 460, height: 590)
        case .backdrop: return NSSize(width: 460, height: 640)
        case .annotate, .redact: return NSSize(width: 600, height: 600)
        case .shrink: return NSSize(width: 400, height: 430)
        case .metadata: return NSSize(width: 400, height: 470)
        case .pages: return NSSize(width: 500, height: 580)
        case .trim, .frame: return NSSize(width: 600, height: 470)
        case .videoCompress: return NSSize(width: 380, height: 400)
        }
    }

    @ViewBuilder
    static func view(_ kind: WheelEditorKind, context: WheelEditorContext) -> some View {
        Group {
            switch kind {
            case .crop: WheelCropEditor(context: context)
            case .backdrop: WheelBackdropEditor(context: context)
            case .annotate: WheelMarkupEditor(context: context, redacting: false)
            case .redact: WheelMarkupEditor(context: context, redacting: true)
            case .shrink: WheelShrinkEditor(context: context)
            case .metadata: WheelMetadataEditor(context: context)
            case .pages: WheelPagesEditor(context: context)
            case .trim, .frame: WheelPlayerEditor(context: context, capturing: kind == .frame)
            case .videoCompress: WheelVideoCompressEditor(context: context)
            }
        }
    }
}

/// A picture read for a window, small enough to stay quick, in the background (at once in the demo).
@Observable
@MainActor
final class WheelPreview {
    var picture: WheelImageEngine.Picture?
    var failed: String?
    /// The size of the original, in pixels (upright).
    var fullSize: CGSize?
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let maxSide: Int
    @ObservationIgnored private var started = false

    init(_ url: URL, maxSide: Int = 1600) {
        self.url = url
        self.maxSide = maxSide
        if DemoData.isEnabled {
            let image = WheelDemo.photo(width: 1500, height: 1000)
            picture = WheelImageEngine.Picture(image: image, uti: "public.jpeg", properties: [:], hasAlpha: false)
            fullSize = CGSize(width: 4032, height: 2688)
        }
    }

    func start() {
        guard !started, picture == nil else { return }
        started = true
        let url = url, maxSide = maxSide
        Task {
            let read: Result<(WheelImageEngine.Picture, CGSize), Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let p = try WheelImageEngine.load(url, maxSide: maxSide)
                    return .success((p, WheelImageEngine.uprightSize(url) ?? p.size))
                } catch {
                    return .failure(error)
                }
            }.value
            switch read {
            case .success(let (p, full)):
                picture = p
                fullSize = full
            case .failure(let error):
                failed = error.localizedDescription
            }
        }
    }
}

/// The picture of a window, fitted in its space; `overlay` draws on top of it, in the picture's own frame.
struct WheelPictureView<Overlay: View>: View {
    let preview: WheelPreview
    @ViewBuilder var overlay: (CGSize) -> Overlay

    var body: some View {
        GeometryReader { g in
            if let p = preview.picture {
                let fit = WheelFit.size(p.size, in: g.size)
                ZStack {
                    WheelCheckerboard().opacity(p.hasAlpha ? 1 : 0)
                    Image(decorative: p.image, scale: 1).resizable().interpolation(.high)
                    overlay(fit)
                }
                .frame(width: fit.width, height: fit.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.r(6)))
                .position(x: g.size.width / 2, y: g.size.height / 2)
            } else if let failed = preview.failed {
                EmptyHint(text: failed, symbol: "exclamationmark.triangle")
                    .frame(width: g.size.width, height: g.size.height)
            } else {
                BusyMascot(.inspecting, pixel: 2)
                    .frame(width: g.size.width, height: g.size.height)
            }
        }
    }
}

enum WheelFit {
    /// `size` scaled to fit in `space`, ratio kept.
    static func size(_ size: CGSize, in space: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return space }
        let s = min(space.width / size.width, space.height / size.height)
        return CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
    }
}

/// The grey squares that show transparency.
struct WheelCheckerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.92)))
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : s
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color(white: 0.8)))
                    x += 2 * s
                }
                y += s
                row += 1
            }
        }
    }
}

/// A number field that snapshots can draw (the AppKit field comes out as a yellow box there).
struct WheelNumberField: View {
    @Binding var value: Int
    var width: CGFloat = 64
    var onCommit: () -> Void = {}
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if Snapshot.isActive {
                Text(Fmt.int(value)).font(.ui(11.5).monospacedDigit()).foregroundStyle(Theme.text)
                    .padding(.horizontal, 6)
                    .frame(width: width, height: 22, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.r(5)).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.r(5)).strokeBorder(Theme.border, lineWidth: Theme.line))
            } else {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.ui(11.5).monospacedDigit())
                    .frame(width: width)
                    .focused($focused)
                    .onSubmit(apply)
                    .onChange(of: focused) { _, on in if !on { apply() } }
            }
        }
        .onAppear { text = "\(value)" }
        .onChange(of: value) { _, v in if !focused { text = "\(v)" } }
    }

    private func apply() {
        let digits = text.filter(\.isNumber)
        if let v = Int(digits), v > 0 { value = v; onCommit() }
        text = "\(value)"
    }
}
