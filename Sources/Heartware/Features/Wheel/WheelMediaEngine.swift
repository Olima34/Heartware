import Foundation
import AVFoundation
import PDFKit
import ImageIO

/// PDF work the converter does not do: Word and text out of a PDF (read by OCR when it is a scan), a single page as an
/// image, and a new PDF of chosen pages.
enum WheelDocEngine {
    /// The text of every page; a page without text (a scan) is read by OCR.
    static func text(of input: URL, control: ConverterControl) throws -> String {
        let doc = try ConverterPDFEngine.open(input)
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            try control.check()
            guard let page = doc.page(at: i) else { continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 12, let image = ConverterPDFEngine.render(page, dpi: 200) {
                text = (try? ConverterVision.recognizeText(image)) ?? text
            }
            pages.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            control.progress(Double(i + 1) / Double(max(1, doc.pageCount)))
        }
        return pages.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func toText(_ input: URL, folder: URL?, control: ConverterControl) throws -> URL {
        let text = try self.text(of: input, control: control)
        guard !text.isEmpty else { throw ConverterError.failed("Aucun texte trouvé dans « \(input.lastPathComponent) ».") }
        return try FileOps.write(Data(text.utf8), to: FileOps.outputURL(for: input, extension: "txt", folder: folder))
    }

    /// A Word document with the PDF's text and its look (fonts, sizes, bold), page after page; a scan gives its OCR text.
    static func toWord(_ input: URL, folder: URL?, control: ConverterControl) throws -> URL {
        let doc = try ConverterPDFEngine.open(input)
        let result = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            try control.check()
            guard let page = doc.page(at: i) else { continue }
            var part = page.attributedString ?? NSAttributedString()
            if part.string.trimmingCharacters(in: .whitespacesAndNewlines).count < 12, let image = ConverterPDFEngine.render(page, dpi: 200),
               let text = try? ConverterVision.recognizeText(image), !text.isEmpty {
                part = NSAttributedString(string: text)
            }
            if result.length > 0 && part.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(part)
            control.progress(Double(i + 1) / Double(max(1, doc.pageCount)))
        }
        guard result.string.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else {
            throw ConverterError.failed("Aucun texte trouvé dans « \(input.lastPathComponent) ».")
        }
        guard let data = try? result.data(from: NSRange(location: 0, length: result.length),
                                          documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]) else {
            throw ConverterError.failed("Le document Word n'a pas pu être écrit.")
        }
        return try FileOps.write(data, to: FileOps.outputURL(for: input, extension: "docx", folder: folder))
    }

    /// A PDF of one page becomes one picture next to it; a longer one, a folder of pictures (the converter's).
    static func toImages(_ input: URL, format: ConverterRasterFormat, folder: URL?, control: ConverterControl) throws -> URL {
        let doc = try ConverterPDFEngine.open(input)
        guard doc.pageCount == 1, let page = doc.page(at: 0) else {
            return try ConverterPDFEngine.toImages(input, format: format, dpi: 200, spec: "", folder: folder, control: control)
        }
        control.progress(nil)
        guard let image = ConverterPDFEngine.render(page, dpi: 200),
              let data = ConverterImageEngine.encode(image, uti: format.uti, quality: format == .png ? nil : 0.9) else {
            throw ConverterError.failed("La page n'a pas pu être dessinée.")
        }
        return try FileOps.write(data, to: FileOps.outputURL(for: input, extension: format.ext, folder: folder))
    }

    /// A page kept in the new PDF, in its new place, with the quarter turns added to its own.
    struct PageChoice: Sendable, Equatable {
        var index: Int
        var turns: Int
    }

    /// A new PDF with these pages, in this order, turned as asked.
    static func pages(_ input: URL, _ choices: [PageChoice], folder: URL?, control: ConverterControl) throws -> URL {
        let doc = try ConverterPDFEngine.open(input)
        let out = PDFDocument()
        for (n, c) in choices.enumerated() {
            try control.check()
            guard let page = doc.page(at: c.index)?.copy() as? PDFPage else { continue }
            page.rotation = ((page.rotation + 90 * c.turns) % 360 + 360) % 360
            out.insert(page, at: out.pageCount)
            control.progress(Double(n + 1) / Double(max(1, choices.count)))
        }
        guard out.pageCount > 0, let data = out.dataRepresentation() else { throw ConverterError.failed("Le PDF n'a pas pu être écrit.") }
        let kept = ConverterPDFEngine.describePages(choices.map(\.index).sorted())
        let reordered = choices.map(\.index) != choices.map(\.index).sorted()
        let suffix = choices.count == doc.pageCount ? (reordered ? "réordonné" : "pivoté") : "pages \(kept)"
        return try FileOps.write(data, to: FileOps.outputURL(for: input, extension: "pdf", suffix: suffix, folder: folder))
    }
}

/// Video and audio work the converter does not do: without the sound, cut, one frame as a picture.
enum WheelMediaEngine {
    /// The same container when a copy can go in it untouched (MOV stays MOV, MP4 and M4V become MP4).
    static func fileType(for input: URL) -> (type: AVFileType, ext: String) {
        switch input.pathExtension.lowercased() {
        case "mov", "qt": return (.mov, "mov")
        case "m4a": return (.m4a, "m4a")
        default: return (.mp4, "mp4")
        }
    }

    static func mute(_ input: URL, folder: URL?, control: ConverterControl) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let videos = try await asset.loadTracks(withMediaType: .video)
        guard !videos.isEmpty else { throw ConverterError.unsupported("« \(input.lastPathComponent) » n'a pas d'image.") }
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard !audios.isEmpty else { throw ConverterError.unsupported("« \(input.lastPathComponent) » n'a déjà pas de son.") }
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for track in videos {
            guard let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try copy.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            // A phone video keeps its orientation.
            copy.preferredTransform = try await track.load(.preferredTransform)
        }
        let (type, ext) = fileType(for: input)
        return try await export(composition, preset: AVAssetExportPresetPassthrough, type: type == .m4a ? .mp4 : type,
                                out: FileOps.outputURL(for: input, extension: ext == "m4a" ? "mp4" : ext, suffix: "sans son", folder: folder),
                                range: nil, control: control)
    }

    /// The part between `start` and `end`, without re-encoding when the format allows it.
    static func trim(_ input: URL, start: Double, end: Double, folder: URL?, control: ConverterControl) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let hasVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
        var (type, ext) = fileType(for: input)
        var preset = AVAssetExportPresetPassthrough
        if !hasVideo {
            // Sound: an M4A is cut as it is, anything else becomes AAC.
            if ext != "m4a" { preset = AVAssetExportPresetAppleM4A }
            type = .m4a
            ext = "m4a"
        } else if !(await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: type)) {
            preset = AVAssetExportPresetHighestQuality
        }
        return try await export(asset, preset: preset, type: type, out: FileOps.outputURL(for: input, extension: ext, suffix: "coupée", folder: folder),
                                range: range, control: control)
    }

    /// The frame at `seconds`, as a PNG named after the moment ("vacances image 1 min 05 s.png").
    static func frame(_ input: URL, at seconds: Double, folder: URL?) async throws -> URL {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: input))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        guard let data = ConverterImageEngine.pngData(image) else { throw ConverterError.failed("L'image n'a pas pu être enregistrée.") }
        return try FileOps.write(data, to: FileOps.outputURL(for: input, extension: "png", suffix: "image \(moment(seconds))", folder: folder))
    }

    /// "12 s", "1 min 05 s", "1 h 02 min 05 s": readable in a file name (no colon, the Finder shows it as a slash).
    static func moment(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        if h > 0 { return "\(h) h \(String(format: "%02d", m)) min \(String(format: "%02d", r)) s" }
        if m > 0 { return "\(m) min \(String(format: "%02d", r)) s" }
        return "\(r) s"
    }

    /// "1:05,3" under the player.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let m = Int(s) / 60
        let r = s - Double(m * 60)
        return "\(m):\(String(format: "%04.1f", r).replacingOccurrences(of: ".", with: ","))"
    }

    private static func export(_ asset: AVAsset, preset: String, type: AVFileType, out: URL, range: CMTimeRange?,
                               control: ConverterControl) async throws -> URL {
        guard !DemoData.isEnabled else { throw FileOps.Failure.demo }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConverterError.failed("Ce fichier ne peut pas être exporté ainsi.")
        }
        session.outputURL = out
        session.outputFileType = type
        if let range { session.timeRange = range }
        session.shouldOptimizeForNetworkUse = type == .mp4 || type == .m4a
        let done = ConverterFlag()
        session.exportAsynchronously { done.set() }
        while !done.isSet {
            if control.isCancelled || Task.isCancelled { session.cancelExport() }
            control.progress(Double(session.progress))
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        switch session.status {
        case .completed:
            FileOps.didCreate(out)
            control.progress(1)
            return out
        case .cancelled:
            ConverterOutputs.discard(out)
            throw ConverterError.cancelled
        default:
            ConverterOutputs.discard(out)
            throw ConverterError.failed(session.error?.localizedDescription ?? "L'export a échoué.")
        }
    }
}
