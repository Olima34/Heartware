import AppKit
import ImageIO

// MARK: - Model

/// A Word section: page size, margins, columns, headers and footers.
struct ConverterDocxSection {
    var start = 0
    var pageSize = CGSize(width: 595.28, height: 841.89)
    var margins = NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
    var header: CGFloat = 36
    var footer: CGFloat = 36
    var columns = 1
    var columnSpace: CGFloat = 36
    var startsPage = true
    var titlePage = false
    var pageStart: Int?
    var pageFormat = "decimal"
    var headers: [String: ConverterDocxStory] = [:]
    var footers: [String: ConverterDocxStory] = [:]

    var textWidth: CGFloat { pageSize.width - margins.left - margins.right }
    var textHeight: CGFloat { pageSize.height - margins.top - margins.bottom }

    func sameGeometry(_ o: ConverterDocxSection) -> Bool {
        pageSize == o.pageSize && columns == o.columns && margins.left == o.margins.left && margins.right == o.margins.right
            && margins.top == o.margins.top && margins.bottom == o.margins.bottom
    }
}

/// Text laid out on its own: a header, a footer, a footnote, the content of a text box.
struct ConverterDocxStory {
    var text: NSAttributedString
    var anchors: [ConverterDocxAnchor] = []
}

/// A floating picture or shape, placed relative to the page, the margins or the paragraph it is anchored to.
final class ConverterDocxAnchor {
    var image: CGImage?
    var fill: NSColor?
    var stroke: NSColor?
    var lineWidth: CGFloat = 0.75
    var geometry = "rect"
    var story: ConverterDocxStory?
    var insets = NSEdgeInsets(top: 3.6, left: 7.2, bottom: 3.6, right: 7.2)
    var textAnchor = "t"
    var size: CGSize
    /// The outline of a shape in its own box, and whether it is a line (stroked, never filled).
    var outline: CGPath?
    var open = false
    var rotation: CGFloat = 0
    var flipH = false
    var flipV = false
    var headEnd: String?
    var tailEnd: String?
    var dash: [CGFloat] = []
    /// The shapes of a group or drawing canvas, each placed at `inner` inside it.
    var scene: [ConverterDocxAnchor]?
    var inner = CGPoint.zero
    var hRelative = "column"
    var hOffset: CGFloat = 0
    var hAlign: String?
    var vRelative = "paragraph"
    var vOffset: CGFloat = 0
    var vAlign: String?
    var behind = false
    var wrap = "none"
    var distance = NSEdgeInsets()
    var index = 0

    init(size: CGSize) { self.size = size }
}

/// A Word document ready to be laid out on pages.
struct ConverterDocxDocument {
    var text: NSAttributedString
    var sections: [ConverterDocxSection]
    var anchors: [ConverterDocxAnchor] = []
    var breaks: [Int] = []
    var footnotes: [(index: Int, story: ConverterDocxStory)] = []
    var evenAndOdd = false
    /// Word's own page breaks from its last save, to follow where they fall near the bottom of a page.
    var hints: [Int] = []
}

// MARK: - Reader

/// Word (.docx) read like Word lays it out: styles and their inheritance, theme fonts and colors, lists, tables,
/// pictures, text boxes, headers and footers, footnotes, sections. The result is drawn by `ConverterPageLayout`.
enum ConverterDocx {
    static let keepNextKey = NSAttributedString.Key("ConverterDocxKeepNext")
    static let widowKey = NSAttributedString.Key("ConverterDocxWidow")
    static let fieldKey = NSAttributedString.Key("ConverterDocxField")
    static let leadersKey = NSAttributedString.Key("ConverterDocxLeaders")
    static let beforeKey = NSAttributedString.Key("ConverterDocxBefore")

    static func read(_ data: Data) throws -> ConverterDocxDocument {
        let pkg = try ConverterDocxPackage(try ConverterZip(data))
        guard let root = pkg.xml(pkg.main), let body = root.child("body") else {
            throw ConverterError.failed("Ce document Word est illisible (pas de corps de texte).")
        }
        var sectionNodes: [ConverterXMLNode?] = []
        func collect(_ n: ConverterXMLNode) {
            for c in n.children {
                if c.name == "sectPr" { sectionNodes.append(c) } else if c.name != "tbl" { collect(c) }
            }
        }
        collect(body)
        if sectionNodes.isEmpty { sectionNodes = [nil] }
        var sections = sectionNodes.map { pkg.section($0) }

        let builder = ConverterDocxBuilder(pkg, part: pkg.main, width: sections[0].textWidth)
        builder.sections = sections
        builder.blocks(body.children)
        builder.endnotes()
        builder.finish()
        for (i, start) in builder.sectionStarts.enumerated() where i < sections.count { sections[i].start = start }

        // Headers and footers, inherited from the previous section when a section has none of its own.
        for i in sections.indices {
            guard let node = sectionNodes[i] else { continue }
            if i > 0 {
                sections[i].headers = sections[i - 1].headers
                sections[i].footers = sections[i - 1].footers
            }
            for (tag, footer) in [("headerReference", false), ("footerReference", true)] {
                for ref in node.all(tag) {
                    guard let id = ref["r:id"], let target = pkg.target(id, part: pkg.main), !target.external else { continue }
                    let story = pkg.story(target.path, width: sections[i].textWidth)
                    if footer { sections[i].footers[ref["type"] ?? "default"] = story } else { sections[i].headers[ref["type"] ?? "default"] = story }
                }
            }
        }

        var doc = ConverterDocxDocument(text: builder.out, sections: sections, anchors: builder.anchors)
        doc.evenAndOdd = pkg.evenAndOdd
        // Word's last page breaks are trusted when Word saved the file last: as many breaks as pages, minus one.
        if let app = pkg.xml("docProps/app.xml"), (app.child("Application")?.text ?? "").contains("Microsoft"),
           let pages = Int(app.child("Pages")?.text ?? ""), pages == builder.renderedBreaks.count + 1 {
            doc.hints = builder.renderedBreaks.filter { $0 > 0 && $0 < builder.out.length }
        }
        var breaks = Set(builder.breaks)
        for i in sections.indices.dropFirst() where sections[i].startsPage || !sections[i].sameGeometry(sections[i - 1]) {
            breaks.insert(sections[i].start)
        }
        doc.breaks = breaks.filter { $0 > 0 && $0 < builder.out.length }.sorted()
        doc.footnotes = builder.footnotes.compactMap { ref in
            pkg.note(ref.id, endnote: false, number: ref.number, width: sections[0].textWidth).map { (ref.index, $0) }
        }
        return doc
    }
}

/// The parts every builder shares: relationships, styles, numbering, theme, settings, pictures.
final class ConverterDocxPackage {
    let zip: ConverterZip
    let main: String
    let theme: ConverterDocxTheme
    let styles: ConverterDocxStyles
    let numbering: ConverterDocxNumbering
    var fontKinds: [String: String] = [:]
    var defaultTab: CGFloat = 36
    var evenAndOdd = false
    var hyphenate = false
    var noteNumber = 0
    var endnoteNumber = 0
    private var relsCache: [String: [String: (target: String, external: Bool)]] = [:]
    private var imageCache: [String: CGImage] = [:]
    private var notesCache: [String: [String: ConverterXMLNode]] = [:]

    init(_ zip: ConverterZip) throws {
        self.zip = zip
        var main = "word/document.xml"
        if let rels = zip.data("_rels/.rels").flatMap(ConverterXMLNode.parse) {
            for r in rels.all("Relationship") where (r["Type"] ?? "").hasSuffix("/officeDocument") {
                if let t = r["Target"] { main = t.hasPrefix("/") ? String(t.dropFirst()) : t }
            }
        }
        guard zip.contains(main) else { throw ConverterError.failed("Ce fichier n'est pas un document Word (.docx).") }
        self.main = main
        let dir = (main as NSString).deletingLastPathComponent
        let mainRels = Self.relationships(zip, part: main)
        func part(_ suffix: String) -> ConverterXMLNode? {
            guard let t = mainRels.values.first(where: { $0.type.hasSuffix("/" + suffix) }), !t.external else { return nil }
            return zip.data(Self.resolve(t.target, dir: dir)).flatMap(ConverterXMLNode.parse)
        }
        theme = ConverterDocxTheme(part("theme"))
        styles = ConverterDocxStyles(part("styles"), theme: theme)
        numbering = ConverterDocxNumbering(part("numbering"), theme: theme)
        for f in part("fontTable")?.all("font") ?? [] {
            if let name = f["name"], let kind = f.child("family")?.val { fontKinds[name] = f.child("pitch")?.val == "fixed" ? "modern" : kind }
        }
        if let settings = part("settings") {
            defaultTab = ConverterDocxUnit.twips(settings.child("defaultTabStop")?.val).map { max(4, $0) } ?? 36
            evenAndOdd = settings.flag("evenAndOddHeaders") ?? false
            hyphenate = settings.flag("autoHyphenation") ?? false
        }
        for (key, suffix) in [("footnotes", "footnotes"), ("endnotes", "endnotes")] {
            var bodies: [String: ConverterXMLNode] = [:]
            for n in part(suffix)?.children ?? [] where n["type"] == nil || n["type"] == "normal" {
                if let id = n["id"] { bodies[id] = n }
            }
            notesCache[key] = bodies
        }
    }

    func xml(_ path: String) -> ConverterXMLNode? { zip.data(path).flatMap(ConverterXMLNode.parse) }

    private static func relationships(_ zip: ConverterZip, part: String) -> [String: (target: String, type: String, external: Bool)] {
        let path = (part as NSString).deletingLastPathComponent + "/_rels/" + (part as NSString).lastPathComponent + ".rels"
        var out: [String: (String, String, Bool)] = [:]
        for r in zip.data(path).flatMap(ConverterXMLNode.parse)?.all("Relationship") ?? [] {
            if let id = r["Id"], let t = r["Target"] { out[id] = (t, r["Type"] ?? "", r["TargetMode"] == "External") }
        }
        return out
    }

    private static func resolve(_ target: String, dir: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = dir.isEmpty ? [] : dir.split(separator: "/").map(String.init)
        for p in target.split(separator: "/") {
            if p == ".." { _ = parts.popLast() } else if p != "." { parts.append(String(p)) }
        }
        return parts.joined(separator: "/")
    }

    /// A relationship of a part: the package path of its target, or the URL of an external link.
    func target(_ id: String, part: String) -> (path: String, external: Bool)? {
        if relsCache[part] == nil {
            relsCache[part] = Self.relationships(zip, part: part).mapValues { ($0.target, $0.external) }
        }
        guard let t = relsCache[part]?[id] else { return nil }
        return t.external ? (t.target, true) : (Self.resolve(t.target, dir: (part as NSString).deletingLastPathComponent), false)
    }

    /// A picture of the package, decoded once; very large ones are reduced to what the page needs.
    func image(_ id: String, part: String, size: CGSize) -> CGImage? {
        guard let t = target(id, part: part), !t.external else { return nil }
        if let cached = imageCache[t.path] { return cached }
        guard let data = zip.data(t.path) else { return nil }
        if ConverterMetafile.isMetafile(data) {
            let image = ConverterMetafile.image(data, size: size)
            if let image { imageCache[t.path] = image }
            return image
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let pixels = max(props?[kCGImagePropertyPixelWidth] as? Int ?? 0, props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let needed = Int(max(size.width, size.height) / 72 * 300)
        let image: CGImage?
        if needed > 0, pixels > needed * 2 {
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: needed,
                           kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, options)
        } else {
            image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        if let image { imageCache[t.path] = image }
        return image
    }

    func section(_ e: ConverterXMLNode?) -> ConverterDocxSection {
        var s = ConverterDocxSection()
        guard let e else { return s }
        if let pg = e.child("pgSz"), let w = ConverterDocxUnit.twips(pg["w"]), let h = ConverterDocxUnit.twips(pg["h"]), w > 0, h > 0 {
            s.pageSize = pg["orient"] == "landscape" && w < h ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }
        if let m = e.child("pgMar") {
            let gutter = ConverterDocxUnit.twips(m["gutter"]) ?? 0
            s.margins = NSEdgeInsets(top: abs(ConverterDocxUnit.twips(m["top"]) ?? 72), left: (ConverterDocxUnit.twips(m["left"]) ?? 72) + gutter,
                                     bottom: abs(ConverterDocxUnit.twips(m["bottom"]) ?? 72), right: ConverterDocxUnit.twips(m["right"]) ?? 72)
            s.header = ConverterDocxUnit.twips(m["header"]) ?? 36
            s.footer = ConverterDocxUnit.twips(m["footer"]) ?? 36
        }
        if s.textWidth < 72 { s.margins.left = 36; s.margins.right = 36 }
        if s.textHeight < 72 { s.margins.top = 36; s.margins.bottom = 36 }
        if let cols = e.child("cols"), let n = cols["num"].flatMap(Int.init), n > 1 {
            s.columns = min(n, 6)
            s.columnSpace = ConverterDocxUnit.twips(cols["space"]) ?? 36
        }
        s.startsPage = (e.child("type")?.val ?? "nextPage") != "continuous"
        s.titlePage = e.flag("titlePg") ?? false
        if let n = e.child("pgNumType") {
            s.pageStart = n["start"].flatMap(Int.init)
            s.pageFormat = n["fmt"] ?? "decimal"
        }
        return s
    }

    /// A header or footer part.
    func story(_ path: String, width: CGFloat) -> ConverterDocxStory {
        let builder = ConverterDocxBuilder(self, part: path, width: width)
        builder.blocks(xml(path)?.children ?? [])
        builder.finish()
        return ConverterDocxStory(text: builder.out, anchors: builder.anchors)
    }

    /// The text of a footnote or endnote, its number in front.
    func note(_ id: String, endnote: Bool, number: String, width: CGFloat) -> ConverterDocxStory? {
        guard let node = notesCache[endnote ? "endnotes" : "footnotes"]?[id] else { return nil }
        let part = (main as NSString).deletingLastPathComponent + (endnote ? "/endnotes.xml" : "/footnotes.xml")
        let builder = ConverterDocxBuilder(self, part: part, width: width)
        builder.noteMark = number
        builder.blocks(node.children)
        builder.finish()
        return ConverterDocxStory(text: builder.out, anchors: [])
    }

    func hasEndnotes() -> Bool { !(notesCache["endnotes"]?.isEmpty ?? true) }
}

// MARK: - Builder

/// Walks one part (the body, a header, a footnote…) and writes it as attributed text for TextKit.
final class ConverterDocxBuilder {
    let pkg: ConverterDocxPackage
    let part: String
    var width: CGFloat
    let out = NSMutableAttributedString()
    var anchors: [ConverterDocxAnchor] = []
    var breaks: [Int] = []
    var footnotes: [(index: Int, id: String, number: String)] = []
    var endnoteRefs: [(id: String, number: String)] = []
    var noteMark: String?
    var sections: [ConverterDocxSection] = []
    var sectionStarts: [Int] = [0]
    /// Where Word last broke the pages, as it saved them (`w:lastRenderedPageBreak`).
    var renderedBreaks: [Int] = []

    private var cells: [NSTextBlock] = []
    private var tableStyle: ConverterDocxConditional?
    private var fields: [(code: String, result: Bool, emitted: Bool)] = []
    private var link: URL?
    private var paragraphStart = 0
    private var deferred: [ConverterXMLNode] = []
    private var previous: (range: NSRange, style: String?, contextual: Bool)?
    private var group: (block: ConverterDocxBorderBlock, key: String, last: NSRange, after: CGFloat)?
    private var runBase = ConverterDocxRunProps()
    private var pendingBreak = false
    private var displayMath: String?
    private var picture = false
    private var lineRoom: CGFloat = 0

    init(_ pkg: ConverterDocxPackage, part: String, width: CGFloat) {
        self.pkg = pkg
        self.part = part
        self.width = width
    }

    private var theme: ConverterDocxTheme { pkg.theme }
    private var styles: ConverterDocxStyles { pkg.styles }

    func finish() {
        closeGroup()
        if out.length > 0, (out.string as NSString).character(at: out.length - 1) == 10 {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
    }

    // MARK: Blocks

    func blocks(_ nodes: [ConverterXMLNode]) {
        for n in nodes {
            switch n.name {
            case "p": paragraph(n)
            case "tbl": table(n)
            case "sdt": blocks(n.child("sdtContent")?.children ?? [])
            case "customXml", "ins", "moveTo", "txbxContent": blocks(n.children)
            case "AlternateContent": blocks(Self.choose(n))
            default: break
            }
        }
    }

    /// `mc:AlternateContent`: the modern choice when it is something this reader knows, otherwise the fallback.
    private static func choose(_ n: ConverterXMLNode) -> [ConverterXMLNode] {
        let known: Set<String> = ["wps", "wp14", "w14", "w15", "a14", "wpg", "wpc"]
        for c in n.all("Choice") {
            let requires = Set((c["Requires"] ?? "").split(separator: " ").map(String.init))
            if requires.isSubset(of: known) { return c.children }
        }
        return n.child("Fallback")?.children ?? []
    }

    // MARK: Paragraphs

    private func paragraph(_ p: ConverterXMLNode) {
        let pPr = p.child("pPr")
        let direct = ConverterDocxParaProps.parse(pPr, theme: theme)
        let styleID = styles.exists(direct.style) ? direct.style : styles.defaultParagraphStyle
        let style = styles.style(styleID)

        var para = styles.defaultPara
        if let t = tableStyle { para.merge(t.para) }
        para.merge(style.para)
        var probe = para
        probe.merge(direct)
        var label: (text: String, level: ConverterDocxLevel)?
        if let num = probe.numID, num != "0", let level = pkg.numbering.level(num, probe.numLevel ?? 0, styles: styles) {
            para.merge(level.para)
            if let text = pkg.numbering.next(num, probe.numLevel ?? 0, styles: styles) { label = (text, level) }
        }
        para.merge(direct)

        var base = styles.defaultRun
        if let t = tableStyle { base.merge(t.run) }
        base.merge(style.run)
        runBase = base
        let markDirect = ConverterDocxRunProps.parse(pPr?.child("rPr"), theme: theme)
        var mark = base
        if let cs = markDirect.charStyle { mark.merge(styles.style(cs).run) }
        mark.merge(markDirect)

        let start = out.length
        paragraphStart = start
        displayMath = nil
        if para.pageBreakBefore == true, cells.isEmpty { breaks.append(start) }

        var extraTab: CGFloat?
        if let label, !label.text.isEmpty || label.level.suffix != "nothing" {
            var props = mark
            props.underline = nil
            props.merge(label.level.run)
            let symbol = ConverterDocxNumbering.symbol(label.text, font: props.font)
            if !symbol.keepFont { props.font = mark.font }
            let suffix = label.level.suffix == "space" ? " " : (label.level.suffix == "nothing" ? "" : "\t")
            append(symbol.text + suffix, props)
            if suffix == "\t" { extraTab = para.left }
        }
        picture = false
        lineRoom = (para.beforeAuto == true ? 14 : max(0, para.before ?? 0)) + (para.afterAuto == true ? 14 : max(0, para.after ?? 0))
        inline(p.children, base: base)
        // The paragraph mark sets the height of an empty paragraph; Word never underlines or highlights it.
        var end = mark
        end.underline = nil
        end.strike = nil
        end.doubleStrike = nil
        end.highlight = nil
        end.shading = nil
        append("\n", end, force: true)
        if pendingBreak {
            pendingBreak = false
            breaks.append(out.length)
        }
        let range = NSRange(location: start, length: out.length - start)

        let ps = paragraphStyle(para, extraTab: extraTab)
        if let jc = displayMath { ps.alignment = jc == "left" ? .left : (jc == "right" ? .right : .center) }
        // Word does not stretch a line holding a picture by the line spacing multiple; TextKit would.
        if picture { ps.lineHeightMultiple = 0 }
        if let previous, previous.style == styleID {
            if para.contextual == true { ps.paragraphSpacingBefore = 0 }
            if previous.contextual { restyle(previous.range) { $0.paragraphSpacing = 0 } }
            if group != nil, previous.contextual { group?.after = 0 }
        }
        let before = ps.paragraphSpacingBefore
        // Between two paragraphs Word keeps the larger of the space after the first and the space before the second.
        // That space goes before the second one: like Word, a page may then end without room for the space after its
        // last line, and TextKit drops it at the top of the next page.
        if let previous, let above = out.attribute(.paragraphStyle, at: previous.range.location, effectiveRange: nil) as? NSParagraphStyle,
           above.textBlocks.count == cells.count {
            ps.paragraphSpacingBefore = max(ps.paragraphSpacingBefore, above.paragraphSpacing)
            if above.paragraphSpacing > 0 { restyle(previous.range) { $0.paragraphSpacing = 0 } }
        }
        box(para, style: ps, range: range)
        out.addAttribute(.paragraphStyle, value: ps, range: range)
        // At the top of a page Word keeps the whole space before a paragraph; TextKit drops it (see `ConverterPageLayout`).
        if before > 0, ps.textBlocks.isEmpty { out.addAttribute(ConverterDocx.beforeKey, value: before, range: range) }
        if cells.isEmpty {
            let keep = (para.keepNext == true ? 2 : 0) | (para.keepLines == true ? 1 : 0)
            if keep != 0 { out.addAttribute(ConverterDocx.keepNextKey, value: keep, range: range) }
            // Word keeps widows and orphans off unless a style or the paragraph turns the control off.
            if para.widowControl != false { out.addAttribute(ConverterDocx.widowKey, value: true, range: range) }
        }
        let leaders = para.tabs.filter { ["dot", "hyphen", "underscore", "middleDot", "heavy"].contains($0.leader ?? "none") }
        if !leaders.isEmpty {
            out.addAttribute(ConverterDocx.leadersKey, value: leaders.map { [$0.position, $0.leader == "dot" ? 0 : ($0.leader == "middleDot" ? 1 : ($0.leader == "hyphen" ? 2 : 3))] }, range: range)
        }
        previous = (range, styleID, para.contextual == true)

        if !deferred.isEmpty {
            let boxes = deferred
            deferred = []
            for b in boxes { blocks(b.children) }
        }
        if pPr?.child("sectPr") != nil, cells.isEmpty {
            sectionStarts.append(out.length)
            if sectionStarts.count - 1 < sections.count { width = sections[sectionStarts.count - 1].textWidth }
        }
    }

    private func paragraphStyle(_ p: ConverterDocxParaProps, extraTab: CGFloat?) -> NSMutableParagraphStyle {
        let s = NSMutableParagraphStyle()
        switch p.align {
        case "center": s.alignment = .center
        case "right", "end": s.alignment = p.bidi == true ? .left : .right
        case "both", "distribute", "lowKashida", "mediumKashida", "highKashida", "thaiDistribute": s.alignment = .justified
        default: s.alignment = p.bidi == true ? .right : .left
        }
        if p.bidi == true { s.baseWritingDirection = .rightToLeft }
        let left = p.left ?? 0
        let first = p.firstLine ?? 0
        s.headIndent = max(0, left)
        s.firstLineHeadIndent = max(0, left + first)
        if let right = p.right, right > 0 { s.tailIndent = -right }
        // "Auto" spacing (pasted from the web) is 14 pt, as measured on Word's own PDFs.
        s.paragraphSpacingBefore = p.beforeAuto == true ? 14 : max(0, p.before ?? 0)
        s.paragraphSpacing = p.afterAuto == true ? 14 : max(0, p.after ?? 0)
        if let line = p.line {
            switch p.lineRule {
            case "exact":
                s.minimumLineHeight = line / 20
                s.maximumLineHeight = line / 20
            case "atLeast":
                s.minimumLineHeight = line / 20
            default:
                if abs(line - 240) > 1 { s.lineHeightMultiple = max(0.5, line / 240) }
            }
        }
        var stops = p.tabs.filter { $0.align != "bar" && $0.align != "clear" && $0.position >= 0 }.map { t -> NSTextTab in
            switch t.align {
            case "center": return NSTextTab(textAlignment: .center, location: t.position)
            case "right", "end": return NSTextTab(textAlignment: .right, location: t.position)
            case "decimal":
                return NSTextTab(textAlignment: .right, location: t.position, options: [.columnTerminators: NSTextTab.columnTerminators(for: Locale(identifier: "fr_FR"))])
            default: return NSTextTab(textAlignment: .left, location: t.position)
            }
        }
        // Word stops a tab at the hanging indent, whether the paragraph is a list item or not.
        let hanging = extraTab ?? (first < 0 ? left : nil)
        if let h = hanging, h > s.firstLineHeadIndent, !stops.contains(where: { $0.location > s.firstLineHeadIndent && $0.location <= h }) {
            stops.append(NSTextTab(textAlignment: .left, location: h))
        }
        s.tabStops = stops.sorted { $0.location < $1.location }
        s.defaultTabInterval = pkg.defaultTab
        s.textBlocks = cells
        if pkg.hyphenate { s.hyphenationFactor = 0.9 }
        return s
    }

    private func restyle(_ range: NSRange, _ change: (NSMutableParagraphStyle) -> Void) {
        guard range.location < out.length,
              let current = out.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
              let copy = current.mutableCopy() as? NSMutableParagraphStyle else { return }
        change(copy)
        out.addAttribute(.paragraphStyle, value: copy, range: NSRange(location: range.location, length: min(range.length, out.length - range.location)))
    }

    /// Paragraph borders and shading: one block around consecutive paragraphs that share them, drawn as Word draws it.
    private func box(_ p: ConverterDocxParaProps, style s: NSMutableParagraphStyle, range: NSRange) {
        let edges = ["top", "left", "bottom", "right"].filter { p.borders[$0]?.visible == true }
        let shade = p.shading.flatMap { $0 == "none" ? nil : $0 }
        guard !edges.isEmpty || shade != nil else {
            closeGroup()
            return
        }
        let key = edges.map { e in "\(e):\(p.borders[e].map { "\($0.style)\($0.width)\($0.space)\($0.color ?? "")" } ?? "")" }.joined()
            + "|\(shade ?? "")|\(p.left ?? 0)|\(p.right ?? 0)"
        if let g = group, g.key == key {
            s.textBlocks = cells + [g.block]
            group?.last = range
            group?.after = s.paragraphSpacing
            return
        }
        closeGroup()
        let block = ConverterDocxBorderBlock()
        for name in edges {
            guard let b = p.borders[name] else { continue }
            block.lines[name] = (b.width, b.space, ConverterDocxColor.color(b.color) ?? .black)
            if name == "top" { block.setWidth(b.space + b.width, type: .absoluteValueType, for: .padding, edge: .minY) }
            if name == "bottom" { block.setWidth(b.space + b.width, type: .absoluteValueType, for: .padding, edge: .maxY) }
        }
        block.fill = shade.flatMap(ConverterDocxColor.color)
        block.left = max(0, p.left ?? 0)
        block.right = max(0, p.right ?? 0)
        // TextKit draws a block only when its width is set.
        block.setValue(max(10, width), type: .absoluteValueType, for: .width)
        block.setWidth(s.paragraphSpacingBefore, type: .absoluteValueType, for: .margin, edge: .minY)
        s.paragraphSpacingBefore = 0
        s.textBlocks = cells + [block]
        group = (block, key, range, s.paragraphSpacing)
    }

    private func closeGroup() {
        guard let g = group else { return }
        group = nil
        g.block.setWidth(g.after, type: .absoluteValueType, for: .margin, edge: .maxY)
        restyle(g.last) { $0.paragraphSpacing = 0 }
    }

    // MARK: Runs

    private func inline(_ nodes: [ConverterXMLNode], base: ConverterDocxRunProps) {
        for n in nodes {
            switch n.name {
            case "r": run(n, base: base)
            case "hyperlink":
                let saved = link
                if let id = n["r:id"], let t = pkg.target(id, part: part), t.external { link = URL(string: t.path) }
                inline(n.children, base: base)
                link = saved
            case "ins", "moveTo", "smartTag", "customXml", "dir", "bdo": inline(n.children, base: base)
            case "sdt": inline(n.child("sdtContent")?.children ?? [], base: base)
            case "fldSimple":
                fields.append((n["instr"] ?? "", true, false))
                inline(n.children, base: base)
                endField(base)
            case "AlternateContent": inline(Self.choose(n), base: base)
            case "oMathPara":
                displayMath = n.child("oMathParaPr")?.child("jc")?.val ?? "centerGroup"
                for (i, m) in n.all("oMath").enumerated() {
                    if i > 0 { append("\u{2028}", base) }
                    equation(m, base: base, display: true)
                }
            case "oMath": equation(n, base: base, display: false)
            default: break
            }
        }
    }

    /// An Office Math equation, laid out by `ConverterMath` and set in the line like a character.
    private func equation(_ m: ConverterXMLNode, base: ConverterDocxRunProps, display: Bool) {
        guard visible else { return }
        var props = base
        if let sz = m.find("sz")?.val.flatMap(Double.init) { props.size = CGFloat(sz) / 2 }
        if let c = m.find("color") { props.color = ConverterDocxColor.text(c, theme: theme) ?? props.color }
        let color = ConverterDocxColor.color(props.color)?.cgColor ?? CGColor(gray: 0, alpha: 1)
        let box = ConverterMath(size: props.size ?? 10, color: color, display: display).layout(m)
        guard box.width > 0 else { return }
        let attachment = NSTextAttachment()
        attachment.attachmentCell = ConverterMathCell(box)
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttributes(attributes(props), range: NSRange(location: 0, length: text.length))
        materializeBreak()
        out.append(text)
    }

    private func run(_ r: ConverterXMLNode, base: ConverterDocxRunProps) {
        let direct = ConverterDocxRunProps.parse(r.child("rPr"), theme: theme)
        var props = base
        if let cs = direct.charStyle { props.merge(styles.style(cs).run) }
        props.merge(direct)
        content(r.children, props)
    }

    private func content(_ nodes: [ConverterXMLNode], _ props: ConverterDocxRunProps) {
        for c in nodes {
            switch c.name {
            case "t": append(c.text, props)
            case "tab", "ptab": append("\t", props)
            case "br":
                if c["type"] == "page" || c["type"] == "column" {
                    if cells.isEmpty { pageBreak() }
                } else {
                    append("\u{2028}", props)
                }
            case "cr": append("\u{2028}", props)
            case "noBreakHyphen": append("\u{2011}", props)
            case "softHyphen": append("\u{00AD}", props)
            case "sym":
                guard let code = c["char"].flatMap({ UInt32($0, radix: 16) }), let scalar = UnicodeScalar(code) else { continue }
                var p = props
                let symbol = ConverterDocxNumbering.symbol(String(Character(scalar)), font: c["font"])
                p.font = symbol.keepFont ? (c["font"] ?? props.font) : props.font
                append(symbol.text, p)
            case "fldChar":
                switch c["fldCharType"] {
                case "begin": fields.append(("", false, false))
                case "separate": if !fields.isEmpty { fields[fields.count - 1].result = true }
                case "end": endField(props)
                default: break
                }
            case "instrText": if let last = fields.indices.last, !fields[last].result { fields[last].code += c.text }
            case "drawing": if visible { drawing(c, props) }
            case "pict", "object": if visible { vml(c, props) }
            case "footnoteReference", "endnoteReference": note(c, props)
            case "footnoteRef", "endnoteRef":
                var p = props
                if p.vertAlign == nil { p.vertAlign = "superscript" }
                append(noteMark ?? "", p)
            case "AlternateContent": content(Self.choose(c), props)
            case "lastRenderedPageBreak": if cells.isEmpty, visible { renderedBreaks.append(out.length) }
            default: break
            }
        }
    }

    /// A page break in the text: the rest of the paragraph, or the next paragraph, starts a new page.
    private func pageBreak() { pendingBreak = true }

    /// Text follows a page break in the same paragraph: it goes on a new line, at the top of the next page.
    private func materializeBreak() {
        guard pendingBreak else { return }
        pendingBreak = false
        if out.length > paragraphStart, (out.string as NSString).character(at: out.length - 1) != 0x2028 {
            out.append(NSAttributedString(string: "\u{2028}", attributes: attributes(runBase)))
        }
        breaks.append(out.length)
    }

    private var visible: Bool { !fields.contains { !$0.result } }

    private func endField(_ props: ConverterDocxRunProps) {
        guard let f = fields.popLast() else { return }
        // A page number field without a stored result still shows its number.
        if !f.emitted, Self.pageField(f.code) != nil, visible {
            fields.append((f.code, true, false))
            append("1", props)
            fields.removeLast()
        }
    }

    private static func pageField(_ code: String) -> String? {
        let word = code.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map { $0.uppercased() } ?? ""
        return ["PAGE", "NUMPAGES", "SECTIONPAGES"].contains(word) ? word : nil
    }

    private func note(_ c: ConverterXMLNode, _ props: ConverterDocxRunProps) {
        guard let id = c["id"], visible else { return }
        var p = props
        if p.vertAlign == nil { p.vertAlign = "superscript" }
        let endnote = c.name == "endnoteReference"
        let number: String
        if endnote {
            pkg.endnoteNumber += 1
            number = ConverterDocxNumbering.format(pkg.endnoteNumber, "lowerRoman")
        } else {
            pkg.noteNumber += 1
            number = "\(pkg.noteNumber)"
        }
        let index = out.length
        if c["customMarkFollows"] != "1" && c["customMarkFollows"] != "true" { append(number, p) }
        if endnote { endnoteRefs.append((id, number)) } else { footnotes.append((index, id, number)) }
    }

    /// Endnotes at the end of the text, after a short rule.
    func endnotes() {
        guard !endnoteRefs.isEmpty else { return }
        closeGroup()
        let rule = NSMutableParagraphStyle()
        rule.paragraphSpacingBefore = 12
        rule.paragraphSpacing = 6
        out.append(NSAttributedString(string: String(repeating: "\u{2014}", count: 8) + "\n",
                                      attributes: [.font: ConverterDocxFonts.font(styles.defaultRun.font, size: 9, bold: false, italic: false, kind: nil),
                                                   .foregroundColor: NSColor.gray, .paragraphStyle: rule]))
        for ref in endnoteRefs {
            if let story = pkg.note(ref.id, endnote: true, number: ref.number, width: width) {
                out.append(story.text)
                out.append(NSAttributedString(string: "\n"))
            }
        }
    }

    // MARK: Text

    private func append(_ s: String, _ p: ConverterDocxRunProps, force: Bool = false) {
        guard !s.isEmpty else { return }
        if !force {
            guard p.hidden != true, visible else { return }
            materializeBreak()
        }
        var attrs = attributes(p)
        if !force {
            if let link = link ?? fieldLink() { attrs[.link] = link }
            if let kind = fields.last.flatMap({ Self.pageField($0.code) }) {
                attrs[ConverterDocx.fieldKey] = kind
                fields[fields.count - 1].emitted = true
            }
        }
        if p.smallCaps == true, p.caps != true, let font = attrs[.font] as? NSFont {
            let small = ConverterDocxFonts.font(p.font, size: font.pointSize * 0.8, bold: p.bold ?? false, italic: p.italic ?? false,
                                                kind: pkg.fontKinds[p.font ?? ""])
            var segment = ""
            var lower: Bool?
            func flush() {
                guard !segment.isEmpty else { return }
                var a = attrs
                if lower == true { a[.font] = small }
                out.append(NSAttributedString(string: lower == true ? segment.uppercased() : segment, attributes: a))
                segment = ""
            }
            for ch in s {
                let isLower = ch.isLowercase
                if isLower != lower { flush(); lower = isLower }
                segment.append(ch)
            }
            flush()
            return
        }
        out.append(NSAttributedString(string: p.caps == true ? s.uppercased() : s, attributes: attrs))
    }

    private func fieldLink() -> URL? {
        for f in fields.reversed() {
            let code = f.code.trimmingCharacters(in: .whitespaces)
            guard code.uppercased().hasPrefix("HYPERLINK") else { continue }
            let parts = code.components(separatedBy: "\"")
            if parts.count >= 2, let url = URL(string: parts[1]), url.scheme != nil { return url }
        }
        return nil
    }

    private func attributes(_ p: ConverterDocxRunProps) -> [NSAttributedString.Key: Any] {
        let size = p.size ?? 10
        var fontSize = size
        var baseline = p.position ?? 0
        if p.vertAlign == "superscript" {
            fontSize = size * 0.65
            baseline += size * 0.33
        } else if p.vertAlign == "subscript" {
            fontSize = size * 0.65
            baseline -= size * 0.14
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: ConverterDocxFonts.font(p.font, size: max(1, fontSize), bold: p.bold ?? false, italic: p.italic ?? false, kind: pkg.fontKinds[p.font ?? ""]),
            .foregroundColor: ConverterDocxColor.color(p.color) ?? NSColor.black
        ]
        if let bg = [p.highlight, p.shading].compactMap({ $0 }).first(where: { $0 != "none" }), let c = ConverterDocxColor.color(bg) {
            attrs[.backgroundColor] = c
        }
        if let u = p.underline, u != "none" {
            var style: NSUnderlineStyle = u.contains("thick") || u.hasSuffix("Heavy") ? .thick : (u == "double" ? .double : .single)
            if u.hasPrefix("dotted") { style.insert(.patternDot) }
            if u.hasPrefix("dash") || u.hasPrefix("dashLong") { style.insert(.patternDash) }
            if u.hasPrefix("dotDash") { style.insert(.patternDashDot) }
            if u.hasPrefix("dotDotDash") { style.insert(.patternDashDotDot) }
            if u == "words" { style.insert(.byWord) }
            attrs[.underlineStyle] = style.rawValue
            if let c = ConverterDocxColor.color(p.underlineColor) { attrs[.underlineColor] = c }
        }
        if p.strike == true { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if p.doubleStrike == true { attrs[.strikethroughStyle] = NSUnderlineStyle.double.rawValue }
        if baseline != 0 { attrs[.baselineOffset] = baseline }
        if let k = p.spacing, k != 0 { attrs[.kern] = k }
        return attrs
    }

    // MARK: Pictures and shapes

    private func drawing(_ d: ConverterXMLNode, _ props: ConverterDocxRunProps) {
        guard let holder = d.child("inline") ?? d.child("anchor"), let graphic = holder.find("graphicData") else { return }
        let ext = holder.child("extent")
        let size = CGSize(width: ConverterDocxUnit.emu(ext?["cx"]) ?? 0, height: ConverterDocxUnit.emu(ext?["cy"]) ?? 0)
        let floating = holder.name == "anchor"
        if let pic = graphic.child("pic") {
            guard let image = picture(pic, size: size) else { return }
            let xfrm = pic.child("spPr")?.child("xfrm")
            let rotation = CGFloat(Double(xfrm?["rot"] ?? "0") ?? 0) / 60_000
            let flipH = xfrm?["flipH"] == "1", flipV = xfrm?["flipV"] == "1"
            if floating {
                let a = anchor(holder, size: size)
                a.image = image
                a.rotation = rotation
                a.flipH = flipH
                a.flipV = flipV
                anchors.append(a)
            } else if rotation != 0 || flipH || flipV {
                // A turned picture takes the room of its turned box in the line.
                let angle = rotation * .pi / 180
                let box = CGSize(width: abs(size.width * cos(angle)) + abs(size.height * sin(angle)),
                                 height: abs(size.width * sin(angle)) + abs(size.height * cos(angle)))
                let item = ConverterDocxAnchor(size: size)
                item.image = image
                item.rotation = rotation
                item.flipH = flipH
                item.flipV = flipV
                item.inner = CGPoint(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2)
                attachment(image: nil, scene: [item], size: box, props)
            } else {
                attachment(image: image, scene: nil, size: size, props)
            }
        } else if let shape = graphic.child("wsp") {
            if floating {
                anchors.append(self.shape(shape, holder: holder, size: size))
            } else {
                attachment(image: nil, scene: [self.shape(shape, holder: nil, size: size)], size: size, props)
            }
        } else if let container = graphic.child("wgp") ?? graphic.child("wpc") {
            // A group maps its children's coordinates onto its frame; a drawing canvas uses its own.
            let xfrm = container.child("grpSpPr")?.child("xfrm")
            let origin = CGPoint(x: ConverterDocxUnit.emu(xfrm?.child("chOff")?["x"]) ?? 0, y: ConverterDocxUnit.emu(xfrm?.child("chOff")?["y"]) ?? 0)
            let inner = CGSize(width: ConverterDocxUnit.emu(xfrm?.child("chExt")?["cx"]) ?? size.width,
                               height: ConverterDocxUnit.emu(xfrm?.child("chExt")?["cy"]) ?? size.height)
            let items = scene(container, origin: origin, scale: CGSize(width: inner.width > 0 ? size.width / inner.width : 1,
                                                                       height: inner.height > 0 ? size.height / inner.height : 1))
            guard !items.isEmpty else { return }
            if floating {
                let a = anchor(holder, size: size)
                a.scene = items
                anchors.append(a)
            } else {
                attachment(image: nil, scene: items, size: size, props)
            }
        }
    }

    /// The shapes, pictures and nested groups of a group or canvas, placed in its frame.
    private func scene(_ container: ConverterXMLNode, origin: CGPoint, scale: CGSize) -> [ConverterDocxAnchor] {
        var items: [ConverterDocxAnchor] = []
        for c in container.children where ["wsp", "pic", "grpSp", "wgp", "cxnSp", "sp"].contains(c.name) {
            let group = c.name == "grpSp" || c.name == "wgp"
            let xfrm = (group ? c.child("grpSpPr") : c.child("spPr"))?.child("xfrm")
            let off = CGPoint(x: ConverterDocxUnit.emu(xfrm?.child("off")?["x"]) ?? 0, y: ConverterDocxUnit.emu(xfrm?.child("off")?["y"]) ?? 0)
            let ext = CGSize(width: ConverterDocxUnit.emu(xfrm?.child("ext")?["cx"]) ?? 0, height: ConverterDocxUnit.emu(xfrm?.child("ext")?["cy"]) ?? 0)
            let frame = CGRect(x: (off.x - origin.x) * scale.width, y: (off.y - origin.y) * scale.height,
                               width: ext.width * scale.width, height: ext.height * scale.height)
            if group {
                let childOrigin = CGPoint(x: ConverterDocxUnit.emu(xfrm?.child("chOff")?["x"]) ?? off.x, y: ConverterDocxUnit.emu(xfrm?.child("chOff")?["y"]) ?? off.y)
                let childExt = CGSize(width: ConverterDocxUnit.emu(xfrm?.child("chExt")?["cx"]) ?? ext.width,
                                      height: ConverterDocxUnit.emu(xfrm?.child("chExt")?["cy"]) ?? ext.height)
                let nested = scene(c, origin: childOrigin, scale: CGSize(width: childExt.width > 0 ? frame.width / childExt.width : scale.width,
                                                                         height: childExt.height > 0 ? frame.height / childExt.height : scale.height))
                for item in nested {
                    item.inner = CGPoint(x: item.inner.x + frame.minX, y: item.inner.y + frame.minY)
                    items.append(item)
                }
            } else if c.name == "pic" {
                guard let image = picture(c, size: frame.size) else { continue }
                let a = ConverterDocxAnchor(size: frame.size)
                a.image = image
                a.inner = frame.origin
                a.rotation = CGFloat(Double(xfrm?["rot"] ?? "0") ?? 0) / 60_000
                a.flipH = xfrm?["flipH"] == "1"
                a.flipV = xfrm?["flipV"] == "1"
                items.append(a)
            } else {
                let a = shape(c, holder: nil, size: frame.size)
                a.inner = frame.origin
                items.append(a)
            }
        }
        return items
    }

    private func picture(_ pic: ConverterXMLNode, size: CGSize) -> CGImage? {
        guard let blip = pic.find("blip"), let id = blip["r:embed"], var image = pkg.image(id, part: part, size: size) else { return nil }
        if let crop = pic.find("srcRect") {
            func f(_ k: String) -> CGFloat { max(0, CGFloat(Double(crop[k] ?? "0") ?? 0) / 100_000) }
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let rect = CGRect(x: w * f("l"), y: h * f("t"), width: w * (1 - f("l") - f("r")), height: h * (1 - f("t") - f("b"))).integral
            if rect.width >= 1, rect.height >= 1, rect != CGRect(x: 0, y: 0, width: w, height: h), let cropped = image.cropping(to: rect) {
                image = cropped
            }
        }
        return image
    }

    /// A picture, shape or drawing in the line of text.
    private func attachment(image: CGImage?, scene: [ConverterDocxAnchor]?, size: CGSize, _ props: ConverterDocxRunProps) {
        var s = size.width > 0 && size.height > 0 || image == nil ? size
            : CGSize(width: CGFloat(image?.width ?? 0) * 0.75, height: CGFloat(image?.height ?? 0) * 0.75)
        guard s.width > 0, s.height > 0 else { return }
        let maxWidth = max(20, width)
        if s.width > maxWidth { s = CGSize(width: maxWidth, height: s.height * maxWidth / s.width) }
        // The whole line must fit on a page, its line spacing and paragraph spacing included.
        let page = sections.isEmpty ? 700 : sections[min(sections.count, sectionStarts.count) - 1].textHeight
        let maxHeight: CGFloat = max(20, page - 6 - lineRoom)
        if s.height > maxHeight { s = CGSize(width: s.width * maxHeight / s.height, height: maxHeight) }
        let attachment = NSTextAttachment()
        if let scene, s != size, size.width > 0, size.height > 0 {
            // Shrunk to fit the page: the drawing shrinks with it.
            let k = s.width / size.width
            for item in scene {
                item.inner = CGPoint(x: item.inner.x * k, y: item.inner.y * k)
                item.size = CGSize(width: item.size.width * k, height: item.size.height * k)
            }
        }
        attachment.attachmentCell = ConverterDocxImageCell(image: image, scene: scene, size: s)
        attachment.bounds = CGRect(origin: .zero, size: s)
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttributes(attributes(props), range: NSRange(location: 0, length: text.length))
        if visible {
            materializeBreak()
            out.append(text)
            picture = true
        }
    }

    private func anchor(_ holder: ConverterXMLNode, size: CGSize) -> ConverterDocxAnchor {
        let a = ConverterDocxAnchor(size: size)
        a.behind = holder["behindDoc"] == "1" || holder["behindDoc"] == "true"
        if holder["simplePos"] == "1", let p = holder.child("simplePos") {
            a.hRelative = "page"; a.vRelative = "page"
            a.hOffset = ConverterDocxUnit.emu(p["x"]) ?? 0
            a.vOffset = ConverterDocxUnit.emu(p["y"]) ?? 0
        } else {
            if let h = holder.child("positionH") {
                a.hRelative = h["relativeFrom"] ?? "column"
                a.hOffset = ConverterDocxUnit.emu(h.child("posOffset")?.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                a.hAlign = h.child("align")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let v = holder.child("positionV") {
                a.vRelative = v["relativeFrom"] ?? "paragraph"
                a.vOffset = ConverterDocxUnit.emu(v.child("posOffset")?.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                a.vAlign = v.child("align")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        for c in holder.children where c.name.hasPrefix("wrap") {
            a.wrap = String(c.name.dropFirst(4)).lowercased()
        }
        if a.behind { a.wrap = "none" }
        a.distance = NSEdgeInsets(top: ConverterDocxUnit.emu(holder["distT"]) ?? 0, left: ConverterDocxUnit.emu(holder["distL"]) ?? 0,
                                  bottom: ConverterDocxUnit.emu(holder["distB"]) ?? 0, right: ConverterDocxUnit.emu(holder["distR"]) ?? 0)
        a.index = paragraphStart
        return a
    }

    /// A Word shape (`wps:wsp`): its fill, outline and text box.
    private func shape(_ wsp: ConverterXMLNode, holder: ConverterXMLNode?, size: CGSize) -> ConverterDocxAnchor {
        let a = holder.map { anchor($0, size: size) } ?? ConverterDocxAnchor(size: size)
        let spPr = wsp.child("spPr")
        let style = wsp.child("style")
        a.geometry = spPr?.child("prstGeom")?["prst"] ?? "rect"
        let xfrm = spPr?.child("xfrm")
        a.rotation = CGFloat(Double(xfrm?["rot"] ?? "0") ?? 0) / 60_000
        a.flipH = xfrm?["flipH"] == "1"
        a.flipV = xfrm?["flipV"] == "1"
        var adjust: [String: CGFloat] = [:]
        for gd in spPr?.child("prstGeom")?.child("avLst")?.all("gd") ?? [] {
            if let name = gd["name"], let f = gd["fmla"], f.hasPrefix("val "), let v = Double(f.dropFirst(4)) { adjust[name] = CGFloat(v) }
        }
        let outline = spPr?.child("custGeom").flatMap { ConverterDocxGeometry.custom($0, size: size) }
            ?? ConverterDocxGeometry.preset(a.geometry, size: size, adjust: adjust)
        a.outline = outline.path
        a.open = outline.open
        if spPr?.child("noFill") != nil {
            a.fill = nil
        } else if let fill = spPr?.child("solidFill") {
            a.fill = ConverterDocxColor.color(theme.drawingColor(fill))
        } else if spPr?.child("gradFill") != nil, let stop = spPr?.child("gradFill")?.find("gs") {
            a.fill = ConverterDocxColor.color(theme.drawingColor(stop))
        } else if let ref = style?.child("fillRef"), ref["idx"] != "0" {
            a.fill = ConverterDocxColor.color(theme.drawingColor(ref))
        }
        if let ln = spPr?.child("ln") {
            if ln.child("noFill") == nil {
                a.stroke = ConverterDocxColor.color(theme.drawingColor(ln.child("solidFill")))
                    ?? style?.child("lnRef").flatMap { ConverterDocxColor.color(theme.drawingColor($0)) }
            }
            a.lineWidth = ConverterDocxUnit.emu(ln["w"]) ?? 0.75
            a.headEnd = ln.child("headEnd")?["type"]
            a.tailEnd = ln.child("tailEnd")?["type"]
            switch ln.child("prstDash")?.val ?? "solid" {
            case "dash", "sysDash": a.dash = [4, 3]
            case "dot", "sysDot": a.dash = [1, 2]
            case "dashDot", "sysDashDot": a.dash = [4, 3, 1, 3]
            case "lgDash": a.dash = [8, 3]
            case "lgDashDot": a.dash = [8, 3, 1, 3]
            case "lgDashDotDot", "sysDashDotDot": a.dash = [8, 3, 1, 3, 1, 3]
            default: break
            }
        } else if let ref = style?.child("lnRef"), ref["idx"] != "0" {
            a.stroke = ConverterDocxColor.color(theme.drawingColor(ref))
        }
        if let body = wsp.child("bodyPr") {
            a.insets = NSEdgeInsets(top: ConverterDocxUnit.emu(body["tIns"]) ?? 3.6, left: ConverterDocxUnit.emu(body["lIns"]) ?? 7.2,
                                    bottom: ConverterDocxUnit.emu(body["bIns"]) ?? 3.6, right: ConverterDocxUnit.emu(body["rIns"]) ?? 7.2)
            a.textAnchor = body["anchor"] ?? "t"
        }
        if let content = wsp.find("txbxContent") {
            let inner = ConverterDocxBuilder(pkg, part: part, width: max(10, size.width - a.insets.left - a.insets.right))
            inner.blocks(content.children)
            inner.finish()
            a.story = ConverterDocxStory(text: inner.out, anchors: [])
        }
        return a
    }

    /// Older VML pictures (`w:pict`, `w:object`): the picture inline, text boxes after the paragraph.
    private func vml(_ n: ConverterXMLNode, _ props: ConverterDocxRunProps) {
        if let content = n.find("txbxContent") { deferred.append(content) }
        guard let data = n.find("imagedata"), let id = data["r:id"] else { return }
        let shape = n.children.first { ["shape", "rect", "roundrect", "oval"].contains($0.name) && $0.find("imagedata") != nil }
        var css: [String: String] = [:]
        for part in (shape?["style"] ?? "").split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { css[kv[0]] = kv[1] }
        }
        func length(_ s: String?) -> CGFloat? {
            guard let s else { return nil }
            if s.hasSuffix("pt") { return Double(s.dropLast(2)).map { CGFloat($0) } }
            if s.hasSuffix("in") { return Double(s.dropLast(2)).map { CGFloat($0) * 72 } }
            if s.hasSuffix("cm") { return Double(s.dropLast(2)).map { CGFloat($0) * 72 / 2.54 } }
            if s.hasSuffix("mm") { return Double(s.dropLast(2)).map { CGFloat($0) * 72 / 25.4 } }
            if s.hasSuffix("px") { return Double(s.dropLast(2)).map { CGFloat($0) * 0.75 } }
            return Double(s).map { CGFloat($0) * 0.75 }
        }
        let size = CGSize(width: length(css["width"]) ?? 0, height: length(css["height"]) ?? 0)
        guard let image = pkg.image(id, part: part, size: size) else { return }
        if css["position"] == "absolute" {
            let a = ConverterDocxAnchor(size: size.width > 0 ? size : CGSize(width: CGFloat(image.width) * 0.75, height: CGFloat(image.height) * 0.75))
            a.image = image
            a.hRelative = css["mso-position-horizontal-relative"].map { $0 == "text" ? "column" : $0 } ?? "column"
            a.vRelative = css["mso-position-vertical-relative"].map { $0 == "text" ? "paragraph" : $0 } ?? "paragraph"
            a.hOffset = length(css["margin-left"]) ?? (length(css["left"]) ?? 0)
            a.vOffset = length(css["margin-top"]) ?? (length(css["top"]) ?? 0)
            a.hAlign = css["mso-position-horizontal"].flatMap { $0 == "absolute" ? nil : $0 }
            a.vAlign = css["mso-position-vertical"].flatMap { $0 == "absolute" ? nil : $0 }
            a.behind = (css["z-index"].flatMap { Int($0) } ?? 0) < 0
            a.index = paragraphStart
            anchors.append(a)
        } else {
            attachment(image: image, scene: nil, size: size, props)
        }
    }

    // MARK: Tables

    private struct Cell {
        let node: ConverterXMLNode
        let props: ConverterDocxCellProps
        let column: Int
        let span: Int
    }

    private func table(_ tbl: ConverterXMLNode) {
        closeGroup()
        previous = nil
        let tblPr = tbl.child("tblPr")
        let direct = ConverterDocxTableProps.parse(tblPr, theme: theme)
        let given = tblPr?.child("tblStyle")?.val
        let styleID = styles.exists(given) ? given : styles.defaultTableStyle
        let style = styles.style(styleID)
        let parts = styles.conditional(styleID)
        var tp = style.table
        tp.merge(direct)
        let look = ConverterDocxTableProps.look(tblPr)

        func rows(_ n: ConverterXMLNode) -> [ConverterXMLNode] {
            n.children.flatMap { c -> [ConverterXMLNode] in
                switch c.name {
                case "tr": return [c]
                case "sdt": return rows(c.child("sdtContent") ?? c)
                case "customXml": return rows(c)
                default: return []
                }
            }
        }
        func rowCells(_ n: ConverterXMLNode) -> [ConverterXMLNode] {
            n.children.flatMap { c -> [ConverterXMLNode] in
                switch c.name {
                case "tc": return [c]
                case "sdt": return rowCells(c.child("sdtContent") ?? c)
                case "customXml": return rowCells(c)
                default: return []
                }
            }
        }
        let rowNodes = rows(tbl)
        guard !rowNodes.isEmpty else { return }
        var matrix: [[Cell]] = []
        var columnCount = 0
        for row in rowNodes {
            var col = row.child("trPr")?.child("gridBefore")?.val.flatMap(Int.init) ?? 0
            var list: [Cell] = []
            for tc in rowCells(row) {
                let props = ConverterDocxCellProps.parse(tc.child("tcPr"), theme: theme)
                let span = max(1, props.span ?? 1)
                list.append(Cell(node: tc, props: props, column: col, span: span))
                col += span
            }
            columnCount = max(columnCount, col)
            matrix.append(list)
        }
        guard columnCount > 0 else { return }

        // Column widths: the grid Word saved, else the cell widths, else equal shares.
        var grid = (tbl.child("tblGrid")?.all("gridCol") ?? []).map { ConverterDocxUnit.twips($0["w"]) ?? 0 }
        if grid.count < columnCount { grid += Array(repeating: 0, count: columnCount - grid.count) }
        if grid.contains(where: { $0 <= 0 }) {
            for row in matrix {
                for c in row where c.span == 1 && c.column < grid.count && grid[c.column] <= 0 {
                    if let w = c.props.width, w > 0 { grid[c.column] = w }
                }
            }
            let known = grid.filter { $0 > 0 }.reduce(0, +)
            let missing = grid.filter { $0 <= 0 }.count
            let tableWidth = tp.widthType == "pct" ? width * (tp.width ?? 100) / 100 : (tp.widthType == "dxa" ? (tp.width ?? width) : width)
            let share = missing > 0 ? max(18, (tableWidth - known) / CGFloat(missing)) : 0
            grid = grid.map { $0 > 0 ? $0 : share }
        }
        let total = grid.reduce(0, +)
        if total > width + 2 { grid = grid.map { $0 * width / total } }
        let tableWidth = grid.reduce(0, +)

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        var offset = tp.indent ?? 0
        switch tp.align {
        case "center": offset = (width - tableWidth) / 2
        case "right", "end": offset = width - tableWidth
        default: break
        }
        offset = max(0, min(offset, width - tableWidth))
        if offset > 0.5 { table.setWidth(offset, type: .absoluteValueType, for: .margin, edge: .minX) }

        let bandRows = max(1, tp.rowBand ?? 1)
        let bandCols = max(1, tp.colBand ?? 1)
        let headerRows = look.contains("firstRow") ? 1 : 0
        let saved = (cells: self.cells, style: tableStyle, width: width, previous: previous)

        for (r, row) in matrix.enumerated() {
            let trPr = rowNodes[r].child("trPr")
            let rowHeight = ConverterDocxUnit.twips(trPr?.child("trHeight")?.val)
            for cell in row where cell.props.vMerge != "continue" {
                var rowSpan = 1
                if cell.props.vMerge == "restart" {
                    var next = r + 1
                    while next < matrix.count, matrix[next].contains(where: { $0.column == cell.column && $0.props.vMerge == "continue" }) {
                        rowSpan += 1
                        next += 1
                    }
                }
                // The table style's parts that apply to this cell, from the widest to the most specific.
                var cond = ConverterDocxConditional()
                cond.para = style.para
                cond.run = style.run
                cond.cell = style.cell
                let lastRow = r + rowSpan == matrix.count
                let firstCol = cell.column == 0
                let lastCol = cell.column + cell.span == columnCount
                var applied: [String] = []
                if !look.contains("noVBand") { applied.append((cell.column / bandCols) % 2 == 0 ? "band1Vert" : "band2Vert") }
                if !look.contains("noHBand"), r >= headerRows { applied.append(((r - headerRows) / bandRows) % 2 == 0 ? "band1Horz" : "band2Horz") }
                if look.contains("firstColumn"), firstCol { applied.append("firstCol") }
                if look.contains("lastColumn"), lastCol { applied.append("lastCol") }
                if look.contains("firstRow"), r == 0 { applied.append("firstRow") }
                if look.contains("lastRow"), lastRow { applied.append("lastRow") }
                if r == 0, firstCol { applied.append("nwCell") }
                if r == 0, lastCol { applied.append("neCell") }
                if lastRow, firstCol { applied.append("swCell") }
                if lastRow, lastCol { applied.append("seCell") }
                for name in applied { if let part = parts[name] { cond.merge(part) } }
                var cp = cond.cell
                cp.merge(cell.props)

                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: rowSpan, startingColumn: cell.column, columnSpan: cell.span)
                func margin(_ edge: String, _ fallback: CGFloat) -> CGFloat { cp.margins[edge] ?? tp.margins[edge] ?? fallback }
                let padL = margin("left", 5.4), padR = margin("right", 5.4), padT = margin("top", 0), padB = margin("bottom", 0)
                block.setWidth(padL, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(padR, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(padT, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(padB, type: .absoluteValueType, for: .padding, edge: .maxY)
                let span = grid[cell.column..<min(grid.count, cell.column + cell.span)].reduce(0, +)
                var content = max(4, span - padL - padR)
                func border(_ name: String, outer: Bool, inside: String) -> ConverterDocxBorder? {
                    cp.borders[name] ?? (outer ? (cond.table.borders[name] ?? tp.borders[name]) : (cp.borders[inside] ?? cond.table.borders[inside] ?? tp.borders[inside]))
                }
                let edges: [(NSRectEdge, ConverterDocxBorder?)] = [
                    (.minY, border("top", outer: r == 0, inside: "insideH")),
                    (.maxY, border("bottom", outer: lastRow, inside: "insideH")),
                    (.minX, border("left", outer: firstCol, inside: "insideV")),
                    (.maxX, border("right", outer: lastCol, inside: "insideV"))
                ]
                for (edge, b) in edges {
                    guard let b, b.visible else { continue }
                    block.setWidth(b.width, type: .absoluteValueType, for: .border, edge: edge)
                    block.setBorderColor(ConverterDocxColor.color(b.color) ?? .black, for: edge)
                    // Word centres a border on the column's edge; TextKit adds it to the cell: half of it comes off the text.
                    if edge == .minX || edge == .maxX { content -= b.width / 2 }
                }
                // Each cell sets its own width; a width on the whole table would make TextKit shrink every column.
                block.setValue(max(4, content), type: .absoluteValueType, for: .width)
                if let shade = cp.shading ?? tp.shading, shade != "none" { block.backgroundColor = ConverterDocxColor.color(shade) }
                switch cp.vAlign {
                case "center": block.verticalAlignment = .middleAlignment
                case "bottom": block.verticalAlignment = .bottomAlignment
                default: block.verticalAlignment = .topAlignment
                }
                if let h = rowHeight, rowSpan == 1, trPr?.child("trHeight")?["hRule"] != "auto" {
                    block.setValue(max(0, h - padT - padB), type: .absoluteValueType, for: .minimumHeight)
                }

                self.cells = saved.cells + [block]
                tableStyle = cond
                width = content
                previous = nil
                let before = out.length
                blocks(cell.node.children)
                closeGroup()
                if out.length == before {
                    let s = paragraphStyle(styles.defaultPara, extraTab: nil)
                    out.append(NSAttributedString(string: "\n", attributes: attributes(styles.defaultRun).merging([.paragraphStyle: s]) { $1 }))
                }
            }
        }
        self.cells = saved.cells
        tableStyle = saved.style
        width = saved.width
        previous = nil
    }
}

/// Paragraph borders and shading as Word draws them: the left and right borders sit outside the text, at their spacing.
final class ConverterDocxBorderBlock: NSTextBlock {
    var lines: [String: (width: CGFloat, space: CGFloat, color: NSColor)] = [:]
    var fill: NSColor?
    var left: CGFloat = 0
    var right: CGFloat = 0

    override init() { super.init() }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = ConverterDocxBorderBlock()
        copy.lines = lines
        copy.fill = fill
        copy.left = left
        copy.right = right
        for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            copy.setWidth(width(for: .padding, edge: edge), type: .absoluteValueType, for: .padding, edge: edge)
            copy.setWidth(width(for: .margin, edge: edge), type: .absoluteValueType, for: .margin, edge: edge)
        }
        copy.setValue(contentWidth, type: contentWidthValueType, for: .width)
        return copy
    }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange,
                                 layoutManager: NSLayoutManager) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let top = width(for: .margin, edge: .minY)
        let bottom = width(for: .margin, edge: .maxY)
        let outLeft = lines["left"].map { $0.space + $0.width } ?? 0
        let outRight = lines["right"].map { $0.space + $0.width } ?? 0
        let box = CGRect(x: frameRect.minX + left - outLeft, y: frameRect.minY + top,
                         width: frameRect.width - left - right + outLeft + outRight, height: max(0, frameRect.height - top - bottom))
        if let fill {
            ctx.setFillColor(fill.cgColor)
            ctx.fill(box)
        }
        for (edge, line) in lines {
            let h = line.width / 2
            ctx.setStrokeColor(line.color.cgColor)
            ctx.setLineWidth(line.width)
            switch edge {
            case "top":
                ctx.move(to: CGPoint(x: box.minX, y: box.minY + h))
                ctx.addLine(to: CGPoint(x: box.maxX, y: box.minY + h))
            case "bottom":
                ctx.move(to: CGPoint(x: box.minX, y: box.maxY - h))
                ctx.addLine(to: CGPoint(x: box.maxX, y: box.maxY - h))
            case "left":
                ctx.move(to: CGPoint(x: box.minX + h, y: box.minY))
                ctx.addLine(to: CGPoint(x: box.minX + h, y: box.maxY))
            default:
                ctx.move(to: CGPoint(x: box.maxX - h, y: box.minY))
                ctx.addLine(to: CGPoint(x: box.maxX - h, y: box.maxY))
            }
            ctx.strokePath()
        }
    }
}

/// Draws a picture of the document in the text; works off the main thread, in any graphics context.
final class ConverterDocxImageCell: NSTextAttachmentCell {
    private let picture: CGImage?
    private let scene: [ConverterDocxAnchor]?
    private let size: CGSize

    init(image: CGImage?, scene: [ConverterDocxAnchor]?, size: CGSize) {
        picture = image
        self.scene = scene
        self.size = size
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func cellSize() -> NSSize { size }
    override func cellBaselineOffset() -> NSPoint { .zero }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        ctx.saveGState()
        if let scene {
            if !flipped {
                ctx.translateBy(x: 0, y: cellFrame.minY + cellFrame.maxY)
                ctx.scaleBy(x: 1, y: -1)
            }
            for item in scene {
                ConverterPageLayout.draw(item, in: CGRect(origin: CGPoint(x: cellFrame.minX + item.inner.x, y: cellFrame.minY + item.inner.y),
                                                          size: item.size), ctx: ctx)
            }
        } else if let picture {
            if flipped {
                ctx.translateBy(x: cellFrame.minX, y: cellFrame.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(picture, in: CGRect(origin: .zero, size: cellFrame.size))
            } else {
                ctx.draw(picture, in: cellFrame)
            }
        }
        ctx.restoreGState()
    }
}
