import SwiftUI
import AppKit
import Quartz
import AVKit
import UniformTypeIdentifiers

/// « Aperçu » : the original and what the chosen operation really makes of it, side by side, before anything is saved.
/// Nothing is done blind.
struct ConverterPreviewPanel: View {
    let model: ConverterModel
    var height: CGFloat = 240

    var body: some View {
        let preview = model.previewer
        let op = model.operation
        let targets = op.map { model.targets(for: $0) } ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("APERÇU").font(.ui(10, .semibold)).tracking(0.6).foregroundStyle(Theme.text3)
                Text(subtitle(preview)).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if let op, !op.isBatch, targets.count > 1 {
                    ConverterPager(label: "\(preview.fileIndex + 1) sur \(targets.count)", index: preview.fileIndex, count: targets.count) { i in
                        preview.fileIndex = i
                        preview.schedule(model)
                    }
                }
            }
            if let op, ConverterPreviewer.usesPiece(op) {
                pieceControls(preview)
            }
            content(preview)
                .frame(height: height)
            footer(preview)
        }
    }

    private func subtitle(_ preview: ConverterPreviewer) -> String {
        if preview.isWorking { return "je prépare le rendu…" }
        guard let r = preview.result else { return "" }
        let names = r.sources.map(\.lastPathComponent)
        let what = names.count > 1 ? "\(names.count) fichiers" : "« \(names.first ?? "") »"
        if let s = r.excerptSeconds {
            let from = r.excerptStart > 0 ? "à partir de \(Self.clock(r.excerptStart))" : "depuis le début"
            return "\(Int(s)) s \(from) de \(what), rien d'enregistré"
        }
        return "\(what), rien d'enregistré"
    }

    @ViewBuilder
    private func content(_ preview: ConverterPreviewer) -> some View {
        switch preview.state {
        case .idle:
            placeholder(symbol: "eye", text: "")
        case .working:
            BusyMascot(.converting, pixel: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Theme.r(10)).fill(Theme.bg.opacity(0.5)))
        case .failed(let message):
            placeholder(symbol: "exclamationmark.triangle", text: "Ça ne marcherait pas : \(message)", tint: Theme.warn)
        case .skipped(let message):
            placeholder(symbol: "scalemass", text: message)
        case .ready(let r):
            HStack(spacing: 10) {
                pane(title: "Avant", detail: detailLine(size: r.sourceSize, detail: r.sourceDetail)) {
                    ConverterPreviewSurface(url: r.sources.first, demo: r.demo, demoAfter: false) { seconds in
                        // The "Avant" player tells where it is: "Depuis 00:44" starts the preview there.
                        if abs(preview.playhead - seconds) >= 1 { preview.playhead = seconds }
                    }
                }
                Image(systemName: "arrow.right").font(.ui(12, .semibold)).foregroundStyle(Theme.text3)
                pane(title: "Après", detail: afterDetail(r)) {
                    after(r, index: preview.outputIndex)
                }
            }
        }
    }

    @ViewBuilder
    private func after(_ r: ConverterPreviewResult, index: Int) -> some View {
        if let text = r.text {
            ScrollArea {
                Group {
                    if Snapshot.isActive {
                        Text(text.isEmpty ? "Aucun texte reconnu." : text)
                    } else {
                        Text(text.isEmpty ? "Aucun texte reconnu." : text).textSelection(.enabled)
                    }
                }
                .font(.ui(12)).foregroundStyle(text.isEmpty ? Theme.text3 : Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: Theme.r(10)).fill(Theme.bg.opacity(0.6)))
        } else if r.operation == .qrRead {
            listBox(r.codes.isEmpty ? ["Aucun code trouvé."] : r.codes)
        } else if let listing = r.listing {
            listBox(listing + (r.listingTotal > listing.count ? ["… et \(Fmt.plural(r.listingTotal - listing.count, "autre", "autres"))"] : []))
        } else {
            let shown = ConverterPreviewFiles.expand(r.outputs)
            VStack(spacing: 6) {
                ConverterPreviewSurface(url: shown.isEmpty ? nil : shown[min(index, shown.count - 1)], demo: r.demo, demoAfter: true)
                if shown.count > 1 {
                    ConverterPager(label: "\(min(index, shown.count - 1) + 1) sur \(shown.count)",
                                   index: min(index, shown.count - 1), count: shown.count) { model.previewer.outputIndex = $0 }
                }
            }
        }
    }

    /// "Sur 10 s · 30 s · 1 min · Tout", and from where in the video.
    private func pieceControls(_ preview: ConverterPreviewer) -> some View {
        @Bindable var preview = preview
        return HStack(spacing: 8) {
            Text("Sur").font(.ui(11)).foregroundStyle(Theme.text3)
            WheelChips(options: ConverterPreviewSpan.allCases, selection: $preview.span, label: \.title)
            if preview.span != .full {
                Button("Depuis \(Self.clock(preview.playhead))") { preview.start = preview.playhead }
                    .buttonStyle(SoftButtonStyle(small: true))
                    .disabled(preview.playhead < 1 || abs(preview.playhead - preview.start) < 1)
                    .help("Lis la vidéo de gauche jusqu'au passage voulu : l'aperçu partira de là")
                if preview.start > 0 {
                    Button("Depuis le début") { preview.start = 0 }.buttonStyle(SoftButtonStyle(small: true))
                }
            }
            Spacer(minLength: 0)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func listBox(_ lines: [String]) -> some View {
        ScrollArea {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.mono(11)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: Theme.r(10)).fill(Theme.bg.opacity(0.6)))
    }

    private func pane<Content: View>(title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title).font(.ui(10.5, .semibold)).foregroundStyle(Theme.text2)
                Text(detail).font(.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.r(10)))
                .overlay(RoundedRectangle(cornerRadius: Theme.r(10)).strokeBorder(Theme.border, lineWidth: Theme.line).allowsHitTesting(false))
        }
        .frame(maxWidth: .infinity)
    }

    private func detailLine(size: Int64, detail: String?) -> String {
        ([size > 0 ? Fmt.bytes(size) : nil, detail].compactMap { $0 }).joined(separator: " · ")
    }

    private func afterDetail(_ r: ConverterPreviewResult) -> String {
        if r.text != nil { return "Texte reconnu" }
        if r.operation == .qrRead { return Fmt.plural(r.codes.count, "code", "codes") }
        if r.listing != nil { return Fmt.plural(r.listingTotal, "élément", "éléments") }
        let shown = ConverterPreviewFiles.expand(r.outputs)
        var parts: [String] = []
        if let estimated = r.estimatedSize { parts.append("≈ \(Fmt.bytes(estimated))") } else if r.outputSize > 0 { parts.append(Fmt.bytes(r.outputSize)) }
        if shown.count > 1 { parts.append(Fmt.plural(shown.count, "fichier", "fichiers")) }
        if let d = r.outputDetail { parts.append(d) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func footer(_ preview: ConverterPreviewer) -> some View {
        if let r = preview.result {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if r.sourceSize > 0, (r.estimatedSize ?? r.outputSize) > 0, r.text == nil, r.listing == nil, r.operation != .qrRead {
                    Text(ConverterPreviewer.sizeLine(from: r.sourceSize, to: r.estimatedSize ?? r.outputSize))
                        .font(.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                }
                if let note = r.note {
                    Text(note).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(2)
                }
                Spacer(minLength: 6)
                let shown = ConverterPreviewFiles.expand(r.outputs)
                if !r.demo, !shown.isEmpty {
                    Button("Voir en grand") {
                        NSWorkspace.shared.open(shown[min(preview.outputIndex, shown.count - 1)])
                    }
                    .buttonStyle(SoftButtonStyle(small: true))
                    .help("Ouvre le fichier d'aperçu (temporaire) dans son app")
                }
            }
        }
    }

    private func placeholder(symbol: String, text: String, tint: Color = Theme.text3) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.ui(20, .light)).foregroundStyle(tint)
            if !text.isEmpty {
                Text(text).font(.ui(11.5)).foregroundStyle(tint)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.r(10)).fill(Theme.bg.opacity(0.5)))
    }
}

/// ◀ "2 sur 5" ▶
struct ConverterPager: View {
    var label: String
    var index: Int
    var count: Int
    var go: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button { go((index - 1 + count) % count) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
            Text(label).font(.ui(11.5, .medium)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
            Button { go((index + 1) % count) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
        }
        .font(.ui(11, .semibold))
        .foregroundStyle(Theme.text2)
    }
}

/// A preview result made of folders (a PDF exported as images, pages cut one by one): the files inside, in order.
enum ConverterPreviewFiles {
    static func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            guard FS.isDirectory(url.path) else { return [url] }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return names.filter { !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .prefix(200)
                .map { url.appendingPathComponent($0) }
        }
    }
}

/// Quick Look draws any file (image, PDF, video, sound, document): the same view as the space bar in the Finder.
/// Snapshots and the demo get a drawing instead.
struct ConverterPreviewSurface: View {
    var url: URL?
    var demo: Bool
    var demoAfter: Bool
    /// For videos and sounds: the position of the player, about once a second.
    var onTime: ((Double) -> Void)? = nil

    var body: some View {
        if demo || Snapshot.isActive {
            let ext = url?.pathExtension.lowercased() ?? ""
            if ["m4a", "mp3", "wav", "aiff", "aif", "flac", "aac"].contains(ext) {
                ConverterDemoWave(after: demoAfter)
            } else {
                ConverterDemoArtwork(after: demoAfter, page: ["pdf", "docx", "txt", "md", "rtf", "html", "odt", "pages"].contains(ext),
                                     badge: ["mp4", "mov"].contains(ext) ? "HEVC · 1080p" : (ext == "jpg" ? "JPEG · 82 %" : nil))
            }
        } else if let url, Self.isMedia(url) {
            // macOS's own player: play, pause, volume, scrubbing, speed, full screen.
            ConverterPlayer(url: url, onTime: onTime)
        } else if let url, url.pathExtension.lowercased() == "pdf" {
            // PDFKit's own viewer: every page, scrolled with the trackpad, with a page counter.
            ConverterPDFPane(url: url)
        } else if let url {
            ConverterQuickLook(url: url)
        } else {
            Color.clear
        }
    }
}

extension ConverterPreviewSurface {
    static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audiovisualContent) && !type.conforms(to: .gif)
    }
}

/// AVKit's player view, the one QuickTime uses.
struct ConverterPlayer: NSViewRepresentable {
    var url: URL
    var onTime: ((Double) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = false
        view.videoGravity = .resizeAspect
        context.coordinator.onTime = onTime
        context.coordinator.load(url, into: view)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.onTime = onTime
        if context.coordinator.url != url { context.coordinator.load(url, into: view) }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.stop()
        view.player?.pause()
        view.player = nil
    }

    final class Coordinator {
        var url: URL?
        var onTime: ((Double) -> Void)?
        private var observer: Any?
        private weak var player: AVPlayer?

        func load(_ url: URL, into view: AVPlayerView) {
            stop()
            view.player?.pause()
            let player = AVPlayer(url: url)
            view.player = player
            self.player = player
            self.url = url
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 2), queue: .main) { [weak self] time in
                guard time.isNumeric else { return }
                MainActor.assumeIsolated { self?.onTime?(time.seconds) }
            }
        }

        func stop() {
            if let observer, let player { player.removeTimeObserver(observer) }
            observer = nil
        }
    }
}

struct ConverterQuickLook: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// The demo's photo, before and after: the same picture, the "after" a little softer (JPEG, smaller).
struct ConverterDemoArtwork: View {
    var after: Bool
    /// A document or a PDF: a sheet of paper instead of a photo.
    var page = false
    var badge: String? = "JPEG · 82 %"

    var body: some View {
        if page { sheet } else { photo }
    }

    private var sheet: some View {
        GeometryReader { g in
            let n = after ? 2 : 3
            let w = min(130, (g.size.width - 24 - CGFloat(n - 1) * 10) / CGFloat(n))
            let h = min(w * 1.38, g.size.height - 20)
            ZStack {
                Theme.bg.opacity(0.6)
                HStack(spacing: 10) {
                    ForEach(0..<n, id: \.self) { i in
                        // Document content, not interface: a white sheet whatever the theme.
                        RoundedRectangle(cornerRadius: 3).fill(Color.white)
                            .frame(width: w, height: h)
                            .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                            .overlay(alignment: .topLeading) {
                                VStack(alignment: .leading, spacing: h * 0.035) {
                                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0xD97757)).frame(width: w * (0.38 + CGFloat(i) * 0.08), height: h * 0.04)
                                    ForEach(0..<8, id: \.self) { l in
                                        RoundedRectangle(cornerRadius: 1.5).fill(Color.black.opacity(0.16)).frame(width: w * (l % 3 == 2 ? 0.54 : 0.8), height: h * 0.022)
                                    }
                                }
                                .padding(w * 0.09)
                            }
                    }
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }

    private var photo: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xF4B266), Color(hex: 0xE0705A), Color(hex: 0x6A4C93)], startPoint: .top, endPoint: .bottom)
            Circle().fill(Color(hex: 0xFFE2A8).opacity(0.95)).frame(width: 70).offset(y: 30)
            VStack(spacing: 0) {
                Spacer()
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 60))
                    p.addLine(to: CGPoint(x: 120, y: 10))
                    p.addLine(to: CGPoint(x: 200, y: 45))
                    p.addLine(to: CGPoint(x: 320, y: 0))
                    p.addLine(to: CGPoint(x: 520, y: 50))
                    p.addLine(to: CGPoint(x: 520, y: 120))
                    p.addLine(to: CGPoint(x: 0, y: 120))
                }
                .fill(Color(hex: 0x2C3A5A))
                .frame(height: 120)
            }
            if after, let badge {
                VStack {
                    HStack {
                        Spacer()
                        Text(badge).font(.ui(10.5, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(PillShape().fill(.black.opacity(0.45)))
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
        .saturation(after ? 0.92 : 1)
    }
}

/// The demo's sound, before and after: a drawn waveform.
struct ConverterDemoWave: View {
    var after: Bool

    var body: some View {
        Canvas { ctx, size in
            let bars = 48
            let w = size.width / CGFloat(bars)
            for i in 0..<bars {
                // Typed step by step: one expression mixing Double and CGFloat is too slow for Xcode 16's type checker.
                let x = Double(i) / Double(bars)
                let wave: Double = abs(sin(x * 9.3) * cos(x * 3.1))
                let h: CGFloat = CGFloat(0.25 + 0.6 * wave) * size.height * 0.7
                let left: CGFloat = CGFloat(i) * w + w * 0.2
                let r = CGRect(x: left, y: (size.height - h) / 2, width: w * 0.6, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: w * 0.3), with: .color(Theme.palette[3].opacity(after ? 0.85 : 0.6)))
            }
        }
        .padding(16)
        .background(Theme.bg.opacity(0.6))
    }
}

/// A PDF in the preview: scrolls page after page (trackpad or arrows), "Page 2 sur 4" in the corner.
struct ConverterPDFPane: View {
    var url: URL
    @State private var page = 1
    @State private var count = 0
    @State private var go: (Int) -> Void = { _ in }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ConverterPDFView(url: url, page: $page, count: $count, go: $go)
            if count > 0 {
                HStack(spacing: 8) {
                    Button { go(page - 1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.plain).disabled(page <= 1)
                    Text("Page \(page) sur \(count)").font(.ui(11, .medium)).monospacedDigit()
                    Button { go(page + 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.plain).disabled(page >= count)
                }
                .font(.ui(10.5, .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(PillShape().fill(Theme.card.opacity(0.92)))
                .overlay(PillShape().strokeBorder(Theme.border, lineWidth: Theme.line))
                .themedShadow(color: .black.opacity(0.18), radius: 4, y: 1)
                .padding(10)
            }
        }
    }
}

struct ConverterPDFView: NSViewRepresentable {
    var url: URL
    @Binding var page: Int
    @Binding var count: Int
    @Binding var go: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        // The theme's page background around the (white) pages, like Preview's gray.
        view.backgroundColor = NSColor(Theme.track)
        context.coordinator.attach(view)
        load(view, context: context)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        view.backgroundColor = NSColor(Theme.track)
        if view.document?.documentURL != url { load(view, context: context) }
    }

    private func load(_ view: PDFView, context: Context) {
        let document = PDFDocument(url: url)
        view.document = document
        let total = document?.pageCount ?? 0
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in
            coordinator.parent.count = total
            coordinator.parent.page = total > 0 ? 1 : 0
            coordinator.parent.go = { [weak view] n in
                guard let view, let doc = view.document, n >= 1, n <= doc.pageCount, let p = doc.page(at: n - 1) else { return }
                view.go(to: p)
            }
        }
    }

    final class Coordinator: NSObject {
        var parent: ConverterPDFView
        private var observer: NSObjectProtocol?

        init(_ parent: ConverterPDFView) { self.parent = parent }

        func attach(_ view: PDFView) {
            observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                guard let self, let view, let doc = view.document, let current = view.currentPage else { return }
                let index = doc.index(for: current) + 1
                MainActor.assumeIsolated { if self.parent.page != index { self.parent.page = index } }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
