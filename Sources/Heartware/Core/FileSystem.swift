import Foundation
import Darwin

/// Fast disk usage measurement with fts(3): allocated blocks, symlinks never followed.
enum FileSizer {
    /// Allocated size of a file or of a whole folder tree.
    static func size(of path: String, isCancelled: () -> Bool = { false }) -> Int64 {
        var total: Int64 = 0
        walk(path, isCancelled: isCancelled) { ent in
            switch Int32(ent.pointee.fts_info) {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                if let st = ent.pointee.fts_statp { total += Int64(st.pointee.st_blocks) * 512 }
            default:
                break
            }
            return true
        }
        return total
    }

    static func size(of url: URL) -> Int64 { size(of: url.path) }

    /// Size and number of files.
    static func usage(of path: String) -> (bytes: Int64, files: Int) {
        var total: Int64 = 0
        var files = 0
        walk(path) { ent in
            switch Int32(ent.pointee.fts_info) {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                if let st = ent.pointee.fts_statp { total += Int64(st.pointee.st_blocks) * 512 }
                files += 1
            default:
                break
            }
            return true
        }
        return (total, files)
    }

    /// Low-level walk. The visitor returns false to skip a directory's content.
    static func walk(_ path: String, physical: Bool = true, isCancelled: () -> Bool = { false },
                     visit: (UnsafeMutablePointer<FTSENT>) -> Bool) {
        guard let cpath = strdup(path) else { return }
        defer { free(cpath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        let options = (physical ? FTS_PHYSICAL : FTS_LOGICAL) | FTS_NOCHDIR
        guard let fts = fts_open(&argv, options, nil) else { return }
        defer { fts_close(fts) }
        var n = 0
        while let ent = fts_read(fts) {
            n += 1
            if n & 0x3FF == 0 && isCancelled() { break }
            if !visit(ent), Int32(ent.pointee.fts_info) == FTS_D {
                fts_set(fts, ent, FTS_SKIP)
            }
        }
    }
}

/// Reads that may wait on a slow disk (a network volume, a disk waking up, a folder of the cloud): on their own few
/// threads, never on those Swift's tasks share with the rest of the app, which a stuck volume would otherwise take one
/// by one.
enum DiskQueue {
    static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "heartware.disk"
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .userInitiated
        return q
    }()

    /// nil when the task was cancelled before its turn came (the row went away, another file got selected).
    static func read<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        let cancelled = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                queue.addOperation { c.resume(returning: cancelled.isCancelled ? nil : work()) }
            }
        } onCancel: {
            cancelled.cancel()
        }
    }
}

enum FS {
    static let fm = FileManager.default
    /// A fictional home in demo mode: nothing real is ever looked at or shown.
    static let home: String = DemoData.isEnabled ? DemoData.home : NSHomeDirectory()

    static func expand(_ p: String) -> String {
        if p.hasPrefix("~/") { return home + String(p.dropFirst(1)) }
        if p == "~" { return home }
        return p
    }

    static func exists(_ p: String) -> Bool { fm.fileExists(atPath: p) }

    static func isDirectory(_ p: String) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }

    static func isSymlink(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Names in a folder, hidden files excluded unless asked. Empty on error.
    static func children(_ p: String, hidden: Bool = false) -> [String] {
        guard let names = try? fm.contentsOfDirectory(atPath: p) else { return [] }
        return names.filter { hidden || !$0.hasPrefix(".") }.sorted()
    }

    static func modified(_ p: String) -> Date? {
        if DemoData.isEnabled { return DemoData.modified(p) }
        var st = stat()
        guard lstat(p, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    /// Whether this process may read a folder (false when macOS privacy protection blocks it).
    static func canList(_ p: String) -> Bool {
        guard let d = opendir(p) else { return false }
        closedir(d)
        return true
    }

    /// `$TMPDIR` and the per-user cache folder (`getconf DARWIN_USER_CACHE_DIR`).
    static var userCacheDir: String? { confPath(_CS_DARWIN_USER_CACHE_DIR) }
    static var userTempDir: String? { confPath(_CS_DARWIN_USER_TEMP_DIR) }

    private static func confPath(_ name: Int32) -> String? {
        let len = confstr(name, nil, 0)
        guard len > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: len)
        confstr(name, &buf, len)
        return String(cString: buf)
    }

    /// Shortens `/Users/x/…` to `~/…` for display.
    static func pretty(_ p: String) -> String {
        p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

/// Full Disk Access is needed to read the Trash, Mail, Safari or the privacy databases.
enum Permissions {
    static var hasFullDiskAccess: Bool {
        if DemoData.isEnabled { return true }
        let probes = [
            FS.home + "/Library/Safari",
            FS.home + "/Library/Mail",
            "/Library/Application Support/com.apple.TCC",
            FS.home + "/.Trash"
        ]
        for p in probes {
            if let d = opendir(p) {
                closedir(d)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return false
    }

    static let fullDiskAccessURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
}
