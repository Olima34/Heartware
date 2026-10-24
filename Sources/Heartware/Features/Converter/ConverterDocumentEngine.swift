import Foundation
import AppKit

/// Text documents: `textutil` (out of process) for Word, RTF, HTML, ODT and text; Markdown read with
/// `AttributedString(markdown:)`; PDF drawn page by page with the AppKit text system.
enum ConverterDocumentEngine {
    static let textutil = "/usr/bin/textutil"

    static func convert(_ input: URL, kind: ConverterKind, to format: ConverterDocFormat, folder: URL?,
                        control: ConverterControl) throws -> URL {
        let ext = input.pathExtension.lowercased()
        if ext == format.ext || (format == .html && ext == "htm") || (format == .txt && ext == "text") {
            throw ConverterError.unsupported("« \(input.lastPathComponent) » est déjà au format \(format.short).")
        }
        control.progress(nil)
        let out = FileOps.outputURL(for: input, extension: format.ext, folder: folder)
        let title = input.deletingPathExtension().lastPathComponent

        if format == .pdf {
            let data = try pdfData(input, kind: kind, control: control)
            return try FileOps.write(data, to: out)
        }

        if kind == .markdown {
            let source = try readText(input)
            let blocks = ConverterMarkdown.parse(source)
            let data: Data?
            switch format {
            case .html: data = Data(ConverterMarkdown.html(blocks, title: title).utf8)
            case .txt: data = Data(ConverterMarkdown.attributed(blocks).string.utf8)
            case .docx, .rtf, .odt: data = documentData(ConverterMarkdown.attributed(blocks), format: format)
            case .pdf: data = nil
            }
            guard let data else { throw ConverterError.failed("La conversion du Markdown a échoué.") }
            try control.check()
            return try FileOps.write(data, to: out)
        }

        let r = Shell.run(textutil, ["-convert", format.rawValue] + encodingArgs(input) + ["-output", out.path, input.path], timeout: 180)
        guard r.ok, FileManager.default.fileExists(atPath: out.path) else {
            ConverterOutputs.discard(out)
            throw ConverterError.failed(r.err.isEmpty ? "textutil n'a pas pu convertir ce document." : r.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        FileOps.didCreate(out)
        control.progress(1)
        return out
    }

    /// The PDF of a text document, in memory: written by `convert`, opened as is by Remplir et signer.
    static func pdfData(_ input: URL, kind: ConverterKind, control: ConverterControl) throws -> Data {
        let ext = input.pathExtension.lowercased()
        let title = input.deletingPathExtension().lastPathComponent
        if kind == .markdown {
            guard let data = ConverterTextPDF.render(ConverterMarkdown.attributed(ConverterMarkdown.parse(try readText(input))), title: title) else {
                throw ConverterError.failed("La conversion du Markdown a échoué.")
            }
            try control.check()
            return data
        }
        // Word: read and laid out like Word does (styles, tables, pictures, headers, footers, page size).
        if ["docx", "docm", "dotx", "dotm"].contains(ext) {
            do {
                let doc = try ConverterDocx.read(try Data(contentsOf: input))
                try control.check()
                if let data = try ConverterPageLayout.render(doc, title: title, control: control) { return data }
            } catch ConverterError.cancelled {
                throw ConverterError.cancelled
            } catch {
                // A document this reader does not understand still goes through textutil below.
            }
        }
        // textutil turns anything else into RTF on stdout; the text system lays it out on the document's own page size.
        let r = Shell.run(textutil, ["-convert", "rtf", "-stdout"] + encodingArgs(input) + [input.path], timeout: 180)
        var info: NSDictionary?
        guard r.ok, let attributed = NSAttributedString(rtf: Data(r.out.utf8), documentAttributes: &info) else {
            throw ConverterError.failed(r.err.isEmpty ? "textutil n'a pas pu lire ce document." : r.err)
        }
        try control.check()
        guard let data = ConverterTextPDF.render(attributed, title: title, page: ConverterTextPDF.page(info)) else {
            throw ConverterError.failed("Le PDF n'a pas pu être dessiné.")
        }
        return data
    }

    /// Plain text files are read as UTF-8 when they are valid UTF-8 (textutil guesses otherwise).
    private static func encodingArgs(_ input: URL) -> [String] {
        guard ["txt", "text"].contains(input.pathExtension.lowercased()),
              let data = try? Data(contentsOf: input), String(data: data, encoding: .utf8) != nil else { return [] }
        return ["-inputencoding", "UTF-8"]
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        throw ConverterError.unreadable(url.lastPathComponent)
    }

    private static func documentData(_ text: NSAttributedString, format: ConverterDocFormat) -> Data? {
        let type: NSAttributedString.DocumentType
        switch format {
        case .docx: type = .officeOpenXML
        case .odt: type = .openDocument
        default: type = .rtf
        }
        return try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
    }
}

// MARK: - Markdown

/// Markdown read by Foundation (`AttributedString(markdown:)`, full syntax), regrouped into blocks,
/// then written as HTML or as an attributed string for PDF and Word.
enum ConverterMarkdown {
    enum Container: Equatable {
        case list(id: Int, ordered: Bool)
        case item(id: Int, ordinal: Int)
        case quote(id: Int)
        case table(id: Int)
        case row(id: Int, header: Bool)
    }

    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case code(String?)
        case rule
        case cell(header: Bool)
    }

    struct Inline: Equatable {
        var text: String
        var strong = false
        var emphasis = false
        var code = false
        var strike = false
        var link: URL?
        var image: URL?
    }

    struct Block: Equatable {
        var kind: Kind
        var containers: [Container]
        var inlines: [Inline]

        var plainText: String { inlines.map(\.text).joined() }
    }

    static func parse(_ source: String) -> [Block] {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let attributed = try? AttributedString(markdown: source, options: options) else {
            return [Block(kind: .paragraph, containers: [], inlines: [Inline(text: source)])]
        }
        var blocks: [Block] = []
        for (intent, range) in attributed.runs[\.presentationIntent] {
            var kind: Kind = .paragraph
            var containers: [Container] = []
            var headerRow = false
            for component in (intent?.components ?? []).reversed() {
                switch component.kind {
                case .paragraph: kind = .paragraph
                case .header(let level): kind = .heading(level)
                case .codeBlock(let language): kind = .code(language)
                case .thematicBreak: kind = .rule
                case .orderedList: containers.append(.list(id: component.identity, ordered: true))
                case .unorderedList: containers.append(.list(id: component.identity, ordered: false))
                case .listItem(let ordinal): containers.append(.item(id: component.identity, ordinal: ordinal))
                case .blockQuote: containers.append(.quote(id: component.identity))
                case .table: containers.append(.table(id: component.identity))
                case .tableHeaderRow:
                    headerRow = true
                    containers.append(.row(id: component.identity, header: true))
                case .tableRow: containers.append(.row(id: component.identity, header: false))
                case .tableCell: kind = .cell(header: headerRow)
                @unknown default: break
                }
            }
            var inlines: [Inline] = []
            for run in attributed[range].runs {
                let intents = run.inlinePresentationIntent ?? []
                inlines.append(Inline(text: String(attributed[run.range].characters),
                                      strong: intents.contains(.stronglyEmphasized), emphasis: intents.contains(.emphasized),
                                      code: intents.contains(.code), strike: intents.contains(.strikethrough),
                                      link: run.link, image: run.imageURL))
            }
            blocks.append(Block(kind: kind, containers: containers, inlines: inlines))
        }
        return blocks
    }

    // MARK: HTML

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func inlineHTML(_ inlines: [Inline]) -> String {
        inlines.map { i in
            if let image = i.image { return "<img src=\"\(escape(image.absoluteString))\" alt=\"\(escape(i.text))\">" }
            var s = escape(i.text).replacingOccurrences(of: "\u{2028}", with: "<br>")
            if i.code { s = "<code>\(s)</code>" }
            if i.strike { s = "<del>\(s)</del>" }
            if i.emphasis { s = "<em>\(s)</em>" }
            if i.strong { s = "<strong>\(s)</strong>" }
            if let link = i.link { s = "<a href=\"\(escape(link.absoluteString))\">\(s)</a>" }
            return s
        }.joined()
    }

    static func body(_ blocks: [Block]) -> String {
        var out = ""
        var stack: [Container] = []
        func open(_ c: Container) -> String {
            switch c {
            case .list(_, let ordered): return ordered ? "<ol>\n" : "<ul>\n"
            case .item: return "<li>"
            case .quote: return "<blockquote>\n"
            case .table: return "<table>\n"
            case .row: return "<tr>"
            }
        }
        func close(_ c: Container) -> String {
            switch c {
            case .list(_, let ordered): return ordered ? "</ol>\n" : "</ul>\n"
            case .item: return "</li>\n"
            case .quote: return "</blockquote>\n"
            case .table: return "</table>\n"
            case .row: return "</tr>\n"
            }
        }
        for b in blocks {
            var common = 0
            while common < stack.count, common < b.containers.count, stack[common] == b.containers[common] { common += 1 }
            while stack.count > common { out += close(stack.removeLast()) }
            for c in b.containers[common...] {
                out += open(c)
                stack.append(c)
            }
            let inner = inlineHTML(b.inlines)
            switch b.kind {
            case .paragraph:
                // Tight list items read better without paragraph margins.
                if case .item = stack.last { out += inner } else { out += "<p>\(inner)</p>\n" }
            case .heading(let level): out += "<h\(min(6, level))>\(inner)</h\(min(6, level))>\n"
            case .code(let language):
                var code = b.plainText
                if code.hasSuffix("\n") { code.removeLast() }
                let lang = language.map { $0.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "+" } } ?? ""
                out += lang.isEmpty ? "<pre><code>\(escape(code))</code></pre>\n" : "<pre><code class=\"language-\(lang)\">\(escape(code))</code></pre>\n"
            case .rule: out += "<hr>\n"
            case .cell(let header): out += header ? "<th>\(inner)</th>" : "<td>\(inner)</td>"
            }
        }
        while let c = stack.popLast() { out += close(c) }
        return out
    }

    static func html(_ blocks: [Block], title: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="Heartware">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 16px/1.65 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; max-width: 46em; margin: 3em auto; padding: 0 1.2em; color: #1f1e1d; background: #fcfbf9; }
        h1, h2, h3 { font-family: ui-serif, "New York", Georgia, serif; font-weight: 500; line-height: 1.25; }
        a { color: #2c84db; }
        code { font: 0.88em ui-monospace, Menlo, monospace; background: #efede7; padding: 0.1em 0.35em; border-radius: 4px; }
        pre { background: #efede7; padding: 1em 1.2em; border-radius: 10px; overflow: auto; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 1em 0; padding: 0.1em 1em; border-left: 3px solid #d6d3c9; color: #5f5d57; }
        table { border-collapse: collapse; margin: 1em 0; }
        th, td { border: 1px solid #deDBd1; padding: 0.4em 0.75em; text-align: left; }
        hr { border: 0; border-top: 1px solid #deDBd1; margin: 2em 0; }
        img { max-width: 100%; }
        @media (prefers-color-scheme: dark) {
          body { color: #f4f2ec; background: #141413; }
          code, pre { background: #222221; }
          blockquote { color: #b4b1a7; border-color: #3a3a37; }
          th, td, hr { border-color: #3a3a37; }
          a { color: #4c9ae6; }
        }
        </style>
        </head>
        <body>
        \(body(blocks))</body>
        </html>

        """
    }

    // MARK: Attributed string (PDF, Word, RTF)

    static func attributed(_ blocks: [Block]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodySize: CGFloat = 11
        let text = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.11, alpha: 1)
        let muted = NSColor(srgbRed: 0.37, green: 0.36, blue: 0.34, alpha: 1)
        let codeBackground = NSColor(srgbRed: 0.94, green: 0.93, blue: 0.91, alpha: 1)
        var previousItem: Int?
        for (index, b) in blocks.enumerated() {
            let lists = b.containers.compactMap { c -> Bool? in if case .list(_, let ordered) = c { return ordered } else { return nil } }
            let quotes = b.containers.filter { if case .quote = $0 { return true } else { return false } }.count
            var itemID: Int?
            var ordinal = 1
            for c in b.containers { if case .item(let id, let n) = c { itemID = id; ordinal = n } }
            let indent = CGFloat(lists.count) * 18 + CGFloat(quotes) * 14

            let para = NSMutableParagraphStyle()
            para.lineHeightMultiple = 1.18
            para.paragraphSpacing = 7
            para.headIndent = indent
            para.firstLineHeadIndent = indent
            var font = NSFont.systemFont(ofSize: bodySize)
            var color = quotes > 0 ? muted : text
            var prefix = ""
            switch b.kind {
            case .heading(let level):
                let sizes: [CGFloat] = [22, 17, 14, 12.5, 11.5, 11]
                font = NSFont.systemFont(ofSize: sizes[min(5, max(0, level - 1))], weight: level <= 2 ? .bold : .semibold)
                para.paragraphSpacingBefore = level <= 2 ? 12 : 8
                para.paragraphSpacing = 6
            case .code:
                font = NSFont.monospacedSystemFont(ofSize: bodySize - 1.5, weight: .regular)
                para.lineHeightMultiple = 1.05
            case .rule:
                color = muted
                para.alignment = .center
            case .cell:
                // Columns on fixed tab stops.
                para.tabStops = (1...8).map { NSTextTab(textAlignment: .left, location: indent + CGFloat($0) * 150) }
                para.defaultTabInterval = 150
                para.paragraphSpacing = 3
            case .paragraph:
                break
            }
            if let itemID, itemID != previousItem, !isCode(b.kind) {
                prefix = (lists.last ?? false) ? "\(ordinal).\t" : "•\t"
                para.firstLineHeadIndent = indent - 14
                para.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            }
            previousItem = itemID ?? previousItem

            let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
            if !prefix.isEmpty { result.append(NSAttributedString(string: prefix, attributes: base)) }
            if b.kind == .rule {
                result.append(NSAttributedString(string: String(repeating: "—", count: 12), attributes: base))
            } else if isCode(b.kind) {
                var code = b.plainText
                if code.hasSuffix("\n") { code.removeLast() }
                var attrs = base
                attrs[.backgroundColor] = codeBackground
                result.append(NSAttributedString(string: code, attributes: attrs))
            } else {
                for i in b.inlines {
                    var attrs = base
                    var f = font
                    if case .cell(header: true) = b.kind { f = NSFont.systemFont(ofSize: f.pointSize, weight: .semibold) }
                    if i.strong { f = NSFont.systemFont(ofSize: f.pointSize, weight: .bold) }
                    if i.emphasis { f = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(.italic), size: f.pointSize) ?? f }
                    if i.code {
                        f = NSFont.monospacedSystemFont(ofSize: f.pointSize - 1, weight: .regular)
                        attrs[.backgroundColor] = codeBackground
                    }
                    if i.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    if let link = i.link ?? i.image {
                        attrs[.link] = link
                        attrs[.foregroundColor] = NSColor(srgbRed: 0.17, green: 0.52, blue: 0.86, alpha: 1)
                    }
                    attrs[.font] = f
                    result.append(NSAttributedString(string: i.text.replacingOccurrences(of: "\u{2028}", with: "\n"), attributes: attrs))
                }
            }
            // Table cells of one row share a line, separated by tabs.
            if case .cell = b.kind, index + 1 < blocks.count, case .cell = blocks[index + 1].kind,
               rowID(b) == rowID(blocks[index + 1]) {
                result.append(NSAttributedString(string: "\t", attributes: base))
            } else if index + 1 < blocks.count {
                result.append(NSAttributedString(string: "\n", attributes: base))
            }
        }
        return result
    }

    private static func isCode(_ kind: Kind) -> Bool {
        if case .code = kind { return true }
        return false
    }

    private static func rowID(_ b: Block) -> Int? {
        for c in b.containers { if case .row(let id, _) = c { return id } }
        return nil
    }
}

// MARK: - Text to PDF

/// Lays an attributed string out on pages (A4 unless the document says otherwise), through `ConverterPageLayout`.
enum ConverterTextPDF {
    static func render(_ text: NSAttributedString, title: String, page: ConverterDocxSection? = nil) -> Data? {
        var section = page ?? ConverterDocxSection()
        if page == nil { section.margins = NSEdgeInsets(top: 56.7, left: 56.7, bottom: 56.7, right: 56.7) }
        return try? ConverterPageLayout.render(ConverterDocxDocument(text: text, sections: [section]), title: title)
    }

    /// The paper size and margins an RTF document carries, when they make sense.
    static func page(_ info: NSDictionary?) -> ConverterDocxSection? {
        guard let info, let paper = (info[NSAttributedString.DocumentAttributeKey.paperSize] as? NSValue)?.sizeValue,
              paper.width > 144, paper.height > 144 else { return nil }
        var section = ConverterDocxSection()
        section.pageSize = paper
        func margin(_ key: NSAttributedString.DocumentAttributeKey) -> CGFloat {
            (info[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 72
        }
        section.margins = NSEdgeInsets(top: margin(.topMargin), left: margin(.leftMargin), bottom: margin(.bottomMargin), right: margin(.rightMargin))
        if section.textWidth < 72 || section.textHeight < 72 { section.margins = NSEdgeInsets(top: 56.7, left: 56.7, bottom: 56.7, right: 56.7) }
        return section
    }
}
