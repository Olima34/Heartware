import SwiftUI
import ImageIO

/// How the images of « Alléger » and « Taille » come out. Pure: `selfTest` checks `targetSide`.
struct WheelShrinkSettings: Equatable, Sendable {
    enum Size: String, CaseIterable, Identifiable, Sendable {
        case original, half, quarter, side2560, side1920, side1280, side800

        var id: String { rawValue }

        var title: String {
            switch self {
            case .original: return "Taille d'origine"
            case .half: return "50 %"
            case .quarter: return "25 %"
            case .side2560: return "2 560 px"
            case .side1920: return "1 920 px"
            case .side1280: return "1 280 px"
            case .side800: return "800 px"
            }
        }
    }

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case same, jpeg, heic

        var id: String { rawValue }
        var title: String { self == .same ? "Même format" : (self == .jpeg ? "JPEG" : "HEIC") }
    }

    var size: Size = .original
    var quality = 0.75
    var format: Format = .same

    /// The longest side in pixels for an image whose longest side is `longest` (0: unchanged). Never larger than it was.
    static func targetSide(_ size: Size, longest: Int) -> Int {
        switch size {
        case .original: return 0
        case .half: return max(1, longest / 2)
        case .quarter: return max(1, longest / 4)
        case .side2560: return longest > 2560 ? 2560 : 0
        case .side1920: return longest > 1920 ? 1920 : 0
        case .side1280: return longest > 1280 ? 1280 : 0
        case .side800: return longest > 800 ? 800 : 0
        }
    }

    func imageFormat(for url: URL) -> ConverterImageFormat {
        switch format {
        case .same:
            let same = ConverterImageEngine.sameFormat(for: url)
            // A lossless format would not get lighter: a PNG photo becomes a JPEG (a transparent one stays PNG).
            return same.lossy ? same : .jpeg
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }
}

/// « Alléger » and « Taille » : the quality and the size, with the weight of the result measured on the first image
/// before anything is saved. Works on several images at once.
struct WheelShrinkEditor: View {
    let context: WheelEditorContext
    @State private var settings: WheelShrinkSettings
    @State private var estimate: (before: Int64, after: Int64)?
    @State private var measuring = false
    @State private var measureTask: Task<Void, Never>?
    @State private var dimensions: (Int, Int)?

    init(context: WheelEditorContext) {
        self.context = context
        var s = WheelShrinkSettings()
        if context.action == .resize { s.size = .side1920; s.quality = 0.85 }
        _settings = State(initialValue: s)
        if DemoData.isEnabled {
            _estimate = State(initialValue: (3_480_000, 712_000))
            _dimensions = State(initialValue: (4032, 3024))
        }
    }

    var body: some View {
        WheelWindowChrome(title: context.action == .resize ? "Changer la taille" : "Alléger l'image",
                          subtitle: context.files.count == 1 ? context.file.name : WheelRunner.summary(context.files), close: context.close) {
            VStack(alignment: .leading, spacing: 16) {
                weight
                VStack(alignment: .leading, spacing: 8) {
                    WheelFieldLabel(text: "Taille")
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(WheelShrinkSettings.Size.allCases) { s in
                            WheelSmallButton(title: sizeTitle(s), symbol: nil, prominent: settings.size == s) { settings.size = s }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    WheelFieldLabel(text: "Qualité")
                    WheelSlider(value: $settings.quality, range: 0.3...1, text: Fmt.pct(settings.quality))
                    Text(qualityHint).font(.ui(10.5)).foregroundStyle(Theme.text3)
                }
                HStack(spacing: 8) {
                    WheelFieldLabel(text: "Format")
                    WheelChips(options: WheelShrinkSettings.Format.allCases, selection: $settings.format, label: \.title)
                    Spacer()
                }
            }
            .padding(.top, 4)
        } footer: {
            Text(context.files.count > 1 ? "Mesuré sur la première image" : "La photo d'origine ne change pas")
                .font(.ui(10.5)).foregroundStyle(Theme.text3)
            Spacer()
            Button { save() } label: { Text(context.action == .resize ? "Redimensionner" : "Alléger") }
                .buttonStyle(SoftButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
        }
        .onAppear { measure() }
        .onChange(of: settings) { _, _ in measure() }
    }

    private func sizeTitle(_ s: WheelShrinkSettings.Size) -> String {
        guard let (w, h) = dimensions, s != .original else { return s.title }
        let side = WheelShrinkSettings.targetSide(s, longest: max(w, h))
        return side == 0 && s != .half && s != .quarter ? "\(s.title) (déjà)" : s.title
    }

    private var qualityHint: String {
        switch settings.quality {
        case ..<0.5: return "Très léger : des défauts peuvent se voir sur les dégradés."
        case ..<0.8: return "Le bon compromis : la différence ne se voit pas à l'écran."
        default: return "Presque sans perte : le gain est plus faible."
        }
    }

    private var weight: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Avant").font(.ui(10.5)).foregroundStyle(Theme.text3)
                Text(estimate.map { Fmt.bytes($0.before) } ?? "—").font(.serif(20)).foregroundStyle(Theme.text2)
            }
            Image(systemName: "arrow.right").font(.ui(12, .semibold)).foregroundStyle(Theme.text3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Après").font(.ui(10.5)).foregroundStyle(Theme.text3)
                Text(estimate.map { Fmt.bytes($0.after) } ?? "…").font(.serif(20)).foregroundStyle(Theme.text)
            }
            Spacer()
            if measuring {
                BusyMascot(.inspecting, pixel: 1.5)
            } else if let e = estimate, e.before > 0 {
                let gain = 1 - Double(e.after) / Double(e.before)
                Tag(text: gain > 0 ? "−\(Fmt.pct(gain))" : "Pas plus léger", tint: gain > 0.05 ? Theme.good : Theme.warn, filled: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.r(12)).fill(Theme.card.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(12)).strokeBorder(Theme.border, lineWidth: Theme.line))
    }

    /// Encodes the first image in memory with these settings (the newest asked only).
    private func measure() {
        guard !DemoData.isEnabled else { return }
        measureTask?.cancel()
        let url = context.file.url, s = settings
        measuring = true
        measureTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let r = await Task.detached(priority: .userInitiated) { () -> (Int64, Int64, Int, Int)? in
                guard let src = try? ConverterImageEngine.source(url), let (w, h) = ConverterImageEngine.pixelSize(src) else { return nil }
                let side = WheelShrinkSettings.targetSide(s.size, longest: max(w, h))
                guard let image = ConverterImageEngine.uprightImage(src, index: CGImageSourceGetPrimaryImageIndex(src), maxSide: side) else { return nil }
                let format = s.imageFormat(for: url)
                let data = ConverterImageEngine.encode(image, uti: format.uti, quality: format.lossy ? s.quality : nil)
                let before = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                return (before, Int64(data?.count ?? 0), w, h)
            }.value
            guard !Task.isCancelled else { return }
            measuring = false
            if let r {
                estimate = (r.0, r.1)
                dimensions = (r.2, r.3)
            }
        }
    }

    private func save() {
        let files = context.files.map(\.url)
        let s = settings
        let suffix = context.action == .resize ? nil : "allégée"
        context.saveMany { folder, control in
            var out: [URL] = []
            for (i, url) in files.enumerated() {
                try control.check()
                let src = try ConverterImageEngine.source(url)
                let longest = ConverterImageEngine.pixelSize(src).map { max($0.0, $0.1) } ?? 0
                let side = WheelShrinkSettings.targetSide(s.size, longest: longest)
                out.append(try ConverterImageEngine.convert(url, format: s.imageFormat(for: url), maxSide: side, quality: s.quality, strip: nil,
                                                            suffix: suffix ?? (side > 0 ? "\(side) px" : "allégée"), folder: folder,
                                                            control: ConverterControl { _ in }))
                control.progress(Double(i + 1) / Double(files.count))
            }
            return out
        }
    }
}
