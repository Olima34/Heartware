import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

/// The Convertisseur's window (`ConverterHub`): the files dropped in the middle of the wheel, or handed over by the
/// Finder's Services, the Dock icon, the launcher or another page; every operation they allow, grouped; the settings of
/// the one chosen and a preview of its result. What it starts runs in the wheel's toast (`WheelRunner`): progress,
/// Arrêter, then Afficher, Copier and Annuler.
@Observable
@MainActor
final class ConverterModel: AppModule {
    var files: [ConverterFile] = [] {
        didSet { previewer.schedule(self) }
    }
    /// The operation chosen in the window (nil: none yet).
    private(set) var action: WheelAction?
    /// « Créer un QR code » : no file needed.
    private(set) var makingQR = false
    /// The converter's operation behind `action`: its settings and its preview (nil: the action has none).
    var operation: ConverterOperation? {
        didSet { if operation != oldValue { previewer.fileIndex = 0 }; previewer.schedule(self) }
    }
    var options = ConverterOptions() {
        didSet { previewer.schedule(self) }
    }
    /// The real result of the chosen operation, computed on one file before anything is saved.
    let previewer = ConverterPreviewer()
    var message: String?
    var qrText = ""
    var ffmpegPath: String?
    /// Read once files are added (nil before).
    var ffmpegEncoders: Set<String>?
    /// Asked for before any file was there (the launcher's « Compresser une vidéo »): chosen once they arrive.
    private(set) var wanted: ConverterOperation?
    @ObservationIgnored let window = ConverterHub()
    @ObservationIgnored private var toolsChecked = false
    @ObservationIgnored private var readingEncoders = false
    @ObservationIgnored private var qrCache: (text: String, image: CGImage?) = ("", nil)

    // MARK: - Opening the window

    /// The files dropped in the middle of the wheel (or on an action whose settings are here), next to where they were.
    func open(_ dropped: [WheelFile], action chosen: WheelAction?, near point: NSPoint) {
        guard !dropped.isEmpty else { return }
        reset()
        add(dropped.map(\.url))
        if let chosen, actions.contains(chosen) { select(chosen) }
        window.show(self, near: point)
    }

    /// Shows these files (if any) in the window, set to `op` when given: the Finder's Services, the Dock icon, the
    /// launcher, Remplir et signer. Added to the files already there while the window is open.
    func present(_ urls: [URL] = [], focus op: ConverterOperation? = nil) {
        guard !DemoData.isEnabled else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        if !window.isOpen { reset() }
        wanted = op
        if op == .qrGenerate {
            makeQR()
        } else {
            makingQR = false
            if !urls.isEmpty { add(urls) }
            if let op, let a = WheelAction.forOperation(op), actions.contains(a) { select(a) }
        }
        window.show(self, near: nil)
    }

    /// Everything goes when the window closes: files, choice, preview scratch files.
    func closed() {
        reset()
    }

    private func reset() {
        previewer.cleanUp()
        files.removeAll()
        action = nil
        operation = nil
        makingQR = false
        wanted = nil
        message = nil
        if !options.mergePages.isEmpty { options.mergePages = [:] }
        options.mergeName = ""
    }

    /// The demo's files and choice, as if they had been dropped (`add` refuses anything in the demo).
    func showDemo(_ demoFiles: [ConverterFile], action chosen: WheelAction?, qr: Bool = false) {
        action = nil
        operation = nil
        makingQR = false
        wanted = nil
        message = nil
        files = demoFiles
        if qr {
            makeQR()
        } else if let chosen {
            select(chosen)
        }
        previewer.loadDemo(self)
    }

    // MARK: - Files

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !DemoData.isEnabled else {
            message = DemoData.refusal
            return
        }
        checkTools()
        readEncoders()
        var known = Set(files.map { $0.url.standardizedFileURL.path })
        var fresh: [ConverterFile] = []
        for url in urls.map(\.standardizedFileURL) where url.isFileURL && known.insert(url.path).inserted {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            fresh.append(ConverterFile(url: url, kind: ConverterKind.detect(name: url.lastPathComponent, isDirectory: FS.isDirectory(url.path))))
        }
        guard !fresh.isEmpty else { return }
        makingQR = false
        files += fresh
        message = nil
        filesChanged()
        inspect(fresh)
    }

    /// Size, dimensions or duration, and dates, read in the background.
    private func inspect(_ entries: [ConverterFile]) {
        let items = entries.map { (id: $0.id, url: $0.url, kind: $0.kind) }
        Task { [weak self] in
            for item in items {
                let info = await ConverterInspector.inspect(item.url, kind: item.kind)
                guard let self, let i = self.files.firstIndex(where: { $0.id == item.id }) else { continue }
                self.files[i].size = info.size
                self.files[i].detail = info.detail
                self.files[i].date = info.date
                self.files[i].pages = info.pages
                self.files[i].inspected = true
            }
        }
    }

    func remove(_ file: ConverterFile) {
        files.removeAll { $0.id == file.id }
        if options.mergePages[file.url.path] != nil { options.mergePages[file.url.path] = nil }
        filesChanged()
    }

    /// The choice follows the files: kept while it still suits them, else what suits them best.
    private func filesChanged() {
        let list = actions
        if let action, list.contains(action) {
            operation = action.hubOperation(family)
            return
        }
        if let wanted, let a = WheelAction.forOperation(wanted), list.contains(a) { return select(a) }
        let suggested = WheelAction.suggested(family, count: files.count)
        if let a = list.contains(suggested) ? suggested : list.first(where: { !$0.opensWindow }) {
            select(a)
        } else {
            action = nil
            operation = nil
        }
    }

    /// Renamed by the window (or back to their old names by « Annuler »): the list follows.
    func follow(_ pairs: [ConverterRenamePair]) {
        for pair in pairs {
            if let i = files.firstIndex(where: { $0.url.standardizedFileURL == pair.from.standardizedFileURL }) { files[i].url = pair.to }
        }
    }

    /// Moves a file up (-1) or down (+1) in the list (merge order).
    func move(_ file: ConverterFile, by offset: Int) {
        guard let i = files.firstIndex(where: { $0.id == file.id }) else { return }
        let j = i + offset
        guard files.indices.contains(j) else { return }
        files.swapAt(i, j)
    }

    /// Drag and drop in the merge order: the file goes to `index` among the files of `op`; the others keep their places.
    func move(_ id: UUID, to index: Int, among op: ConverterOperation) {
        var order = targets(for: op)
        guard let from = order.firstIndex(where: { $0.id == id }) else { return }
        let file = order.remove(at: from)
        order.insert(file, at: min(max(0, index), order.count))
        guard order.map(\.id) != targets(for: op).map(\.id) else { return }
        var next = order.makeIterator()
        files = files.map { op.accepts.contains($0.kind) ? (next.next() ?? $0) : $0 }
    }

    var kinds: [ConverterKind] { files.map(\.kind) }
    var family: WheelFamily { WheelFamily.of(kinds) }
    var wheelFiles: [WheelFile] { files.map { WheelFile(url: $0.url, kind: $0.kind) } }
    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    func targets(for op: ConverterOperation) -> [ConverterFile] {
        files.filter { op.accepts.contains($0.kind) }
    }

    // MARK: - Operations

    /// What this Mac can do beyond macOS itself (everything in the demo).
    var capabilities: WheelCapabilities {
        if DemoData.isEnabled { return WheelCapabilities(ffmpeg: true, webp: true) }
        return WheelCapabilities(ffmpeg: ffmpegPath != nil, webp: ffmpegEncoders.map { $0.contains("libwebp") })
    }

    /// Every operation these files allow, in the order of the wheel's actions (the formats « Changer de format » offers
    /// with its settings are left out).
    var actions: [WheelAction] {
        guard !files.isEmpty else { return [] }
        let fam = family
        return WheelMenu.available(wheelFiles, in: WheelAction.allCases, capabilities: capabilities).filter { !$0.coveredInHub(fam) }
    }

    /// The window's list: its sections, each with its operations.
    var sections: [(group: WheelActionGroup, actions: [WheelAction])] {
        let list = actions
        return WheelActionGroup.allCases.compactMap { g in
            // « Changer de format » first: it holds every format.
            let a = list.filter { $0.group == g }.sorted { $0 == .convert && $1 != .convert }
            return a.isEmpty ? nil : (g, a)
        }
    }

    /// Chooses an operation: its settings and its preview show. One that has its own window opens it instead.
    func select(_ a: WheelAction) {
        message = nil
        let op = a.hubOperation(family)
        if op == nil, a.opensWindow, !a.opensHub {
            guard !files.isEmpty else { return }
            AppContext.model?.wheel.run(a, files: wheelFiles, at: window.center ?? NSEvent.mouseLocation)
            return
        }
        makingQR = false
        action = a
        operation = op
        if op != nil { checkTools() }
    }

    /// « Créer un QR code », without any file.
    func makeQR() {
        makingQR = true
        action = nil
        operation = nil
        message = nil
    }

    /// The title of the operation chosen.
    var title: String {
        if makingQR { return "Créer un QR code" }
        return action?.title(count: files.count, family: family) ?? "Convertisseur"
    }

    /// The main button.
    var verb: String {
        if makingQR { return "Enregistrer en PNG…" }
        guard let action else { return "Convertir" }
        if let op = operation, action.runsWithOptions(family) { return op.actionTitle }
        return action.verb(family, count: files.count)
    }

    /// What the button will do, in a few words: "3 fichiers · → JPEG · qualité 82 %".
    var summary: String {
        if makingQR { return "PNG de 1 024 pixels" }
        guard let action, !files.isEmpty else { return "" }
        if let op = operation, action.runsWithOptions(family) {
            if op == .rename {
                let n = renamePreview.filter { !$0.unchanged }.count
                return n == 0 ? "Aucun nom ne change" : "\(Fmt.plural(n, "fichier change", "fichiers changent")) de nom"
            }
            return "\(Fmt.plural(targets(for: op).count, "fichier", "fichiers")) · \(Self.summary(op, options, qualityApplies: qualityApplies(op)))"
        }
        return Fmt.plural(files.count, "fichier", "fichiers")
    }

    var canStart: Bool {
        if makingQR { return qrImage != nil }
        guard let action, !files.isEmpty else { return false }
        guard let op = operation, action.runsWithOptions(family) else { return true }
        guard targets(for: op).count >= op.minimumCount else { return false }
        switch op {
        case .rename: return renamePreview.contains { !$0.unchanged } && renameDatesReady
        case .pdfMerge: return mergeProblem == nil
        case .pdfSplit, .pdfRotate, .pdfToImages:
            return targets(for: op).allSatisfy { file in
                guard let pages = file.pages else { return false }
                return ConverterPDFEngine.parsePages(options.pdfPages, count: pages)?.isEmpty == false
            }
        default: return true
        }
    }

    /// Starts the operation chosen, with its settings; the window stays open for another one.
    func start() {
        if makingQR { return saveQR() }
        guard let action, canStart else { return }
        guard !DemoData.isEnabled else {
            message = DemoData.refusal
            return
        }
        guard let wheel = AppContext.model?.wheel else { return }
        let fam = family
        guard let op = operation, action.runsWithOptions(fam) else {
            wheel.run(action, files: wheelFiles, at: window.center ?? NSEvent.mouseLocation, under: window.frame)
            return
        }
        var parts = targets(for: op).map { WheelFile(url: $0.url, kind: $0.kind) }
        var names: [String] = []
        if op == .rename {
            guard renameDatesReady else {
                message = "Je lis encore les dates des fichiers : un instant."
                return
            }
            let changing = renamePreview.filter { !$0.unchanged }
            guard !changing.isEmpty else {
                message = "Les noms ne changent pas : rien à renommer."
                return
            }
            parts = changing.map { p in WheelFile(url: p.url, kind: files.first { $0.url == p.url }?.kind ?? .other) }
            names = changing.map(\.newName)
        }
        message = nil
        wheel.run(action, operation: op, files: parts, options: options, names: names, ffmpeg: ffmpegPath, under: window.frame)
    }

    // MARK: - Merge

    /// The pages kept from a PDF of the merge ("" : all of them).
    func mergePages(_ file: ConverterFile) -> String {
        options.mergePages[file.url.path] ?? ""
    }

    func setMergePages(_ file: ConverterFile, _ spec: String) {
        options.mergePages[file.url.path] = spec.isEmpty ? nil : spec
    }

    /// The pages each document brings to the merge (nil while a PDF's page count is unknown or its list is not understood),
    /// blank pages for double-sided printing included.
    var mergePageCount: Int? {
        var total = 0
        let parts = targets(for: .pdfMerge)
        for (n, file) in parts.enumerated() {
            if file.kind == .image {
                total += 1
            } else {
                guard let count = file.pages, let pages = ConverterPDFEngine.parsePages(mergePages(file), count: count), !pages.isEmpty else { return nil }
                total += pages.count
            }
            if options.mergeDuplex, n < parts.count - 1, total % 2 == 1 { total += 1 }
        }
        return total
    }

    /// Why the merge cannot start yet: no PDF, or a list of pages not understood.
    var mergeProblem: String? {
        let parts = targets(for: .pdfMerge)
        guard parts.contains(where: { $0.kind == .pdf }) else { return "Il faut au moins un PDF." }
        for file in parts where file.kind == .pdf {
            guard let count = file.pages else { continue }
            let spec = mergePages(file)
            if ConverterPDFEngine.parsePages(spec, count: count)?.isEmpty != false {
                return "Pages de « \(file.name) » : « \(spec) » ne va pas (\(Fmt.plural(count, "page", "pages")))."
            }
        }
        return nil
    }

    // MARK: - Renaming and images

    var renamePreview: [ConverterRenamePreview] {
        ConverterRename.preview(targets(for: .rename), rule: options.rename)
    }

    /// False while {date} or {heure} wait for the files' own dates (read just after they were added).
    var renameDatesReady: Bool {
        !ConverterRename.needsDates(options.rename) || targets(for: .rename).allSatisfy(\.inspected)
    }

    /// The format chosen for an image operation (nil: "même format", each image keeps its own).
    func chosenImageFormat(_ op: ConverterOperation) -> ConverterImageFormat? {
        switch op {
        case .imageConvert: return options.imageFormat
        case .imageResize: return options.resizeFormat
        case .imageCompress: return options.compressFormat
        default: return nil
        }
    }

    /// The format each image of `op` is written in ("même format" keeps a PNG in PNG, without loss).
    func writtenFormats(_ op: ConverterOperation) -> [ConverterImageFormat] {
        let chosen = chosenImageFormat(op)
        return targets(for: op).map { chosen ?? ConverterImageEngine.sameFormat(for: $0.url) }
    }

    /// False when every image would be written without loss (a PNG kept in PNG): the quality changes nothing then.
    func qualityApplies(_ op: ConverterOperation) -> Bool {
        if let chosen = chosenImageFormat(op) { return chosen.lossy }
        let formats = writtenFormats(op)
        return formats.isEmpty || formats.contains(where: \.lossy)
    }

    // MARK: - Tools

    /// Looks for ffmpeg once, without starting it: opening the window runs nothing. Its encoders are read once files are
    /// added (a conversion is coming), or by the conversion itself (`ConverterMediaEngine.ffmpegEncoders`, kept for the
    /// session); ffmpeg then runs without the app's permissions (`Shell`).
    func checkTools() {
        guard !toolsChecked, !DemoData.isEnabled else { return }
        toolsChecked = true
        ffmpegPath = Shell.which("ffmpeg")
    }

    private func readEncoders() {
        guard let path = ffmpegPath, ffmpegEncoders == nil, !readingEncoders else { return }
        readingEncoders = true
        Task { [weak self] in
            let encoders = await Task.detached(priority: .utility) { ConverterMediaEngine.ffmpegEncoders(path) }.value
            self?.ffmpegEncoders = encoders
            self?.readingEncoders = false
        }
    }

    /// WebP needs ffmpeg built with libwebp; until its encoders are read, ffmpeg's presence decides
    /// (the conversion checks again and says so).
    var imageFormats: [ConverterImageFormat] {
        ConverterImageEngine.formats(webp: DemoData.isEnabled || (ffmpegEncoders.map { $0.contains("libwebp") } ?? (ffmpegPath != nil)))
    }
    var audioFormats: [ConverterAudioFormat] { ConverterAudioFormat.available(ffmpeg: DemoData.isEnabled || ffmpegPath != nil) }
    var containers: [ConverterVideoContainer] {
        ConverterVideoContainer.allCases.filter { !$0.viaFFmpeg || ffmpegPath != nil || DemoData.isEnabled }
    }

    // MARK: - QR codes

    var qrImage: CGImage? {
        let text = qrText
        if qrCache.text == text { return qrCache.image }
        let image = text.utf8.count <= ConverterVision.qrCapacity ? ConverterVision.qrImage(text) : nil
        qrCache = (text, image)
        return image
    }

    func copyQR(_ text: String? = nil) {
        guard let image = text.map({ ConverterVision.qrImage($0) }) ?? qrImage, let png = ConverterImageEngine.pngData(image) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        HUD.show("QR code copié", symbol: "qrcode")
    }

    func saveQR() {
        guard !DemoData.isEnabled, let image = qrImage, let png = ConverterImageEngine.pngData(image) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "QR code.png"
        panel.directoryURL = (AppContext.model?.wheel.settings.folder).map { URL(fileURLWithPath: $0) } ?? ConverterDestination.downloadsURL
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let saved = try FileOps.write(png, to: url)
            HUD.show("Enregistré : \(saved.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([saved])
        } catch {
            HUD.show(error.localizedDescription, symbol: "xmark.octagon.fill")
        }
    }

    // MARK: - Texts

    /// What the job will do, in a few words: "→ JPEG · qualité 82 %". `qualityApplies` false: every image is written
    /// without loss (a PNG kept in PNG), the quality is not mentioned.
    static func summary(_ op: ConverterOperation, _ o: ConverterOptions, qualityApplies: Bool = true) -> String {
        let quality = "qualité \(Int((o.imageQuality * 100).rounded())) %"
        switch op {
        case .imageConvert:
            let f = o.imageFormat
            return "→ \(f?.name ?? "même format")" + (f?.lossy ?? true ? " · \(quality)" : "") + (o.stripOnConvert ? " · sans GPS" : "")
        case .imageResize:
            return "→ \(Fmt.int(o.maxSide)) px max · \(o.resizeFormat?.name ?? "même format")"
        case .imageCompress:
            return "→ " + [qualityApplies ? quality : nil, o.compressFormat?.name ?? "même format",
                           o.compressMaxSide > 0 ? "\(Fmt.int(o.compressMaxSide)) px" : nil].compactMap { $0 }.joined(separator: " · ")
        case .imageStrip:
            return o.stripMode == .gps ? "→ sans localisation" : "→ sans métadonnées"
        case .imagesToPDF:
            return "→ PDF · \(o.pageSize.title.lowercased())"
        case .videoCompress:
            return "→ \(o.videoPreset.title) · \(o.compressContainer.name)"
        case .videoContainer:
            return "→ \(o.container.name)"
        case .videoAudio:
            return "→ AAC (.m4a)"
        case .videoGIF:
            return "→ GIF \(o.gifWidth) px · \(o.gifFPS) i/s" + (o.gifSeconds > 0 ? " · \(o.gifSeconds) s max" : "")
        case .audioConvert:
            return "→ \(o.audioFormat.name)" + (o.audioFormat.lossy ? " · \(o.audioBitrate) kb/s" : "")
        case .pdfMerge:
            return "→ un seul PDF" + (o.mergeBookmarks ? " · un signet par document" : "") + (o.mergeDuplex ? " · prêt pour le recto verso" : "")
        case .pdfSplit:
            let pages = o.pdfPages.trimmingCharacters(in: .whitespaces)
            return "→ pages \(pages.isEmpty ? "toutes" : pages) · \(o.splitMode.title.lowercased())"
        case .pdfRotate:
            return "→ \(o.rotation == 90 ? "90° à droite" : (o.rotation == 180 ? "180°" : "90° à gauche"))"
                + (o.pdfPages.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " · pages \(o.pdfPages)")
        case .pdfCompress:
            return "→ \(o.pdfCompression.title.lowercased())"
        case .pdfToImages:
            return "→ \(o.rasterFormat.name) · \(o.rasterDPI) ppp"
        case .documentConvert:
            return "→ \(o.docFormat.name)"
        case .archiveZip:
            return "→ ZIP · \(o.zipMode.title.lowercased())"
        case .archiveExtract:
            return "→ nouveau dossier"
        case .rename:
            return "Motif « \(o.rename.pattern) »"
        case .ocr:
            return "→ texte (français, anglais)"
        case .qrRead:
            return "→ contenu des codes"
        case .qrGenerate:
            return "→ PNG"
        }
    }

    // MARK: - AppModule

    /// The work under way, in the wheel's toast (the dashboard's tile).
    var activeJobs: [WheelTask] { AppContext.model?.wheel.runner.tasks.filter(\.isRunning) ?? [] }
    var isBusy: Bool { !activeJobs.isEmpty }

    /// The scratch files of the previews go when the app quits.
    func stop() {
        window.close()
        previewer.cleanUp()
    }

    func commands(app: AppModel) -> [AppCommand] {
        ConverterOperation.allCases.map { op in
            AppCommand(id: op.commandID, title: op.commandTitle, subtitle: op.explanation, keywords: op.keywords + ["convertir", "convertisseur"],
                       icon: .symbol(op.symbol, op.family.tint), group: .convert, assistantSafe: true, urlSafe: true, hint: "Ouvrir") { ctx in
                ctx.app.converter.present(focus: op)
                return .done
            }
        }
    }

    /// "qr bonjour" → the QR code of "bonjour" (⌘ copies the image straight away).
    func results(for query: String, app: AppModel) -> [AppCommand] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count > 3, q.lowercased().hasPrefix("qr ") else { return [] }
        let text = String(q.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.utf8.count <= ConverterVision.qrCapacity else { return [] }
        let shown = text.count > 40 ? String(text.prefix(40)) + "…" : text
        return [AppCommand(id: "conv_qr_result", title: "QR code : « \(shown) »", subtitle: "Ouvre le QR code · ⌘ pour copier l'image",
                           icon: .symbol("qrcode", ConverterFamily.vision.tint), group: .convert, hint: "Créer", boost: 1500) { ctx in
            if ctx.alternate {
                ctx.app.converter.copyQR(text)
                return .done
            }
            ctx.app.launcher.hide()
            ctx.app.converter.qrText = text
            ctx.app.converter.present(focus: .qrGenerate)
            return .done
        }]
    }

    func dump() -> [String] {
        checkTools()
        var lines: [String] = []
        lines.append("Fenêtre : \(window.isOpen ? "ouverte" : "fermée") · fichiers : \(files.count) · opération : \(action?.title ?? (makingQR ? "QR code" : "aucune"))")
        lines.append("Formats d'image écrivables : " + ConverterImageEngine.formats(webp: false).map(\.name).joined(separator: ", "))
        let presets = Set(AVAssetExportSession.allExportPresets())
        lines.append("Préréglages vidéo : " + ConverterVideoPreset.allCases.map { "\($0.short) \(presets.contains($0.rawValue) ? "✓" : "✗")" }.joined(separator: ", "))
        lines.append("ffmpeg : \(ffmpegPath ?? "absent (MP3, MKV, WebM et WebP indisponibles)")")
        if let path = ffmpegPath {
            let enc = ConverterMediaEngine.ffmpegEncoders(path)
            lines.append("Encodeurs ffmpeg utiles : " + ["libx264", "libmp3lame", "libwebp", "libvpx-vp9", "libopus"].map { "\($0) \(enc.contains($0) ? "✓" : "✗")" }.joined(separator: ", "))
        }
        for tool in [ConverterDocumentEngine.textutil, ConverterMediaEngine.afconvert, "/usr/bin/ditto", "/usr/bin/zip", "/usr/bin/tar"] {
            lines.append("\(tool) : \(Shell.exists(tool) ? "présent" : "ABSENT")")
        }
        lines.append("Filtre Quartz « Reduce File Size » : \(FileManager.default.fileExists(atPath: ConverterPDFEngine.reduceFilter) ? "présent" : "absent")")
        lines.append("Opérations : \(ConverterOperation.allCases.count) · commandes du lanceur : \(ConverterOperation.allCases.map(\.commandID).joined(separator: " "))")
        for family in WheelFamily.allCases {
            let file = WheelModel.sample(family)
            let fam = family
            let list = WheelMenu.available([file], in: WheelAction.allCases, capabilities: WheelCapabilities(ffmpeg: ffmpegPath != nil))
                .filter { !$0.coveredInHub(fam) }
            lines.append("Fenêtre pour « \(file.name) » : " + list.map(\.title).joined(separator: ", "))
        }
        for f in files.prefix(20) {
            lines.append("  \(f.kind.title)\t\(Fmt.bytes(f.size))\t\(f.name)\(f.detail.map { " · \($0)" } ?? "")")
        }
        return lines
    }
}

/// Reads what the file list shows, off the main actor.
enum ConverterInspector {
    struct Info: Sendable {
        var size: Int64
        var detail: String?
        var date: Date?
        var pages: Int?
    }

    static func inspect(_ url: URL, kind: ConverterKind) async -> Info {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        var info = Info(size: ConverterOutputs.size(url), detail: nil, date: values?.creationDate ?? values?.contentModificationDate)
        switch kind {
        case .image:
            let d = ConverterImageEngine.describe(url)
            info.detail = d.detail
            if let date = d.date { info.date = date }
        case .video, .audio:
            info.detail = await ConverterMediaEngine.describe(url, kind: kind)
        case .pdf:
            info.pages = ConverterPDFEngine.pageCount(url)
            info.detail = info.pages.map { Fmt.plural($0, "page", "pages") }
        case .folder:
            let n = (try? FileManager.default.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }.count) ?? 0
            info.detail = Fmt.plural(n, "élément", "éléments")
        default:
            break
        }
        return info
    }
}
