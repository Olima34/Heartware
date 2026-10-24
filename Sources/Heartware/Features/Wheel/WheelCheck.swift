import AppKit
import ImageIO

/// `--wheel-check [secondes]` : the wheel alone, without the rest of the app (no setting written), for a
/// while: it says what it sees (the gestures, the segment under the pointer, the drop) and runs the actions done at once
/// next to the original. The small windows are only named.
@MainActor
enum WheelCheck {
    static func run(seconds: Double) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let watcher = WheelWatcher()
        let overlay = WheelOverlay()
        let runner = WheelRunner()
        let capabilities = WheelCapabilities(ffmpeg: Shell.which("ffmpeg") != nil)
        watcher.start()
        watcher.onOpen = { point, urls, gesture in
            let files = urls.map { WheelFile(url: $0) }
            let menu = WheelMenu.make(files, chosen: nil, capabilities: capabilities)
            print("roue ouverte (\(gesture.rawValue)) en \(Int(point.x)),\(Int(point.y)) pour \(files.map(\.name).joined(separator: ", "))")
            print("  formats : \(menu.formats.map(\.label).joined(separator: " ")) · outils : \(menu.tools.map(\.label).joined(separator: " "))")
            let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
            overlay.leaveDistance = CGFloat(WheelSettings().leaveDistance) * WheelGeometry.pointsPerCentimetre(screen)
            overlay.open(files, menu: menu, at: point, clicking: false, hint: true)
        }
        var faded = false
        watcher.onMove = { point in
            overlay.track(point)
            let alpha = overlay.isOpen ? (NSApp.windows.first { $0 is WheelPanel }?.alphaValue ?? 1) : 1
            if alpha < 0.99 && !faded { print("  la roue s'estompe (pointeur hors de la roue)") }
            faded = alpha < 0.99
        }
        watcher.onRelease = {
            print("bouton relâché")
            overlay.released()
        }
        overlay.onLeft = {
            print("roue effacée : pointeur à plus de \(Fmt.dec(WheelSettings().leaveDistance)) cm de la roue")
            watcher.rearm()
        }
        overlay.onChoose = { action, files, point in
            guard let action else { return print("lâché au centre : la fenêtre du Convertisseur s'ouvrirait") }
            if let kind = action.editor { return print("lâché sur \(action.label) : la fenêtre « \(kind.rawValue) » s'ouvrirait") }
            if action.opensHub { return print("lâché sur \(action.label) : la fenêtre du Convertisseur s'ouvrirait, sur « \(action.title) »") }
            if action == .sign { return print("lâché sur \(action.label) : Remplir et signer s'ouvrirait") }
            print("lâché sur \(action.label) pour \(files.map(\.name).joined(separator: ", "))")
            let ffmpeg = Shell.which("ffmpeg")
            runner.run(action, files: files, at: point) { control, onStep in
                let place = WheelJobs.folder(for: files[0].url, destination: .beside)
                return try await WheelJobs.perform(action, files: files, context: .init(folder: place.folder, ffmpeg: ffmpeg),
                                                   control: control, onStep: onStep)
            }
        }
        runner.onDone = { task in
            print("créé : \(task.result.outputs.map(\.path).joined(separator: ", "))\(task.result.copied.map { " · texte copié (\($0.count) caractères)" } ?? "")")
        }
        var lastHover = "rien"
        var lastOpen = false
        let end = Date().addingTimeInterval(seconds)
        print("Glisse un fichier (pause, secousse ou ⇧) pendant \(Int(seconds)) s…")
        while Date() < end {
            if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
            let hover = overlay.state.action(at: overlay.state.hovered)?.label ?? (overlay.state.hovered == .hub ? "centre" : "rien")
            if overlay.isOpen && hover != lastHover { print("  sous le pointeur : \(hover)") }
            if lastOpen && !overlay.isOpen { print("roue fermée") }
            lastHover = hover
            lastOpen = overlay.isOpen
            for task in runner.tasks where task.isRunning == false && task.finished != nil {
                if case .failed(let why) = task.state { print("✗ \(task.action.label) : \(why)"); task.finished = nil }
            }
        }
        watcher.stop()
    }
}

/// `--wheel-engines <dossier>` : every action of the wheel on files made up in that folder (a photo with its position, a
/// three-page PDF, a short video and its sound through ffmpeg when it is there), and what each one wrote.
enum WheelEngineCheck {
    static func run(folder: String) async -> [String] {
        let dir = URL(fileURLWithPath: folder)
        var lines: [String] = []
        func note(_ label: String, _ result: Result<[URL], Error>) {
            switch result {
            case .success(let urls):
                let sizes = urls.map { "\($0.lastPathComponent) (\(Fmt.bytes(ConverterOutputs.size($0))))" }
                lines.append("✓ \(label) → \(sizes.joined(separator: ", "))")
            case .failure(let e):
                lines.append("✗ \(label) : \(e.localizedDescription)")
            }
        }
        func attempt(_ label: String, _ work: () async throws -> [URL]) async {
            do { note(label, .success(try await work())) } catch { note(label, .failure(error)) }
        }
        let control = ConverterControl { _ in }
        guard let photo = makePhoto(dir.appendingPathComponent("sommet.jpg")), let pdf = makePDF(dir.appendingPathComponent("contrat.pdf")),
              let pdf2 = makePDF(dir.appendingPathComponent("annexe.pdf")) else { return ["✗ fichiers d'essai impossibles à écrire"] }
        let image = WheelFile(url: photo, kind: .image)
        let ctx = WheelJobs.Context(folder: nil, ffmpeg: Shell.which("ffmpeg"))
        for action in [WheelAction.png, .heic, .pdf, .text, .rotate, .cutout, .copyText] {
            await attempt("Photo · \(action.title)") {
                let r = try await WheelJobs.perform(action, files: [image], context: ctx, control: control) { _ in }
                return r.outputs + (r.copied.map { _ in [] } ?? [])
            }
        }
        await attempt("Photo · Recadrer 16:9") { [try WheelImageEngine.crop(photo, rect: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.45), quarterTurns: 0, folder: nil)] }
        await attempt("Photo · Fond (dégradé)") {
            let p = try WheelImageEngine.load(photo)
            let img = WheelImageEngine.backdrop(p.image, hasAlpha: false, style: WheelBackdropStyle(fill: .gradient(2), ratio: .square), blurred: nil)!
            return [try WheelImageEngine.save(img, from: photo, picture: p, suffix: "avec fond", as: .png, keepMetadata: false, folder: nil)]
        }
        await attempt("Photo · Fond (flou)") {
            let p = try WheelImageEngine.load(photo)
            let img = WheelImageEngine.backdrop(p.image, hasAlpha: false, style: WheelBackdropStyle(fill: .blur, ratio: .wide),
                                                blurred: WheelImageEngine.blurredBackground(p.image))!
            return [try WheelImageEngine.save(img, from: photo, picture: p, suffix: "avec fond flou", as: .png, keepMetadata: false, folder: nil)]
        }
        await attempt("Photo · Annoter") {
            let p = try WheelImageEngine.load(photo)
            let img = WheelImageEngine.marked(p, marks: WheelDemo.marks(redacting: false), layers: nil)!
            let out = try WheelImageEngine.save(img, from: photo, picture: p, suffix: "annotée", as: .same, keepMetadata: true, dropGPS: true, folder: nil)
            if ConverterImageEngine.hasGPS(out) { throw ConverterError.failed("la position est restée") }
            return [out]
        }
        await attempt("Photo · Masquer (noir, flou, pixels)") {
            let p = try WheelImageEngine.load(photo)
            var marks = WheelDemo.marks(redacting: true)
            marks.append(WheelMark(kind: .redact, points: [CGPoint(x: 0.3, y: 0.55), CGPoint(x: 0.55, y: 0.8)], redaction: .blur))
            let img = WheelImageEngine.marked(p, marks: marks, layers: WheelImageEngine.redactionLayers(p.image))!
            let out = try WheelImageEngine.save(img, from: photo, picture: p, suffix: "masquée", as: .same, keepMetadata: false, dropGPS: true, folder: nil)
            if ConverterImageEngine.hasGPS(out) { throw ConverterError.failed("la position est restée") }
            return [out]
        }
        await attempt("Photo · Alléger") {
            [try ConverterImageEngine.convert(photo, format: .jpeg, maxSide: 0, quality: 0.6, strip: nil, suffix: "allégée", folder: nil, control: control)]
        }
        await attempt("Photo · Taille 800 px, puis Annuler") {
            let out = try ConverterImageEngine.convert(photo, format: .jpeg, maxSide: 800, quality: 0.85, strip: nil, suffix: "800 px", folder: nil, control: control)
            // « Annuler » : the copy goes to the Trash, even outside the home folder.
            guard Remover.trashOwnOutput(out), !FileManager.default.fileExists(atPath: out.path) else { throw ConverterError.failed("la copie n'est pas partie à la Corbeille") }
            return []
        }
        await attempt("Photo · Sans la position") {
            let out = try ConverterImageEngine.stripMetadata(photo, mode: .gps, folder: nil, control: control).url
            if ConverterImageEngine.hasGPS(out) { throw ConverterError.failed("la position est restée") }
            return [out]
        }
        await attempt("Photo · Retirer le GPS") {
            let out = try await WheelJobs.perform(.strip, files: [image], context: ctx, control: control) { _ in }.outputs
            if out.contains(where: ConverterImageEngine.hasGPS) { throw ConverterError.failed("la position est restée") }
            return out
        }
        await attempt("Photos · Changer de format (fenêtre : AVIF, sans métadonnées)") {
            var o = ConverterOptions()
            o.imageFormat = .avif
            o.stripOnConvert = true
            return try await WheelJobs.converter(.imageConvert, [image], options: o, context: ctx, control: control) { _ in }.outputs
        }
        if let qr = makeQR(dir.appendingPathComponent("affiche.png")) {
            let r = try? await WheelJobs.perform(.qrRead, files: [WheelFile(url: qr, kind: .image)], context: ctx, control: control) { _ in }
            lines.append(r?.codes == ["https://exemple.fr/concert"] ? "✓ Image · Lire un QR code → « \(r?.codes.first ?? "") »"
                                                                     : "✗ Image · Lire un QR code : \(r?.codes ?? [])")
        }
        await attempt("Renommer (fenêtre), puis Annuler") {
            let a = try FileOps.write(Data("a".utf8), to: dir.appendingPathComponent("note 1.txt"))
            let b = try FileOps.write(Data("b".utf8), to: dir.appendingPathComponent("note 2.txt"))
            let files = [WheelFile(url: a, kind: .document), WheelFile(url: b, kind: .document)]
            let r = try await WheelJobs.converter(.rename, files, options: ConverterOptions(), names: ["Réunion 1.txt", "Réunion 2.txt"],
                                                  context: ctx, control: control) { _ in }
            guard r.renamed.count == 2, r.outputs.map(\.lastPathComponent) == ["Réunion 1.txt", "Réunion 2.txt"] else {
                throw ConverterError.failed("renommés : \(r.outputs.map(\.lastPathComponent))")
            }
            // « Annuler » : the old names come back.
            _ = try ConverterRename.apply(r.renamed.map { (url: $0.to, newName: $0.from.lastPathComponent) }, control: control)
            guard FileManager.default.fileExists(atPath: a.path), FileManager.default.fileExists(atPath: b.path) else {
                throw ConverterError.failed("les anciens noms ne sont pas revenus")
            }
            return [a, b]
        }
        let markdown = try? FileOps.write(Data("# Compte rendu\n\nLa *réunion* a duré **une heure**.\n\n- un\n- deux\n".utf8),
                                          to: dir.appendingPathComponent("compte rendu.md"))
        if let markdown {
            let note = WheelFile(url: markdown, kind: .markdown)
            for action in [WheelAction.rtf, .odt, .pdf] {
                await attempt("Markdown · \(action.title)") { try await WheelJobs.perform(action, files: [note], context: ctx, control: control) { _ in }.outputs }
            }
        }
        let sensitive = WheelImageEngine.sensitiveText(try! WheelImageEngine.load(makeCard(dir.appendingPathComponent("carte.png"))!).image)
        lines.append(sensitive.count >= 2 ? "✓ Masquer · \(sensitive.count) zones sensibles trouvées sur la carte de visite" : "✗ Masquer · \(sensitive.count) zone(s) sensible(s) seulement")
        let doc = WheelFile(url: pdf, kind: .pdf)
        for action in [WheelAction.word, .text, .jpeg, .pdfCompress, .pdfRotate, .copyText] {
            await attempt("PDF · \(action.title)") {
                let r = try await WheelJobs.perform(action, files: [doc], context: ctx, control: control) { _ in }
                if let n = r.note, r.outputs.isEmpty { throw ConverterError.failed("rien d'écrit : \(n)") }
                return r.outputs
            }
        }
        await attempt("PDF · Pages (3, 1 pivotée)") { [try WheelDocEngine.pages(pdf, [.init(index: 2, turns: 0), .init(index: 0, turns: 1)], folder: nil, control: control)] }
        await attempt("PDF · Découper (fenêtre : pages 1 et 3, une par fichier)") {
            var o = ConverterOptions()
            o.pdfPages = "1, 3"
            o.splitMode = .eachPage
            return try await WheelJobs.converter(.pdfSplit, [doc], options: o, context: ctx, control: control) { _ in }.outputs
        }
        await attempt("PDF et photo · Fusionner (fenêtre)") {
            try await WheelJobs.converter(.pdfMerge, [doc, image], options: ConverterOptions(), context: ctx, control: control) { _ in }.outputs
        }
        await attempt("PDF · Fusionner") {
            try await WheelJobs.perform(.merge, files: [doc, WheelFile(url: pdf2, kind: .pdf)], context: ctx, control: control) { _ in }.outputs
        }
        await attempt("Images · Assembler en PDF") {
            try await WheelJobs.perform(.pdf, files: [image, image], context: ctx, control: control) { _ in }.outputs
        }
        guard let ffmpeg = Shell.which("ffmpeg") else { return lines + ["· vidéo et son : ffmpeg absent, pas essayés"] }
        let video = dir.appendingPathComponent("vacances.mov")
        let r = Shell.run(ffmpeg, ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=4:size=640x360:rate=25", "-f", "lavfi",
                                   "-i", "sine=frequency=440:duration=4", "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", video.path], timeout: 60)
        guard r.ok else { return lines + ["✗ vidéo d'essai : \(r.err)"] }
        let movie = WheelFile(url: video, kind: .video)
        for action in [WheelAction.mp4, .mkv, .webm, .gif, .sound, .mute] {
            await attempt("Vidéo · \(action.title)") { try await WheelJobs.perform(action, files: [movie], context: ctx, control: control) { _ in }.outputs }
        }
        await attempt("Vidéo · Couper 1 s → 3 s") { [try await WheelMediaEngine.trim(video, start: 1, end: 3, folder: nil, control: control)] }
        await attempt("Vidéo · Capturer à 2 s") { [try await WheelMediaEngine.frame(video, at: 2, folder: nil)] }
        await attempt("Vidéo · Alléger (720p)") { [try await ConverterMediaEngine.compress(video, preset: .h264_720, container: .mp4, folder: nil, control: control)] }
        let sound = dir.appendingPathComponent("vacances.m4a")
        if let s = try? await WheelJobs.perform(.sound, files: [movie], context: .init(folder: nil, ffmpeg: ffmpeg), control: control,
                                                onStep: { _ in }).outputs.first {
            try? FileManager.default.moveItem(at: s, to: sound)
        }
        let audio = WheelFile(url: sound, kind: .audio)
        for action in [WheelAction.wav, .aiff, .flac, .mp3] {
            await attempt("Son · \(action.title)") { try await WheelJobs.perform(action, files: [audio], context: ctx, control: control) { _ in }.outputs }
        }
        await attempt("Son · Couper") { [try await WheelMediaEngine.trim(sound, start: 0.5, end: 2, folder: nil, control: control)] }
        await attempt("Tout · ZIP") { try await WheelJobs.perform(.zip, files: [image, doc], context: ctx, control: control) { _ in }.outputs }
        return lines
    }

    /// The demo mountain as a JPEG with a GPS position.
    private static func makePhoto(_ url: URL) -> URL? {
        let image = DispatchQueue.main.sync { MainActor.assumeIsolated { WheelDemo.photo(width: 1600, height: 1000) } }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return nil }
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 45.83, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 6.86, kCGImagePropertyGPSLongitudeRef: "E"]
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    /// A poster with a QR code on it.
    private static func makeQR(_ url: URL) -> URL? {
        guard let code = ConverterVision.qrImage("https://exemple.fr/concert"), let png = ConverterImageEngine.pngData(code) else { return nil }
        return try? FileOps.write(png, to: url)
    }

    /// A business card with an e-mail address and a phone number.
    private static func makeCard(_ url: URL) -> URL? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 600).fill()
        let font = NSFont.systemFont(ofSize: 48)
        ("Camille Martin" as NSString).draw(at: NSPoint(x: 80, y: 420), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 60)])
        ("camille.martin@exemple.fr" as NSString).draw(at: NSPoint(x: 80, y: 280), withAttributes: [.font: font])
        ("06 12 34 56 78" as NSString).draw(at: NSPoint(x: 80, y: 170), withAttributes: [.font: font])
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    /// Three pages of text.
    private static func makePDF(_ url: URL) -> URL? {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        for n in 1...3 {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ("Page \(n) du contrat de location" as NSString).draw(at: NSPoint(x: 60, y: 760), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 22)])
            ("Le présent contrat est conclu entre les parties pour une durée d'un an." as NSString)
                .draw(at: NSPoint(x: 60, y: 720), withAttributes: [.font: NSFont.systemFont(ofSize: 13)])
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }
}
