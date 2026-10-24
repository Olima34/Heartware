import Foundation
import PDFKit

enum FillSignError: LocalizedError {
    case unreadable(String)
    case locked
    case wrongPassword
    case empty
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "« \(name) » ne s'ouvre pas comme un PDF ou une image."
        case .locked: return "Ce PDF est protégé par un mot de passe."
        case .wrongPassword: return "Ce n'est pas le bon mot de passe."
        case .empty: return "Ce PDF n'a aucune page."
        case .unsupported(let name) where name.lowercased().hasSuffix(".pages"):
            return "Exporte d'abord « \(name) » en PDF depuis Pages (Fichier › Exporter vers › PDF)."
        case .unsupported(let name): return "« \(name) » n'est ni un PDF, ni une image, ni un document texte."
        case .failed(let why): return why
        }
    }
}

/// An open document: its bytes (the result is always written from a fresh copy of them), the size of each page as shown,
/// its form fields, and a copy whose fields are emptied to draw the pages under the editor (it draws the values itself).
final class FillSignDocument: @unchecked Sendable {
    let url: URL?
    let name: String
    let data: Data
    let password: String?
    let pageSizes: [CGSize]
    let fields: [FillSignField]
    let initialValues: [String: String]
    /// Made from a photo or a scan: the result is a new PDF anyway.
    let fromImage: Bool
    private let canvas: PDFDocument
    private let lock = NSLock()

    var pageCount: Int { pageSizes.count }
    var hasForm: Bool { fields.contains { !$0.readOnly } }

    init(url: URL?, name: String, data: Data, password: String?, fromImage: Bool) throws {
        let doc = try Self.open(data: data, password: password)
        self.url = url
        self.name = name
        self.data = data
        self.password = password
        self.fromImage = fromImage
        pageSizes = (0..<doc.pageCount).map { doc.page(at: $0).map(Self.displaySize) ?? CGSize(width: 595, height: 842) }
        let found = Self.fields(in: doc)
        fields = found.fields
        initialValues = found.values
        Self.empty(doc)
        canvas = doc
    }

    /// A PDF, an image made into a one-page PDF, or a Word, RTF, ODT, text or Markdown document laid out as a PDF first
    /// (in memory: the signed copy is the only file written, next to the original).
    static func load(_ url: URL, password: String? = nil) throws -> FillSignDocument {
        let name = url.deletingPathExtension().lastPathComponent
        let kind = ConverterKind.detect(name: url.lastPathComponent, isDirectory: false)
        switch kind {
        case .pdf:
            // Read whole (not mapped): the file may change or go while it is open here.
            guard let data = try? Data(contentsOf: url) else { throw FillSignError.unreadable(url.lastPathComponent) }
            return try FillSignDocument(url: url, name: name, data: data, password: password, fromImage: false)
        case .image:
            let data: Data
            do {
                data = try ConverterPDFEngine.imagesPDFData([url], pageSize: .image, quality: 0.92, control: ConverterControl { _ in })
            } catch {
                throw FillSignError.unreadable(url.lastPathComponent)
            }
            return try FillSignDocument(url: url, name: name, data: data, password: nil, fromImage: true)
        case .document, .markdown:
            let data: Data
            do {
                data = try ConverterDocumentEngine.pdfData(url, kind: kind, control: ConverterControl { _ in })
            } catch {
                throw FillSignError.failed("« \(url.lastPathComponent) » n'a pas pu devenir un PDF : \(error.localizedDescription)")
            }
            return try FillSignDocument(url: url, name: name, data: data, password: nil, fromImage: false)
        default:
            throw FillSignError.unsupported(url.lastPathComponent)
        }
    }

    /// `--fillsign-check <fichier>`: what the window would open, without writing anything.
    static func check(_ path: String) -> [String] {
        let url = URL(fileURLWithPath: FS.expand(path))
        let start = Date()
        do {
            let doc = try load(url)
            let fields = doc.fields.count
            return ["✓ « \(url.lastPathComponent) » s'ouvre en \(String(format: "%.2f", Date().timeIntervalSince(start))) s : "
                    + "\(doc.pageCount) page(s), \(fields) champ(s)\(doc.fromImage ? ", photo devenue PDF" : "")",
                    "  la copie irait dans \(FillSignExport.folder(for: doc).path)"]
        } catch {
            return ["✗ « \(url.lastPathComponent) » : \(error.localizedDescription)"]
        }
    }

    static func open(data: Data, password: String?) throws -> PDFDocument {
        guard let doc = PDFDocument(data: data) else { throw FillSignError.unreadable("Le document") }
        if doc.isLocked {
            guard let password else { throw FillSignError.locked }
            guard doc.unlock(withPassword: password) else { throw FillSignError.wrongPassword }
        }
        guard doc.pageCount > 0 else { throw FillSignError.empty }
        return doc
    }

    // MARK: Geometry

    /// A page as shown: its crop box, turned.
    static func displaySize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    /// A rectangle of the PDF's own space on the page as shown (turned, cropped), from its top left corner.
    static func displayRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        let shown = rect.applying(page.transform(for: .cropBox))
        return CGRect(x: shown.minX, y: displaySize(page).height - shown.maxY, width: shown.width, height: shown.height)
    }

    // MARK: Fields

    static func isWidget(_ a: PDFAnnotation) -> Bool {
        (a.type ?? "").replacingOccurrences(of: "/", with: "") == "Widget"
    }

    /// The fields the user can see, and the values they hold.
    static func fields(in doc: PDFDocument) -> (fields: [FillSignField], values: [String: String]) {
        var fields: [FillSignField] = []
        var values: [String: String] = [:]
        var ticked = Set<String>()
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            for (i, a) in page.annotations.enumerated() where isWidget(a) && a.shouldDisplay {
                let rect = displayRect(a.bounds, on: page)
                guard rect.width >= 4, rect.height >= 4 else { continue }
                let name = a.fieldName ?? ""
                let id = "p\(p)-a\(i)"
                let key = name.isEmpty ? id : name
                let kind: FillSignField.Kind
                switch a.widgetFieldType {
                case .text:
                    kind = .text(multiline: a.isMultiline, maxLength: a.maximumLength, fontSize: a.font?.pointSize ?? 0,
                                 alignment: a.alignment == .center ? 1 : (a.alignment == .right ? 2 : 0))
                    if values[key] == nil || !(a.widgetStringValue ?? "").isEmpty { values[key] = a.widgetStringValue ?? "" }
                case .button:
                    let on = a.buttonWidgetStateString
                    switch a.widgetControlType {
                    case .checkBoxControl: kind = .checkbox(on: on)
                    case .radioButtonControl: kind = .radio(on: on)
                    default: continue
                    }
                    if a.buttonWidgetState == .onState {
                        values[key] = on
                        ticked.insert(id)
                    } else if values[key] == nil {
                        values[key] = ""
                    }
                case .choice:
                    kind = .choice(options: a.choices ?? [])
                    if values[key] == nil || !(a.widgetStringValue ?? "").isEmpty { values[key] = a.widgetStringValue ?? "" }
                case .signature:
                    kind = .signature
                default:
                    continue
                }
                // The field's description for people (TU), else its name.
                let tip = a.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/TU")) as? String
                let label = (tip?.isEmpty == false ? tip : nil) ?? (name.isEmpty ? "Champ sans nom" : name)
                fields.append(FillSignField(id: id, page: p, annotationIndex: i, key: key, label: label, rect: rect, kind: kind,
                                            readOnly: a.isReadOnly))
            }
        }
        // Radio buttons whose choices all carry the same name (the forms PDFKit makes say "Yes" for each): each choice is
        // told apart by its place instead, so that picking one does not pick them all.
        for key in Set(fields.filter { if case .radio = $0.kind { return true } else { return false } }.map(\.key)) {
            let group = fields.indices.filter { fields[$0].key == key }
            guard Set(group.map { fields[$0].onState ?? "" }).count < group.count else { continue }
            values[key] = group.map { fields[$0].id }.first { ticked.contains($0) } ?? ""
            for i in group {
                let f = fields[i]
                fields[i] = FillSignField(id: f.id, page: f.page, annotationIndex: f.annotationIndex, key: f.key, label: f.label, rect: f.rect,
                                          kind: .radio(on: f.id), readOnly: f.readOnly)
            }
        }
        return (fields, values)
    }

    /// Checkboxes and radio buttons: PDFKit forgets their choices when it rewrites a form (each becomes "Yes", none ticked),
    /// so such a form is only saved as a final version.
    var hasButtons: Bool { fields.contains(where: \.isButton) }

    /// Writes `values` into the widgets of `doc` (a fresh copy of the same document: the fields are at the same places).
    /// `buttonsOff`: checkboxes and radio buttons are left unticked, the final version draws their mark itself (PDFKit draws
    /// a grey box instead of the tick of a form without appearances, and every choice of a group whose choices share a name).
    static func apply(_ values: [String: String], to doc: PDFDocument, fields: [FillSignField], buttonsOff: Bool = false) {
        for f in fields where !f.readOnly {
            guard let page = doc.page(at: f.page) else { continue }
            let annotations = page.annotations
            guard annotations.indices.contains(f.annotationIndex) else { continue }
            let a = annotations[f.annotationIndex]
            let value = values[f.key] ?? ""
            switch f.kind {
            case .text, .choice:
                if (a.widgetStringValue ?? "") != value { a.widgetStringValue = value }
            case .checkbox(let on), .radio(let on):
                a.buttonWidgetState = !buttonsOff && !on.isEmpty && value == on ? .onState : .offState
            case .signature:
                break
            }
        }
    }

    /// The mark of a ticked checkbox or a chosen radio button, as the editor shows it and the final version draws it.
    static func buttonMark(_ field: FillSignField) -> (mark: FillSignMark, rect: CGRect) {
        if case .radio = field.kind {
            return (.dot, field.rect.insetBy(dx: field.rect.width * 0.1, dy: field.rect.height * 0.1))
        }
        return (.check, field.rect)
    }

    /// The fields without their values: the editor draws the pages from this copy and its own values on top.
    private static func empty(_ doc: PDFDocument) {
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            for a in page.annotations where isWidget(a) && !a.isReadOnly {
                switch a.widgetFieldType {
                case .text, .choice:
                    if !(a.widgetStringValue ?? "").isEmpty { a.widgetStringValue = "" }
                case .button:
                    if a.widgetControlType != .pushButtonControl { a.buttonWidgetState = .offState }
                default:
                    break
                }
            }
        }
    }

    // MARK: Drawing

    /// One page as shown, `pixelWidth` pixels wide, on white. Safe from any thread (one page at a time).
    func image(page index: Int, pixelWidth: Int) -> CGImage? {
        guard pageSizes.indices.contains(index), pixelWidth > 0 else { return nil }
        let size = pageSizes[index]
        let scale = CGFloat(pixelWidth) / max(1, size.width)
        let w = pixelWidth, h = max(1, Int((size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        lock.lock()
        defer { lock.unlock() }
        guard let page = canvas.page(at: index) else { return nil }
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }
}
