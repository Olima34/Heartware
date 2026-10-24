import SwiftUI
import UniformTypeIdentifiers

// MARK: - Families

/// What the wheel offers depends on the kind of the dropped files; several kinds at once fall back to `.other`.
enum WheelFamily: String, CaseIterable, Identifiable, Codable, Sendable {
    case image, pdf, video, audio, document, archive, folder, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return "Images"
        case .pdf: return "PDF"
        case .video: return "Vidéos"
        case .audio: return "Audio"
        case .document: return "Documents"
        case .archive: return "Archives"
        case .folder: return "Dossiers"
        case .other: return "Autres"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.text"
        case .archive: return "doc.zipper"
        case .folder: return "folder"
        case .other: return "doc"
        }
    }

    /// The converter's kinds of this family (the actions accept those).
    var kinds: Set<ConverterKind> {
        switch self {
        case .image: return [.image]
        case .pdf: return [.pdf]
        case .video: return [.video]
        case .audio: return [.audio]
        case .document: return [.document, .markdown]
        case .archive: return [.archive]
        case .folder: return [.folder]
        case .other: return [.other]
        }
    }

    static func of(_ kind: ConverterKind) -> WheelFamily {
        switch kind {
        case .image: return .image
        case .pdf: return .pdf
        case .video: return .video
        case .audio: return .audio
        case .document, .markdown: return .document
        case .archive: return .archive
        case .folder: return .folder
        case .other: return .other
        }
    }

    /// The family of a drop: the one every file shares, `.other` for a mix.
    static func of(_ kinds: [ConverterKind]) -> WheelFamily {
        let families = Set(kinds.map(of))
        return families.count == 1 ? families.first! : .other
    }

    /// The wheel of a family before the user changes it: formats first (the inner ring), then the tools (the outer one).
    var defaultActions: [WheelAction] {
        switch self {
        case .image: return [.jpeg, .png, .heic, .pdf, .crop, .backdrop, .annotate, .redact, .cutout, .compress, .resize, .metadata]
        case .pdf: return [.word, .jpeg, .png, .text, .sign, .pdfCompress, .pdfPages, .pdfRotate, .copyText, .merge, .airdrop, .zip]
        case .video: return [.mp4, .mov, .gif, .sound, .videoCompress, .trim, .frame, .mute, .airdrop, .zip]
        case .audio: return [.aac, .mp3, .wav, .flac, .alac, .trim, .airdrop, .zip]
        case .document: return [.pdf, .word, .text, .html, .sign, .copyText, .airdrop, .zip]
        case .archive: return [.extract, .airdrop, .copyPath]
        case .folder: return [.zip, .airdrop, .copyPath]
        case .other: return [.zip, .airdrop, .copyPath]
        }
    }

    /// Every action that can sit on this family's wheel, in the order of the settings.
    var pool: [WheelAction] {
        let all = WheelAction.allCases.filter { (!$0.accepts.isDisjoint(with: kinds) || $0.universal) && ($0 != .merge || self == .pdf) }
        let defaults = defaultActions
        return defaults + all.filter { !defaults.contains($0) }
    }
}

// MARK: - Actions

/// The small window an action opens before anything is written.
enum WheelEditorKind: String, Sendable {
    case crop, backdrop, annotate, redact, shrink, metadata, pages, trim, frame, videoCompress
}

/// The sections of the Convertisseur's window, in its order.
enum WheelActionGroup: Int, CaseIterable, Identifiable {
    case convert, edit, lighten, pages, media, text, share

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .convert: return "Convertir"
        case .edit: return "Retoucher"
        case .lighten: return "Alléger et nettoyer"
        case .pages: return "Pages"
        case .media: return "Vidéo et son"
        case .text: return "Texte et codes"
        case .share: return "Ranger et partager"
        }
    }
}

/// Everything the wheel can do with the dropped files. Formats sit on the inner ring, tools on the outer one.
/// Nothing ever touches the original: every action writes a new file next to it (or in Téléchargements), except
/// « Renommer », which renames in place and can be undone.
enum WheelAction: String, CaseIterable, Identifiable, Codable, Sendable {
    // Formats
    case jpeg, png, heic, webp, pdf, word, text, html, rtf, odt
    case mp4, mov, mkv, webm, gif, sound
    case aac, mp3, wav, aiff, flac, alac
    // Image tools
    case crop, backdrop, annotate, redact, cutout, compress, resize, metadata, strip, rotate, copyText, qrRead
    // PDF tools
    case sign, pdfCompress, pdfPages, pdfSplit, pdfRotate, merge, pdfImages
    // Video and audio tools
    case videoCompress, trim, mute, frame
    // Any file
    case convert, rename, extract, zip, airdrop, copyPath

    var id: String { rawValue }

    /// On the inner ring: the file in another format.
    var isFormat: Bool {
        switch self {
        case .jpeg, .png, .heic, .webp, .pdf, .word, .text, .html, .rtf, .odt, .mp4, .mov, .mkv, .webm, .gif, .sound,
             .aac, .mp3, .wav, .aiff, .flac, .alac: return true
        default: return false
        }
    }

    /// Offered for any file, whatever its kind.
    var universal: Bool { self == .zip || self == .airdrop || self == .copyPath || self == .rename }

    /// On the wheel, in capitals.
    var label: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .webp: return "WEBP"
        case .pdf: return "PDF"
        case .word: return "WORD"
        case .text: return "TXT"
        case .html: return "HTML"
        case .rtf: return "RTF"
        case .odt: return "ODT"
        case .mp4: return "MP4"
        case .mov: return "MOV"
        case .mkv: return "MKV"
        case .webm: return "WEBM"
        case .gif: return "GIF"
        case .sound: return "SON"
        case .aac: return "AAC"
        case .mp3: return "MP3"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .flac: return "FLAC"
        case .alac: return "ALAC"
        case .crop: return "RECADRER"
        case .backdrop: return "FOND"
        case .annotate: return "ANNOTER"
        case .redact: return "MASQUER"
        case .cutout: return "DÉTOURER"
        case .compress, .pdfCompress, .videoCompress: return "ALLÉGER"
        case .resize: return "TAILLE"
        case .metadata: return "MÉTADONNÉES"
        case .strip: return "SANS GPS"
        case .rotate, .pdfRotate: return "PIVOTER"
        case .copyText: return "TEXTE"
        case .qrRead: return "QR CODE"
        case .sign: return "SIGNER"
        case .pdfPages: return "PAGES"
        case .pdfSplit: return "DÉCOUPER"
        case .merge: return "FUSIONNER"
        case .pdfImages: return "IMAGES"
        case .trim: return "COUPER"
        case .mute: return "MUET"
        case .frame: return "IMAGE"
        case .convert: return "FORMATS"
        case .rename: return "RENOMMER"
        case .extract: return "EXTRAIRE"
        case .zip: return "ZIP"
        case .airdrop: return "AIRDROP"
        case .copyPath: return "CHEMIN"
        }
    }

    /// In the middle of the wheel, the list of all actions and the settings.
    var title: String {
        switch self {
        case .jpeg: return "En JPEG"
        case .png: return "En PNG"
        case .heic: return "En HEIC"
        case .webp: return "En WebP"
        case .pdf: return "En PDF"
        case .word: return "En Word"
        case .text: return "En texte brut"
        case .html: return "En page web"
        case .rtf: return "En RTF"
        case .odt: return "En OpenDocument"
        case .mp4: return "En MP4"
        case .mov: return "En MOV"
        case .mkv: return "En MKV"
        case .webm: return "En WebM"
        case .gif: return "En GIF animé"
        case .sound: return "Garder le son"
        case .aac: return "En AAC"
        case .mp3: return "En MP3"
        case .wav: return "En WAV"
        case .aiff: return "En AIFF"
        case .flac: return "En FLAC"
        case .alac: return "En Apple Lossless"
        case .crop: return "Recadrer"
        case .backdrop: return "Mettre sur un fond"
        case .annotate: return "Annoter"
        case .redact: return "Masquer des zones"
        case .cutout: return "Détourer le sujet"
        case .compress: return "Alléger l'image"
        case .resize: return "Changer la taille"
        case .metadata: return "Métadonnées"
        case .strip: return "Retirer le GPS"
        case .rotate: return "Pivoter"
        case .copyText: return "Copier le texte"
        case .qrRead: return "Lire un QR code"
        case .sign: return "Remplir et signer"
        case .pdfCompress: return "Alléger le PDF"
        case .pdfPages: return "Choisir des pages"
        case .pdfSplit: return "Découper"
        case .pdfRotate: return "Pivoter les pages"
        case .merge: return "Fusionner"
        case .pdfImages: return "Une image par page"
        case .videoCompress: return "Alléger la vidéo"
        case .trim: return "Couper"
        case .mute: return "Retirer le son"
        case .frame: return "Capturer une image"
        case .convert: return "Changer de format"
        case .rename: return "Renommer"
        case .extract: return "Extraire"
        case .zip: return "Compresser en ZIP"
        case .airdrop: return "Envoyer par AirDrop"
        case .copyPath: return "Copier le chemin"
        }
    }

    /// One sentence: the settings' list.
    var detail: String {
        switch self {
        case .jpeg: return "Une copie en JPEG, lisible partout (les pages d'un PDF deviennent des images)."
        case .png: return "Une copie en PNG, sans perte (les pages d'un PDF deviennent des images)."
        case .heic: return "Le format des iPhone : deux fois plus léger que le JPEG."
        case .webp: return "Le format léger du web (demande ffmpeg)."
        case .pdf: return "Un PDF de l'image ou du document ; plusieurs images font un seul PDF."
        case .word: return "Un document Word modifiable, texte et mise en forme compris."
        case .text: return "Tout le texte dans un fichier .txt, lu par OCR pour une image ou un scan."
        case .html: return "Une page web qui s'ouvre dans n'importe quel navigateur."
        case .rtf: return "Un document RTF, lisible par tous les traitements de texte."
        case .odt: return "Le format de LibreOffice, modifiable."
        case .mp4: return "Change d'emballage sans réencoder quand c'est possible."
        case .mov: return "Le format de QuickTime, sans réencoder quand c'est possible."
        case .mkv: return "L'emballage MKV, sans réencoder (demande ffmpeg)."
        case .webm: return "Le format vidéo du web (demande ffmpeg)."
        case .gif: return "Les 10 premières secondes en GIF qui tourne en boucle."
        case .sound: return "Seulement la bande-son, en AAC (.m4a)."
        case .aac: return "Léger et lisible partout (.m4a)."
        case .mp3: return "Le plus répandu (demande ffmpeg)."
        case .wav: return "Sans perte et sans compression : pour un logiciel de musique."
        case .aiff: return "Sans perte, le format audio historique du Mac."
        case .flac: return "Sans perte, deux fois plus léger que le WAV."
        case .alac: return "Sans perte, le format de Musique sur Mac et iPhone."
        case .crop: return "Une fenêtre pour cadrer, avec les formats 1:1, 16:9, 4:3…"
        case .backdrop: return "Pose l'image sur un dégradé, avec marge, coins arrondis et ombre."
        case .annotate: return "Flèches, cadres, surligneur, texte et numéros, puis une copie annotée."
        case .redact: return "Cache des zones en noir, flou ou pixels ; trouve seul visages, e-mails et numéros."
        case .cutout: return "Le sujet de la photo sur un fond transparent, en PNG."
        case .compress: return "Règle la qualité en voyant le poids gagné avant d'enregistrer."
        case .resize: return "Le côté le plus long en pixels, ou un pourcentage."
        case .metadata: return "Date, appareil et position GPS ; une copie sans ce que tu veux retirer."
        case .strip: return "Sans la position GPS (ou sans aucune métadonnée), sans toucher aux pixels."
        case .rotate: return "Une copie tournée d'un quart de tour vers la droite."
        case .copyText: return "Le texte lu (OCR pour une image) va dans le presse-papiers."
        case .qrRead: return "Le contenu des QR codes et codes-barres, prêt à coller."
        case .sign: return "Le document dans sa fenêtre : remplis-le, signe-le, enregistre une copie."
        case .pdfCompress: return "Recompresse les images du PDF, gardé seulement s'il est plus léger."
        case .pdfPages: return "Les miniatures : garde, pivote et réordonne les pages."
        case .pdfSplit: return "Les pages choisies dans un nouveau PDF, ou une page par fichier."
        case .pdfRotate: return "Toutes les pages tournées d'un quart de tour vers la droite."
        case .merge: return "Les PDF lâchés ensemble, dans un seul document."
        case .pdfImages: return "Chaque page en image, dans un nouveau dossier."
        case .videoCompress: return "Choisis le poids : pour l'envoyer, équilibrée ou qualité maximale."
        case .trim: return "Le début et la fin à la souris, puis une copie coupée."
        case .mute: return "La même vidéo sans sa bande-son."
        case .frame: return "Avance jusqu'au bon moment et garde l'image en PNG."
        case .convert: return "Tous les formats, avec la qualité et un aperçu."
        case .rename: return "Un nouveau nom pour chaque fichier, vu avant de valider."
        case .extract: return "Dans un nouveau dossier, rien n'est écrasé."
        case .zip: return "Une archive que tout le monde peut ouvrir, Windows compris."
        case .airdrop: return "Vers un iPhone, un iPad ou un Mac à côté."
        case .copyPath: return "Le chemin complet du fichier, prêt à coller."
        }
    }

    var symbol: String {
        switch self {
        case .jpeg, .png, .heic, .webp: return "photo"
        case .pdf: return "doc.richtext"
        case .word: return "doc.text"
        case .text: return "text.alignleft"
        case .html: return "globe"
        case .rtf, .odt: return "doc.text"
        case .mp4, .mov, .mkv, .webm: return "film"
        case .gif: return "sparkles.tv"
        case .sound: return "music.note"
        case .aac, .mp3, .wav, .aiff, .flac, .alac: return "waveform"
        case .crop: return "crop"
        case .backdrop: return "photo.artframe"
        case .annotate: return "pencil.tip.crop.circle"
        case .redact: return "eye.slash"
        case .cutout: return "person.and.background.dotted"
        case .compress, .pdfCompress, .videoCompress: return "arrow.down.right.and.arrow.up.left"
        case .resize: return "arrow.up.left.and.arrow.down.right"
        case .metadata: return "tag"
        case .strip: return "location.slash"
        case .rotate, .pdfRotate: return "rotate.right"
        case .copyText: return "text.viewfinder"
        case .qrRead: return "qrcode.viewfinder"
        case .sign: return "signature"
        case .pdfPages: return "doc.on.doc"
        case .pdfSplit: return "scissors"
        case .merge: return "rectangle.stack.badge.plus"
        case .pdfImages: return "photo.stack"
        case .trim: return "timeline.selection"
        case .mute: return "speaker.slash"
        case .frame: return "camera.viewfinder"
        case .convert: return "arrow.triangle.2.circlepath"
        case .rename: return "character.cursor.ibeam"
        case .extract: return "archivebox"
        case .zip: return "doc.zipper"
        case .airdrop: return "dot.radiowaves.up.forward"
        case .copyPath: return "link"
        }
    }

    /// The color of its segment's faint tint.
    var tint: Color {
        switch self {
        case .jpeg, .png, .heic, .webp: return Theme.palette[5]
        case .pdf: return Theme.bad
        case .word, .html, .rtf, .odt: return Theme.accent
        case .text, .copyText, .qrRead, .convert: return Theme.palette[1]
        case .mp4, .mov, .mkv, .webm, .gif: return Theme.palette[4]
        case .sound, .aac, .mp3, .wav, .aiff, .flac, .alac: return Theme.palette[3]
        case .crop, .backdrop, .annotate, .cutout, .rotate, .pdfRotate, .pdfPages, .pdfSplit, .merge, .trim, .frame, .sign: return Theme.brand
        case .redact, .metadata, .strip, .mute: return Theme.palette[2]
        case .compress, .pdfCompress, .videoCompress, .resize, .pdfImages: return Theme.good
        case .extract, .zip, .airdrop, .copyPath, .rename: return Theme.palette[7]
        }
    }

    /// The kinds of files it works on (`universal` ones take anything).
    var accepts: Set<ConverterKind> {
        switch self {
        case .jpeg, .png: return [.image, .pdf]
        case .heic, .webp: return [.image]
        case .pdf: return [.image, .document, .markdown]
        case .word: return [.pdf, .document, .markdown]
        case .text: return [.pdf, .image, .document, .markdown]
        case .html, .rtf, .odt: return [.document, .markdown]
        case .mp4, .mov, .mkv, .webm, .gif, .sound: return [.video]
        case .aac, .mp3, .wav, .aiff, .flac, .alac: return [.audio]
        case .crop, .backdrop, .annotate, .redact, .cutout, .compress, .resize, .metadata, .strip, .rotate: return [.image]
        case .copyText: return [.image, .pdf, .document, .markdown]
        case .qrRead: return [.image, .pdf]
        // Word, Pages or Markdown: the window turns it into a PDF first.
        case .sign: return [.pdf, .image, .document, .markdown]
        case .pdfCompress, .pdfPages, .pdfSplit, .pdfRotate, .pdfImages: return [.pdf]
        // Images become pages of the merge, around a PDF.
        case .merge: return [.pdf, .image]
        case .videoCompress, .frame, .mute: return [.video]
        case .trim: return [.video, .audio]
        case .convert: return [.image, .video, .audio, .document, .markdown]
        case .extract: return [.archive]
        case .zip, .airdrop, .copyPath, .rename: return Set(ConverterKind.allCases)
        }
    }

    /// The small window it opens first, or nil when it is done at once.
    var editor: WheelEditorKind? {
        switch self {
        case .crop: return .crop
        case .backdrop: return .backdrop
        case .annotate: return .annotate
        case .redact: return .redact
        case .compress, .resize: return .shrink
        case .metadata: return .metadata
        case .pdfPages: return .pages
        case .trim: return .trim
        case .frame: return .frame
        case .videoCompress: return .videoCompress
        default: return nil
        }
    }

    /// Its settings are in the Convertisseur's window: dropped on the wheel, it opens there.
    var opensHub: Bool { self == .convert || self == .pdfSplit || self == .rename }

    /// Opens a window before anything is written (its own, the Convertisseur's or Remplir et signer).
    var opensWindow: Bool { editor != nil || opensHub || self == .sign }

    /// Its window shows one file at a time: offered only for a single file.
    var singleFile: Bool {
        switch self {
        case .crop, .backdrop, .annotate, .redact, .metadata, .pdfPages, .trim, .frame, .copyPath, .sign: return true
        default: return false
        }
    }

    /// Needs several files (a merge).
    var needsSeveral: Bool { self == .merge }

    /// Needs ffmpeg on this Mac.
    var needsFFmpeg: Bool { self == .webp || self == .mp3 || self == .mkv || self == .webm }

    /// The extensions this format already is: a JPEG is not offered "En JPEG".
    var ownExtensions: Set<String> {
        switch self {
        case .jpeg: return ["jpg", "jpeg", "jpe"]
        case .png: return ["png"]
        case .heic: return ["heic", "heif"]
        case .webp: return ["webp"]
        case .word: return ["docx"]
        case .text: return ["txt", "text"]
        case .html: return ["html", "htm"]
        case .rtf: return ["rtf"]
        case .odt: return ["odt"]
        case .mp4: return ["mp4", "m4v"]
        case .mov: return ["mov", "qt"]
        case .mkv: return ["mkv"]
        case .webm: return ["webm"]
        case .gif: return ["gif"]
        case .aac: return ["m4a", "aac"]
        case .mp3: return ["mp3"]
        case .wav: return ["wav"]
        case .aiff: return ["aif", "aiff", "aifc"]
        case .flac: return ["flac"]
        case .alac: return ["m4a"]
        default: return []
        }
    }

    /// The title when several files are dropped together ("Assembler en PDF").
    func title(count: Int, family: WheelFamily) -> String {
        if self == .pdf && count > 1 && family == .image { return "Assembler en PDF" }
        if self == .zip && count > 1 { return "Tout dans un ZIP" }
        return title
    }

    // MARK: In the Convertisseur's window

    var group: WheelActionGroup {
        switch self {
        case .crop, .backdrop, .annotate, .redact, .cutout, .rotate, .sign: return .edit
        case .compress, .resize, .metadata, .strip, .pdfCompress, .videoCompress: return .lighten
        case .pdfPages, .pdfSplit, .pdfRotate, .merge: return .pages
        case .trim, .mute, .frame: return .media
        case .copyText, .qrRead: return .text
        case .rename, .extract, .zip, .airdrop, .copyPath: return .share
        default: return .convert
        }
    }

    /// Left out of the window, where « Changer de format » (or « Une image par page ») offers it with its settings.
    func coveredInHub(_ family: WheelFamily) -> Bool {
        switch family {
        case .image: return [.jpeg, .png, .heic, .webp].contains(self)
        case .video: return [.mp4, .mov, .mkv, .webm].contains(self)
        case .audio: return [.aac, .mp3, .wav, .aiff, .flac, .alac].contains(self)
        case .document: return [.pdf, .word, .text, .html, .rtf, .odt].contains(self)
        case .pdf: return [.jpeg, .png].contains(self)
        default: return false
        }
    }

    /// The converter's operation behind it in the window: its settings and its preview (nil: none, it is done at once
    /// or in its own window).
    func hubOperation(_ family: WheelFamily) -> ConverterOperation? {
        switch self {
        case .convert:
            switch family {
            case .image: return .imageConvert
            case .video: return .videoContainer
            case .audio: return .audioConvert
            case .document: return .documentConvert
            default: return nil
            }
        case .pdf: return family == .image ? .imagesToPDF : nil
        case .gif: return .videoGIF
        case .sound: return .videoAudio
        case .compress: return .imageCompress
        case .resize: return .imageResize
        case .strip: return .imageStrip
        case .videoCompress: return .videoCompress
        case .pdfCompress: return .pdfCompress
        case .pdfSplit: return .pdfSplit
        case .pdfRotate: return .pdfRotate
        case .pdfImages: return .pdfToImages
        case .merge: return .pdfMerge
        case .zip: return .archiveZip
        case .extract: return .archiveExtract
        case .rename: return .rename
        case .qrRead: return .qrRead
        case .copyText, .text: return family == .image || family == .pdf ? .ocr : nil
        default: return nil
        }
    }

    /// Run with the window's settings (else as the wheel does it: the window only showed the preview).
    func runsWithOptions(_ family: WheelFamily) -> Bool {
        hubOperation(family) != nil && self != .copyText && self != .text
    }

    /// The main button of the window.
    func verb(_ family: WheelFamily, count: Int) -> String {
        switch self {
        case .pdf where family == .image: return "Créer le PDF"
        case .gif: return "Créer le GIF"
        case .sound: return "Extraire le son"
        case .text: return "Enregistrer le texte"
        case _ where isFormat: return "Convertir"
        case .convert: return "Convertir"
        case .cutout: return "Détourer"
        case .rotate, .pdfRotate: return "Pivoter"
        case .compress, .pdfCompress, .videoCompress: return "Alléger"
        case .resize: return "Redimensionner"
        case .strip: return "Nettoyer"
        case .copyText: return "Copier le texte"
        case .qrRead: return "Lire"
        case .sign: return "Signer"
        case .pdfSplit: return "Découper"
        case .merge: return "Fusionner"
        case .pdfImages: return "Exporter"
        case .mute: return "Retirer le son"
        case .rename: return "Renommer"
        case .extract: return "Extraire"
        case .zip: return "Compresser"
        case .airdrop: return "Envoyer"
        case .copyPath: return "Copier"
        default: return "Ouvrir"
        }
    }

    /// The action of the window for an operation the launcher (or another page) asked for.
    static func forOperation(_ op: ConverterOperation) -> WheelAction? {
        switch op {
        case .imageConvert, .videoContainer, .audioConvert, .documentConvert: return .convert
        case .imageResize: return .resize
        case .imageCompress: return .compress
        case .imageStrip: return .strip
        case .imagesToPDF: return .pdf
        case .videoCompress: return .videoCompress
        case .videoAudio: return .sound
        case .videoGIF: return .gif
        case .pdfMerge: return .merge
        case .pdfSplit: return .pdfSplit
        case .pdfRotate: return .pdfRotate
        case .pdfCompress: return .pdfCompress
        case .pdfToImages: return .pdfImages
        case .archiveZip: return .zip
        case .archiveExtract: return .extract
        case .rename: return .rename
        case .ocr: return .copyText
        case .qrRead: return .qrRead
        case .qrGenerate: return nil
        }
    }

    /// What the window shows first for these files.
    static func suggested(_ family: WheelFamily, count: Int) -> WheelAction {
        switch family {
        case .image, .audio, .document: return .convert
        case .pdf: return count > 1 ? .merge : .pdfCompress
        case .video: return .videoCompress
        case .archive: return .extract
        case .folder, .other: return .zip
        }
    }
}

// MARK: - A drop

/// One of the dropped files.
struct WheelFile: Equatable, Sendable {
    let url: URL
    let kind: ConverterKind

    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    init(url: URL, kind: ConverterKind) {
        self.url = url
        self.kind = kind
    }

    /// Reads only the name (and whether it is a folder): fast enough while a drag is going on.
    init(url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        self.init(url: url, kind: ConverterKind.detect(name: url.lastPathComponent, isDirectory: isDirectory))
    }
}

/// What this Mac can do beyond macOS itself.
struct WheelCapabilities: Equatable, Sendable {
    var ffmpeg = false
    /// nil until the encoders were read: WebP is offered as soon as ffmpeg is there.
    var webp: Bool?
}

/// The two rings of one drop.
struct WheelMenu: Equatable {
    var formats: [WheelAction]
    var tools: [WheelAction]
    var family: WheelFamily
    var count: Int

    static let maxFormats = 4
    static let maxTools = 8

    var isEmpty: Bool { formats.isEmpty && tools.isEmpty }
    var all: [WheelAction] { formats + tools }

    /// The rings for these files: the family's actions (the user's order, else the default one) that accept every file,
    /// without the format they already are, those that need one file or several, or ffmpeg.
    static func make(_ files: [WheelFile], chosen: [WheelAction]?, capabilities: WheelCapabilities) -> WheelMenu {
        let family = WheelFamily.of(files.map(\.kind))
        let list = available(files, in: chosen ?? family.defaultActions, capabilities: capabilities)
        return WheelMenu(formats: Array(list.filter(\.isFormat).prefix(maxFormats)),
                         tools: Array(list.filter { !$0.isFormat }.prefix(maxTools)), family: family, count: files.count)
    }

    /// Every action of `candidates` that suits these files, in that order (the wheel, the list of all actions).
    static func available(_ files: [WheelFile], in candidates: [WheelAction], capabilities: WheelCapabilities) -> [WheelAction] {
        guard !files.isEmpty else { return [] }
        let kinds = Set(files.map(\.kind))
        let exts = Set(files.map(\.ext))
        var seen = Set<WheelAction>()
        return candidates.filter { a in
            guard seen.insert(a).inserted else { return false }
            if !a.universal && !kinds.isSubset(of: a.accepts) { return false }
            if a.singleFile && files.count > 1 { return false }
            if a.needsSeveral && files.count < 2 { return false }
            if a.needsFFmpeg && !capabilities.ffmpeg { return false }
            if a == .webp && capabilities.webp == false { return false }
            // Already in that format (all of them): nothing to do.
            if !a.ownExtensions.isEmpty && exts.isSubset(of: a.ownExtensions) { return false }
            // ALAC and AAC share the .m4a extension: only the one that is not already there would make sense, unknown here.
            if a == .alac && exts.contains("m4a") { return false }
            // A folder or an archive is zipped as it is; an archive is not zipped again.
            if a == .zip && kinds == [.archive] { return false }
            // One kind of file at a time: a photo and a video do not share a format.
            if a == .convert && WheelFamily.of(Array(kinds)) == .other { return false }
            // Images alone are assembled (« En PDF »), not merged.
            if a == .merge && !kinds.contains(.pdf) { return false }
            return true
        }
    }
}

// MARK: - Settings

/// Where the copies go: next to the original, in Téléchargements, or in a folder the user chose (`WheelSettings.folder`).
enum WheelDestination: String, Codable, CaseIterable, Identifiable, Sendable {
    case beside, downloads, folder

    var id: String { rawValue }
}

/// Saved choices (wheel.json).
struct WheelSettings: Codable, Equatable {
    var enabled = true
    /// The wheel opens as soon as a file starts moving (else only after one of the gestures below).
    var instant = true
    /// Past this distance from the wheel's edge, in centimetres on the screen, the wheel goes: the file is only being moved.
    var leaveDistance = 3.5
    /// Press, hold still a moment, then move: the wheel opens as the drag starts.
    var hold = true
    var holdDelay = 0.45
    /// A quick sideways shake of the dragged file.
    var shake = true
    /// ⇧ pressed while dragging.
    var shift = true
    var destination: WheelDestination = .beside
    /// The folder chosen for `.folder`.
    var folder: String?
    /// The last copy made (the tool stays in the sidebar while it is used).
    var lastUsed: Date?
    /// The wheel of each family, as the user arranged it (missing: the default one).
    var layouts: [String: [WheelAction]] = [:]
    /// The hint under the wheel the first few times.
    var opened = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WheelSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        instant = try c.decodeIfPresent(Bool.self, forKey: .instant) ?? d.instant
        leaveDistance = try c.decodeIfPresent(Double.self, forKey: .leaveDistance) ?? d.leaveDistance
        hold = try c.decodeIfPresent(Bool.self, forKey: .hold) ?? d.hold
        holdDelay = try c.decodeIfPresent(Double.self, forKey: .holdDelay) ?? d.holdDelay
        shake = try c.decodeIfPresent(Bool.self, forKey: .shake) ?? d.shake
        shift = try c.decodeIfPresent(Bool.self, forKey: .shift) ?? d.shift
        destination = (try? c.decodeIfPresent(WheelDestination.self, forKey: .destination)) ?? d.destination
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
        // An action that a later version dropped is skipped, not the whole layout.
        let raw = try c.decodeIfPresent([String: [String]].self, forKey: .layouts) ?? [:]
        layouts = raw.mapValues { $0.compactMap(WheelAction.init(rawValue:)) }
        opened = try c.decodeIfPresent(Int.self, forKey: .opened) ?? d.opened
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(instant, forKey: .instant)
        try c.encode(leaveDistance, forKey: .leaveDistance)
        try c.encode(hold, forKey: .hold)
        try c.encode(holdDelay, forKey: .holdDelay)
        try c.encode(shake, forKey: .shake)
        try c.encode(shift, forKey: .shift)
        try c.encode(destination, forKey: .destination)
        try c.encodeIfPresent(folder, forKey: .folder)
        try c.encodeIfPresent(lastUsed, forKey: .lastUsed)
        try c.encode(layouts.mapValues { $0.map(\.rawValue) }, forKey: .layouts)
        try c.encode(opened, forKey: .opened)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, instant, leaveDistance, hold, holdDelay, shake, shift, destination, folder, lastUsed, layouts, opened
    }

    /// At least one way to open it.
    var canOpen: Bool { instant || hold || shake || shift }

    /// The family's wheel: what the user chose, or the default.
    func actions(_ family: WheelFamily) -> [WheelAction] {
        layouts[family.rawValue] ?? family.defaultActions
    }
}
