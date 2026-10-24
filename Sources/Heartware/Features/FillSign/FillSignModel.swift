import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The signature pad: a new signature or initials, drawn, typed or taken from a picture.
struct FillSignPad: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case draw, type, image
        var id: String { rawValue }
        var title: String {
            switch self {
            case .draw: return "Dessiner"
            case .type: return "Taper"
            case .image: return "Importer"
            }
        }
    }

    /// Size of the drawing area, in points.
    static let size = CGSize(width: 520, height: 180)
    static let pen: CGFloat = 2.6

    var kind: FillSignSignature.Kind
    var mode: Mode = .draw
    var strokes: [[CGPoint]] = []
    var text = ""
    var font = FillSignDraw.scriptFonts.first?.name ?? "Helvetica"
    var image: (png: Data, size: CGSize)?
    var ink: FillSignInk = .black
    /// Opened from the page: the new signature is put where the user clicked (or in the signature field).
    var placeAt: (page: Int, point: CGPoint, field: CGRect?)?

    static func == (a: FillSignPad, b: FillSignPad) -> Bool {
        a.kind == b.kind && a.mode == b.mode && a.strokes == b.strokes && a.text == b.text && a.font == b.font
            && a.image?.png == b.image?.png && a.ink == b.ink
    }

    /// What the pad holds, as a signature; nil while it is empty.
    var signature: FillSignSignature? {
        switch mode {
        case .draw:
            guard let n = FillSignDraw.normalized(strokes, pen: Self.pen) else { return nil }
            return FillSignSignature(kind: kind, style: .drawn(strokes: n.strokes, width: Self.pen), size: n.size, ink: ink)
        case .type:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            return FillSignSignature(kind: kind, style: .typed(text: t, font: font), size: FillSignDraw.typedLayout(t, font: font).size, ink: ink)
        case .image:
            guard let image else { return nil }
            return FillSignSignature(kind: kind, style: .image(png: image.png), size: image.size, ink: ink)
        }
    }
}

/// Fill in a PDF form, write anywhere on a document, sign and initial it, then save a copy.
@Observable
@MainActor
final class FillSignModel: AppModule {
    var document: FillSignDocument?
    /// Field values, by field name.
    var values: [String: String] = [:]
    var items: [FillSignItem] = []
    var selection: UUID?
    /// The text being typed.
    var editing: UUID?
    var tool: FillSignTool = .select
    /// The signature or initials the next click puts down.
    var armed: FillSignSignature?
    /// Ink and size for what is added next.
    var ink: FillSignInk = .black
    var fontSize: CGFloat = 12
    /// 1 = the widest page fits the width of the editor.
    var zoom: CGFloat = 1
    var visiblePage = 0
    /// A page to bring into view (thumbnails, new document).
    var scrollTarget: Int?
    var pad: FillSignPad?
    var signatures: [FillSignSignature] = [] {
        didSet { if signatures != oldValue { store.value = signatures } }
    }
    /// The file being opened (the mascot reads it).
    var opening: String?
    /// A PDF with a password, waiting for it.
    var passwordFor: URL?
    var passwordWrong = false
    var message: String?
    var saving = false
    var saved: URL?
    /// Save a form that stays editable (only the fields' values, nothing added).
    var keepForm = false

    /// The « ? » next to the signatures, in the window.
    static let tip = HelpTip(
        id: "fillsign.signature",
        title: "Ce que vaut cette signature",
        text: "C'est une signature simple, comme une signature manuscrite scannée : elle suffit pour un devis, un bail, "
            + "un bon de commande ou une autorisation. Un acte qui exige une signature électronique qualifiée (notaire, "
            + "certains marchés publics) passe par un service certifié.")

    @ObservationIgnored private let store = JSONStore<[FillSignSignature]>("signatures", default: [])
    @ObservationIgnored private var undoStack: [Snapshot] = []
    @ObservationIgnored private var redoStack: [Snapshot] = []
    @ObservationIgnored private var lastToken: String?
    @ObservationIgnored private var lastClick: (time: Date, point: CGPoint, page: Int)?
    /// The file being read: a result for another file (or for a window closed meanwhile) is dropped.
    @ObservationIgnored private var loadToken: UUID?
    /// Pages already drawn at the editor's size, the most recent last (a page at full size takes megabytes: four are kept).
    @ObservationIgnored private var pageCache: [(key: String, image: CGImage)] = []
    @ObservationIgnored private var thumbCache: [Int: CGImage] = [:]
    var undoCount = 0
    var redoCount = 0

    private struct Snapshot {
        var items: [FillSignItem]
        var values: [String: String]
    }

    init() {
        signatures = store.value
    }

    // MARK: Document

    var hasChanges: Bool {
        guard let document else { return false }
        return !items.isEmpty || values.contains { (document.initialValues[$0.key] ?? "") != $0.value }
    }

    /// The fields to fill in: text, lists and radio groups (a checkbox left empty or a signature field is not "missing").
    private var answerFields: [FillSignField] {
        (document?.fields ?? []).filter { f in
            guard !f.readOnly else { return false }
            switch f.kind {
            case .text, .choice, .radio: return true
            case .checkbox, .signature: return false
            }
        }
    }

    var filledCount: Int {
        Set(answerFields.filter { !(values[$0.key] ?? "").isEmpty }.map(\.key)).count
    }

    var fieldCount: Int {
        Set(answerFields.map(\.key)).count
    }

    var signatureCount: Int { items.filter { $0.signature != nil }.count }

    /// The form can be saved still editable: it has text fields only (PDFKit would lose the boxes ticked), nothing added on top.
    var canKeepForm: Bool {
        guard let document else { return false }
        return document.hasForm && !document.fromImage && !document.hasButtons && items.isEmpty
    }

    /// What can be filled in or signed (a Word, Pages or Markdown file goes through the converter first).
    static let types: [UTType] = [.pdf, .image, .rtf, .plainText] + ["docx", "doc", "odt", "md"].compactMap { UTType(filenameExtension: $0) }

    /// A file to choose, then its window (the launcher's commands, « Choisir un autre document… »). Cancelled: nothing opens.
    func choose() {
        guard !DemoData.isEnabled else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.types
        panel.prompt = "Ouvrir"
        panel.message = "Le document à remplir ou à signer (PDF, photo ou scan)"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Fills and signs this document in its window, without the main window (the Convertisseur's « Signer », the launcher).
    func openWindow(_ url: URL) {
        open(url)
    }

    /// `url` is the document open right now (not one being read): it is not read again.
    func windowKeeps(_ url: URL) -> Bool {
        guard let current = document?.url, opening == nil else { return false }
        return current.standardizedFileURL.path == url.standardizedFileURL.path
    }

    /// Nothing to show: no document, nothing being opened, asked or said. The window does not stay open like that.
    var isIdle: Bool {
        document == nil && opening == nil && passwordFor == nil && message == nil
    }

    func showWindow() {
        guard let app = AppContext.model else { return }
        FillSignWindow.shared.show(app: app)
    }

    /// The window asks before closing on changes not saved: false keeps it open.
    func windowMayClose() -> Bool {
        guard document != nil, hasChanges, saved == nil else { return true }
        return CommandRunner.confirm("Fermer « \(document?.name ?? "") » ?", "Ce que tu y as ajouté n'est pas enregistré.", button: "Fermer sans enregistrer")
    }

    /// The window is gone, and its document with it.
    func windowDidClose() {
        loadToken = nil
        opening = nil
        passwordFor = nil
        passwordWrong = false
        message = nil
        pad = nil
        discard()
    }

    /// Opens `url` in the window (the one already open comes to the front instead). Returns false when the user keeps
    /// the document already open (changes not saved).
    @discardableResult
    func open(_ url: URL, password: String? = nil) -> Bool {
        guard !DemoData.isEnabled else {
            message = DemoData.refusal
            return false
        }
        if windowKeeps(url) {
            showWindow()
            return true
        }
        // A password typed for the file asked about: closing the current document was already agreed.
        if document != nil, hasChanges, url != document?.url, url != passwordFor,
           !CommandRunner.confirm("Fermer « \(document?.name ?? "") » ?", "Ce que tu y as ajouté n'est pas enregistré.", button: "Fermer sans enregistrer") {
            return false
        }
        opening = url.lastPathComponent
        message = nil
        let token = UUID()
        loadToken = token
        showWindow()
        Task { [weak self] in
            let result: Result<FillSignDocument, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try FillSignDocument.load(url, password: password)) } catch { return .failure(error) }
            }.value
            guard let self, self.loadToken == token else { return }
            self.loadToken = nil
            self.opening = nil
            switch result {
            case .success(let doc):
                self.passwordFor = nil
                self.passwordWrong = false
                self.show(doc)
            case .failure(FillSignError.locked):
                self.passwordFor = url
                self.passwordWrong = false
            case .failure(FillSignError.wrongPassword):
                self.passwordFor = url
                self.passwordWrong = true
            case .failure(let error):
                self.message = error.localizedDescription
            }
        }
        return true
    }

    /// Shows a loaded document, its fields holding their current values.
    func show(_ doc: FillSignDocument) {
        document = doc
        FillSignWindow.shared.retitle(doc.name)
        values = doc.initialValues
        items = []
        selection = nil
        editing = nil
        tool = .select
        armed = nil
        saved = nil
        keepForm = false
        zoom = 1
        visiblePage = 0
        scrollTarget = 0
        pageCache = []
        thumbCache = [:]
        undoStack = []
        redoStack = []
        lastToken = nil
        syncUndo()
    }

    /// Back to no document, without asking.
    func discard() {
        document = nil
        values = [:]
        items = []
        selection = nil
        editing = nil
        armed = nil
        saved = nil
        pageCache = []
        thumbCache = [:]
        undoStack = []
        redoStack = []
        syncUndo()
    }

    // MARK: Pages

    /// A page at `pixelWidth` (drawn in the background, kept for the next time).
    func pageImage(_ index: Int, pixelWidth: Int) async -> CGImage? {
        let key = "\(index)-\(pixelWidth)"
        if let hit = pageCache.first(where: { $0.key == key }) { return hit.image }
        guard let doc = document else { return nil }
        let image = await Task.detached(priority: .userInitiated) { doc.image(page: index, pixelWidth: pixelWidth) }.value
        guard let image, doc === document else { return nil }
        pageCache.removeAll { $0.key.hasPrefix("\(index)-") }
        pageCache.append((key, image))
        if pageCache.count > 4 { pageCache.removeFirst(pageCache.count - 4) }
        return image
    }

    /// What is already drawn for a page (any size), to show while the right size is drawn.
    func cachedImage(_ index: Int) -> CGImage? {
        pageCache.last { $0.key.hasPrefix("\(index)-") }?.image ?? thumbCache[index]
    }

    func thumbnail(_ index: Int) async -> CGImage? {
        if let hit = thumbCache[index] { return hit }
        guard let doc = document else { return nil }
        let image = await Task.detached(priority: .utility) { doc.image(page: index, pixelWidth: 180) }.value
        if let image, doc === document { thumbCache[index] = image }
        return image
    }

    func go(to page: Int) {
        visiblePage = page
        scrollTarget = page
    }

    // MARK: Undo

    /// Called before a change. Typing in the same text or field counts as one change (`token`).
    private func record(_ token: String? = nil) {
        if let token, token == lastToken { return }
        lastToken = token
        undoStack.append(Snapshot(items: items, values: values))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        syncUndo()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(Snapshot(items: items, values: values))
        restore(last)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(items: items, values: values))
        restore(next)
    }

    private func restore(_ s: Snapshot) {
        items = s.items
        values = s.values
        lastToken = nil
        editing = nil
        if let selection, !items.contains(where: { $0.id == selection }) { self.selection = nil }
        saved = nil
        syncUndo()
    }

    private func syncUndo() {
        undoCount = undoStack.count
        redoCount = redoStack.count
    }

    // MARK: Fields

    func value(_ field: FillSignField) -> String { values[field.key] ?? "" }

    func setValue(_ field: FillSignField, _ value: String) {
        guard !field.readOnly else { return }
        var v = value
        if case .text(_, let max, _, _) = field.kind, max > 0, v.count > max { v = String(v.prefix(max)) }
        guard values[field.key] != v else { return }
        record("field:\(field.key)")
        values[field.key] = v
        saved = nil
    }

    /// A checkbox ticks or unticks; a radio button picks its choice.
    func toggle(_ field: FillSignField) {
        guard !field.readOnly, let on = field.onState else { return }
        record()
        lastToken = nil
        if case .radio = field.kind {
            values[field.key] = on
        } else {
            values[field.key] = value(field) == on ? "" : on
        }
        selection = nil
        endEditing()
        saved = nil
    }

    func isOn(_ field: FillSignField) -> Bool {
        guard let on = field.onState, !on.isEmpty else { return false }
        return value(field) == on
    }

    func clearFields() {
        guard let document else { return }
        record()
        lastToken = nil
        for f in document.fields where !f.readOnly { values[f.key] = "" }
        saved = nil
    }

    // MARK: Items

    var selected: FillSignItem? { items.first { $0.id == selection } }

    /// A click on the page with the current tool. Returns true when it put something down.
    @discardableResult
    func tap(at point: CGPoint, page: Int) -> Bool {
        endEditing()
        switch tool {
        case .select:
            selection = nil
            return false
        case .text:
            addText("", at: point, page: page)
        case .check, .cross, .dot:
            addMark(tool.mark ?? .check, at: point, page: page)
        case .date:
            addText(FillSignText.today(), at: point, page: page, edit: false)
        case .signature, .initials:
            let kind: FillSignSignature.Kind = tool == .signature ? .signature : .initials
            if let sig = armed ?? signatures.last(where: { $0.kind == kind }) {
                place(sig, at: point, page: page, in: nil)
            } else {
                newSignature(kind, placeAt: (page, point, nil))
                return false
            }
        }
        if !tool.staysOn { tool = .select }
        return true
    }

    /// A click on the page itself (not on a field or an item). Two quick clicks at the same place with the selection
    /// tool start a text there; one click does what the tool says right away (no wait for a second click).
    func pageClick(at point: CGPoint, page: Int) {
        let now = Date()
        if tool == .select, armed == nil, let last = lastClick, last.page == page, now.timeIntervalSince(last.time) < NSEvent.doubleClickInterval,
           hypot(last.point.x - point.x, last.point.y - point.y) < 6 {
            lastClick = nil
            addText("", at: point, page: page)
            return
        }
        lastClick = (now, point, page)
        tap(at: point, page: page)
    }

    func addText(_ text: String, at point: CGPoint, page: Int, edit: Bool = true) {
        record()
        lastToken = nil
        let size = FillSignText.size(text, fontSize: fontSize)
        // The click is where the text's line sits: the box starts a little above it.
        let origin = CGPoint(x: point.x - 2, y: point.y - size.height / 2)
        let item = FillSignItem(page: page, rect: clamp(CGRect(origin: origin, size: size), page: page), content: .text(text),
                                fontSize: fontSize, ink: ink)
        items.append(item)
        selection = item.id
        editing = edit ? item.id : nil
        saved = nil
    }

    func addMark(_ mark: FillSignMark, at point: CGPoint, page: Int) {
        record()
        lastToken = nil
        let side = max(9, fontSize * 1.1)
        let item = FillSignItem(page: page, rect: clamp(CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), page: page),
                                content: .mark(mark), fontSize: fontSize, ink: ink)
        items.append(item)
        selection = item.id
        saved = nil
    }

    /// A signature on the page: centred on the click, or fitted into a signature field.
    func place(_ sig: FillSignSignature, at point: CGPoint, page: Int, in field: CGRect?) {
        record()
        lastToken = nil
        let natural = sig.size
        let aspect = natural.width / max(1, natural.height)
        var rect: CGRect
        if let field {
            let h = min(field.height * 0.9, field.width * 0.9 / aspect)
            let w = h * aspect
            rect = CGRect(x: field.midX - w / 2, y: field.midY - h / 2, width: w, height: h)
        } else {
            let w = sig.kind == .initials ? 54.0 : 150.0
            let h = w / aspect
            rect = CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
        }
        let item = FillSignItem(page: page, rect: clamp(rect, page: page), content: .signature(sig), fontSize: fontSize, ink: sig.ink)
        items.append(item)
        selection = item.id
        armed = nil
        saved = nil
    }

    func select(_ id: UUID?) {
        if editing != nil, editing != id { endEditing() }
        selection = id
        lastToken = nil
    }

    func edit(_ id: UUID) {
        guard items.first(where: { $0.id == id })?.text != nil else { return }
        selection = id
        editing = id
    }

    func setText(_ id: UUID, _ text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].text != text else { return }
        record("text:\(id)")
        items[i].content = .text(text)
        items[i].rect.size = FillSignText.size(text, fontSize: items[i].fontSize)
        saved = nil
    }

    /// Typing done: an empty text goes away.
    func endEditing() {
        if let id = editing, let item = items.first(where: { $0.id == id }), (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.removeAll { $0.id == id }
            if selection == id { selection = nil }
        }
        editing = nil
        lastToken = nil
    }

    /// Moves an item by `delta` points, staying on its page.
    func move(_ id: UUID, by delta: CGSize) {
        guard let i = items.firstIndex(where: { $0.id == id }), delta != .zero else { return }
        record()
        lastToken = nil
        items[i].rect = clamp(items[i].rect.offsetBy(dx: delta.width, dy: delta.height), page: items[i].page)
        saved = nil
    }

    /// The bottom right handle: a signature or a mark keeps its proportions, a text changes its size.
    func resize(_ id: UUID, width: CGFloat) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        record()
        lastToken = nil
        var item = items[i]
        if let text = item.text {
            let k = width / max(1, item.rect.width)
            item.fontSize = min(72, max(6, (item.fontSize * k * 2).rounded() / 2))
            item.rect.size = FillSignText.size(text, fontSize: item.fontSize)
        } else {
            let w = min(max(8, width), pageSize(item.page).width)
            item.rect.size = CGSize(width: w, height: w / item.aspect)
            if case .mark = item.content { item.fontSize = w / 1.1 }
        }
        item.rect = clamp(item.rect, page: item.page)
        items[i] = item
        saved = nil
    }

    func setFontSize(_ size: CGFloat) {
        let s = min(72, max(6, size))
        fontSize = s
        guard let id = selection, let i = items.firstIndex(where: { $0.id == id }), let text = items[i].text else { return }
        record()
        lastToken = nil
        items[i].fontSize = s
        items[i].rect.size = FillSignText.size(text, fontSize: s)
        items[i].rect = clamp(items[i].rect, page: items[i].page)
        saved = nil
    }

    func setInk(_ newInk: FillSignInk) {
        ink = newInk
        guard let id = selection, let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let sig = items[i].signature, !sig.takesInk { return }
        record()
        lastToken = nil
        items[i].ink = newInk
        if var sig = items[i].signature {
            sig.ink = newInk
            items[i].content = .signature(sig)
        }
        saved = nil
    }

    func deleteSelection() {
        guard let id = selection else { return }
        record()
        lastToken = nil
        items.removeAll { $0.id == id }
        selection = nil
        editing = nil
        saved = nil
    }

    func duplicateSelection() {
        guard let item = selected else { return }
        record()
        lastToken = nil
        var copy = item
        copy.id = UUID()
        copy.rect = clamp(item.rect.offsetBy(dx: 12, dy: 12), page: item.page)
        items.append(copy)
        selection = copy.id
        saved = nil
    }

    /// Initials (or anything else) at the same place on every other page.
    func copyToAllPages() {
        guard let item = selected, let document else { return }
        record()
        lastToken = nil
        for p in 0..<document.pageCount where p != item.page {
            var copy = item
            copy.id = UUID()
            copy.page = p
            copy.rect = clamp(item.rect, page: p)
            items.append(copy)
        }
        saved = nil
    }

    /// ⎋: stops typing, then leaves the tool, then clears the selection.
    func escape() {
        if editing != nil {
            endEditing()
        } else if tool != .select || armed != nil {
            tool = .select
            armed = nil
        } else {
            selection = nil
        }
    }

    /// The arrow keys move the selected item by one point.
    func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        guard let id = selection, editing == nil else { return }
        record("nudge:\(id)")
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].rect = clamp(items[i].rect.offsetBy(dx: dx, dy: dy), page: items[i].page)
        saved = nil
    }

    func pageSize(_ page: Int) -> CGSize {
        guard let sizes = document?.pageSizes, sizes.indices.contains(page) else { return CGSize(width: 595, height: 842) }
        return sizes[page]
    }

    /// Keeps a box on its page.
    func clamp(_ r: CGRect, page: Int) -> CGRect {
        let size = pageSize(page)
        var out = r
        out.size.width = min(out.width, size.width)
        out.size.height = min(out.height, size.height)
        out.origin.x = min(max(0, out.minX), size.width - out.width)
        out.origin.y = min(max(0, out.minY), size.height - out.height)
        return out
    }

    func choose(_ newTool: FillSignTool) {
        endEditing()
        tool = newTool
        armed = nil
        if newTool != .select { selection = nil }
        if (newTool == .signature || newTool == .initials), !signatures.contains(where: { $0.kind == (newTool == .signature ? .signature : .initials) }) {
            newSignature(newTool == .signature ? .signature : .initials)
        }
    }

    // MARK: Signatures

    func newSignature(_ kind: FillSignSignature.Kind, placeAt: (page: Int, point: CGPoint, field: CGRect?)? = nil) {
        var p = FillSignPad(kind: kind)
        p.ink = ink
        p.placeAt = placeAt
        if kind == .initials, let name = signatures.compactMap({ s -> String? in
            if case .typed(let t, _) = s.style { return t } else { return nil }
        }).first {
            p.text = Self.initials(of: name)
        }
        pad = p
    }

    /// "Camille Martin" → "CM".
    static func initials(of name: String) -> String {
        name.split(whereSeparator: { $0 == " " || $0 == "-" }).compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    /// The pad's signature joins the saved ones (and goes on the page when the pad was opened from there).
    func savePad() {
        guard let p = pad, let sig = p.signature else { return }
        signatures.append(sig)
        pad = nil
        if let at = p.placeAt, document != nil {
            place(sig, at: at.point, page: at.page, in: at.field)
            tool = .select
        } else if document != nil {
            armed = sig
            tool = sig.kind == .signature ? .signature : .initials
        }
    }

    func importPadImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Importer"
        panel.message = "Une photo ou un scan de ta signature, sur papier blanc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let cleaned = FillSignImageImport.signature(from: url) {
            pad?.image = cleaned
        } else {
            HUD.show("Aucune signature trouvée sur cette image", symbol: "exclamationmark.triangle.fill")
        }
    }

    func deleteSignature(_ sig: FillSignSignature) {
        guard CommandRunner.confirm("Supprimer \(sig.kind == .signature ? "cette signature" : "ce paraphe") ?",
                                    "Les documents déjà enregistrés la gardent ; elle ne sera simplement plus proposée.", button: "Supprimer") else { return }
        signatures.removeAll { $0.id == sig.id }
        if armed?.id == sig.id { armed = nil }
    }

    /// The next click on the page puts this signature down.
    func arm(_ sig: FillSignSignature) {
        endEditing()
        armed = sig
        tool = sig.kind == .signature ? .signature : .initials
        selection = nil
    }

    /// A signature field: the last signature fills it, or the pad opens.
    func sign(_ field: FillSignField) {
        if let sig = armed ?? signatures.last(where: { $0.kind == .signature }) {
            place(sig, at: CGPoint(x: field.rect.midX, y: field.rect.midY), page: field.page, in: field.rect)
            tool = .select
        } else {
            newSignature(.signature, placeAt: (field.page, CGPoint(x: field.rect.midX, y: field.rect.midY), field.rect))
        }
    }

    // MARK: Saving

    func save() {
        guard let document, !saving else { return }
        guard !DemoData.isEnabled else {
            message = DemoData.refusal
            return
        }
        endEditing()
        saving = true
        let values = values, items = items
        let form = keepForm && canKeepForm
        let name = FillSignExport.outputName(document.name, signed: signatureCount > 0)
        let target = FillSignExport.folder(for: document).appendingPathComponent(name).appendingPathExtension("pdf")
        Task { [weak self] in
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let data = form ? try FillSignExport.filledForm(document, values: values)
                                    : try FillSignExport.flattened(document, values: values, items: items)
                    return .success(try FileOps.write(data, to: target))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            self.saving = false
            switch result {
            case .success(let url):
                self.saved = url
                HUD.show("Enregistré : \(url.lastPathComponent)", symbol: "checkmark.seal.fill")
            case .failure(let error):
                self.message = "L'enregistrement a échoué : \(error.localizedDescription)"
            }
        }
    }

    func revealSaved() {
        if let saved { Finder.reveal(saved.path) }
    }

    func openSaved() {
        if let saved { NSWorkspace.shared.open(saved) }
    }

    /// A new message in Mail with the PDF attached (nothing is sent: the user writes and sends it).
    func mailSaved() {
        guard let saved else { return }
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [saved]) {
            service.perform(withItems: [saved])
        } else {
            HUD.show("Aucune app de messagerie n'est configurée", symbol: "envelope.badge")
        }
    }

    // MARK: AppModule

    func stop() {
        store.flush()
    }

    func commands(app: AppModel) -> [AppCommand] {
        [
            AppCommand(id: "fillsign_open", title: "Remplir et signer un PDF", subtitle: "Formulaires, texte, signature et paraphe",
                       keywords: ["signer", "signature", "remplir", "formulaire", "pdf", "parapher", "paraphe", "contrat", "cerfa"],
                       icon: .symbol("signature", FillSignStyle.tint), group: .tools, assistantSafe: true, urlSafe: true, hint: "Choisir") { ctx in
                // The file first, then its window: nothing opens empty.
                Task { @MainActor in ctx.app.fillSign.choose() }
                return .done
            },
            AppCommand(id: "fillsign_choose", title: "Signer un document…", subtitle: "Choisis un PDF ou la photo d'un document",
                       keywords: ["signer", "signature", "remplir", "formulaire", "pdf", "document"],
                       icon: .symbol("doc.badge.plus", FillSignStyle.tint), group: .tools, assistantSafe: true, hint: "Choisir") { ctx in
                Task { @MainActor in ctx.app.fillSign.choose() }
                return .done
            }
        ]
    }

    func dump() -> [String] {
        var lines = ["Signatures gardées : \(signatures.filter { $0.kind == .signature }.count) · paraphes : \(signatures.filter { $0.kind == .initials }.count)",
                     "Polices manuscrites : " + FillSignDraw.scriptFonts.map(\.title).joined(separator: ", ")]
        if let document {
            lines.append("Document : \(document.name) · \(Fmt.plural(document.pageCount, "page", "pages")) · \(Fmt.plural(fieldCount, "champ", "champs"))")
            for f in document.fields.prefix(30) {
                lines.append("  p\(f.page + 1) \(f.key) [\(f.kind)] = « \(values[f.key] ?? "") »")
            }
            lines.append("Ajouts : \(items.count)")
        }
        return lines
    }
}
