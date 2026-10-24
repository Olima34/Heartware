import Foundation

// MARK: - The device

/// What the page shows of a plugged iPhone (or iPad), read through `PhoneBridge`.
struct PhoneInfo: Equatable, Codable {
    var udid: String
    var name: String
    /// « iPhone18,3 ».
    var productType: String
    /// « iPhone », « iPad ».
    var deviceClass: String
    var iosVersion: String
    var build: String
    var storage: PhoneStorage?
    var battery: PhoneBattery?
    /// iCloud backup switched on in the iPhone's settings.
    var cloudBackup: Bool?
    /// The last backup Finder made on this Mac (nil without Full Disk Access, or never).
    var localBackup: Date?

    var model: String { PhoneRules.modelName(productType) ?? deviceClass }
    var symbol: String { deviceClass.lowercased().contains("ipad") ? "ipad" : "iphone" }
}

struct PhoneStorage: Equatable, Codable {
    var total: Int64
    var free: Int64

    var used: Int64 { max(0, total - free) }
    var freeFraction: Double { total > 0 ? Double(free) / Double(total) : 0 }
}

struct PhoneBattery: Equatable, Codable {
    var level: Int?
    var charging = false
    var cycles: Int?
    /// mAh: when new, and what it holds today.
    var design: Int?
    var full: Int?
    var temperature: Double?

    /// What it holds today against when new (Réglages › Batterie › État de la batterie shows about the same).
    var health: Double? {
        guard let design, let full, design > 0, full > 0 else { return nil }
        return min(1, Double(full) / Double(design))
    }
}

/// Where the cable stands.
enum PhoneLink: Equatable {
    case absent
    /// Plugged, being read.
    case reading
    /// Plugged, but it has not trusted this Mac.
    case untrusted
    case ready
}

// MARK: - Photos and videos

/// A photo or a video on the iPhone, as ImageCaptureCore lists it. `id` is the item's handle for this session.
struct PhoneItem: Identifiable, Hashable {
    enum Kind: String { case photo, video }

    let id: String
    var name: String
    var kind: Kind
    /// With its Live Photo video and edits.
    var size: Int64
    var date: Date
    var width: Int
    var height: Int
    var duration: Double = 0
    var burst: String? = nil
    /// Picked in the burst, or marked as favourite.
    var burstKept = false
    var live = false
    var slowMo = false
    var timeLapse = false
    var located = false
    // Filled by the deep analysis.
    /// Vision's overall aesthetics score, -1…1 (macOS 15).
    var score: Float? = nil
    /// Vision: a receipt, a document, a screen… nothing to remember.
    var utility = false
    /// Its series of near-identical shots.
    var series: Int? = nil
    /// The same file, older, kept on the iPhone.
    var duplicateOf: String? = nil

    var ext: String { (name as NSString).pathExtension.uppercased() }
}

enum PhoneCategoryKind: String, CaseIterable, Identifiable {
    case videos, similar, screenshots, recordings, bursts, duplicates, utility, failed
    /// Everything, oldest first: « Tout parcourir », never in the list of what to free.
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videos: return "Grosses vidéos"
        case .similar: return "Séries presque identiques"
        case .screenshots: return "Captures d'écran"
        case .recordings: return "Enregistrements d'écran"
        case .bursts: return "Rafales"
        case .duplicates: return "Doublons exacts"
        case .utility: return "Images utilitaires"
        case .failed: return "Photos sans doute ratées"
        case .all: return "Toutes les photos et vidéos"
        }
    }

    var symbol: String {
        switch self {
        case .videos: return "film"
        case .similar: return "square.on.square"
        case .screenshots: return "camera.viewfinder"
        case .recordings: return "record.circle"
        case .bursts: return "square.stack.3d.down.right"
        case .duplicates: return "plus.square.on.square"
        case .utility: return "doc.text.viewfinder"
        case .failed: return "camera.metering.unknown"
        case .all: return "photo.on.rectangle"
        }
    }

    /// What it holds, and what Heartware keeps.
    var detail: String {
        switch self {
        case .videos: return "Les plus lourdes d'abord : une minute en 4K pèse jusqu'à 400 Mo"
        case .similar: return "Prises à quelques secondes d'écart : la plus réussie de chaque série est gardée"
        case .screenshots: return "Souvent utiles un jour, oubliées ensuite"
        case .recordings: return "Les vidéos de l'écran, souvent longues"
        case .bursts: return "Les vues d'une rafale que tu n'as pas choisies"
        case .duplicates: return "Le même fichier deux fois : l'original reste sur l'iPhone"
        case .utility: return "Tickets, papiers, images reçues : rien d'un souvenir, d'après l'analyse d'images"
        case .failed: return "Floues, sombres ou prises dans la poche, d'après l'analyse d'images"
        case .all: return "Des plus anciennes aux plus récentes, pour choisir toi-même"
        }
    }

    /// Only known once the thumbnails have been looked at.
    var needsAnalysis: Bool { [.similar, .duplicates, .utility, .failed].contains(self) }
}

struct PhoneCategory: Identifiable, Equatable {
    var kind: PhoneCategoryKind
    var ids: [String]
    var size: Int64
    /// Near-identical series: each one's ids, the kept shot first.
    var groups: [[String]] = []

    var id: String { kind.rawValue }
}

/// Where the photo library stands.
enum PhoneLibraryState: Equatable {
    case idle
    /// The iPhone is locked: ImageCaptureCore waits for it.
    case locked
    case listing
    case ready
    case failed(String)
}

/// How a photo leaves the iPhone.
enum PhoneDeletion: Equatable {
    /// iCloud Photos is off: through the cable, at once and for good (a copy is made on the Mac first).
    case cable
    /// iCloud Photos is on: through the Photos library of this Mac, which keeps it 30 days in « Supprimés récemment ».
    case library
    /// iCloud Photos is on but this Mac's library is another one, or the iPhone refuses deletions: copies only.
    case none
}

/// Whether this Mac's Photos library is the iPhone's (iCloud Photos on both, same Apple Account). With iCloud Photos,
/// the iPhone refuses any deletion through the cable (« Delete files failed », seen on iOS 27): this is the only way.
enum PhoneLibrarySync: Equatable {
    /// Not looked yet (no Photos permission, or nothing listed).
    case unknown
    case checking
    /// Most of a sample of the iPhone's photos is in it; the number of photos and videos it holds.
    case synced(Int)
    /// Photos is filling it from iCloud (oldest first): it grew since the last look, or holds part of the sample.
    case syncing(Int)
    case missing(Int)

    /// The photos and videos it held at the last look.
    var total: Int? {
        switch self {
        case .synced(let n), .syncing(let n), .missing(let n): return n
        default: return nil
        }
    }

    /// Not usable yet: looked at again now and then.
    var waiting: Bool {
        switch self {
        case .syncing, .missing: return true
        default: return false
        }
    }
}

/// The work under way on the photos.
struct PhoneTask: Equatable {
    enum Kind: Equatable { case analysis, archive, deletion }

    var kind: Kind
    var done: Int
    var total: Int
    var bytes: Int64 = 0

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// An asset of the Mac's Photos library, as `PhonePhotoLibrary` reads it to find an iPhone item there.
struct PhoneLibraryAsset: Equatable {
    var id: String
    var filename: String
    var date: Date
    var width: Int
    var height: Int
    var video: Bool
}

/// What a search in the Mac's Photos library found.
struct PhoneLibrarySearch: Equatable {
    /// iPhone item → asset.
    var found: [String: String] = [:]
    /// Photos and videos in the library.
    var total = 0
    /// One line per item not found, for the actions log.
    var misses: [String] = []
}

// MARK: - Kept on the Mac

/// One check-up of a device, a day.
struct PhoneHealthPoint: Codable, Equatable {
    /// yyyy-MM-dd.
    var day: String
    var free: Int64
    var total: Int64
    var health: Double?
    var cycles: Int?
    /// Photos and videos on the iPhone, when they were listed that day.
    var media: Int64?
}

struct PhoneHealthDevice: Codable, Equatable {
    var name: String
    var productType: String
    var lastSeen: Date
    var points: [PhoneHealthPoint] = []
}

/// The health notebook: every device plugged into this Mac, a point per day it was seen.
struct PhoneHealthLog: Codable, Equatable {
    var devices: [String: PhoneHealthDevice] = [:]
}

/// A photo or a video put away on the Mac.
struct PhoneArchiveEntry: Codable, Equatable {
    var device: String
    var name: String
    var taken: Date
    var size: Int64
    var path: String
    var archived: Date
    /// Then deleted from the iPhone.
    var freed = false
}

struct PhoneSettings: Codable, Equatable {
    /// Where the originals go, chosen the first time.
    var archiveFolder: String?
}
