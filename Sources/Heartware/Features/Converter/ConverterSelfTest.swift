import Foundation
import AVFoundation
import PDFKit
import AppKit

/// `--selftest`: pure checks (names, matrix, page ranges, rename patterns, presets, Markdown, QR round trip, Word layout). Writes nothing.
extension ConverterModel {
    func selfTest() -> [String] {
        var previewFailures: [String] = []
        if ConverterPreviewer.parseListing("a.txt\n__MACOSX/x\ndossier/\ndossier/b.txt\n.DS_Store\n") != ["a.txt", "dossier/", "dossier/b.txt"] {
            previewFailures.append("aperçu : liste d'une archive")
        }
        if ConverterPreviewer.sizeLine(from: 1_000_000, to: 430_000) != "\(Fmt.bytes(1_000_000)) → \(Fmt.bytes(430_000)) (−57 %)" {
            previewFailures.append("aperçu : ligne de taille (\(ConverterPreviewer.sizeLine(from: 1_000_000, to: 430_000)))")
        }
        if ConverterPreviewer.previews(.rename) || ConverterPreviewer.previews(.qrGenerate) || !ConverterPreviewer.previews(.pdfSplit) {
            previewFailures.append("aperçu : opérations couvertes")
        }
        if !ConverterPreviewer.processesEverything(.archiveZip) || !ConverterPreviewer.processesEverything(.pdfCompress)
            || ConverterPreviewer.processesEverything(.videoCompress) || ConverterPreviewer.heavyLimit != 200_000_000 {
            previewFailures.append("aperçu : opérations trop lourdes sans clic")
        }
        var failures: [String] = []
        func expect(_ condition: Bool, _ what: @autoclosure () -> String) {
            if !condition { failures.append(what()) }
        }

        // Kinds
        let kinds: [(String, Bool, ConverterKind)] = [
            ("IMG_1.HEIC", false, .image), ("a.jpeg", false, .image), ("b.webp", false, .image), ("c.mov", false, .video),
            ("d.MP4", false, .video), ("e.mkv", false, .video), ("f.m4a", false, .audio), ("g.flac", false, .audio),
            ("h.ogg", false, .audio), ("i.pdf", false, .pdf), ("j.md", false, .markdown), ("k.docx", false, .document),
            ("l.rtfd", true, .document), ("m.zip", false, .archive), ("n.tar.gz", false, .archive), ("Photos", true, .folder),
            ("o.xyz123", false, .other)
        ]
        for (name, dir, kind) in kinds {
            let got = ConverterKind.detect(name: name, isDirectory: dir)
            expect(got == kind, "Type de « \(name) » : \(got.rawValue) au lieu de \(kind.rawValue)")
        }

        // Operation matrix
        let images = ConverterOperation.available(for: [.image, .image])
        expect(images.contains(.imageConvert) && images.contains(.imagesToPDF) && images.contains(.ocr), "Opérations des images incomplètes")
        expect(!images.contains(.pdfMerge) && !images.contains(.videoCompress), "Opérations des images en trop")
        expect(!ConverterOperation.available(for: [.pdf]).contains(.pdfMerge), "Fusion proposée pour un seul PDF")
        expect(ConverterOperation.available(for: [.pdf, .pdf]).contains(.pdfMerge), "Fusion absente pour deux PDF")
        expect(ConverterOperation.available(for: [.pdf, .image]).contains(.pdfMerge), "Fusion absente pour un PDF et une image")
        let folder = ConverterOperation.available(for: [.folder])
        expect(Set(folder) == [.archiveZip, .rename], "Opérations d'un dossier : \(folder.map(\.rawValue))")
        expect(ConverterOperation.available(for: [.markdown]).contains(.documentConvert), "Markdown sans conversion")
        expect(!ConverterOperation.available(for: [.image]).contains(.qrGenerate), "La création de QR ne dépend pas des fichiers")
        expect(ConverterOperation.suggested(for: [.video, .image, .video]) == .videoCompress, "Suggestion vidéo")
        expect(ConverterOperation.suggested(for: [.pdf, .pdf]) == .pdfMerge, "Suggestion fusion")
        expect(ConverterOperation.suggested(for: []) == nil, "Suggestion sans fichier")
        for op in ConverterOperation.allCases {
            expect(!op.title.isEmpty && !op.explanation.isEmpty && !op.actionTitle.isEmpty, "Textes manquants : \(op.rawValue)")
            expect(op == .qrGenerate || !op.accepts.isEmpty, "\(op.rawValue) n'accepte aucun fichier")
            expect(!ConverterModel.summary(op, ConverterOptions()).isEmpty, "Résumé vide : \(op.rawValue)")
            expect(op.commandID.hasPrefix("conv_") && AppCommand.isValidID(op.commandID), "Identifiant invalide : \(op.commandID)")
        }
        expect(Set(ConverterOperation.allCases.map(\.commandID)).count == ConverterOperation.allCases.count, "Identifiants en double")

        // Output names (FileOps never overwrites; these folders do not exist)
        let photo = URL(fileURLWithPath: "/nonexistent-hw/Vacances/IMG_4102.HEIC")
        expect(FileOps.outputURL(for: photo, extension: "jpg").lastPathComponent == "IMG_4102.jpg", "Nom de sortie simple")
        expect(FileOps.outputURL(for: photo, extension: "jpg", suffix: "2048 px").lastPathComponent == "IMG_4102 2048 px.jpg", "Nom avec suffixe")
        expect(FileOps.outputURL(for: photo, extension: "pdf", folder: URL(fileURLWithPath: "/nonexistent-hw/Sortie")).path
               == "/nonexistent-hw/Sortie/IMG_4102.pdf", "Nom dans un dossier choisi")
        expect(ConverterArchiveEngine.baseName("photos.tar.gz") == "photos", "Nom de base d'un .tar.gz")
        expect(ConverterArchiveEngine.baseName("rapport.zip") == "rapport", "Nom de base d'un .zip")
        let parent = ConverterArchiveEngine.commonParent([URL(fileURLWithPath: "/a/b/c/x.txt"), URL(fileURLWithPath: "/a/b/d/y.txt")])
        expect(parent.path == "/a/b", "Dossier commun : \(parent.path)")

        // Page ranges
        expect(ConverterPDFEngine.parsePages("1-3, 5, 8-", count: 10) == [0, 1, 2, 4, 7, 8, 9], "Pages « 1-3, 5, 8- »")
        expect(ConverterPDFEngine.parsePages("", count: 3) == [0, 1, 2], "Pages vides = toutes")
        expect(ConverterPDFEngine.parsePages("3–1", count: 5) == nil, "Plage à l'envers acceptée")
        expect(ConverterPDFEngine.parsePages("0", count: 5) == nil, "Page 0 acceptée")
        expect(ConverterPDFEngine.parsePages("12", count: 5) == nil, "Page hors du PDF acceptée")
        expect(ConverterPDFEngine.parsePages("deux", count: 5) == nil, "Texte accepté comme page")
        expect(ConverterPDFEngine.parsePages("2 à 4; 2", count: 5) == [1, 2, 3], "Pages « 2 à 4; 2 »")
        expect(ConverterPDFEngine.describePages([0, 1, 2, 4, 7, 8]) == "1-3, 5, 8-9", "Description des pages")

        // Batch renaming
        var rule = ConverterRenameRule(pattern: "Vacances {n:3}", start: 1)
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 7, day: 14, hour: 9, minute: 5, second: 3).date
        func name(_ n: String, _ i: Int = 0, dir: Bool = false) -> String {
            ConverterRename.newName(name: n, isDirectory: dir, folderName: "Été", index: i, date: date, rule: rule)
        }
        expect(name("IMG_1.JPG", 4) == "Vacances 005.JPG", "Motif numéroté : \(name("IMG_1.JPG", 4))")
        rule.lowercaseExtension = true
        expect(name("IMG_1.JPG") == "Vacances 001.jpg", "Extension en minuscules")
        rule = ConverterRenameRule(pattern: "{date} {heure} {nom} ({dossier})")
        expect(name("photo.png") == "2026-07-14 09-05-03 photo (Été).png", "Date et heure : \(name("photo.png"))")
        rule = ConverterRenameRule(pattern: "{nom}", find: "img_", replace: "Plage ", caseMode: .unchanged)
        expect(name("IMG_42.heic") == "Plage 42.heic", "Rechercher et remplacer : \(name("IMG_42.heic"))")
        rule = ConverterRenameRule(pattern: "{nom}", caseMode: .upper)
        expect(name("été.txt") == "ÉTÉ.txt", "Majuscules")
        rule = ConverterRenameRule(pattern: "{nom}", caseMode: .capitalized)
        expect(name("MON FICHIER.txt") == "Mon fichier.txt", "Première lettre")
        rule = ConverterRenameRule(pattern: "a/b:c {inconnu}")
        expect(name("x.txt") == "a-b-c {inconnu}.txt", "Caractères interdits : \(name("x.txt"))")
        rule = ConverterRenameRule(pattern: "   ")
        expect(name("x.txt") == "Sans titre.txt", "Nom vide")
        rule = ConverterRenameRule(pattern: "{nom} v2")
        expect(name("Projet.final", dir: true) == "Projet.final v2", "Dossier avec un point")
        expect(ConverterRename.needsDates(ConverterRenameRule(pattern: "Plage {Date}")) && ConverterRename.needsDates(ConverterRenameRule(pattern: "{HEURE}"))
               && !ConverterRename.needsDates(ConverterRenameRule(pattern: "{nom} {n:3}")), "Motif avec date : attente des dates")
        let batch = ["a.jpg", "b.jpg"].map { ConverterFile(url: URL(fileURLWithPath: "/nonexistent-hw/\($0)"), kind: .image) }
        let preview = ConverterRename.preview(batch, rule: ConverterRenameRule(pattern: "photo"))
        expect(preview.count == 2 && !preview[0].conflict && preview[1].conflict, "Doublon de nom non signalé")

        // Video presets: all known to this macOS, and never the macOS 26 one.
        let presets = Set(AVAssetExportSession.allExportPresets())
        for p in ConverterVideoPreset.allCases {
            expect(presets.contains(p.rawValue), "Préréglage inconnu : \(p.rawValue)")
            expect(!p.rawValue.contains("4320"), "Préréglage réservé à macOS 26 : \(p.rawValue)")
        }

        // Formats
        let writable = ConverterImageEngine.formats(webp: false).map(\.uti)
        expect(writable.contains("public.jpeg") && writable.contains("public.png"), "ImageIO n'écrit ni JPEG ni PNG ?")
        expect(!writable.contains("org.webmproject.webp") || ConverterImageEngine.writable.contains("org.webmproject.webp"), "WebP sans ffmpeg")
        expect(ConverterImageFormat.matching(uti: "public.heif") == .heic, "HEIF → HEIC")
        let same = { (name: String) in ConverterImageEngine.sameFormat(for: URL(fileURLWithPath: "/nonexistent-hw/" + name)) }
        expect(same("a.PNG") == .png && !same("a.png").lossy && same("b.jpeg") == .jpeg && same("c.xyz123") == .jpeg, "« Même format » d'après le nom")

        // "Même format" on a PNG: lossless, the quality is neither shown nor announced.
        let pngs = ConverterModel()
        pngs.files = ["a.png", "b.png"].map { ConverterFile(url: URL(fileURLWithPath: "/nonexistent-hw/\($0)"), kind: .image) }
        pngs.options.compressFormat = nil
        expect(!pngs.qualityApplies(.imageCompress), "Qualité proposée pour des PNG gardés en PNG")
        expect(!ConverterModel.summary(.imageCompress, pngs.options, qualityApplies: false).contains("qualité"), "Résumé : qualité d'un PNG")
        pngs.files.append(ConverterFile(url: URL(fileURLWithPath: "/nonexistent-hw/c.jpg"), kind: .image))
        expect(pngs.qualityApplies(.imageCompress), "Qualité absente avec un JPEG dans la sélection")
        pngs.files.removeLast()
        pngs.options.compressFormat = .jpeg
        expect(pngs.qualityApplies(.imageCompress), "Qualité absente pour des PNG convertis en JPEG")
        pngs.options.resizeFormat = .png
        expect(!pngs.qualityApplies(.imageResize), "Qualité proposée pour un redimensionnement en PNG")

        // "MOV ↔ MP4" refuses a video already in the chosen format (the preview asks the same question).
        let mp4 = URL(fileURLWithPath: "/nonexistent-hw/film.mp4")
        expect((try? ConverterMediaEngine.checkChangesContainer(mp4, to: .mp4)) == nil, "MP4 → MP4 accepté")
        expect((try? ConverterMediaEngine.checkChangesContainer(URL(fileURLWithPath: "/nonexistent-hw/film.m4v"), to: .mp4)) == nil, "M4V → MP4 accepté")
        expect((try? ConverterMediaEngine.checkChangesContainer(mp4, to: .mov)) != nil, "MP4 → MOV refusé")
        expect(!ConverterAudioFormat.available(ffmpeg: false).contains(.mp3), "MP3 proposé sans ffmpeg")
        expect(ConverterAudioFormat.available(ffmpeg: true).contains(.mp3), "MP3 absent avec ffmpeg")
        let encoders = ConverterMediaEngine.ffmpegEncodersParse(" V....D libx264              libx264 H.264\n A....D libmp3lame   MP3\n ------\n")
        expect(encoders == ["libx264", "libmp3lame"], "Lecture des encodeurs ffmpeg : \(encoders)")
        expect(ConverterMediaEngine.clock(134) == "2:14" && ConverterMediaEngine.clock(3725) == "1:02:05", "Durées")

        // Markdown
        let blocks = ConverterMarkdown.parse("# Titre\n\nDu **gras**, de l'*italique* et `du code`.\n\n- un\n- deux\n\n1. premier\n\n> cité\n\n```\nlet x = 1\n```\n\n[lien](https://exemple.fr)")
        let html = ConverterMarkdown.body(blocks)
        for piece in ["<h1>Titre</h1>", "<strong>gras</strong>", "<em>italique</em>", "<code>du code</code>", "<ul>", "<li>un</li>",
                      "<ol>", "<blockquote>", "<pre><code>let x = 1</code></pre>", "<a href=\"https://exemple.fr\">lien</a>"] {
            expect(html.contains(piece), "Markdown → HTML sans \(piece)")
        }
        expect(ConverterMarkdown.escape("<a & \"b\">") == "&lt;a &amp; &quot;b&quot;&gt;", "Échappement HTML")
        expect(ConverterMarkdown.attributed(blocks).string.contains("•\tun"), "Puces du Markdown → PDF")

        // Launcher
        let app = AppModel(liveMonitor: false)
        expect(results(for: "qr bonjour", app: app).count == 1, "« qr bonjour » ne propose pas de QR code")
        expect(results(for: "qr", app: app).isEmpty && results(for: "quitter", app: app).isEmpty, "QR proposé à tort")
        expect(commands(app: app).count == ConverterOperation.allCases.count, "Commandes du lanceur")

        // QR round trip, in memory: drawn by Core Image, read back by Vision.
        if let qr = ConverterVision.qrImage("Heartware 🧹") {
            let read = (try? ConverterVision.barcodes(qr)) ?? []
            expect(read.contains("Heartware 🧹"), "QR code illisible après création : \(read)")
        } else {
            failures.append("QR code non créé")
        }
        expect(ConverterVision.qrImage("") == nil, "QR code d'un texte vide")
        failures += Self.mergeChecks()
        failures += Self.docxChecks()
        return failures + previewFailures
    }

    /// The merge, in memory: pages kept, the sources' own bookmarks under theirs, blank pages for double-sided printing.
    static func mergeChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ what: @autoclosure () -> String) {
            if !condition { failures.append("Fusion : " + what()) }
        }
        guard let a = samplePDF("A", pages: 3), let b = samplePDF("B", pages: 1), let c = samplePDF("C", pages: 2),
              let a0 = a.page(at: 0), let a1 = a.page(at: 1), let a2 = a.page(at: 2) else {
            return ["Fusion : PDF d'essai non créés"]
        }
        // A's own bookmarks: "Début" (page 1), "Chapitre 2" (page 2, left out) and under it "Section" (page 3, kept).
        let own = PDFOutline()
        a.outlineRoot = own
        for (label, page) in [("Début", a0), ("Chapitre 2", a1)] {
            let item = PDFOutline()
            item.label = label
            item.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 400))
            own.insertChild(item, at: own.numberOfChildren)
        }
        let section = PDFOutline()
        section.label = "Section"
        section.destination = PDFDestination(page: a2, at: CGPoint(x: 0, y: 400))
        own.child(at: 1)?.insertChild(section, at: 0)
        guard let photo = samplePDF("P", pages: 1) else { return ["Fusion : image d'essai non créée"] }
        let parts = [ConverterPDFEngine.MergePart(name: "A", source: .pdf(a, pages: "1, 3")),
                     ConverterPDFEngine.MergePart(name: "B", source: .pdf(b, pages: "")),
                     ConverterPDFEngine.MergePart(name: "C", source: .pdf(c, pages: "2-")),
                     ConverterPDFEngine.MergePart(name: "Photo", source: .image(photo))]
        let control = ConverterControl { _ in }
        guard let doc = try? ConverterPDFEngine.mergedDocument(parts, settings: .init(bookmarks: true, duplex: true, title: "Essai"),
                                                               control: control) else {
            return ["Fusion : échec sur des PDF valides"]
        }
        // A1 A3 · B1 · blank (B ended on a recto) · C2 · blank · the image
        let texts = (0..<doc.pageCount).map { doc.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        expect(texts == ["A1", "A3", "B1", "", "C2", "", "P1"], "pages \(texts) au lieu de A1 A3 B1 (blanche) C2 (blanche) P1")
        let root = doc.outlineRoot
        let labels = (0..<(root?.numberOfChildren ?? 0)).compactMap { root?.child(at: $0)?.label }
        expect(labels == ["A", "B", "C", "Photo"], "signets \(labels)")
        let inA = root?.child(at: 0)
        let ownLabels = (0..<(inA?.numberOfChildren ?? 0)).compactMap { inA?.child(at: $0)?.label }
        expect(ownLabels == ["Début", "Section"], "signets de A : \(ownLabels) au lieu de Début, Section")
        if let target = inA?.child(at: 1)?.destination?.page { expect(doc.index(for: target) == 1, "« Section » ne mène pas à sa page") }
        if let target = root?.child(at: 2)?.destination?.page { expect(doc.index(for: target) == 4, "le signet de C ne mène pas à sa page") }
        // Written and read back: the outline and the title stay.
        let back = doc.dataRepresentation().flatMap { PDFDocument(data: $0) }
        expect(back?.outlineRoot?.numberOfChildren == 4, "signets perdus à l'écriture")
        expect(back?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Essai", "titre perdu à l'écriture")
        let invalid = [ConverterPDFEngine.MergePart(name: "A", source: .pdf(a, pages: "9"))]
        expect((try? ConverterPDFEngine.mergedDocument(invalid, settings: .init(), control: control)) == nil, "page 9 d'un PDF de 3 acceptée")
        let first = URL(fileURLWithPath: "/tmp/Devis cuisine.pdf")
        for (typed, expected) in [("", "Devis cuisine fusionné"), ("  ", "Devis cuisine fusionné"), ("Dossier/2026.PDF", "Dossier-2026"),
                                  (".cache", "cache"), ("Dossier cuisine", "Dossier cuisine")] {
            let got = ConverterPDFEngine.mergeName(typed, first: first)
            expect(got == expected, "nom « \(typed) » → « \(got) » au lieu de « \(expected) »")
        }
        return failures
    }

    /// A small PDF whose pages say "A1", "A2"…
    static func samplePDF(_ label: String, pages: Int) -> PDFDocument? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for i in 1...pages {
            ctx.beginPDFPage(nil)
            let text = NSAttributedString(string: "\(label)\(i)", attributes: [.font: NSFont.systemFont(ofSize: 20)])
            ctx.textPosition = CGPoint(x: 40, y: 300)
            CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return PDFDocument(data: data as Data)
    }
}
