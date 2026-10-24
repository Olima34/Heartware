import AppKit
import CoreText

/// Lays a document out on its pages with TextKit, off the main thread: sections and columns, page breaks,
/// headings kept with what follows, widows and orphans, footnotes, floating pictures and shapes (text flows
/// around them), headers and footers with their page numbers, clickable links.
enum ConverterPageLayout {
    private struct Column {
        let container: NSTextContainer
        let origin: CGPoint
        let full: CGFloat
        var notes: [ConverterDocxStory]
    }

    private struct Page {
        let section: Int
        var columns: [Column] = []
    }

    /// A story laid out on its own (the storage owns the layout manager: keep it alive while drawing).
    private struct Laid {
        let storage: NSTextStorage
        let layout: NSLayoutManager
        let container: NSTextContainer
        var height: CGFloat { layout.usedRect(for: container).height }
    }

    static func render(_ doc: ConverterDocxDocument, title: String, control: ConverterControl? = nil) throws -> Data? {
        let sections = doc.sections.isEmpty ? [ConverterDocxSection()] : doc.sections
        let storage = NSTextStorage(attributedString: doc.text)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        layout.delegate = ConverterLineHeights.shared
        storage.addLayoutManager(layout)
        let length = storage.length
        let text = storage.string as NSString
        let notes = doc.footnotes.sorted { $0.index < $1.index }
        let breaks = doc.breaks

        func section(at index: Int) -> Int {
            var found = 0
            for (k, s) in sections.enumerated() where s.start <= index { found = k }
            return found
        }
        func characters(_ c: NSTextContainer) -> NSRange {
            layout.characterRange(forGlyphRange: layout.glyphRange(for: c), actualGlyphRange: nil)
        }
        func lineTop(_ index: Int) -> CGFloat {
            let g = layout.glyphIndexForCharacter(at: min(max(0, index), max(0, length - 1)))
            return layout.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY
        }
        // TextKit drops the space before a paragraph at the top of a column; Word keeps it.
        func lead(_ index: Int) -> CGFloat {
            guard index < length, index == 0 || [10, 13, 0x2029].contains(text.character(at: index - 1)) else { return 0 }
            return storage.attribute(ConverterDocx.beforeKey, at: index, effectiveRange: nil) as? CGFloat ?? 0
        }
        func keeps(_ index: Int, _ flag: Int) -> Bool {
            guard index < length, let v = storage.attribute(ConverterDocx.keepNextKey, at: index, effectiveRange: nil) as? Int else { return false }
            return v & flag != 0
        }
        func lines(_ range: NSRange) -> Int {
            var count = 0
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { _, _, _, _, _ in count += 1 }
            return count
        }

        // Where the last paragraph of a column must leave it: kept with the next one, kept whole, no lone line.
        func keepLimit(_ range: NSRange, width: CGFloat) -> CGFloat? {
            let end = NSMaxRange(range)
            guard end < length, end > range.location, !breaks.contains(end) else { return nil }
            let last = text.paragraphRange(for: NSRange(location: end - 1, length: 0))
            guard last.location > range.location else { return nil }
            if NSMaxRange(last) > end {
                if keeps(last.location, 1) { return lineTop(last.location) }
                guard storage.attribute(ConverterDocx.widowKey, at: last.location, effectiveRange: nil) != nil else { return nil }
                let here = lines(NSRange(location: last.location, length: end - last.location))
                if here <= 1 { return lineTop(last.location) }
                let rest = Self.lay(storage.attributedSubstring(from: NSRange(location: end, length: NSMaxRange(last) - end)), width: width)
                var restLines = 0
                rest.layout.enumerateLineFragments(forGlyphRange: rest.layout.glyphRange(for: rest.container)) { _, _, _, _, _ in restLines += 1 }
                guard restLines <= 1 else { return nil }
                return here == 2 ? lineTop(last.location) : lineTop(end - 1)
            }
            var p = last
            var limit: CGFloat?
            while keeps(p.location, 2), p.location > range.location {
                limit = lineTop(p.location)
                guard p.location > 0 else { break }
                let prev = text.paragraphRange(for: NSRange(location: p.location - 1, length: 0))
                guard prev.location > range.location, keeps(prev.location, 2) else { break }
                p = prev
            }
            return limit
        }

        var frames: [ObjectIdentifier: (column: Int, rect: CGRect)] = [:]
        var columnCount = 0

        func anchorFrame(_ a: ConverterDocxAnchor, sec: ConverterDocxSection, column: CGRect) -> CGRect {
            let index = min(max(0, a.index), max(0, length - 1))
            let g = layout.glyphIndexForCharacter(at: index)
            let line = layout.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let x = column.minX + line.minX + layout.location(forGlyphAt: g).x
            return Self.frame(a, sec: sec, column: column, paragraphTop: column.minY + line.minY, charX: x)
        }

        // Text flows around the floating pictures of this column; their place is fixed the first time they are seen.
        func wraps(_ range: NSRange, _ container: NSTextContainer, origin: CGPoint, sec: ConverterDocxSection, column: Int) -> [CGRect] {
            var rects: [CGRect] = []
            for a in doc.anchors where ["square", "tight", "through", "topandbottom"].contains(a.wrap) && NSLocationInRange(a.index, range) {
                let id = ObjectIdentifier(a)
                let rect: CGRect
                if let f = frames[id], f.column == column {
                    rect = f.rect
                } else {
                    rect = anchorFrame(a, sec: sec, column: CGRect(origin: origin, size: container.size))
                    frames[id] = (column, rect)
                }
                var r = rect.offsetBy(dx: -origin.x, dy: -origin.y)
                r = CGRect(x: r.minX - a.distance.left, y: r.minY - a.distance.top, width: r.width + a.distance.left + a.distance.right,
                           height: r.height + a.distance.top + a.distance.bottom)
                if a.wrap == "topandbottom" { r = CGRect(x: 0, y: r.minY, width: container.size.width, height: r.height) }
                r = r.intersection(CGRect(origin: .zero, size: CGSize(width: container.size.width, height: 100_000)))
                if !r.isNull, r.width > 0, r.height > 0 { rects.append(r) }
            }
            return rects
        }

        var heights: [Int: CGFloat] = [:]
        func noteHeight(_ i: Int, width: CGFloat) -> CGFloat {
            if let h = heights[i] { return h }
            let h = Self.lay(notes[i].story.text, width: width).height + 2
            heights[i] = h
            return h
        }

        func fit(_ container: NSTextContainer, origin: CGPoint, sec: ConverterDocxSection) -> [ConverterDocxStory] {
            let full = container.size.height
            var height = full
            var exclusions: [CGRect] = []
            let column = columnCount
            for _ in 0..<12 {
                let range = characters(container)
                guard range.length > 0 else { break }
                var limit = height
                if let b = breaks.first(where: { $0 > range.location && $0 < NSMaxRange(range) }) {
                    let top = lineTop(b)
                    if top > 1 { limit = min(limit, top + 0.5) }
                }
                let refs = notes.indices.filter { NSLocationInRange(notes[$0].index, range) }
                if !refs.isEmpty {
                    let reserve = refs.reduce(CGFloat(14)) { $0 + noteHeight($1, width: container.size.width) }
                    limit = min(limit, max(full * 0.35, full - reserve))
                }
                // Where Word broke this page itself, near its bottom: break there too (keeps and widows included).
                var followed = false
                if let h = doc.hints.first(where: { $0 > range.location && $0 < NSMaxRange(range) }) {
                    let top = lineTop(h)
                    if top >= full * 0.72 {
                        limit = min(limit, top + 0.5)
                        followed = true
                    }
                }
                if !followed, let keep = keepLimit(range, width: container.size.width), keep > 1 { limit = min(limit, keep + 0.5) }
                var changed = false
                let rects = wraps(range, container, origin: origin, sec: sec, column: column)
                if rects != exclusions {
                    exclusions = rects
                    container.exclusionPaths = rects.map { NSBezierPath(rect: $0) }
                    changed = true
                }
                if limit < height - 0.25 {
                    height = limit
                    container.size = CGSize(width: container.size.width, height: height)
                    changed = true
                }
                if !changed { break }
            }
            let range = characters(container)
            return notes.filter { NSLocationInRange($0.index, range) }.map(\.story)
        }

        // Pages: one text container per column, each fitted before the next one is added.
        var pages: [Page] = []
        var next = 0
        if length == 0 { pages = [Page(section: 0)] }
        paging: while next < length, pages.count < 5000 {
            try control?.check()
            let si = section(at: next)
            let sec = sections[si]
            let width = max(36, (sec.textWidth - CGFloat(sec.columns - 1) * sec.columnSpace) / CGFloat(sec.columns))
            var page = Page(section: si)
            for c in 0..<sec.columns {
                let top = min(lead(next), sec.textHeight / 3)
                let container = NSTextContainer(size: CGSize(width: width, height: sec.textHeight - top))
                container.lineFragmentPadding = 0
                layout.addTextContainer(container)
                let origin = CGPoint(x: sec.margins.left + CGFloat(c) * (width + sec.columnSpace), y: sec.margins.top + top)
                let columnNotes = fit(container, origin: origin, sec: sec)
                columnCount += 1
                page.columns.append(Column(container: container, origin: origin, full: sec.textHeight - top, notes: columnNotes))
                let range = characters(container)
                guard range.length > 0 else {
                    pages.append(page)
                    break paging
                }
                next = NSMaxRange(range)
                if next >= length || section(at: next) != si { break }
            }
            pages.append(page)
        }

        // Drawing.
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var media = CGRect(origin: .zero, size: sections[pages.first?.section ?? 0].pageSize)
        let info = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Heartware"] as CFDictionary
        guard let ctx = CGContext(consumer: consumer, mediaBox: &media, info) else { return nil }
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        var perSection: [Int: Int] = [:]
        for p in pages { perSection[p.section, default: 0] += 1 }
        var number = 0
        var columnIndex = 0
        for (i, page) in pages.enumerated() {
            try control?.check()
            let sec = sections[page.section]
            let first = i == 0 || pages[i - 1].section != page.section
            if first, let start = sec.pageStart { number = start } else { number += 1 }
            var box = CGRect(origin: .zero, size: sec.pageSize)
            let boxData = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: sec.pageSize.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

            // Floating objects of the body anchored on this page.
            var placed: [(ConverterDocxAnchor, CGRect)] = []
            for (k, col) in page.columns.enumerated() {
                let range = characters(col.container)
                let isLast = i == pages.count - 1 && k == page.columns.count - 1
                for a in doc.anchors where NSLocationInRange(a.index, range) || (isLast && a.index >= NSMaxRange(range)) {
                    let rect = frames[ObjectIdentifier(a)].map { $0.column == columnIndex + k ? $0.rect : nil } ?? nil
                    placed.append((a, rect ?? anchorFrame(a, sec: sec, column: CGRect(origin: col.origin, size: CGSize(width: col.container.size.width, height: col.full)))))
                }
            }
            for (a, rect) in placed where a.behind { Self.draw(a, in: rect, ctx: ctx) }

            let values = ["PAGE": ConverterDocxNumbering.format(number, sec.pageFormat), "NUMPAGES": "\(pages.count)",
                          "SECTIONPAGES": "\(perSection[page.section] ?? 1)"]
            let kind = first && sec.titlePage ? "first" : (doc.evenAndOdd && number % 2 == 0 ? "even" : "default")
            if let header = sec.headers[kind] { Self.drawStory(header, sec: sec, top: sec.header, bottom: nil, values: values, ctx: ctx) }
            if let footer = sec.footers[kind] {
                Self.drawStory(footer, sec: sec, top: nil, bottom: sec.pageSize.height - sec.footer, values: values, ctx: ctx)
            }

            var links: [(URL, CGRect)] = []
            for col in page.columns {
                let glyphs = layout.glyphRange(for: col.container)
                layout.drawBackground(forGlyphRange: glyphs, at: col.origin)
                layout.drawGlyphs(forGlyphRange: glyphs, at: col.origin)
                Self.drawLeaders(storage, layout, col.container, glyphs: glyphs, origin: col.origin, ctx: ctx)
                storage.enumerateAttribute(.link, in: characters(col.container)) { value, range, _ in
                    guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return }
                    let g = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    layout.enumerateEnclosingRects(forGlyphRange: g, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                   in: col.container) { rect, _ in
                        let r = rect.offsetBy(dx: col.origin.x, dy: col.origin.y)
                        links.append((url, CGRect(x: r.minX, y: sec.pageSize.height - r.maxY, width: r.width, height: r.height)))
                    }
                }
                // Footnotes at the bottom of the column, under a short rule.
                if !col.notes.isEmpty {
                    let laid = col.notes.map { Self.lay($0.text, width: col.container.size.width) }
                    let total = laid.reduce(0) { $0 + $1.height + 2 }
                    var y = col.origin.y + col.full - total
                    ctx.setStrokeColor(NSColor.black.cgColor)
                    ctx.setLineWidth(0.5)
                    ctx.move(to: CGPoint(x: col.origin.x, y: y - 6))
                    ctx.addLine(to: CGPoint(x: col.origin.x + min(144, col.container.size.width / 3), y: y - 6))
                    ctx.strokePath()
                    for l in laid {
                        let g = l.layout.glyphRange(for: l.container)
                        l.layout.drawBackground(forGlyphRange: g, at: CGPoint(x: col.origin.x, y: y))
                        l.layout.drawGlyphs(forGlyphRange: g, at: CGPoint(x: col.origin.x, y: y))
                        y += l.height + 2
                    }
                }
            }
            for (a, rect) in placed where !a.behind { Self.draw(a, in: rect, ctx: ctx) }
            columnIndex += page.columns.count

            NSGraphicsContext.current = previous
            ctx.restoreGState()
            for (url, rect) in links { ctx.setURL(url as CFURL, for: rect) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    // MARK: Pieces

    private static func lay(_ text: NSAttributedString, width: CGFloat) -> Laid {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        layout.delegate = ConverterLineHeights.shared
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: 100_000))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return Laid(storage: storage, layout: layout, container: container)
    }

    /// Page numbers and page counts written into a header or footer.
    static func fill(_ text: NSAttributedString, _ values: [String: String]) -> NSAttributedString {
        var ranges: [(NSRange, String)] = []
        text.enumerateAttribute(ConverterDocx.fieldKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let k = value as? String, let v = values[k] { ranges.append((range, v)) }
        }
        guard !ranges.isEmpty else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        for (range, value) in ranges.reversed() { out.replaceCharacters(in: range, with: value) }
        return out
    }

    private static func drawStory(_ story: ConverterDocxStory, sec: ConverterDocxSection, top: CGFloat?, bottom: CGFloat?,
                                  values: [String: String], ctx: CGContext) {
        let laid = lay(fill(story.text, values), width: sec.textWidth)
        let y = top ?? ((bottom ?? 0) - laid.height)
        let origin = CGPoint(x: sec.margins.left, y: y)
        let column = CGRect(origin: origin, size: CGSize(width: sec.textWidth, height: laid.height))
        let placed = story.anchors.map { a -> (ConverterDocxAnchor, CGRect) in
            let index = min(max(0, a.index), max(0, laid.storage.length - 1))
            let line = laid.storage.length > 0
                ? laid.layout.lineFragmentRect(forGlyphAt: laid.layout.glyphIndexForCharacter(at: index), effectiveRange: nil) : .zero
            return (a, frame(a, sec: sec, column: column, paragraphTop: origin.y + line.minY, charX: origin.x + line.minX))
        }
        for (a, rect) in placed where a.behind { draw(a, in: rect, ctx: ctx) }
        let g = laid.layout.glyphRange(for: laid.container)
        laid.layout.drawBackground(forGlyphRange: g, at: origin)
        laid.layout.drawGlyphs(forGlyphRange: g, at: origin)
        for (a, rect) in placed where !a.behind { draw(a, in: rect, ctx: ctx) }
    }

    /// Where a floating object goes on its page.
    static func frame(_ a: ConverterDocxAnchor, sec: ConverterDocxSection, column: CGRect, paragraphTop: CGFloat, charX: CGFloat) -> CGRect {
        let size = a.size
        let page = sec.pageSize
        let margin = CGRect(x: sec.margins.left, y: sec.margins.top, width: sec.textWidth, height: sec.textHeight)
        let h: (CGFloat, CGFloat)
        switch a.hRelative {
        case "page": h = (0, page.width)
        case "margin", "insideMargin", "outsideMargin": h = (margin.minX, margin.width)
        case "leftMargin": h = (0, margin.minX)
        case "rightMargin": h = (margin.maxX, page.width - margin.maxX)
        case "character": h = (charX, 0)
        default: h = (column.minX, column.width)
        }
        let v: (CGFloat, CGFloat)
        switch a.vRelative {
        case "page": v = (0, page.height)
        case "margin", "insideMargin", "outsideMargin": v = (margin.minY, margin.height)
        case "topMargin": v = (0, margin.minY)
        case "bottomMargin": v = (margin.maxY, page.height - margin.maxY)
        default: v = (paragraphTop, 0)
        }
        func place(_ align: String?, _ offset: CGFloat, _ area: (CGFloat, CGFloat), _ length: CGFloat) -> CGFloat {
            switch align {
            case "center": return area.0 + (area.1 - length) / 2
            case "right", "bottom", "outside": return area.0 + area.1 - length
            case "left", "top", "inside": return area.0
            default: return area.0 + offset
            }
        }
        return CGRect(x: place(a.hAlign, a.hOffset, h, size.width) + a.inner.x, y: place(a.vAlign, a.vOffset, v, size.height) + a.inner.y,
                      width: a.size.width, height: a.size.height)
    }

    /// Draws a floating picture or shape (or a whole group) in its frame, turned and flipped as Word does.
    static func draw(_ a: ConverterDocxAnchor, in rect: CGRect, ctx: CGContext) {
        if let scene = a.scene {
            for item in scene {
                draw(item, in: CGRect(origin: CGPoint(x: rect.minX + item.inner.x, y: rect.minY + item.inner.y), size: item.size), ctx: ctx)
            }
            return
        }
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        if a.rotation != 0 { ctx.rotate(by: a.rotation * .pi / 180) }
        let local = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
        ctx.saveGState()
        ctx.scaleBy(x: a.flipH ? -1 : 1, y: a.flipV ? -1 : 1)
        var outline = a.outline ?? CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
        if a.outline != nil, a.size != rect.size, a.size.width > 0, a.size.height > 0 {
            var k = CGAffineTransform(scaleX: rect.width / a.size.width, y: rect.height / a.size.height)
            outline = outline.copy(using: &k) ?? outline
        }
        var move = CGAffineTransform(translationX: local.minX, y: local.minY)
        let path = outline.copy(using: &move) ?? outline
        if let fill = a.fill, !a.open {
            ctx.addPath(path)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
        }
        if let image = a.image {
            ctx.saveGState()
            ctx.translateBy(x: local.minX, y: local.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(origin: .zero, size: local.size))
            ctx.restoreGState()
        }
        if let stroke = a.stroke, a.lineWidth > 0 {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(a.lineWidth)
            if !a.dash.isEmpty { ctx.setLineDash(phase: 0, lengths: a.dash.map { $0 * max(1, a.lineWidth) }) }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            if a.open, let ends = ConverterDocxGeometry.ends(path) {
                for (type, tip, from) in [(a.headEnd, ends.start, ends.afterStart), (a.tailEnd, ends.end, ends.beforeEnd)] {
                    guard let type, let head = ConverterDocxGeometry.arrow(type, tip: tip, from: from, width: a.lineWidth) else { continue }
                    ctx.addPath(head.path)
                    if head.fill {
                        ctx.setFillColor(stroke.cgColor)
                        ctx.fillPath()
                    } else {
                        ctx.strokePath()
                    }
                }
            }
        }
        ctx.restoreGState()
        if let story = a.story, story.text.length > 0 {
            let laid = lay(story.text, width: local.width - a.insets.left - a.insets.right)
            let room = local.height - a.insets.top - a.insets.bottom
            var y = local.minY + a.insets.top
            if a.textAnchor == "ctr" { y += max(0, (room - laid.height) / 2) }
            if a.textAnchor == "b" { y += max(0, room - laid.height) }
            let g = laid.layout.glyphRange(for: laid.container)
            let origin = CGPoint(x: local.minX + a.insets.left, y: y)
            laid.layout.drawBackground(forGlyphRange: g, at: origin)
            laid.layout.drawGlyphs(forGlyphRange: g, at: origin)
        }
        ctx.restoreGState()
    }

    /// Dots (or dashes, or a line) before the tab stops that ask for them, as in a table of contents.
    private static func drawLeaders(_ storage: NSTextStorage, _ layout: NSLayoutManager, _ container: NSTextContainer,
                                    glyphs: NSRange, origin: CGPoint, ctx: CGContext) {
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let text = storage.string as NSString
        storage.enumerateAttribute(ConverterDocx.leadersKey, in: chars) { value, range, _ in
            guard let stops = value as? [[CGFloat]] else { return }
            var i = range.location
            while i < NSMaxRange(range) {
                defer { i += 1 }
                guard text.character(at: i) == 9 else { continue }
                let g = layout.glyphIndexForCharacter(at: i)
                let rect = layout.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: container)
                guard rect.width > 8, let style = storage.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle,
                      let target = style.tabStops.first(where: { $0.location > rect.minX + 0.5 }),
                      let stop = stops.first(where: { abs($0[0] - target.location) < 1 }), stop.count > 1 else { continue }
                let char = ["." , "·", "-", "_"][min(3, max(0, Int(stop[1])))]
                let font = storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont ?? NSFont.systemFont(ofSize: 10)
                let color = storage.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor ?? .black
                let unit = NSAttributedString(string: char, attributes: [.font: font])
                let w = max(1, unit.size().width + (char == "_" ? 0 : 1.5))
                let count = Int((rect.width - 4) / w)
                guard count > 0 else { continue }
                let lineRect = layout.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                let baseline = origin.y + lineRect.minY + layout.location(forGlyphAt: g).y
                let leader = NSAttributedString(string: String(repeating: char, count: count),
                                                attributes: [.font: font, .foregroundColor: color, .kern: w - unit.size().width])
                let ctLine = CTLineCreateWithAttributedString(leader)
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(x: origin.x + rect.maxX - 2 - CGFloat(count) * w, y: baseline)
                CTLineDraw(ctLine, ctx)
                ctx.restoreGState()
            }
        }
    }
}

/// Lines as tall as Word makes them. TextKit rounds a font's ascent and descent to whole points before applying the
/// line spacing (Verdana 11 pt: 13 instead of 13.37, 3 % per line, a page every thirty); Word keeps the exact
/// ascent + descent + line gap. Only that rounding is corrected: lines with pictures or raised text keep TextKit's height.
final class ConverterLineHeights: NSObject, NSLayoutManagerDelegate {
    static let shared = ConverterLineHeights()

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = layoutManager.textStorage, glyphRange.length > 0 else { return false }
        let chars = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard chars.location < storage.length,
              let style = storage.attribute(.paragraphStyle, at: chars.location, effectiveRange: nil) as? NSParagraphStyle,
              style.maximumLineHeight == 0 else { return false }
        var exact: CGFloat = 0
        var plain = true
        storage.enumerateAttributes(in: chars, options: []) { attrs, _, stop in
            if attrs[.attachment] != nil || (attrs[.baselineOffset] as? CGFloat ?? 0) != 0 {
                plain = false
                stop.pointee = true
                return
            }
            if let font = attrs[.font] as? NSFont { exact = max(exact, font.ascender - font.descender + font.leading) }
        }
        guard plain, exact > 0 else { return false }
        let multiple = style.lineHeightMultiple > 0 ? style.lineHeightMultiple : 1
        let wanted = max(exact * multiple, style.minimumLineHeight)
        let used = lineFragmentUsedRect.pointee.height
        let delta = wanted - used
        guard delta != 0, abs(delta) <= 0.6 * multiple + 0.01 else { return false }
        lineFragmentRect.pointee.size.height += delta
        lineFragmentUsedRect.pointee.size.height += delta
        return true
    }
}
