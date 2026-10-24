import Foundation
import PDFKit
import Quartz
import ImageIO

/// PDF with PDFKit and Core Graphics. Every operation writes a new file.
enum ConverterPDFEngine {
    static let reduceFilter = "/System/Library/Filters/Reduce File Size.qfilter"

    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ConverterError.unreadable(url.lastPathComponent) }
        if doc.isLocked { throw ConverterError.unsupported("« \(url.lastPathComponent) » est protégé par un mot de passe.") }
        return doc
    }

    // MARK: - Page ranges

    /// "1-3, 5, 8-" → zero-based indexes in reading order, without duplicates. Empty means every page; nil when invalid.
    static func parsePages(_ spec: String, count: Int) -> [Int]? {
        let cleaned = spec.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: " à ", with: "-")
        let tokens = cleaned.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if tokens.isEmpty { return count > 0 ? Array(0..<count) : nil }
        var result: [Int] = []
        var seen = Set<Int>()
        for token in tokens {
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let range: ClosedRange<Int>
            switch bounds.count {
            case 1:
                guard let n = Int(bounds[0]) else { return nil }
                range = n...n
            case 2:
                let a = bounds[0].isEmpty ? 1 : Int(bounds[0])
                let b = bounds[1].isEmpty ? count : Int(bounds[1])
                guard let a, let b, a <= b else { return nil }
                range = a...b
            default:
                return nil
            }
            guard range.lowerBound >= 1, range.upperBound <= count else { return nil }
            for p in range where seen.insert(p - 1).inserted { result.append(p - 1) }
        }
        return result
    }

    /// [0, 1, 2, 4] → "1-3, 5" (one-based).
    static func describePages(_ pages: [Int]) -> String {
        var parts: [String] = []
        var i = 0
        while i < pages.count {
            var j = i
            while j + 1 < pages.count && pages[j + 1] == pages[j] + 1 { j += 1 }
            parts.append(j > i ? "\(pages[i] + 1)-\(pages[j] + 1)" : "\(pages[i] + 1)")
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }

    private static func pagesOrThrow(_ spec: String, count: Int) throws -> [Int] {
        guard let pages = parsePages(spec, count: count), !pages.isEmpty else {
            throw ConverterError.unsupported("Pages invalides : « \(spec) ». Ce PDF en a \(count) ; exemple : 1-3, 5, 8-")
        }
        return pages
    }

    private static func write(_ doc: PDFDocument, to url: URL) throws -> URL {
        guard doc.write(to: url) else {
            ConverterOutputs.discard(url)
            throw ConverterError.failed("L'écriture du PDF a échoué.")
        }
        FileOps.didCreate(url)
        return url
    }

    // MARK: - Operations

    // MARK: - Merge

    /// One document of a merge, already open: a PDF and the pages kept from it, or an image made into a page.
    struct MergePart {
        enum Source {
            case pdf(PDFDocument, pages: String)
            /// The one-page PDF made from the image (kept whole: a page lives only as long as its document).
            case image(PDFDocument)
        }
        var name: String
        var source: Source
    }

    /// What a merge asks for, besides the documents.
    struct MergeSettings {
        var bookmarks = true
        /// A blank page after a document that ends on a recto, so that each one starts on a new sheet once printed double-sided.
        var duplex = false
        var title = ""
    }

    /// The PDFs (the chosen pages of each) and the images, in order, in one document: a bookmark per document with its own
    /// bookmarks under it, links and form fields kept. Writes nothing: `merge` saves it.
    static func mergedDocument(_ parts: [MergePart], settings: MergeSettings, control: ConverterControl) throws -> PDFDocument {
        var plan: [(part: MergePart, pages: [Int])] = []
        for part in parts {
            switch part.source {
            case .pdf(let doc, let spec):
                guard let pages = parsePages(spec, count: doc.pageCount), !pages.isEmpty else {
                    throw ConverterError.unsupported("Pages invalides pour « \(part.name) » : « \(spec) ». Il a \(Fmt.plural(doc.pageCount, "page", "pages")) ; exemple : 1-3, 5, 8-")
                }
                plan.append((part, pages))
            case .image:
                plan.append((part, [0]))
            }
        }
        let total = max(1, plan.reduce(0) { $0 + $1.pages.count })
        let result = PDFDocument()
        // A fresh document's outline is written with it (one opened from a file would drop it).
        let root = PDFOutline()
        if settings.bookmarks { result.outlineRoot = root }
        var done = 0
        for (n, step) in plan.enumerated() {
            let first = result.pageCount
            var map: [Int: PDFPage] = [:]
            switch step.part.source {
            case .pdf(let doc, _):
                for i in step.pages {
                    try control.check()
                    guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                    result.insert(page, at: result.pageCount)
                    map[i] = page
                    done += 1
                    control.progress(Double(done) / Double(total))
                }
                if settings.bookmarks, let start = result.page(at: first) {
                    let entry = bookmark(step.part.name, to: start)
                    root.insertChild(entry, at: root.numberOfChildren)
                    if let own = doc.outlineRoot { copyOutline(own, into: entry, pages: map, of: doc) }
                }
            case .image(let doc):
                try control.check()
                guard let page = doc.page(at: 0)?.copy() as? PDFPage else { continue }
                result.insert(page, at: result.pageCount)
                done += 1
                control.progress(Double(done) / Double(total))
                if settings.bookmarks { root.insertChild(bookmark(step.part.name, to: page), at: root.numberOfChildren) }
            }
            // Printed double-sided, the next document starts on a new sheet.
            if settings.duplex, n < plan.count - 1, result.pageCount % 2 == 1, let last = result.page(at: result.pageCount - 1) {
                result.insert(blankPage(like: last), at: result.pageCount)
            }
        }
        guard result.pageCount > 0 else { throw ConverterError.failed("Aucune page à assembler.") }
        var attributes: [AnyHashable: Any] = [PDFDocumentAttribute.creatorAttribute: "Heartware"]
        if !settings.title.isEmpty { attributes[PDFDocumentAttribute.titleAttribute] = settings.title }
        result.documentAttributes = attributes
        return result
    }

    /// Opens the documents of the list (PDFs and images) and saves their merge as one new PDF.
    static func merge(_ inputs: [URL], kinds: [ConverterKind], options o: ConverterOptions, folder: URL?,
                      control: ConverterControl) throws -> URL {
        var parts: [MergePart] = []
        for (url, kind) in zip(inputs, kinds) {
            let name = url.deletingPathExtension().lastPathComponent
            if kind == .image {
                let data = try imagesPDFData([url], pageSize: o.pageSize, quality: 0.9, control: ConverterControl { _ in })
                guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { throw ConverterError.unreadable(url.lastPathComponent) }
                parts.append(MergePart(name: name, source: .image(doc)))
            } else {
                parts.append(MergePart(name: name, source: .pdf(try open(url), pages: o.mergePages[url.path] ?? "")))
            }
        }
        let name = mergeName(o.mergeName, first: inputs[0])
        let doc = try mergedDocument(parts, settings: MergeSettings(bookmarks: o.mergeBookmarks, duplex: o.mergeDuplex, title: name),
                                     control: control)
        let dir = folder ?? inputs[0].deletingLastPathComponent()
        return try write(doc, to: FileOps.uniqueURL(dir.appendingPathComponent(name).appendingPathExtension("pdf")))
    }

    /// The merged PDF's name, without extension: the one typed (cleaned of "/" and ".pdf"), or "<first document> fusionné".
    static func mergeName(_ typed: String, first: URL) -> String {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.lowercased().hasSuffix(".pdf") { name = String(name.dropLast(4)).trimmingCharacters(in: .whitespaces) }
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? first.deletingPathExtension().lastPathComponent + " fusionné" : name
    }

    private static func bookmark(_ label: String, to page: PDFPage) -> PDFOutline {
        let item = PDFOutline()
        item.label = label
        let box = page.bounds(for: .cropBox)
        item.destination = PDFDestination(page: page, at: CGPoint(x: box.minX, y: box.maxY))
        return item
    }

    /// The bookmarks of a source whose page was kept, under its document's bookmark; those of left-out pages go,
    /// their kept children move up a level.
    private static func copyOutline(_ item: PDFOutline, into parent: PDFOutline, pages: [Int: PDFPage], of doc: PDFDocument) {
        for i in 0..<item.numberOfChildren {
            guard let child = item.child(at: i) else { continue }
            let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
            if let destination, let page = destination.page, let target = pages[doc.index(for: page)] {
                let copy = PDFOutline()
                copy.label = child.label
                copy.destination = PDFDestination(page: target, at: destination.point)
                parent.insertChild(copy, at: parent.numberOfChildren)
                copyOutline(child, into: copy, pages: pages, of: doc)
            } else {
                copyOutline(child, into: parent, pages: pages, of: doc)
            }
        }
    }

    /// An empty page of the same size and orientation.
    private static func blankPage(like page: PDFPage) -> PDFPage {
        let blank = PDFPage()
        blank.setBounds(page.bounds(for: .mediaBox), for: .mediaBox)
        blank.setBounds(page.bounds(for: .cropBox), for: .cropBox)
        blank.rotation = page.rotation
        return blank
    }

    static func split(_ input: URL, spec: String, mode: ConverterSplitMode, folder: URL?, control: ConverterControl) throws -> [URL] {
        let doc = try open(input)
        let pages = try pagesOrThrow(spec, count: doc.pageCount)
        let base = input.deletingPathExtension().lastPathComponent
        switch mode {
        case .extract:
            let result = PDFDocument()
            for (n, i) in pages.enumerated() {
                try control.check()
                if let page = doc.page(at: i)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
                control.progress(Double(n + 1) / Double(pages.count))
            }
            let out = FileOps.outputURL(for: input, extension: "pdf", suffix: "pages \(describePages(pages))", folder: folder)
            return [try write(result, to: out)]
        case .eachPage:
            let dir = FileOps.uniqueURL((folder ?? input.deletingLastPathComponent()).appendingPathComponent("\(base) – pages"))
            let digits = String(doc.pageCount).count
            for (n, i) in pages.enumerated() {
                try control.check()
                let single = PDFDocument()
                if let page = doc.page(at: i)?.copy() as? PDFPage { single.insert(page, at: 0) }
                guard let data = single.dataRepresentation() else { throw ConverterError.failed("La page \(i + 1) n'a pas pu être écrite.") }
                try FileOps.write(data, to: dir.appendingPathComponent("\(base) p\(pad(i + 1, digits)).pdf"))
                control.progress(Double(n + 1) / Double(pages.count))
            }
            return [dir]
        }
    }

    static func rotate(_ input: URL, angle: Int, spec: String, folder: URL?, control: ConverterControl) throws -> URL {
        let doc = try open(input)
        let pages = try pagesOrThrow(spec, count: doc.pageCount)
        for i in pages {
            try control.check()
            guard let page = doc.page(at: i) else { continue }
            page.rotation = ((page.rotation + angle) % 360 + 360) % 360
        }
        control.progress(1)
        let out = FileOps.outputURL(for: input, extension: "pdf", suffix: "pivoté", folder: folder)
        return try write(doc, to: out)
    }

    /// Recompresses the images. Returns nil when nothing came out noticeably smaller (no file is written then).
    /// PDFKit's JPEG options come first (macOS 13+; some systems ignore them), then a Quartz filter, the engine
    /// behind Preview's "Reduce File Size", tuned for the chosen level.
    static func compress(_ input: URL, level: ConverterPDFCompression, folder: URL?, control: ConverterControl) throws -> (url: URL?, saved: Int64) {
        let doc = try open(input)
        let original = ConverterOutputs.size(input)
        let target = Double(original) * 0.95
        control.progress(nil)
        var best: Data?
        func consider(_ data: Data?) {
            guard let data, Double(data.count) < target, data.count < (best?.count ?? Int.max) else { return }
            best = data
        }
        if level == .balanced {
            consider(doc.dataRepresentation(options: [PDFDocumentWriteOption.saveImagesAsJPEGOption: true,
                                                      PDFDocumentWriteOption.optimizeImagesForScreenOption: true]))
        }
        try control.check()
        if best == nil, let filter = quartzFilter(level), let fresh = PDFDocument(url: input) {
            consider(fresh.dataRepresentation(options: ["QuartzFilter": filter]))
        }
        try control.check()
        guard let best else { return (nil, 0) }
        let out = FileOps.outputURL(for: input, extension: "pdf", suffix: "allégé", folder: folder)
        let url = try FileOps.write(best, to: out)
        control.progress(1)
        return (url, original - Int64(best.count))
    }

    /// JPEG quality, resolution and longest side of the images for each level.
    static func filterSettings(_ level: ConverterPDFCompression) -> (quality: Double, dpi: Int, maxSide: Int) {
        level == .balanced ? (0.8, 150, 3000) : (0.55, 110, 1600)
    }

    static func quartzFilter(_ level: ConverterPDFCompression) -> QuartzFilter? {
        let s = filterSettings(level)
        let properties: [String: Any] = [
            "Domains": ["Applications": true],
            "FilterType": 1,
            "Name": "Heartware",
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": s.quality,
                "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": ["ImageResolution": s.dpi, "ImageScaleInterpolate": true, "ImageSizeMax": s.maxSide, "ImageSizeMin": 0]
            ]]]
        ]
        if let filter = QuartzFilter(properties: properties) { return filter }
        guard FileManager.default.fileExists(atPath: reduceFilter) else { return nil }
        return QuartzFilter(url: URL(fileURLWithPath: reduceFilter))
    }

    static func toImages(_ input: URL, format: ConverterRasterFormat, dpi: Int, spec: String, folder: URL?,
                         control: ConverterControl) throws -> URL {
        let doc = try open(input)
        let pages = try pagesOrThrow(spec, count: doc.pageCount)
        let base = input.deletingPathExtension().lastPathComponent
        let dir = FileOps.uniqueURL((folder ?? input.deletingLastPathComponent()).appendingPathComponent("\(base) – images"))
        let digits = String(doc.pageCount).count
        for (n, i) in pages.enumerated() {
            try control.check()
            guard let page = doc.page(at: i), let image = render(page, dpi: CGFloat(dpi)),
                  let data = ConverterImageEngine.encode(image, uti: format.uti, quality: format == .png ? nil : 0.9) else {
                throw ConverterError.failed("La page \(i + 1) n'a pas pu être dessinée.")
            }
            try FileOps.write(data, to: dir.appendingPathComponent("\(base) page \(pad(i + 1, digits)).\(format.ext)"))
            control.progress(Double(n + 1) / Double(pages.count))
        }
        return dir
    }

    /// One page as a bitmap (rotation and crop box applied, white background), at most `maxSide` pixels long.
    static func render(_ page: PDFPage, dpi: CGFloat, maxSide: CGFloat = 10_000) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let pageW = turned ? box.height : box.width
        let pageH = turned ? box.width : box.height
        guard pageW > 0, pageH > 0 else { return nil }
        var scale = dpi / 72
        scale = min(scale, maxSide / max(pageW, pageH))
        let w = Int((pageW * scale).rounded()), h = Int((pageH * scale).rounded())
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(w) / pageW, y: CGFloat(h) / pageH)
        // `draw(with:to:)` turns and crops the page itself: adding `transform(for:)` drew a turned or cropped page off the image.
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    /// One page per image, in order. Photos are embedded as JPEG at `quality`; images with transparency stay lossless.
    static func fromImages(_ inputs: [URL], pageSize: ConverterPageSize, quality: Double, folder: URL?,
                           control: ConverterControl) throws -> URL {
        let data = try imagesPDFData(inputs, pageSize: pageSize, quality: quality, control: control)
        let out = FileOps.outputURL(for: inputs[0], extension: "pdf", folder: folder)
        return try FileOps.write(data, to: out)
    }

    /// The PDF of `fromImages`, in memory (a merge takes its pages from there).
    static func imagesPDFData(_ inputs: [URL], pageSize: ConverterPageSize, quality: Double, control: ConverterControl) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw ConverterError.failed("PDF impossible à créer.") }
        var media = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let info = [kCGPDFContextCreator: "Heartware"] as CFDictionary
        guard let ctx = CGContext(consumer: consumer, mediaBox: &media, info) else { throw ConverterError.failed("PDF impossible à créer.") }
        for (n, url) in inputs.enumerated() {
            try control.check()
            let src = try ConverterImageEngine.source(url)
            let primary = CGImageSourceGetPrimaryImageIndex(src)
            guard let upright = ConverterImageEngine.uprightImage(src, index: primary, maxSide: 0) else {
                throw ConverterError.unreadable(url.lastPathComponent)
            }
            let props = CGImageSourceCopyPropertiesAtIndex(src, primary, nil) as? [CFString: Any]
            let image = embeddable(upright, transparent: props?[kCGImagePropertyHasAlpha] as? Bool == true, quality: quality)
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            var page: CGRect
            var target: CGRect
            switch pageSize {
            case .image:
                // The image's own proportions, on a page no longer than an A4.
                let k = min(1, 841.89 / max(iw, ih))
                page = CGRect(x: 0, y: 0, width: (iw * k).rounded(), height: (ih * k).rounded())
                target = page
            case .a4:
                page = iw > ih ? CGRect(x: 0, y: 0, width: 841.89, height: 595.28) : CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
                let margin: CGFloat = 28
                let k = min((page.width - 2 * margin) / iw, (page.height - 2 * margin) / ih)
                let size = CGSize(width: iw * k, height: ih * k)
                target = CGRect(x: (page.width - size.width) / 2, y: (page.height - size.height) / 2, width: size.width, height: size.height)
            }
            var box = page
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: target)
            ctx.endPDFPage()
            control.progress(Double(n + 1) / Double(inputs.count))
        }
        ctx.closePDF()
        return data as Data
    }

    /// A JPEG-backed copy (Core Graphics then embeds the JPEG bytes as they are), unless the image has transparency.
    /// The source decides (ImageIO sets "HasAlpha" only on images with an alpha channel, PNG, HEIC, TIFF, GIF…):
    /// the decoded image cannot tell, an opaque HEIC or AVIF comes out premultiplied.
    private static func embeddable(_ image: CGImage, transparent: Bool, quality: Double) -> CGImage {
        if transparent { return image }
        guard let jpeg = ConverterImageEngine.encode(image, uti: ConverterImageFormat.jpeg.uti, quality: quality),
              let provider = CGDataProvider(data: jpeg as CFData),
              let decoded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return image
        }
        return decoded
    }

    static func pageCount(_ url: URL) -> Int? {
        CGPDFDocument(url as CFURL)?.numberOfPages
    }

    private static func pad(_ n: Int, _ digits: Int) -> String {
        let s = String(n)
        return String(repeating: "0", count: max(0, digits - s.count)) + s
    }
}
