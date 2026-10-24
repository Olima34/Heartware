import SwiftUI
import UniformTypeIdentifiers

// MARK: - Kinds of files

/// What a dropped file is, as far as the converter is concerned.
enum ConverterKind: String, CaseIterable, Identifiable, Sendable {
    case image, video, audio, pdf, document, markdown, archive, folder, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return "Image"
        case .video: return "Vidéo"
        case .audio: return "Audio"
        case .pdf: return "PDF"
        case .document: return "Document"
        case .markdown: return "Markdown"
        case .archive: return "Archive"
        case .folder: return "Dossier"
        case .other: return "Autre"
        }
    }

    var singular: String {
        switch self {
        case .image: return "image"
        case .video: return "vidéo"
        case .audio: return "fichier audio"
        case .pdf: return "PDF"
        case .document: return "document"
        case .markdown: return "fichier Markdown"
        case .archive: return "archive"
        case .folder: return "dossier"
        case .other: return "autre fichier"
        }
    }

    var plural: String {
        switch self {
        case .image: return "images"
        case .video: return "vidéos"
        case .audio: return "fichiers audio"
        case .pdf: return "PDF"
        case .document: return "documents"
        case .markdown: return "fichiers Markdown"
        case .archive: return "archives"
        case .folder: return "dossiers"
        case .other: return "autres fichiers"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .markdown: return "number"
        case .archive: return "doc.zipper"
        case .folder: return "folder"
        case .other: return "doc"
        }
    }

    var tint: Color {
        switch self {
        case .image: return Theme.palette[5]
        case .video: return Theme.palette[4]
        case .audio: return Theme.palette[3]
        case .pdf: return Theme.bad
        case .document, .markdown: return Theme.accent
        case .archive: return Theme.palette[7]
        case .folder: return Theme.palette[1]
        case .other: return Theme.text3
        }
    }

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    static let documentExtensions: Set<String> = ["txt", "text", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt", "wordml", "webarchive"]
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar", "cpio", "xar"]
    /// Videos AVFoundation cannot open: only offered with ffmpeg.
    static let ffmpegVideoExtensions: Set<String> = ["mkv", "webm", "avi", "wmv", "flv", "ogv", "mpg", "mpeg", "ts", "m2ts", "mts", "vob"]
    /// Audio Core Audio cannot read: only offered with ffmpeg.
    static let ffmpegAudioExtensions: Set<String> = ["ogg", "oga", "opus", "wma", "ape", "mka", "wv"]

    /// Detection from the name only (fast, no disk access besides what the caller already knows).
    static func detect(name: String, isDirectory: Bool) -> ConverterKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if isDirectory && ext != "rtfd" { return .folder }
        if markdownExtensions.contains(ext) { return .markdown }
        if ext == "pdf" { return .pdf }
        if documentExtensions.contains(ext) { return .document }
        if archiveExtensions.contains(ext) { return .archive }
        if ffmpegVideoExtensions.contains(ext) { return .video }
        if ffmpegAudioExtensions.contains(ext) { return .audio }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .video }
        return .other
    }
}

/// The gallery's groups of operations.
enum ConverterFamily: String, CaseIterable, Identifiable {
    case images, videos, audio, pdf, documents, files, vision

    var id: String { rawValue }

    var title: String {
        switch self {
        case .images: return "Images"
        case .videos: return "Vidéos"
        case .audio: return "Audio"
        case .pdf: return "PDF"
        case .documents: return "Documents"
        case .files: return "Archives et noms"
        case .vision: return "Texte et QR codes"
        }
    }

    var subtitle: String {
        switch self {
        case .images: return "HEIC, JPEG, PNG, AVIF, TIFF, GIF…"
        case .videos: return "MOV, MP4, H.264 ou HEVC"
        case .audio: return "AAC, ALAC, WAV, AIFF, FLAC"
        case .pdf: return "Fusionner, découper, alléger"
        case .documents: return "Word, RTF, HTML, Markdown"
        case .files: return "ZIP et renommage par lot"
        case .vision: return "OCR en français et anglais"
        }
    }

    var symbol: String {
        switch self {
        case .images: return "photo.on.rectangle"
        case .videos: return "film.stack"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .documents: return "doc.text"
        case .files: return "archivebox"
        case .vision: return "text.viewfinder"
        }
    }

    var tint: Color {
        switch self {
        case .images: return Theme.palette[5]
        case .videos: return Theme.palette[4]
        case .audio: return Theme.palette[3]
        case .pdf: return Theme.bad
        case .documents: return Theme.accent
        case .files: return Theme.palette[7]
        case .vision: return Theme.palette[1]
        }
    }

    var operations: [ConverterOperation] { ConverterOperation.allCases.filter { $0.family == self } }
}

// MARK: - Operations

enum ConverterOperation: String, CaseIterable, Identifiable, Sendable {
    case imageConvert, imageResize, imageCompress, imageStrip, imagesToPDF
    case videoCompress, videoContainer, videoAudio, videoGIF
    case audioConvert
    case pdfMerge, pdfSplit, pdfRotate, pdfCompress, pdfToImages
    case documentConvert
    case archiveZip, archiveExtract, rename
    case ocr, qrRead, qrGenerate

    var id: String { rawValue }

    var family: ConverterFamily {
        switch self {
        case .imageConvert, .imageResize, .imageCompress, .imageStrip, .imagesToPDF: return .images
        case .videoCompress, .videoContainer, .videoAudio, .videoGIF: return .videos
        case .audioConvert: return .audio
        case .pdfMerge, .pdfSplit, .pdfRotate, .pdfCompress, .pdfToImages: return .pdf
        case .documentConvert: return .documents
        case .archiveZip, .archiveExtract, .rename: return .files
        case .ocr, .qrRead, .qrGenerate: return .vision
        }
    }

    /// Short label of the chips.
    var title: String {
        switch self {
        case .imageConvert: return "Changer de format"
        case .imageResize: return "Redimensionner"
        case .imageCompress: return "Compresser les images"
        case .imageStrip: return "Retirer GPS et métadonnées"
        case .imagesToPDF: return "Images → PDF"
        case .videoCompress: return "Compresser la vidéo"
        case .videoContainer: return "MOV ↔ MP4"
        case .videoAudio: return "Extraire l'audio"
        case .videoGIF: return "Vidéo → GIF animé"
        case .audioConvert: return "Convertir l'audio"
        case .pdfMerge: return "Fusionner"
        case .pdfSplit: return "Découper"
        case .pdfRotate: return "Pivoter"
        case .pdfCompress: return "Alléger"
        case .pdfToImages: return "PDF → images"
        case .documentConvert: return "Convertir le document"
        case .archiveZip: return "Compresser en ZIP"
        case .archiveExtract: return "Extraire l'archive"
        case .rename: return "Renommer par lot"
        case .ocr: return "Texte d'une image (OCR)"
        case .qrRead: return "Lire un QR code"
        case .qrGenerate: return "Créer un QR code"
        }
    }

    var symbol: String {
        switch self {
        case .imageConvert: return "photo.on.rectangle.angled"
        case .imageResize: return "arrow.up.left.and.arrow.down.right"
        case .imageCompress: return "arrow.down.right.and.arrow.up.left"
        case .imageStrip: return "location.slash"
        case .imagesToPDF: return "doc.on.doc"
        case .videoCompress: return "film"
        case .videoContainer: return "arrow.triangle.2.circlepath"
        case .videoAudio: return "music.note"
        case .videoGIF: return "sparkles.tv"
        case .audioConvert: return "waveform"
        case .pdfMerge: return "rectangle.stack.badge.plus"
        case .pdfSplit: return "scissors"
        case .pdfRotate: return "rotate.right"
        case .pdfCompress: return "arrow.down.doc"
        case .pdfToImages: return "photo.stack"
        case .documentConvert: return "doc.text"
        case .archiveZip: return "doc.zipper"
        case .archiveExtract: return "archivebox"
        case .rename: return "character.cursor.ibeam"
        case .ocr: return "text.viewfinder"
        case .qrRead: return "qrcode.viewfinder"
        case .qrGenerate: return "qrcode"
        }
    }

    /// One sentence under the options' title.
    var explanation: String {
        switch self {
        case .imageConvert: return "Un nouveau fichier pour chaque image, dans le format choisi. L'original ne bouge pas."
        case .imageResize: return "Réduit le côté le plus long. Les images déjà plus petites gardent leur taille."
        case .imageCompress: return "Allège les photos en réglant la qualité. Pratique avant un envoi par mail."
        case .imageStrip: return "Retire la position GPS (et si tu veux, l'appareil, la date…) sans recompresser l'image."
        case .imagesToPDF: return "Une page par image, dans l'ordre de la liste. Réordonne avec les flèches."
        case .videoCompress: return "Réencode la vidéo avec un préréglage d'Apple : plus légère, quasiment sans perte visible."
        case .videoContainer: return "Change d'emballage sans réencoder quand c'est possible : rapide et sans perte."
        case .videoAudio: return "Garde seulement le son de la vidéo, en AAC (.m4a)."
        case .videoGIF: return "Un GIF animé qui tourne en boucle, prêt à coller dans un message."
        case .audioConvert: return "Convertit avec les encodeurs de macOS. Le fichier d'origine reste intact."
        case .pdfMerge: return "Assemble PDF et images en un seul document : l'ordre et les pages que tu veux, un signet par document."
        case .pdfSplit: return "Garde les pages choisies dans un nouveau PDF, ou une page par fichier."
        case .pdfRotate: return "Fait pivoter toutes les pages, ou seulement celles que tu indiques."
        case .pdfCompress: return "Recompresse les images du PDF. Je ne garde le résultat que s'il est vraiment plus léger."
        case .pdfToImages: return "Une image par page, rangées dans un nouveau dossier."
        case .documentConvert: return "Word, OpenDocument, RTF, HTML, texte brut ou PDF. Le Markdown devient une jolie page."
        case .archiveZip: return "Une archive ZIP que tout le monde peut ouvrir, Windows compris."
        case .archiveExtract: return "Dans un nouveau dossier : rien n'est jamais écrasé."
        case .rename: return "Compose le nouveau nom avec des étiquettes et vérifie l'aperçu avant de valider."
        case .ocr: return "Reconnaît le texte des photos, captures et PDF scannés, en français et en anglais."
        case .qrRead: return "Lit les QR codes et codes-barres d'une image ou d'un PDF."
        case .qrGenerate: return "Tape un texte ou un lien : le QR code se dessine au fur et à mesure."
        }
    }

    /// Kinds of files the operation works on.
    var accepts: Set<ConverterKind> {
        switch self {
        case .imageConvert, .imageResize, .imageCompress, .imageStrip, .imagesToPDF: return [.image]
        case .videoCompress, .videoContainer, .videoAudio, .videoGIF: return [.video]
        case .audioConvert: return [.audio]
        case .pdfMerge: return [.pdf, .image]
        case .pdfSplit, .pdfRotate, .pdfCompress, .pdfToImages: return [.pdf]
        case .documentConvert: return [.document, .markdown]
        case .archiveExtract: return [.archive]
        case .archiveZip, .rename: return Set(ConverterKind.allCases)
        case .ocr, .qrRead: return [.image, .pdf]
        case .qrGenerate: return []
        }
    }

    /// One job for all the files (true) or one job per file (false).
    var isBatch: Bool {
        switch self {
        case .imagesToPDF, .pdfMerge, .archiveZip, .rename: return true
        default: return false
        }
    }

    var minimumCount: Int { self == .pdfMerge ? 2 : (self == .qrGenerate ? 0 : 1) }

    /// Making files lighter is the point: the results show how much was saved.
    var showsSavings: Bool {
        switch self {
        case .imageConvert, .imageResize, .imageCompress, .videoCompress, .videoContainer, .audioConvert, .pdfCompress, .archiveZip: return true
        default: return false
        }
    }

    /// The order of the list matters (merge, images → PDF).
    var isOrdered: Bool { self == .pdfMerge || self == .imagesToPDF }

    /// The main button of the bottom bar.
    var actionTitle: String {
        switch self {
        case .imageConvert, .audioConvert, .documentConvert, .videoContainer: return "Convertir"
        case .imageResize: return "Redimensionner"
        case .imageCompress, .videoCompress, .archiveZip: return "Compresser"
        case .imageStrip: return "Nettoyer les photos"
        case .imagesToPDF: return "Créer le PDF"
        case .videoAudio: return "Extraire l'audio"
        case .videoGIF: return "Créer le GIF"
        case .pdfMerge: return "Fusionner"
        case .pdfSplit: return "Extraire les pages"
        case .pdfRotate: return "Pivoter"
        case .pdfCompress: return "Alléger"
        case .pdfToImages: return "Exporter les images"
        case .archiveExtract: return "Extraire"
        case .rename: return "Renommer"
        case .ocr: return "Lire le texte"
        case .qrRead: return "Lire les codes"
        case .qrGenerate: return "Enregistrer"
        }
    }

    // Launcher

    var commandID: String {
        switch self {
        case .imageConvert: return "conv_images"
        case .imageResize: return "conv_image_resize"
        case .imageCompress: return "conv_image_compress"
        case .imageStrip: return "conv_image_strip_gps"
        case .imagesToPDF: return "conv_images_pdf"
        case .videoCompress: return "conv_video_compress"
        case .videoContainer: return "conv_video_container"
        case .videoAudio: return "conv_video_audio"
        case .videoGIF: return "conv_video_gif"
        case .audioConvert: return "conv_audio"
        case .pdfMerge: return "conv_pdf_merge"
        case .pdfSplit: return "conv_pdf_split"
        case .pdfRotate: return "conv_pdf_rotate"
        case .pdfCompress: return "conv_pdf_compress"
        case .pdfToImages: return "conv_pdf_images"
        case .documentConvert: return "conv_document"
        case .archiveZip: return "conv_zip"
        case .archiveExtract: return "conv_unzip"
        case .rename: return "conv_rename"
        case .ocr: return "conv_ocr"
        case .qrRead: return "conv_qr_read"
        case .qrGenerate: return "conv_qr_make"
        }
    }

    var commandTitle: String {
        switch self {
        case .imageConvert: return "Convertir des images"
        case .imageResize: return "Redimensionner des images"
        case .imageCompress: return "Compresser des images"
        case .imageStrip: return "Retirer la localisation des photos"
        case .imagesToPDF: return "Assembler des images en PDF"
        case .videoCompress: return "Compresser une vidéo"
        case .videoContainer: return "Convertir une vidéo (MOV ↔ MP4)"
        case .videoAudio: return "Extraire l'audio d'une vidéo"
        case .videoGIF: return "Transformer une vidéo en GIF"
        case .audioConvert: return "Convertir un fichier audio"
        case .pdfMerge: return "Fusionner des PDF"
        case .pdfSplit: return "Découper un PDF"
        case .pdfRotate: return "Pivoter un PDF"
        case .pdfCompress: return "Compresser un PDF"
        case .pdfToImages: return "Exporter un PDF en images"
        case .documentConvert: return "Convertir un document"
        case .archiveZip: return "Compresser en ZIP"
        case .archiveExtract: return "Extraire une archive"
        case .rename: return "Renommer des fichiers par lot"
        case .ocr: return "Texte d'une image (OCR)"
        case .qrRead: return "Lire un QR code"
        case .qrGenerate: return "Créer un QR code"
        }
    }

    var keywords: [String] {
        switch self {
        case .imageConvert: return ["heic", "jpeg", "jpg", "png", "photo", "image", "convertir"]
        case .imageResize: return ["taille", "resize", "pixels", "photo", "réduire"]
        case .imageCompress: return ["alléger", "qualité", "photo", "jpeg", "poids"]
        case .imageStrip: return ["gps", "exif", "métadonnées", "vie privée", "localisation"]
        case .imagesToPDF: return ["pdf", "scan", "images", "assembler"]
        case .videoCompress: return ["vidéo", "hevc", "h264", "réduire", "poids", "mp4"]
        case .videoContainer: return ["mov", "mp4", "vidéo", "convertir", "mkv"]
        case .videoAudio: return ["son", "m4a", "audio", "musique", "vidéo"]
        case .videoGIF: return ["gif", "animation", "vidéo", "boucle"]
        case .audioConvert: return ["mp3", "m4a", "wav", "aiff", "flac", "aac", "son"]
        case .pdfMerge: return ["pdf", "assembler", "combiner", "merge", "fusion", "regrouper", "joindre", "dossier"]
        case .pdfSplit: return ["pdf", "pages", "extraire", "split"]
        case .pdfRotate: return ["pdf", "rotation", "tourner", "pages"]
        case .pdfCompress: return ["pdf", "alléger", "réduire", "poids"]
        case .pdfToImages: return ["pdf", "png", "jpeg", "pages", "images"]
        case .documentConvert: return ["word", "docx", "rtf", "html", "markdown", "odt", "txt"]
        case .archiveZip: return ["zip", "archive", "compresser", "dossier"]
        case .archiveExtract: return ["dézipper", "unzip", "décompresser", "tar", "7z"]
        case .rename: return ["renommer", "noms", "numéroter", "lot", "batch"]
        case .ocr: return ["ocr", "texte", "capture", "scan", "reconnaître"]
        case .qrRead: return ["qr", "code-barres", "scanner", "lire"]
        case .qrGenerate: return ["qr", "code", "lien", "générer"]
        }
    }

    /// Operations offered for a set of files: at least `minimumCount` of them must be accepted.
    static func available(for kinds: [ConverterKind]) -> [ConverterOperation] {
        allCases.filter { op in
            op != .qrGenerate && kinds.filter { op.accepts.contains($0) }.count >= op.minimumCount
                // A merge takes images too, but only around a PDF (images alone: « Images → PDF »).
                && (op != .pdfMerge || kinds.contains(.pdf))
        }
    }

    /// The operation picked when files arrive and nothing suitable is selected.
    static func suggested(for kinds: [ConverterKind]) -> ConverterOperation? {
        guard !kinds.isEmpty else { return nil }
        var counts: [ConverterKind: Int] = [:]
        for k in kinds { counts[k, default: 0] += 1 }
        let main = counts.max { a, b in a.value == b.value ? a.key.rawValue > b.key.rawValue : a.value < b.value }!.key
        switch main {
        case .image: return .imageConvert
        case .video: return .videoCompress
        case .audio: return .audioConvert
        case .pdf: return (counts[.pdf] ?? 0) >= 2 ? .pdfMerge : .pdfCompress
        case .document, .markdown: return .documentConvert
        case .archive: return .archiveExtract
        case .folder: return .archiveZip
        case .other: return .rename
        }
    }
}

// MARK: - Formats and presets

struct ConverterImageFormat: Hashable, Identifiable, Sendable {
    let uti: String
    let name: String
    let ext: String
    let lossy: Bool
    /// Written by ffmpeg (WebP), not by ImageIO.
    var viaFFmpeg = false

    var id: String { uti }

    static let heic = ConverterImageFormat(uti: "public.heic", name: "HEIC", ext: "heic", lossy: true)
    static let jpeg = ConverterImageFormat(uti: "public.jpeg", name: "JPEG", ext: "jpg", lossy: true)
    static let png = ConverterImageFormat(uti: "public.png", name: "PNG", ext: "png", lossy: false)
    static let avif = ConverterImageFormat(uti: "public.avif", name: "AVIF", ext: "avif", lossy: true)
    static let tiff = ConverterImageFormat(uti: "public.tiff", name: "TIFF", ext: "tiff", lossy: false)
    static let gif = ConverterImageFormat(uti: "com.compuserve.gif", name: "GIF", ext: "gif", lossy: false)
    static let bmp = ConverterImageFormat(uti: "com.microsoft.bmp", name: "BMP", ext: "bmp", lossy: false)
    static let pdf = ConverterImageFormat(uti: "com.adobe.pdf", name: "PDF", ext: "pdf", lossy: false)
    static let jpeg2000 = ConverterImageFormat(uti: "public.jpeg-2000", name: "JPEG 2000", ext: "jp2", lossy: true)
    static let webp = ConverterImageFormat(uti: "org.webmproject.webp", name: "WebP", ext: "webp", lossy: true, viaFFmpeg: true)

    /// In the order shown; filtered with what this Mac can write.
    static let catalog: [ConverterImageFormat] = [.heic, .jpeg, .png, .avif, .tiff, .gif, .bmp, .pdf, .jpeg2000, .webp]

    /// The writable format matching a source type (`CGImageSourceGetType`), for "same format".
    static func matching(uti: String?) -> ConverterImageFormat? {
        guard let uti else { return nil }
        if uti == "public.heif" { return .heic }
        return catalog.first { $0.uti == uti && !$0.viaFFmpeg }
    }
}

enum ConverterVideoPreset: String, CaseIterable, Identifiable, Sendable {
    // Raw values are AVAssetExportSession preset names. Never AVAssetExportPresetHEVC4320x2160: macOS 26 only.
    case h264_1080 = "AVAssetExportPreset1920x1080"
    case h264_720 = "AVAssetExportPreset1280x720"
    case h264_540 = "AVAssetExportPreset960x540"
    case hevcHighest = "AVAssetExportPresetHEVCHighestQuality"
    case hevc1080 = "AVAssetExportPresetHEVC1920x1080"
    case hevc4K = "AVAssetExportPresetHEVC3840x2160"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264_1080: return "H.264 · 1080p"
        case .h264_720: return "H.264 · 720p"
        case .h264_540: return "H.264 · 540p"
        case .hevcHighest: return "HEVC · qualité max"
        case .hevc1080: return "HEVC · 1080p"
        case .hevc4K: return "HEVC · 4K"
        }
    }

    var subtitle: String {
        switch self {
        case .h264_1080: return "Lisible partout"
        case .h264_720: return "Léger, idéal pour envoyer"
        case .h264_540: return "Le plus léger"
        case .hevcHighest: return "Taille d'origine, deux fois plus léger"
        case .hevc1080: return "Très léger, appareils récents"
        case .hevc4K: return "Pour les vidéos 4K"
        }
    }

    var short: String {
        switch self {
        case .h264_1080: return "H.264 1080p"
        case .h264_720: return "H.264 720p"
        case .h264_540: return "H.264 540p"
        case .hevcHighest: return "HEVC"
        case .hevc1080: return "HEVC 1080p"
        case .hevc4K: return "HEVC 4K"
        }
    }
}

enum ConverterVideoContainer: String, CaseIterable, Identifiable, Sendable {
    case mp4, mov, mkv, webm

    var id: String { rawValue }
    var name: String { rawValue.uppercased() == "WEBM" ? "WebM" : rawValue.uppercased() }
    var ext: String { rawValue }
    var viaFFmpeg: Bool { self == .mkv || self == .webm }
}

enum ConverterAudioFormat: String, CaseIterable, Identifiable, Sendable {
    case aac, alac, wav, aiff, flac, mp3

    var id: String { rawValue }

    var name: String {
        switch self {
        case .aac: return "AAC (.m4a)"
        case .alac: return "Apple Lossless"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .flac: return "FLAC"
        case .mp3: return "MP3"
        }
    }

    var short: String {
        switch self {
        case .aac: return "AAC"
        case .alac: return "ALAC"
        default: return rawValue.uppercased()
        }
    }

    var ext: String {
        switch self {
        case .aac, .alac: return "m4a"
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .flac: return "flac"
        case .mp3: return "mp3"
        }
    }

    var lossy: Bool { self == .aac || self == .mp3 }
    var viaFFmpeg: Bool { self == .mp3 }

    static func available(ffmpeg: Bool) -> [ConverterAudioFormat] {
        allCases.filter { !$0.viaFFmpeg || ffmpeg }
    }
}

enum ConverterDocFormat: String, CaseIterable, Identifiable, Sendable {
    case docx, pdf, rtf, html, txt, odt

    var id: String { rawValue }
    var name: String { self == .docx ? "Word (.docx)" : (self == .odt ? "OpenDocument" : rawValue.uppercased()) }
    var short: String { rawValue.uppercased() }
    var ext: String { rawValue }
}

enum ConverterStripMode: String, CaseIterable, Identifiable, Sendable {
    case gps, all
    var id: String { rawValue }
    var title: String { self == .gps ? "Seulement la localisation" : "Toutes les métadonnées" }
}

enum ConverterSplitMode: String, CaseIterable, Identifiable, Sendable {
    case extract, eachPage
    var id: String { rawValue }
    var title: String { self == .extract ? "Un PDF avec ces pages" : "Une page par fichier" }
}

enum ConverterPageSize: String, CaseIterable, Identifiable, Sendable {
    case image, a4
    var id: String { rawValue }
    var title: String { self == .image ? "Taille de chaque image" : "A4" }
}

enum ConverterZipMode: String, CaseIterable, Identifiable, Sendable {
    case together, each
    var id: String { rawValue }
    var title: String { self == .together ? "Une seule archive" : "Une archive par élément" }
}

enum ConverterPDFCompression: String, CaseIterable, Identifiable, Sendable {
    case balanced, strong
    var id: String { rawValue }
    var title: String { self == .balanced ? "Équilibré" : "Maximal" }
    var subtitle: String {
        self == .balanced ? "Photos en JPEG 80 %, 150 ppp : net à l'écran comme à l'impression"
                          : "JPEG 55 %, 110 ppp : le plus léger, pour un envoi par mail"
    }
}

enum ConverterRasterFormat: String, CaseIterable, Identifiable, Sendable {
    case png, jpeg, heic
    var id: String { rawValue }
    var name: String { rawValue.uppercased() }
    var uti: String { self == .png ? "public.png" : (self == .jpeg ? "public.jpeg" : "public.heic") }
    var ext: String { self == .jpeg ? "jpg" : rawValue }
}

enum ConverterCase: String, CaseIterable, Identifiable, Sendable {
    case unchanged, lower, upper, capitalized
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unchanged: return "Inchangée"
        case .lower: return "minuscules"
        case .upper: return "MAJUSCULES"
        case .capitalized: return "Première lettre"
        }
    }
}

/// How batch renaming builds the new names.
struct ConverterRenameRule: Equatable, Sendable {
    /// Tokens: {nom} {n} {n:3} {date} {heure} {dossier}.
    var pattern = "{nom}"
    var start = 1
    var find = ""
    var replace = ""
    var caseMode: ConverterCase = .unchanged
    var lowercaseExtension = false
}

/// Every option of every operation; copied into each job when it is queued.
struct ConverterOptions: Equatable, Sendable {
    // Images (nil = keep the source format)
    var imageFormat: ConverterImageFormat? = .jpeg
    var resizeFormat: ConverterImageFormat? = nil
    var compressFormat: ConverterImageFormat? = nil
    var imageQuality = 0.82
    var maxSide = 2048
    var compressMaxSide = 0
    var stripOnConvert = false
    var stripMode: ConverterStripMode = .gps
    var pageSize: ConverterPageSize = .image
    // Video
    var videoPreset: ConverterVideoPreset = .hevc1080
    var compressContainer: ConverterVideoContainer = .mp4
    var container: ConverterVideoContainer = .mp4
    var gifWidth = 480
    var gifFPS = 12
    var gifSeconds = 10
    // Audio
    var audioFormat: ConverterAudioFormat = .aac
    var audioBitrate = 256
    // PDF
    var pdfPages = ""
    /// Merge: the pages kept from each PDF, by path (missing or empty: all of them), a bookmark per document, a blank page
    /// so that each document starts on a new sheet once printed double-sided, and the name of the result ("" : "<premier> fusionné").
    var mergePages: [String: String] = [:]
    var mergeBookmarks = true
    var mergeDuplex = false
    var mergeName = ""
    var splitMode: ConverterSplitMode = .extract
    var rotation = 90
    var pdfCompression: ConverterPDFCompression = .balanced
    var rasterFormat: ConverterRasterFormat = .png
    var rasterDPI = 150
    // Documents and files
    var docFormat: ConverterDocFormat = .docx
    var zipMode: ConverterZipMode = .together
    var rename = ConverterRenameRule()
}

// MARK: - Files and jobs

/// A file waiting in the converter's list.
struct ConverterFile: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var kind: ConverterKind
    var size: Int64 = 0
    /// Shooting date for photos, creation date otherwise (renaming with {date}).
    var date: Date?
    /// "4 032 × 3 024", "2:14 · 1 920 × 1 080", "12 pages"…
    var detail: String?
    /// Page count of a PDF, once read.
    var pages: Int?
    /// Size, date and details read (in the background, just after the file was added).
    var inspected = false

    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.uppercased() }
}

struct ConverterRenamePair: Sendable, Equatable {
    var from: URL
    var to: URL
}

/// What an engine produced.
struct ConverterOutput: Sendable {
    var files: [URL] = []
    /// OCR text, codes read…
    var text: String?
    var codes: [String] = []
    /// A remark shown under the result ("déjà optimisé"…).
    var note: String?
    var renamed: [ConverterRenamePair] = []
    /// Total size of what was written (computed off the main thread).
    var size: Int64 = 0
}

enum ConverterError: LocalizedError {
    case cancelled
    case unreadable(String)
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Annulé."
        case .unreadable(let name): return "Je n'arrive pas à lire « \(name) »."
        case .unsupported(let why): return why
        case .failed(let why): return why
        }
    }
}

/// Shared between a job (main actor) and its engine (background): cancellation and throttled progress.
final class ConverterControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastReport = Date.distantPast
    private let report: @Sendable (Double?) -> Void

    init(report: @escaping @Sendable (Double?) -> Void) {
        self.report = report
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        if isCancelled { throw ConverterError.cancelled }
    }

    /// 0…1, or nil when the tool gives no progress. At most four updates per second reach the interface.
    func progress(_ value: Double?) {
        lock.lock()
        let now = Date()
        let due = value == nil || (value ?? 0) >= 1 || now.timeIntervalSince(lastReport) >= 0.25
        if due { lastReport = now }
        lock.unlock()
        if due { report(value.map { min(1, max(0, $0)) }) }
    }
}

/// A one-shot flag set from a completion handler.
final class ConverterFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

// MARK: - Destination

/// Where copies go when their own folder cannot take them (and where « Dans Téléchargements » puts them).
enum ConverterDestination {
    static var downloadsURL: URL { URL(fileURLWithPath: FS.home + "/Downloads") }
}
