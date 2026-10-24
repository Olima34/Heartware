import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// `--preview-check`: makes one small file of each kind in a temporary folder and runs the preview of every operation
/// on it, for real (what the preview shows is what the conversion makes). Nothing outside that folder is touched.
enum ConverterPreviewCheck {
    static func run() async -> [String] {
        guard let tmp = FS.userTempDir else { return ["✗ pas de dossier temporaire"] }
        let dir = URL(fileURLWithPath: tmp).appendingPathComponent("Heartware-banc-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var lines: [String] = []

        // Sample files.
        let png = dir.appendingPathComponent("photo.png")
        let text = dir.appendingPathComponent("note.txt")
        let md = dir.appendingPathComponent("lisez-moi.md")
        let pdf = dir.appendingPathComponent("rapport.pdf")
        let ocrImage = dir.appendingPathComponent("texte.png")
        let audio = dir.appendingPathComponent("voix.aiff")
        let video = dir.appendingPathComponent("film.mp4")
        let zip = dir.appendingPathComponent("archive.zip")
        writePNG(png, text: nil)
        writePNG(ocrImage, text: "Bonjour Heartware")
        try? "Bonjour,\nceci est une note de test.".write(to: text, atomically: true, encoding: .utf8)
        try? "# Titre\n\nUn paragraphe avec **du gras**.\n\n- un\n- deux\n".write(to: md, atomically: true, encoding: .utf8)
        writePDF(pdf, pages: 3)
        _ = Shell.run("/usr/bin/say", ["-o", audio.path, "Bonjour, ceci est un essai."], timeout: 30)
        if let ffmpeg = Shell.which("ffmpeg") {
            _ = Shell.run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc=duration=8:size=640x360:rate=25",
                                   "-f", "lavfi", "-i", "sine=frequency=440:duration=8", "-shortest",
                                   "-pix_fmt", "yuv420p", "-c:a", "aac", video.path], timeout: 60)
        }
        _ = Shell.run("/usr/bin/zip", ["-j", "-q", zip.path, text.path, md.path], timeout: 30)

        var options = ConverterOptions()
        options.pdfPages = "1-2"
        options.container = .mov // the sample is an MP4: "MOV ↔ MP4" must have something to do
        let ffmpeg = Shell.which("ffmpeg")
        let cases: [(ConverterOperation, [URL], ConverterKind)] = [
            (.imageConvert, [png], .image), (.imageResize, [png], .image), (.imageCompress, [png], .image), (.imageStrip, [png], .image),
            (.imagesToPDF, [png, ocrImage], .image),
            (.pdfSplit, [pdf], .pdf), (.pdfRotate, [pdf], .pdf), (.pdfCompress, [pdf], .pdf), (.pdfToImages, [pdf], .pdf), (.pdfMerge, [pdf, pdf], .pdf),
            (.documentConvert, [text], .document), (.documentConvert, [md], .markdown),
            (.audioConvert, [audio], .audio),
            (.videoCompress, [video], .video), (.videoGIF, [video], .video), (.videoAudio, [video], .video), (.videoContainer, [video], .video),
            (.archiveZip, [text, md], .document), (.archiveExtract, [zip], .archive),
            (.ocr, [ocrImage], .image), (.qrRead, [png], .image)
        ]
        for (op, inputs, kind) in cases {
            guard inputs.allSatisfy({ FS.exists($0.path) }) else {
                lines.append("– \(op.title) : fichier d'essai absent (outil manquant)")
                continue
            }
            let folder = dir.appendingPathComponent("apercu-\(op.rawValue)-\(UUID().uuidString.prefix(4))")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let spec = ConverterEngine.Spec(operation: op, inputs: inputs, kinds: inputs.map { _ in kind }, names: [],
                                            options: options, folder: nil, ffmpeg: ffmpeg)
            let t = Date()
            do {
                let piece: (start: Double, seconds: Double?) = ConverterPreviewer.usesPiece(op) ? (2, 4) : (0, nil)
                let r = try await ConverterPreviewer.make(spec, folder: folder, control: ConverterControl(report: { _ in }), piece: piece)
                let shown = ConverterPreviewFiles.expand(r.outputs)
                // Everything the preview made must sit in its own scratch folder.
                let outside = shown.filter { !$0.path.hasPrefix(folder.path) && !$0.path.hasPrefix(dir.path) }
                var what: String
                if let t = r.text { what = "texte « \(t.prefix(40)) »" }
                else if r.operation == .qrRead { what = "\(r.codes.count) code(s)" }
                else if let l = r.listing { what = "\(l.count) élément(s) listés" }
                else { what = "\(shown.count) fichier(s), \(Fmt.bytes(r.outputSize))" + (r.estimatedSize.map { ", ≈ \(Fmt.bytes($0)) en entier" } ?? "") }
                if let d = r.outputDetail { what += " · \(d)" }
                lines.append("\(outside.isEmpty ? "✓" : "✗ écrit hors du dossier d'aperçu !") \(op.title) (\(inputs.first!.pathExtension)) : \(what) en \(String(format: "%.1f", Date().timeIntervalSince(t))) s")
            } catch {
                lines.append("✗ \(op.title) (\(inputs.first!.pathExtension)) : \(error.localizedDescription)")
            }
        }
        // "MOV ↔ MP4" on an MP4 kept in MP4: the preview refuses, like the conversion (the excerpt is a .mov).
        if FS.exists(video.path) {
            var same = options
            same.container = .mp4
            let spec = ConverterEngine.Spec(operation: .videoContainer, inputs: [video], kinds: [.video], names: [], options: same,
                                            folder: nil, ffmpeg: ffmpeg)
            let folder = dir.appendingPathComponent("apercu-meme-format")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let made = try? await ConverterPreviewer.make(spec, folder: folder, control: ConverterControl(report: { _ in }), piece: (2, 4))
            lines.append(made == nil ? "✓ MOV ↔ MP4 (mp4 → mp4) : refusé comme la conversion" : "✗ MOV ↔ MP4 (mp4 → mp4) : l'aperçu réussit, la conversion échouerait")
        }
        // Images → PDF: an opaque HEIC (decoded premultiplied) is still embedded as a JPEG, so the quality changes the size.
        let heic = dir.appendingPathComponent("photo.heic")
        writeHEIC(heic)
        if FS.exists(heic.path) {
            var sizes: [Int64] = []
            for quality in [0.3, 1.0] {
                var o = options
                o.imageQuality = quality
                let spec = ConverterEngine.Spec(operation: .imagesToPDF, inputs: [heic], kinds: [.image], names: [], options: o,
                                                folder: nil, ffmpeg: ffmpeg)
                let folder = dir.appendingPathComponent("apercu-heic-\(Int(quality * 100))")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let r = try? await ConverterPreviewer.make(spec, folder: folder, control: ConverterControl(report: { _ in }))
                sizes.append(r?.outputSize ?? 0)
            }
            lines.append(sizes[0] > 0 && Double(sizes[0]) < Double(sizes[1]) * 0.8
                         ? "✓ Images → PDF (heic opaque) : la qualité compte (\(Fmt.bytes(sizes[0])) à 30 %, \(Fmt.bytes(sizes[1])) à 100 %)"
                         : "✗ Images → PDF (heic opaque) : la qualité ne change rien (\(sizes.map { Fmt.bytes($0) }))")
        }
        lines.append(renameRollBack(in: dir, cancel: false))
        lines.append(renameRollBack(in: dir, cancel: true))
        // The originals must be untouched.
        let untouched = [png, text, md, pdf].allSatisfy { FS.exists($0.path) }
        lines.append(untouched ? "✓ originaux intacts" : "✗ un original a disparu")
        return lines
    }

    /// A batch rename stopped half-way (a locked file, or a cancel after the first file) puts every name back,
    /// the hidden temporary names of a swap included.
    private static func renameRollBack(in dir: URL, cancel: Bool) -> String {
        let what = cancel ? "renommage annulé" : "renommage interrompu"
        let folder = dir.appendingPathComponent(cancel ? "renommage-annule" : "renommage-interrompu")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ["a.txt", "b.txt", "verrou.txt", "x.txt"]
        for n in names { try? Data(n.utf8).write(to: folder.appendingPathComponent(n)) }
        let locked = folder.appendingPathComponent("verrou.txt")
        if !cancel { try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path) }
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        // x is renamed directly, a and b swap through hidden names, the locked file fails last.
        let items = [("x.txt", "x2.txt"), ("a.txt", "b.txt"), ("b.txt", "a.txt"), ("verrou.txt", "verrou2.txt")]
            .map { (url: folder.appendingPathComponent($0.0), newName: $0.1) }
        final class Box: @unchecked Sendable { var control: ConverterControl? }
        let box = Box()
        let control = ConverterControl { _ in if cancel { box.control?.cancel() } }
        box.control = control
        let failed = (try? ConverterRename.apply(items, control: control)) == nil
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        let swapUndone = (try? String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8)) == "a.txt"
        guard failed, left == names, swapUndone else { return "✗ \(what) : \(failed ? "" : "aucune erreur, ")reste \(left)" }
        return "✓ \(what) : tous les noms sont revenus"
    }

    private static func writePNG(_ url: URL, text: String?) {
        let w = 800, h = 500
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 0.95, green: 0.6, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.25, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 160))
        if let text {
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            (text as NSString).draw(at: NSPoint(x: 40, y: 220), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let image = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    /// An opaque photo-like HEIC (a gradient: JPEG quality shows on it).
    private static func writeHEIC(_ url: URL) {
        let w = 800, h = 500
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.95, green: 0.7, blue: 0.4, alpha: 1),
                                                                     CGColor(red: 0.3, green: 0.2, blue: 0.5, alpha: 1)] as CFArray,
                                        locations: nil) else { return }
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        for i in 0..<60 {
            ctx.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: (i * 97) % w, y: (i * 61) % h, width: 30 + i % 40, height: 30 + i % 25))
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func writePDF(_ url: URL, pages: Int) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for i in 1...pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: 0.85, green: 0.45, blue: 0.35, alpha: 1))
            ctx.fill(CGRect(x: 60, y: 600, width: 200 + CGFloat(i) * 40, height: 60))
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
