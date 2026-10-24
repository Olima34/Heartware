import Foundation
import ImageIO

/// Runs one job off the main thread: picks the engine for the operation and gathers what it produced.
enum ConverterEngine {
    struct Spec: Sendable {
        let operation: ConverterOperation
        let inputs: [URL]
        let kinds: [ConverterKind]
        let names: [String]
        let options: ConverterOptions
        let folder: URL?
        let ffmpeg: String?
    }

    static func run(_ spec: Spec, control: ConverterControl) async throws -> ConverterOutput {
        var output = try await perform(spec, control: control)
        output.size = output.files.reduce(0) { $0 + ConverterOutputs.size($1) }
        return output
    }

    private static func perform(_ spec: Spec, control: ConverterControl) async throws -> ConverterOutput {
        guard let input = spec.inputs.first else { throw ConverterError.failed("Aucun fichier.") }
        let o = spec.options
        let folder = spec.folder
        switch spec.operation {
        case .imageConvert:
            if let format = o.imageFormat, format.viaFFmpeg {
                return ConverterOutput(files: [try await webp(input, maxSide: 0, quality: o.imageQuality, spec: spec, control: control)])
            }
            return ConverterOutput(files: [try ConverterImageEngine.convert(input, format: o.imageFormat, maxSide: 0, quality: o.imageQuality,
                                                                             strip: o.stripOnConvert ? .all : nil, suffix: nil, folder: folder, control: control)])
        case .imageResize:
            if let format = o.resizeFormat, format.viaFFmpeg {
                return ConverterOutput(files: [try await webp(input, maxSide: o.maxSide, quality: o.imageQuality, spec: spec, control: control)])
            }
            return ConverterOutput(files: [try ConverterImageEngine.convert(input, format: o.resizeFormat, maxSide: o.maxSide, quality: o.imageQuality,
                                                                             strip: nil, suffix: "\(o.maxSide) px", folder: folder, control: control)])
        case .imageCompress:
            if let format = o.compressFormat, format.viaFFmpeg {
                return ConverterOutput(files: [try await webp(input, maxSide: o.compressMaxSide, quality: o.imageQuality, spec: spec, control: control)])
            }
            let url = try ConverterImageEngine.convert(input, format: o.compressFormat, maxSide: o.compressMaxSide, quality: o.imageQuality,
                                                       strip: nil, suffix: "compressée", folder: folder, control: control)
            return ConverterOutput(files: [url])
        case .imageStrip:
            let r = try ConverterImageEngine.stripMetadata(input, mode: o.stripMode, folder: folder, control: control)
            return ConverterOutput(files: [r.url], note: r.lossless ? "Sans recompression : pixels identiques."
                                                                    : "Réencodée en qualité maximale : ce format garde sinon une partie des informations.")
        case .imagesToPDF:
            return ConverterOutput(files: [try ConverterPDFEngine.fromImages(spec.inputs, pageSize: o.pageSize, quality: o.imageQuality,
                                                                              folder: folder, control: control)])
        case .videoCompress:
            return ConverterOutput(files: [try await ConverterMediaEngine.compress(input, preset: o.videoPreset, container: o.compressContainer,
                                                                                    folder: folder, control: control)])
        case .videoContainer:
            let r = try await ConverterMediaEngine.changeContainer(input, to: o.container, ffmpeg: spec.ffmpeg, folder: folder, control: control)
            return ConverterOutput(files: [r.url], note: r.note)
        case .videoAudio:
            return ConverterOutput(files: [try await ConverterMediaEngine.extractAudio(input, folder: folder, control: control)])
        case .videoGIF:
            return ConverterOutput(files: [try await ConverterMediaEngine.gif(input, width: o.gifWidth, fps: o.gifFPS, seconds: o.gifSeconds,
                                                                               folder: folder, control: control)])
        case .audioConvert:
            return ConverterOutput(files: [try await ConverterMediaEngine.convertAudio(input, to: o.audioFormat, bitrate: o.audioBitrate,
                                                                                        ffmpeg: spec.ffmpeg, folder: folder, control: control)])
        case .pdfMerge:
            return ConverterOutput(files: [try ConverterPDFEngine.merge(spec.inputs, kinds: spec.kinds, options: o, folder: folder,
                                                                         control: control)])
        case .pdfSplit:
            return ConverterOutput(files: try ConverterPDFEngine.split(input, spec: o.pdfPages, mode: o.splitMode, folder: folder, control: control))
        case .pdfRotate:
            return ConverterOutput(files: [try ConverterPDFEngine.rotate(input, angle: o.rotation, spec: o.pdfPages, folder: folder, control: control)])
        case .pdfCompress:
            let r = try ConverterPDFEngine.compress(input, level: o.pdfCompression, folder: folder, control: control)
            guard let url = r.url else {
                return ConverterOutput(note: "Déjà bien optimisé : impossible de gagner plus de 5 %, je n'ai rien créé.")
            }
            return ConverterOutput(files: [url])
        case .pdfToImages:
            return ConverterOutput(files: [try ConverterPDFEngine.toImages(input, format: o.rasterFormat, dpi: o.rasterDPI, spec: o.pdfPages,
                                                                            folder: folder, control: control)])
        case .documentConvert:
            let kind = spec.kinds.first ?? .document
            return ConverterOutput(files: [try ConverterDocumentEngine.convert(input, kind: kind, to: o.docFormat, folder: folder, control: control)])
        case .archiveZip:
            return ConverterOutput(files: try await ConverterArchiveEngine.zip(spec.inputs, mode: o.zipMode, folder: folder, control: control))
        case .archiveExtract:
            return ConverterOutput(files: [try await ConverterArchiveEngine.extract(input, folder: folder, control: control)])
        case .rename:
            let items = zip(spec.inputs, spec.names).map { (url: $0.0, newName: $0.1) }
            let pairs = try ConverterRename.apply(items, control: control)
            return ConverterOutput(files: pairs.map(\.to), renamed: pairs)
        case .ocr:
            let text = try ConverterVision.ocr(input, kind: spec.kinds.first ?? .image, control: control)
            return ConverterOutput(text: text, note: text.isEmpty ? "Aucun texte reconnu." : nil)
        case .qrRead:
            let codes = try ConverterVision.readCodes(input, kind: spec.kinds.first ?? .image, control: control)
            return ConverterOutput(codes: codes, note: codes.isEmpty ? "Aucun code trouvé." : nil)
        case .qrGenerate:
            throw ConverterError.unsupported("Le QR code se crée depuis la page.")
        }
    }

    /// WebP through ffmpeg: the upright image goes through a temporary PNG first (ffmpeg reads HEIC poorly).
    private static func webp(_ input: URL, maxSide: Int, quality: Double, spec: Spec, control: ConverterControl) async throws -> URL {
        guard let ffmpeg = spec.ffmpeg else { throw ConverterError.unsupported("Le WebP demande ffmpeg (brew install ffmpeg).") }
        guard await Task.detached(operation: { ConverterMediaEngine.ffmpegEncoders(ffmpeg) }).value.contains("libwebp") else {
            throw ConverterError.unsupported("Ton ffmpeg n'a pas l'encodeur WebP (libwebp).")
        }
        let src = try ConverterImageEngine.source(input)
        guard let image = ConverterImageEngine.uprightImage(src, index: CGImageSourceGetPrimaryImageIndex(src), maxSide: maxSide),
              let png = ConverterImageEngine.pngData(image), let tmp = FS.userTempDir else {
            throw ConverterError.unreadable(input.lastPathComponent)
        }
        let temp = try FileOps.write(png, to: URL(fileURLWithPath: tmp).appendingPathComponent("Heartware-\(UUID().uuidString).png"))
        defer { ConverterOutputs.discard(temp) }
        let out = FileOps.outputURL(for: input, extension: "webp", folder: spec.folder ?? input.deletingLastPathComponent())
        try await ConverterMediaEngine.runFFmpeg(ffmpeg, input: temp, codec: ["-c:v", "libwebp", "-quality", "\(Int(quality * 100))"],
                                                 output: out, duration: nil, control: control)
        return out
    }
}
