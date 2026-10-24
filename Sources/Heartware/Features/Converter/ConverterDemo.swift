import Foundation

/// Fictional files and results for `--demo` (README screenshots). Nothing here exists on any Mac.
extension ConverterModel {
    func loadDemo() {
        ConverterDemo.fill(self, scene: .image)
    }

    /// `--snapshot --demo --page wheel --tab <scene>`: the Convertisseur's window for `image` (default), `pdf` (a merge),
    /// `video`, `audio`, `document`, `archive`, `renommer`, `texte`, `qr`, `detourer` or `vide`; `attente` while its
    /// preview is being made.
    func applySnapshotTab(_ tab: String) {
        guard DemoData.isEnabled else { return }
        if tab == "attente" {
            ConverterDemo.fill(self, scene: .video)
            previewer.state = .working
            return
        }
        guard let scene = ConverterDemo.Scene(tab: tab) else { return }
        ConverterDemo.fill(self, scene: scene)
    }
}

@MainActor
enum ConverterDemo {
    enum Scene: String {
        case image, pdf, video, audio, document, archive, rename, ocr, qr, cutout, empty

        init?(tab: String) {
            switch tab {
            case "image", "images": self = .image
            case "pdf", "fusion": self = .pdf
            case "video", "videos": self = .video
            case "audio": self = .audio
            case "document", "documents": self = .document
            case "archive": self = .archive
            case "rename", "renommer": self = .rename
            case "ocr", "texte": self = .ocr
            case "qr": self = .qr
            case "cutout", "detourer": self = .cutout
            case "empty", "vide": self = .empty
            default: return nil
            }
        }
    }

    private static let mb: Int64 = 1_000_000
    private static let pictures = DemoData.home + "/Pictures/Week-end à Étretat"
    private static let movies = DemoData.home + "/Movies"
    private static let documents = DemoData.home + "/Documents"
    private static let now = Date()

    private static func file(_ path: String, _ kind: ConverterKind, _ size: Double, _ detail: String?, pages: Int? = nil,
                             daysAgo: Double = 3) -> ConverterFile {
        ConverterFile(url: URL(fileURLWithPath: path), kind: kind, size: Int64(size * Double(mb)), date: now.addingTimeInterval(-daysAgo * 86400),
                      detail: detail, pages: pages, inspected: true)
    }

    static let ticket = """
        BOULANGERIE DU PORT
        12, quai des Galets · 76790 Étretat
        Mardi 14 octobre 2026 · 08:42

        2 croissants au beurre          2,60 €
        1 baguette tradition            1,30 €
        1 tarte normande (6 parts)     16,50 €

        TOTAL TTC                      20,40 €
        Carte bancaire sans contact
        Merci et à bientôt !
        """

    static func fill(_ model: ConverterModel, scene: Scene) {
        model.options = ConverterOptions()
        model.qrText = ""
        switch scene {
        case .image:
            model.options.imageFormat = .jpeg
            model.options.imageQuality = 0.82
            model.options.stripOnConvert = true
            model.showDemo([
                file(pictures + "/IMG_4102.HEIC", .image, 3.42, "4 032 × 3 024"),
                file(pictures + "/IMG_4107.HEIC", .image, 2.87, "4 032 × 3 024"),
                file(pictures + "/IMG_4113.HEIC", .image, 3.18, "3 024 × 4 032"),
                file(pictures + "/IMG_4118.HEIC", .image, 2.64, "4 032 × 3 024")
            ], action: .convert)
        case .pdf:
            model.options.mergePages = [documents + "/Maison/Conditions générales.pdf": "1-3, 12"]
            model.options.mergeName = "Dossier cuisine"
            model.options.pageSize = .a4
            model.showDemo([
                file(documents + "/Maison/Devis cuisine.pdf", .pdf, 1.9, "4 pages", pages: 4),
                file(documents + "/Maison/Plan rez-de-chaussée.pdf", .pdf, 3.4, "2 pages", pages: 2),
                file(documents + "/Maison/Conditions générales.pdf", .pdf, 0.8, "12 pages", pages: 12),
                file(pictures + "/Photo de la cuisine actuelle.jpg", .image, 2.6, "4 032 × 3 024")
            ], action: .merge)
        case .video:
            model.options.videoPreset = .hevc1080
            model.showDemo([
                file(movies + "/Plongée à la Manneporte.mov", .video, 1_840, "4:38 · 3 840 × 2 160"),
                file(movies + "/Pique-nique sur la plage.mov", .video, 655, "1:52 · 1 920 × 1 080")
            ], action: .videoCompress)
        case .audio:
            model.options.audioFormat = .mp3
            model.options.audioBitrate = 256
            model.showDemo([file(DemoData.home + "/Music/Mémo de la répétition.m4a", .audio, 18.4, "12:40 · AAC")], action: .convert)
        case .document:
            model.options.docFormat = .pdf
            model.showDemo([
                file(documents + "/Notes de réunion.md", .markdown, 0.012, nil),
                file(documents + "/Lettre de motivation.docx", .document, 0.046, nil),
                file(documents + "/Recette de la tarte Tatin.rtf", .document, 0.008, nil)
            ], action: .convert)
        case .archive:
            model.showDemo([file(DemoData.home + "/Downloads/Photos du mariage.zip", .archive, 412, nil)], action: .extract)
        case .rename:
            let names = ["IMG_5501.JPG", "IMG_5502.JPG", "IMG_5503.JPG", "IMG_5507.JPG", "IMG_5510.JPG", "IMG_5512.JPG", "IMG_5515.JPG", "IMG_5518.JPG"]
            // One afternoon, a few minutes apart.
            let day = Calendar.current.startOfDay(for: now.addingTimeInterval(-160 * 86400)).addingTimeInterval(14 * 3600)
            model.options.rename = ConverterRenameRule(pattern: "Étretat {date} {n:3}", start: 1, lowercaseExtension: true)
            model.showDemo(names.enumerated().map { i, n in
                var f = file(pictures + "/" + n, .image, 2.4 + Double(i % 3) * 0.3, "4 032 × 3 024")
                f.date = day.addingTimeInterval(Double(i) * 420)
                return f
            }, action: .rename)
        case .ocr:
            model.showDemo([file(DemoData.home + "/Desktop/Ticket boulangerie.jpg", .image, 1.6, "3 024 × 4 032")], action: .copyText)
        case .qr:
            model.qrText = "https://github.com/Olima34/Heartware"
            model.showDemo([], action: nil, qr: true)
        case .cutout:
            model.showDemo([file(DemoData.home + "/Desktop/Sommet.jpg", .image, 4.1, "4 032 × 2 688")], action: .cutout)
        case .empty:
            model.showDemo([], action: nil)
        }
    }
}
