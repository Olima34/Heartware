import Foundation
import CryptoKit
import Darwin

/// One folder (or large file) of the explored tree.
final class StorageNode: Identifiable, @unchecked Sendable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    var size: Int64 = 0
    var files = 0
    /// Bytes of files too small to get their own node.
    var looseBytes: Int64 = 0
    var children: [StorageNode] = []
    weak var parent: StorageNode?
    /// False when sub-folders exist beyond the scanned depth.
    var complete = true
    var modified: Date?

    init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    /// Totals sizes bottom-up and sorts children, biggest first.
    func finalize() {
        var total = looseBytes
        for c in children {
            if c.isDirectory { c.finalize() }
            total += c.size
            files += c.isDirectory ? c.files : 0
        }
        size = total
        children.sort { $0.size > $1.size }
    }

    var ancestors: [StorageNode] {
        var out: [StorageNode] = []
        var n: StorageNode? = self
        while let c = n { out.insert(c, at: 0); n = c.parent }
        return out
    }

    /// Removes a child and updates the totals above it.
    func detach() {
        guard let p = parent else { return }
        p.children.removeAll { $0 === self }
        var a: StorageNode? = p
        while let n = a {
            n.size -= size
            n.files -= isDirectory ? files : 1
            a = n.parent
        }
    }
}

struct BigFile: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let size: Int64
    let modified: Date
    let accessed: Date

    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var lastUse: Date { max(modified, accessed) }

    var kind: FileKind { FileKind(ext: (path as NSString).pathExtension.lowercased()) }
}

enum FileKind: String, CaseIterable, Identifiable {
    case all, video, archive, diskImage, audio, image, document, other
    var id: String { rawValue }

    init(ext: String) {
        switch ext {
        case "mov", "mp4", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mts", "braw", "prores": self = .video
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "xip": self = .archive
        case "dmg", "iso", "img", "pkg", "sparseimage", "sparsebundle", "vmdk", "qcow2", "vdi", "raw": self = .diskImage
        case "mp3", "wav", "aiff", "aif", "flac", "m4a", "caf", "ogg": self = .audio
        case "jpg", "jpeg", "png", "heic", "tiff", "tif", "psd", "raw2", "cr2", "nef", "arw", "dng", "gif", "webp": self = .image
        case "pdf", "key", "pages", "numbers", "docx", "xlsx", "pptx", "doc", "xls", "ppt", "epub": self = .document
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .all: return "Tous"
        case .video: return "Vidéos"
        case .archive: return "Archives"
        case .diskImage: return "Images disque"
        case .audio: return "Audio"
        case .image: return "Images"
        case .document: return "Documents"
        case .other: return "Autres"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "doc"
        case .video: return "film"
        case .archive: return "doc.zipper"
        case .diskImage: return "externaldrive"
        case .audio: return "waveform"
        case .image: return "photo"
        case .document: return "doc.richtext"
        case .other: return "doc"
        }
    }
}

struct StorageScanResult {
    var root: StorageNode
    var bigFiles: [BigFile]
    var unreadable: Int
    var scannedFiles: Int
}

/// One fts pass that builds the folder tree a few levels deep and collects the largest files.
enum StorageScanner {
    static let maxDepth = 6
    static let leafThreshold: Int64 = 50_000_000
    static let bigFileThreshold: Int64 = 50_000_000
    static let skip: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/Network", "/private/var/vm",
                                    "/cores", "/System/Library/AssetsV2"]

    static func scan(_ rootPath: String, isCancelled: @escaping () -> Bool,
                     progress: @escaping (Int, String) -> Void) -> StorageScanResult {
        if DemoData.isEnabled { return DemoData.storage(rootPath) }
        let root = StorageNode(name: rootPath == "/" ? "Macintosh HD" : (rootPath as NSString).lastPathComponent,
                               path: rootPath, isDirectory: true)
        var stack: [StorageNode] = [root]
        var big: [BigFile] = []
        var unreadable = 0
        var count = 0
        let home = FS.home
        let trash = home + "/.Trash/"
        var lastProgress = Date.distantPast

        FileSizer.walk(rootPath, isCancelled: isCancelled) { ent in
            let level = Int(ent.pointee.fts_level)
            let info = Int32(ent.pointee.fts_info)
            switch info {
            case FTS_D:
                if level == 0 { return true }
                let path = String(cString: ent.pointee.fts_path)
                if skip.contains(path) { return false }
                // The Trash and other apps' private data trigger permission prompts or are not ours to map.
                if !Permissions.hasFullDiskAccessCached,
                   path == home + "/Library/Containers" || path == home + "/Library/Group Containers" { return false }
                if level <= maxDepth {
                    let node = StorageNode(name: (path as NSString).lastPathComponent, path: path, isDirectory: true)
                    if let st = ent.pointee.fts_statp {
                        node.modified = Date(timeIntervalSince1970: TimeInterval(st.pointee.st_mtimespec.tv_sec))
                    }
                    if stack.count > level { stack.removeSubrange(level...) }
                    node.parent = stack[level - 1]
                    stack[level - 1].children.append(node)
                    stack.append(node)
                } else if level == maxDepth + 1 {
                    stack[min(maxDepth, stack.count - 1)].complete = false
                }
                return true
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                count += 1
                guard let st = ent.pointee.fts_statp else { return true }
                let bytes = Int64(st.pointee.st_blocks) * 512
                let owner = stack[min(level - 1, stack.count - 1, maxDepth)]
                owner.files += 1
                if bytes >= leafThreshold && level - 1 <= maxDepth {
                    let path = String(cString: ent.pointee.fts_path)
                    let leaf = StorageNode(name: (path as NSString).lastPathComponent, path: path, isDirectory: false)
                    leaf.size = bytes
                    leaf.files = 1
                    leaf.parent = owner
                    leaf.modified = Date(timeIntervalSince1970: TimeInterval(st.pointee.st_mtimespec.tv_sec))
                    owner.children.append(leaf)
                } else {
                    owner.looseBytes += bytes
                }
                // What is already in the Trash would free nothing a second time.
                if bytes >= bigFileThreshold && info == FTS_F, case let path = String(cString: ent.pointee.fts_path), !path.hasPrefix(trash) {
                    big.append(BigFile(path: path, size: bytes,
                                       modified: Date(timeIntervalSince1970: TimeInterval(st.pointee.st_mtimespec.tv_sec)),
                                       accessed: Date(timeIntervalSince1970: TimeInterval(st.pointee.st_atimespec.tv_sec))))
                }
                // At most 4 updates a second, however fast the disk.
                if count % 4000 == 0, Date().timeIntervalSince(lastProgress) >= 0.25 {
                    lastProgress = Date()
                    progress(count, String(cString: ent.pointee.fts_path))
                }
                return true
            case FTS_DNR, FTS_ERR, FTS_NS:
                unreadable += 1
                return true
            default:
                return true
            }
        }
        root.finalize()
        big.sort { $0.size > $1.size }
        return StorageScanResult(root: root, bigFiles: Array(big.prefix(2000)), unreadable: unreadable, scannedFiles: count)
    }
}

extension Permissions {
    /// Read once per launch: the storage scan asks this for every folder.
    nonisolated(unsafe) static var hasFullDiskAccessCached: Bool = Permissions.hasFullDiskAccess
}

// MARK: - Duplicates

struct DuplicateGroup: Identifiable, Hashable {
    let id: String     // content hash
    let size: Int64    // size of one copy
    var paths: [String]
    var wasted: Int64 { size * Int64(max(0, paths.count - 1)) }
}

/// Size → partial hash → full SHA-256. Packages (apps, photo libraries…) are never opened.
enum DuplicateFinder {
    static let packages: Set<String> = ["app", "photoslibrary", "musiclibrary", "tvlibrary", "fcpbundle", "imovielibrary",
                                        "logicx", "band", "xcarchive", "framework", "bundle", "plugin", "kext", "xcodeproj",
                                        "xcworkspace", "sparsebundle", "photolibrary", "aplibrary", "lrdata"]

    static func find(in roots: [String], minSize: Int64 = 1_000_000, isCancelled: @escaping () -> Bool,
                     progress: @escaping (String) -> Void) -> [DuplicateGroup] {
        if DemoData.isEnabled { return DemoData.duplicates() }
        var bySize: [Int64: [String]] = [:]
        var seenInodes = Set<String>()
        var count = 0
        for root in roots {
            FileSizer.walk(root, isCancelled: isCancelled) { ent in
                let info = Int32(ent.pointee.fts_info)
                let path = String(cString: ent.pointee.fts_path)
                if info == FTS_D {
                    let name = (path as NSString).lastPathComponent
                    if ent.pointee.fts_level > 0 && name.hasPrefix(".") { return false }
                    if packages.contains((name as NSString).pathExtension.lowercased()) || name == "node_modules" { return false }
                    return true
                }
                guard info == FTS_F, let st = ent.pointee.fts_statp else { return true }
                let size = Int64(st.pointee.st_size)
                guard size >= minSize else { return true }
                // Hard links are the same file, not a copy.
                guard seenInodes.insert("\(st.pointee.st_dev):\(st.pointee.st_ino)").inserted else { return true }
                bySize[size, default: []].append(path)
                count += 1
                if count % 500 == 0 { progress("\(Fmt.int(count)) fichiers examinés") }
                return true
            }
        }
        var groups: [DuplicateGroup] = []
        let candidates = bySize.filter { $0.value.count > 1 }
        var done = 0
        for (size, paths) in candidates {
            if isCancelled() { break }
            done += 1
            if done % 20 == 0 { progress("Comparaison du contenu… \(done)/\(candidates.count)") }
            // First 64 Ko, then the whole file.
            let byHead = Dictionary(grouping: paths) { hash($0, limit: 65_536) ?? UUID().uuidString }.values.filter { $0.count > 1 }
            for same in byHead {
                let byFull = Dictionary(grouping: same) { hash($0, limit: nil) ?? UUID().uuidString }
                for (h, list) in byFull where list.count > 1 {
                    groups.append(DuplicateGroup(id: h, size: size, paths: list.sorted()))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    static func hash(_ path: String, limit: Int?) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var read = 0
        while true {
            let want = limit.map { min(1 << 20, $0 - read) } ?? (1 << 20)
            if want <= 0 { break }
            guard let data = try? h.read(upToCount: want), !data.isEmpty else { break }
            hasher.update(data: data)
            read += data.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
