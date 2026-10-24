import Foundation
import AppKit
import PDFKit

/// `--doc-check <fichier> [--to pdf|docx|rtf|html|txt|odt] [--out <dossier>]`: converts one real document exactly as the
/// converter does, and says what the Word reader understood of it. Writes only the converted file.
enum ConverterDocCheck {
    static func run(_ path: String, format: String?, folder: String?) -> [String] {
        let url = URL(fileURLWithPath: FS.expand(path))
        var lines: [String] = []
        if ["emf", "wmf"].contains(url.pathExtension.lowercased()) {
            // A metafile alone: drawn to a PNG beside the requested folder, to check the metafile player.
            guard let data = try? Data(contentsOf: url), let image = ConverterMetafile.image(data, size: .zero),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return ["✗ métafichier illisible"] }
            let out = URL(fileURLWithPath: FS.expand(folder ?? url.deletingLastPathComponent().path)).appendingPathComponent(url.lastPathComponent + ".png")
            do { _ = try FileOps.write(png, to: out) } catch { return ["✗ \(error.localizedDescription)"] }
            return ["✓ \(out.path) \(image.width)×\(image.height)"]
        }
        if ["docx", "docm", "dotx", "dotm"].contains(url.pathExtension.lowercased()) {
            do {
                let t = Date()
                let doc = try ConverterDocx.read(try Data(contentsOf: url))
                let s = doc.sections[0]
                lines.append(String(format: "Word lu en %.2f s : %d caractères, %d section(s), page %.0f × %.0f pt, %d objet(s) flottant(s), %d note(s), %d saut(s) de page",
                                    Date().timeIntervalSince(t), doc.text.length, doc.sections.count, s.pageSize.width, s.pageSize.height,
                                    doc.anchors.count, doc.footnotes.count, doc.breaks.count))
            } catch {
                lines.append("✗ lecteur Word : \(error.localizedDescription) (repli sur textutil)")
            }
        }
        let format = ConverterDocFormat(rawValue: format ?? "pdf") ?? .pdf
        let t = Date()
        do {
            let out = try ConverterDocumentEngine.convert(url, kind: ConverterKind.detect(name: url.lastPathComponent, isDirectory: false), to: format,
                                                          folder: folder.map { URL(fileURLWithPath: FS.expand($0)) }, control: ConverterControl { _ in })
            var line = String(format: "✓ %@ en %.2f s", out.path, Date().timeIntervalSince(t))
            if format == .pdf, let pdf = PDFDocument(url: out) { line += ", \(pdf.pageCount) page(s)" }
            lines.append(line)
        } catch {
            lines.append("✗ \(error.localizedDescription)")
        }
        return lines
    }
}
