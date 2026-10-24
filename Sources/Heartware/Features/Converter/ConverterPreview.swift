import SwiftUI
import AVFoundation

/// What the preview shows: the real result of the chosen operation and options, computed on one file into a private
/// scratch folder (nothing is saved where the user keeps files). Videos are previewed on their first seconds,
/// archives to extract by listing their content.
/// How much of a video the compression preview converts (the rest is extrapolated for the size).
enum ConverterPreviewSpan: String, CaseIterable, Identifiable {
    case s10, s30, m1, full

    var id: String { rawValue }
    var title: String {
        switch self {
        case .s10: return "10 s"
        case .s30: return "30 s"
        case .m1: return "1 min"
        case .full: return "Tout"
        }
    }
    var seconds: Double? {
        switch self {
        case .s10: return 10
        case .s30: return 30
        case .m1: return 60
        case .full: return nil
        }
    }
}

/// A preview left out on purpose: too heavy to compute without a click (a 20 Go ZIP would be made in the scratch folder).
struct ConverterPreviewSkipped: LocalizedError {
    var reason: String
    var errorDescription: String? { reason }
}

struct ConverterPreviewResult {
    var operation: ConverterOperation
    var sources: [URL]
    var outputs: [URL] = []
    var outputSize: Int64 = 0
    var sourceSize: Int64 = 0
    /// For a video previewed on its first seconds: the size expected for the whole file.
    var estimatedSize: Int64?
    var excerptSeconds: Double?
    var excerptStart: Double = 0
    var note: String?
    var text: String?
    var codes: [String] = []
    /// Archive content, when the preview lists it instead of extracting it.
    var listing: [String]?
    var listingTotal = 0
    var sourceDetail: String?
    var outputDetail: String?
    /// Demo mode: drawn stand-ins instead of Quick Look.
    var demo = false
}

@Observable
@MainActor
final class ConverterPreviewer {
    enum State {
        case idle, working, ready(ConverterPreviewResult), failed(String), skipped(String)
    }

    var state: State = .idle
    /// For operations that make one result per file: which of the files is previewed.
    var fileIndex = 0 {
        didSet { if fileIndex != oldValue { outputIndex = 0 } }
    }
    /// When a result is made of several files (a PDF cut page by page): which one is shown.
    var outputIndex = 0

    /// Video compression: how long a piece is converted for the preview, and from where (the "Avant" player's position).
    var span: ConverterPreviewSpan = .s10 {
        didSet { if span != oldValue, let model { schedule(model) } }
    }
    var start: Double = 0 {
        didSet { if start != oldValue, let model { schedule(model) } }
    }
    /// Where the "Avant" player is (updated about once a second while it plays).
    var playhead: Double = 0

    @ObservationIgnored private weak var model: ConverterModel?
    @ObservationIgnored private var control: ConverterControl?
    @ObservationIgnored private var work: DispatchWorkItem?
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var lastFileIndex = 0
    @ObservationIgnored private var currentFolder: URL?

    /// Scratch space for previews, inside the user's temporary folder (wiped by macOS anyway).
    nonisolated static var root: String? {
        FS.userTempDir.map { ($0 as NSString).appendingPathComponent("Heartware-apercus") }
    }

    var isWorking: Bool { if case .working = state { return true } else { return false } }

    var result: ConverterPreviewResult? {
        if case .ready(let r) = state { return r }
        return nil
    }

    /// Called whenever the files, the operation or an option changes: the preview follows, a moment later.
    func schedule(_ model: ConverterModel) {
        self.model = model
        work?.cancel()
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        guard let op = model.operation, Self.previews(op) else {
            reset()
            return
        }
        let targets = model.targets(for: op)
        guard targets.count >= op.minimumCount, !targets.isEmpty else {
            reset()
            return
        }
        if fileIndex >= targets.count { fileIndex = 0 }
        let inputs = op.isBatch ? targets : [targets[fileIndex]]
        if fileIndex != lastFileIndex { start = 0; lastFileIndex = fileIndex }
        let pieceKey = Self.usesPiece(op) ? "|\(span.rawValue)|\(Int(start))" : ""
        let newKey = "\(op.rawValue)|\(model.options)|\(inputs.map(\.url.path).joined(separator: "|"))|\(model.ffmpegPath ?? "")\(pieceKey)"
        guard newKey != key else { return }
        let spec = ConverterEngine.Spec(operation: op, inputs: inputs.map(\.url), kinds: inputs.map(\.kind), names: [],
                                        options: model.options, folder: nil, ffmpeg: model.ffmpegPath)
        let piece: (start: Double, seconds: Double?) = (start, Self.usesPiece(op) ? span.seconds : nil)
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.run(spec, key: newKey, piece: piece) }
        }
        work = item
        let delay = op.family == .videos ? 0.9 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Only re-encoding a video takes long enough to preview a piece of it; sound and GIFs are made whole.
    nonisolated static func usesPiece(_ op: ConverterOperation) -> Bool {
        op == .videoCompress || op == .videoContainer
    }

    /// Operations that get a preview here (renaming has its own list, a QR code is drawn as it is typed).
    static func previews(_ op: ConverterOperation) -> Bool {
        op != .rename && op != .qrGenerate
    }

    /// Operations whose preview processes the whole selection (no excerpt possible): beyond `heavyLimit` of sources,
    /// the preview waits for a click instead of zipping or rewriting gigabytes in the scratch folder by itself.
    nonisolated static func processesEverything(_ op: ConverterOperation) -> Bool {
        op == .archiveZip || op == .pdfMerge || op == .pdfCompress || op == .imagesToPDF
    }

    nonisolated static let heavyLimit: Int64 = 200_000_000

    func reset() {
        control?.cancel()
        control = nil
        key = ""
        state = .idle
        discardFolder()
    }

    /// Throws the scratch files away (on quit, when the files are cleared).
    func cleanUp() {
        reset()
        guard let root = Self.root, FS.exists(root) else { return }
        Remover.discardOutput(URL(fileURLWithPath: root))
    }

    private func discardFolder() {
        if let folder = currentFolder { Remover.discardOutput(folder) }
        currentFolder = nil
    }

    private func run(_ spec: ConverterEngine.Spec, key newKey: String, piece: (start: Double, seconds: Double?)) {
        control?.cancel()
        guard let root = Self.root else {
            state = .failed("Pas de dossier temporaire pour préparer l'aperçu.")
            return
        }
        ActionLog.quiet(under: root)
        discardFolder()
        let folder: URL
        do {
            folder = try FileOps.makeDirectory(URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString))
        } catch {
            state = .failed("Impossible de préparer l'aperçu : \(error.localizedDescription)")
            return
        }
        currentFolder = folder
        key = newKey
        state = .working
        outputIndex = 0
        let control = ConverterControl(report: { _ in })
        self.control = control
        Task { [weak self] in
            let outcome: Result<ConverterPreviewResult, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try await Self.make(spec, folder: folder, control: control, piece: piece)) } catch { return .failure(error) }
            }.value
            guard let self, self.key == newKey, !control.isCancelled else { return }
            switch outcome {
            case .success(let r): self.state = .ready(r)
            case .failure(let e):
                if case ConverterError.cancelled = e { return }
                if let skipped = e as? ConverterPreviewSkipped {
                    self.state = .skipped(skipped.reason)
                } else {
                    self.state = .failed(e.localizedDescription)
                }
            }
        }
    }

    // MARK: Making the preview (off the main thread)

    nonisolated static func make(_ spec: ConverterEngine.Spec, folder: URL, control: ConverterControl,
                                 piece: (start: Double, seconds: Double?) = (0, nil)) async throws -> ConverterPreviewResult {
        let op = spec.operation
        var result = ConverterPreviewResult(operation: op, sources: spec.inputs)
        result.sourceSize = spec.inputs.reduce(0) { $0 + ConverterOutputs.size($1) }
        if processesEverything(op), result.sourceSize > heavyLimit {
            throw ConverterPreviewSkipped(reason: "Trop volumineux pour un aperçu : \(Fmt.bytes(result.sourceSize)) à traiter, "
                + "je ne le calcule pas sans ton accord. Lance « \(op.actionTitle) » quand tu veux.")
        }
        // "MOV ↔ MP4" on a video already in that format: the preview fails like the conversion would,
        // before cutting an excerpt for nothing.
        if op == .videoContainer { try ConverterMediaEngine.checkChangesContainer(spec.inputs[0], to: spec.options.container) }
        result.sourceDetail = await describe(spec.inputs[0], kind: spec.kinds.first ?? .other)

        // An archive to extract: its table of contents, not a copy of everything.
        if op == .archiveExtract {
            let listed = try list(spec.inputs[0])
            result.listing = Array(listed.prefix(300))
            result.listingTotal = listed.count
            return result
        }

        var run = spec
        run = ConverterEngine.Spec(operation: spec.operation, inputs: spec.inputs, kinds: spec.kinds, names: spec.names,
                                   options: spec.options, folder: folder, ffmpeg: spec.ffmpeg)
        // Re-encoding a video: the chosen piece (10 s by default, from the chosen position) converted for real,
        // the full size extrapolated. "Tout", sound and GIFs: the whole result.
        var ratio: Double?
        if usesPiece(spec.operation), let seconds = piece.seconds, let duration = await duration(spec.inputs[0]), duration > seconds + 1 {
            let from = max(0, min(piece.start, duration - seconds))
            if let clip = try await excerpt(spec.inputs[0], start: from, seconds: seconds, into: folder, ffmpeg: spec.ffmpeg) {
                run = ConverterEngine.Spec(operation: spec.operation, inputs: [clip], kinds: spec.kinds, names: spec.names,
                                           options: spec.options, folder: folder, ffmpeg: spec.ffmpeg)
                result.excerptSeconds = seconds
                result.excerptStart = from
                ratio = duration / seconds
            }
        }
        try control.check()
        let output: ConverterOutput
        do {
            output = try await ConverterEngine.run(run, control: control)
        } catch {
            // A message about the excerpt names the user's file instead.
            if run.inputs != spec.inputs, let clip = run.inputs.first,
               case let e as LocalizedError = error, let text = e.errorDescription, text.contains(clip.lastPathComponent) {
                throw ConverterError.failed(text.replacingOccurrences(of: clip.lastPathComponent, with: spec.inputs[0].lastPathComponent))
            }
            throw error
        }
        result.outputs = output.files
        result.outputSize = output.size
        result.note = output.note
        result.text = output.text
        result.codes = output.codes
        if let ratio { result.estimatedSize = Int64(Double(output.size) * ratio) }
        if let first = output.files.first {
            result.outputDetail = await describe(first, kind: ConverterKind.detect(name: first.lastPathComponent, isDirectory: FS.isDirectory(first.path)))
        }
        return result
    }

    nonisolated private static func describe(_ url: URL, kind: ConverterKind) async -> String? {
        if kind == .folder {
            let n = (try? FileManager.default.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }.count) ?? 0
            return Fmt.plural(n, "fichier", "fichiers")
        }
        return await ConverterInspector.inspect(url, kind: kind).detail
    }

    nonisolated private static func duration(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration), d.isNumeric else { return nil }
        return d.seconds
    }

    /// The first `seconds` of a video, copied without re-encoding (AVFoundation, or ffmpeg for MKV and WebM).
    nonisolated static func excerpt(_ url: URL, start: Double = 0, seconds: Double, into folder: URL, ffmpeg: String?) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        if (try? await asset.load(.isExportable)) == true,
           let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) {
            // The excerpt keeps the source's container: "MOV ↔ MP4" has the same work to do on it as on the whole file
            // (an MP4 excerpt written as .mov would wrongly be "déjà en MOV").
            let own: AVFileType? = ["mp4": AVFileType.mp4, "m4v": .m4v, "mov": .mov][url.pathExtension.lowercased()]
            let type: AVFileType = own.flatMap { session.supportedFileTypes.contains($0) ? $0 : nil }
                ?? (session.supportedFileTypes.contains(.mov) ? .mov : (session.supportedFileTypes.first ?? .mov))
            let out = FileOps.uniqueURL(folder.appendingPathComponent("extrait.\(type == .mp4 ? "mp4" : (type == .m4v ? "m4v" : "mov"))"))
            session.outputURL = out
            session.outputFileType = type
            session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                            duration: CMTime(seconds: seconds, preferredTimescale: 600))
            // macOS 14 has no async `export(to:as:)`: the classic call, awaited.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { done.resume() }
            }
            if session.status == .completed { return out }
        }
        if let ffmpeg {
            let out = FileOps.uniqueURL(folder.appendingPathComponent("extrait." + url.pathExtension.lowercased()))
            let r = Shell.run(ffmpeg, ["-v", "error", "-ss", String(start), "-i", url.path, "-t", String(seconds), "-c", "copy", out.path], timeout: 60)
            if r.ok, FS.exists(out.path) { return out }
        }
        return nil
    }

    /// The names inside an archive (zip by zipinfo, the others by tar), without extracting anything.
    nonisolated static func list(_ url: URL) throws -> [String] {
        let ext = url.pathExtension.lowercased()
        let r = ext == "zip"
            ? Shell.run("/usr/bin/zipinfo", ["-1", url.path], timeout: 30)
            : Shell.run("/usr/bin/tar", ["-tf", url.path], timeout: 30)
        guard r.ok else { throw ConverterError.unreadable(url.lastPathComponent) }
        return parseListing(r.out)
    }

    nonisolated static func parseListing(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("__MACOSX/") && !$0.hasSuffix("/.DS_Store") && $0 != ".DS_Store" }
    }

    /// "1,2 Mo → 340 Ko (−72 %)".
    nonisolated static func sizeLine(from source: Int64, to output: Int64) -> String {
        guard source > 0, output > 0 else { return Fmt.bytes(max(source, output)) }
        let change = Double(output - source) / Double(source) * 100
        let sign = change < 0 ? "−" : "+"
        return "\(Fmt.bytes(source)) → \(Fmt.bytes(output)) (\(sign)\(Int(abs(change).rounded())) %)"
    }

    // MARK: Demo

    func loadDemo(_ model: ConverterModel) {
        guard let op = model.operation, ConverterPreviewer.previews(op), let file = model.targets(for: op).first else {
            state = .idle
            return
        }
        let all = op.isBatch ? model.targets(for: op) : [file]
        var r = ConverterPreviewResult(operation: op, sources: all.map(\.url), demo: true)
        r.sourceSize = all.reduce(0) { $0 + $1.size }
        r.sourceDetail = file.detail
        let ext: String
        switch op {
        case .imageConvert: ext = model.options.imageFormat?.ext ?? file.url.pathExtension
        case .audioConvert: ext = model.options.audioFormat.ext
        case .documentConvert: ext = model.options.docFormat.ext
        default:
            switch op.family {
            case .images: ext = "jpg"
            case .videos: ext = "mp4"
            case .pdf: ext = "pdf"
            default: ext = file.url.pathExtension
            }
        }
        r.outputs = [URL(fileURLWithPath: FS.home + "/Downloads/" + file.url.deletingPathExtension().lastPathComponent + "." + ext)]
        switch op {
        case .ocr:
            r.outputs = []
            r.text = ConverterDemo.ticket
            state = .ready(r)
            return
        case .qrRead:
            r.outputs = []
            r.codes = ["https://exemple.fr/billetterie/concert-plage"]
            state = .ready(r)
            return
        case .archiveExtract:
            r.outputs = []
            r.listing = ["Photos du mariage/", "Photos du mariage/Cérémonie/", "Photos du mariage/Cérémonie/IMG_0012.jpg",
                         "Photos du mariage/Cérémonie/IMG_0013.jpg", "Photos du mariage/Vin d'honneur/IMG_0088.jpg",
                         "Photos du mariage/Vin d'honneur/IMG_0091.jpg", "Photos du mariage/Soirée/IMG_0140.jpg", "Photos du mariage/Liste des invités.pdf"]
            r.listingTotal = 214
            state = .ready(r)
            return
        case .audioConvert:
            r.outputSize = Int64(Double(file.size) * 1.15)
            r.outputDetail = "12:40 · \(model.options.audioFormat.short)"
            state = .ready(r)
            return
        case .documentConvert:
            r.outputSize = Int64(Double(file.size) * 2.6)
            r.outputDetail = "3 pages"
            state = .ready(r)
            return
        default:
            break
        }
        switch op.family {
        case .images:
            r.outputSize = Int64(Double(file.size) * 0.43)
            r.outputDetail = file.detail
            r.note = model.options.stripOnConvert ? "Sans le GPS : la position de la photo n'est plus dans le fichier." : nil
        case .videos:
            r.excerptSeconds = 10
            r.outputSize = Int64(Double(file.size) * 0.012)
            r.estimatedSize = Int64(Double(file.size) * 0.21)
            r.outputDetail = "HEVC · 1 920 × 1 080"
        case .pdf where op == .pdfMerge:
            r.outputSize = Int64(Double(r.sourceSize) * 0.97)
            r.sourceDetail = Fmt.plural(all.count, "document", "documents")
            r.outputDetail = Fmt.plural(model.mergePageCount ?? all.reduce(0) { $0 + ($1.pages ?? 1) }, "page", "pages")
            r.outputs = [URL(fileURLWithPath: FS.home + "/Downloads/" + ConverterPDFEngine.mergeName(model.options.mergeName, first: file.url) + ".pdf")]
        case .pdf:
            r.outputSize = Int64(Double(file.size) * 0.2)
            r.outputDetail = "4 pages"
        default:
            r.outputSize = Int64(Double(file.size) * 0.8)
        }
        state = .ready(r)
    }
}
