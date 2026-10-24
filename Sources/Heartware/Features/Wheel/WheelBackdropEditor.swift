import SwiftUI

/// What is behind the picture.
enum WheelBackdropFill: Hashable, Sendable {
    case gradient(Int), solid(Int), blur, clear
}

struct WheelBackdropStyle: Equatable, Sendable {
    var fill: WheelBackdropFill = .gradient(0)
    /// The margin around the picture, as a share of its longest side.
    var padding = 0.1
    /// The picture's corners, as a share of its shortest side.
    var corner = 0.035
    /// 0…1.
    var shadow = 0.55
    var ratio: WheelRatio = .free
}

/// The backgrounds: they go into the picture itself, so they do not follow the theme (like the swatches of a paint box).
enum WheelBackdropPalette {
    struct Gradient {
        let name: String
        let colors: [WheelRGB]
    }

    static let gradients: [Gradient] = [
        Gradient(name: "Aube", colors: [WheelRGB(0xFF8A4C), WheelRGB(0xFF5E7E), WheelRGB(0xB362FF)]),
        Gradient(name: "Abricot", colors: [WheelRGB(0xFFD27A), WheelRGB(0xFF8C5A)]),
        Gradient(name: "Lagon", colors: [WheelRGB(0x43E0C8), WheelRGB(0x3A7BFF)]),
        Gradient(name: "Glacier", colors: [WheelRGB(0xDCEBFF), WheelRGB(0x9CC2FF)]),
        Gradient(name: "Lavande", colors: [WheelRGB(0xE6C8FF), WheelRGB(0xFFC2E0)]),
        Gradient(name: "Prairie", colors: [WheelRGB(0xC8F27A), WheelRGB(0x3FBF7F)]),
        Gradient(name: "Sommet", colors: [WheelRGB(0x8CC8F2), WheelRGB(0x5C6F8A)]),
        Gradient(name: "Nuit", colors: [WheelRGB(0x2E3560), WheelRGB(0x0E0F1E)]),
        Gradient(name: "Fauve", colors: [WheelRGB(0xF2C14E), WheelRGB(0x9A5A3A)]),
    ]

    static let solids: [WheelRGB] = [WheelRGB(0xFFFFFF), WheelRGB(0xF2EEE8), WheelRGB(0xD9D9DE), WheelRGB(0x1C1C1E),
                                     WheelRGB(0xFFCF5A), WheelRGB(0x5FB86A), WheelRGB(0x5B8DEF), WheelRGB(0xE8577A)]

    static func gradient(_ i: Int) -> Gradient { gradients[(i % gradients.count + gradients.count) % gradients.count] }
    static func solid(_ i: Int) -> WheelRGB { solids[(i % solids.count + solids.count) % solids.count] }
}

/// A fixed color, for what is drawn into a picture.
struct WheelRGB: Sendable {
    let hex: UInt32

    init(_ hex: UInt32) { self.hex = hex }

    var cg: CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    var color: Color { Color(cgColor: cg) }
}

/// « Mettre sur un fond » : the picture on a gradient, a color, its own blur or nothing, with margin, rounded corners
/// and a shadow, in the shape asked (for a post, a slide…). Saved as PNG.
struct WheelBackdropEditor: View {
    let context: WheelEditorContext
    @State private var preview: WheelPreview
    @State private var style = WheelBackdropStyle()
    @State private var blurred: CGImage?
    @State private var rendered: CGImage?
    @State private var renderTask: Task<Void, Never>?

    init(context: WheelEditorContext) {
        self.context = context
        let p = WheelPreview(context.file.url, maxSide: 1000)
        _preview = State(initialValue: p)
        // Snapshots draw once, without waiting.
        if Snapshot.isActive, let pic = p.picture {
            _rendered = State(initialValue: WheelImageEngine.backdrop(pic.image, hasAlpha: false, style: WheelBackdropStyle(), blurred: nil, maxSide: 900))
        }
    }

    var body: some View {
        WheelWindowChrome(title: "Mettre sur un fond", subtitle: context.file.name, close: context.close) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    WheelCheckerboard().opacity(style.fill == .clear ? 1 : 0)
                    if let rendered {
                        Image(decorative: rendered, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        BusyMascot(.inspecting, pixel: 2)
                    }
                }
                .frame(height: 290)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: Theme.r(10)).fill(Theme.track.opacity(0.35)))
                .clipShape(RoundedRectangle(cornerRadius: Theme.r(10)))
                VStack(alignment: .leading, spacing: 7) {
                    WheelFieldLabel(text: "Fond")
                    swatches
                }
                VStack(spacing: 9) {
                    row("Marge") { WheelSlider(value: $style.padding, range: 0...0.3, text: Fmt.pct(style.padding)) }
                    row("Coins") { WheelSlider(value: $style.corner, range: 0...0.15, text: Fmt.pct(style.corner / 0.15)) }
                    row("Ombre") { WheelSlider(value: $style.shadow, range: 0...1, text: Fmt.pct(style.shadow)) }
                }
                HStack(spacing: 8) {
                    WheelFieldLabel(text: "Format").frame(width: 52, alignment: .leading)
                    WheelChips(options: WheelRatio.backdrop, selection: $style.ratio, label: { $0 == .free ? "Auto" : $0.title })
                    Spacer()
                }
            }
        } footer: {
            Button("Réinitialiser") { style = WheelBackdropStyle() }.buttonStyle(SoftButtonStyle())
            Spacer()
            Button { save() } label: { Text("Enregistrer avec le fond") }
                .buttonStyle(SoftButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(preview.picture == nil)
        }
        .onAppear {
            preview.start()
            if preview.picture != nil && rendered == nil { prepare() }
        }
        .onChange(of: preview.picture?.width) { _, _ in prepare() }
        .onChange(of: style) { _, _ in render() }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            WheelFieldLabel(text: title).frame(width: 52, alignment: .leading)
            content()
        }
    }

    private var swatches: some View {
        let gradients = WheelBackdropPalette.gradients.indices.map { WheelBackdropFill.gradient($0) }
        let solids = WheelBackdropPalette.solids.indices.map { WheelBackdropFill.solid($0) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(gradients, id: \.self) { swatch($0) }
                swatch(.blur)
            }
            HStack(spacing: 6) {
                ForEach(solids, id: \.self) { swatch($0) }
                swatch(.clear)
            }
        }
    }

    private func swatch(_ fill: WheelBackdropFill) -> some View {
        let on = style.fill == fill
        return Button { style.fill = fill } label: {
            ZStack {
                switch fill {
                case .gradient(let i):
                    RoundedRectangle(cornerRadius: Theme.r(6)).fill(LinearGradient(colors: WheelBackdropPalette.gradient(i).colors.map(\.color),
                                                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                case .solid(let i):
                    RoundedRectangle(cornerRadius: Theme.r(6)).fill(WheelBackdropPalette.solid(i).color)
                case .blur:
                    RoundedRectangle(cornerRadius: Theme.r(6)).fill(LinearGradient(colors: [Theme.palette[5], Theme.palette[2]], startPoint: .top, endPoint: .bottom))
                        .blur(radius: 2)
                        .overlay(Image(systemName: "drop.halffull").font(.ui(10, .semibold)).foregroundStyle(.white))
                case .clear:
                    WheelCheckerboard().clipShape(RoundedRectangle(cornerRadius: Theme.r(6)))
                }
                RoundedRectangle(cornerRadius: Theme.r(6)).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
            }
            .frame(width: 30, height: 22)
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: Theme.r(8)).strokeBorder(on ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(fill))
    }

    private func help(_ fill: WheelBackdropFill) -> String {
        switch fill {
        case .gradient(let i): return "Dégradé \(WheelBackdropPalette.gradient(i).name)"
        case .solid: return "Couleur unie"
        case .blur: return "L'image elle-même, floutée"
        case .clear: return "Transparent"
        }
    }

    /// The blurred copy for « Flou », once; then the first picture.
    private func prepare() {
        guard let p = preview.picture else { return }
        Task {
            let image = p.image
            let b = await Task.detached(priority: .userInitiated) { WheelImageEngine.blurredBackground(image).map { WheelImageBox($0) } }.value
            blurred = b?.image
            render()
        }
    }

    /// The preview, drawn off the main thread at a small size (the newest asked only).
    private func render() {
        guard let p = preview.picture else { return }
        renderTask?.cancel()
        let s = style, b = blurred.map { WheelImageBox($0) }
        if Snapshot.isActive {
            rendered = WheelImageEngine.backdrop(p.image, hasAlpha: p.hasAlpha, style: s, blurred: b?.image, maxSide: 900)
            return
        }
        renderTask = Task {
            let out = await Task.detached(priority: .userInitiated) {
                WheelImageEngine.backdrop(p.image, hasAlpha: p.hasAlpha, style: s, blurred: b?.image, maxSide: 900).map { WheelImageBox($0) }
            }.value
            if !Task.isCancelled { rendered = out?.image }
        }
    }

    private func save() {
        let url = context.file.url
        let s = style
        context.save { folder, control in
            control.progress(nil)
            let p = try WheelImageEngine.load(url)
            let blur = s.fill == .blur ? WheelImageEngine.blurredBackground(p.image) : nil
            guard let image = WheelImageEngine.backdrop(p.image, hasAlpha: p.hasAlpha, style: s, blurred: blur) else {
                throw ConverterError.failed("L'image n'a pas pu être composée.")
            }
            return try WheelImageEngine.save(image, from: url, picture: p, suffix: "avec fond", as: .png, keepMetadata: false, folder: folder)
        }
    }
}

/// A CGImage handed between threads (it never changes once made).
struct WheelImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
