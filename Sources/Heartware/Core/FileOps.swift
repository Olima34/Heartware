import Foundation

/// The only way modules create, copy or move files (deletions go through `Remover`).
/// Never overwrites: a name already taken becomes "name 2.ext". Everything is logged; nothing happens in demo mode.
enum FileOps {
    enum Failure: LocalizedError {
        case demo

        var errorDescription: String? { "Mode démo : aucun fichier n'est écrit." }
    }

    /// Names handed out by `uniqueURL` during this run, with when: `Remover.discardOutput` may delete
    /// a half-written output at one of them, even outside the home folder.
    private final class Issued: @unchecked Sendable {
        let lock = NSLock()
        var paths: [String: Date] = [:]
    }
    private static let issued = Issued()

    /// True when `url` is a name this run handed out and the item there was created afterwards.
    static func isOwnOutput(_ url: URL) -> Bool {
        let path = (url.path as NSString).standardizingPath
        issued.lock.lock()
        let since = issued.paths[key(url)]
        issued.lock.unlock()
        guard let since, let created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date else {
            return false
        }
        return created >= since.addingTimeInterval(-2)
    }

    /// The same for a name handed out and for the item written there later: only the folder, which exists both times, is
    /// standardized (macOS shortens "/private/tmp/…" to "/tmp/…" only for what exists).
    private static func key(_ url: URL) -> String {
        (url.deletingLastPathComponent().path as NSString).standardizingPath + "/" + url.lastPathComponent
    }

    /// A free name next to `url`: "photo.jpg", then "photo 2.jpg", "photo 3.jpg"…
    static func uniqueURL(_ url: URL) -> URL {
        let found = freeURL(url)
        issued.lock.lock()
        issued.paths[key(found)] = Date()
        issued.lock.unlock()
        return found
    }

    private static func freeURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Where to write the converted version of `input`: same folder (or `folder`), new extension, unique name.
    static func outputURL(for input: URL, extension ext: String, suffix: String? = nil, folder: URL? = nil) -> URL {
        let dir = folder ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + (suffix.map { " \($0)" } ?? "")
        return uniqueURL(dir.appendingPathComponent(base).appendingPathExtension(ext))
    }

    /// Writes data to a new file and returns where it went.
    @discardableResult
    static func write(_ data: Data, to url: URL) throws -> URL {
        guard !DemoData.isEnabled else { throw Failure.demo }
        let target = uniqueURL(url)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .withoutOverwriting)
        ActionLog.write("CRÉÉ \(Fmt.bytes(Int64(data.count))) \(target.path)")
        return target
    }

    /// Creates a new folder (never an existing one: "Photos 2" if "Photos" is taken) and returns it.
    @discardableResult
    static func makeDirectory(_ url: URL) throws -> URL {
        guard !DemoData.isEnabled else { throw Failure.demo }
        let target = uniqueURL(url)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        ActionLog.write("DOSSIER CRÉÉ \(target.path)")
        return target
    }

    /// Records a file another API wrote itself (AVFoundation, PDFKit…) at a URL obtained from `outputURL`.
    static func didCreate(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        ActionLog.write("CRÉÉ \(Fmt.bytes(size)) \(url.path)")
    }

    @discardableResult
    static func copy(_ src: URL, to dst: URL) throws -> URL {
        guard !DemoData.isEnabled else { throw Failure.demo }
        let target = uniqueURL(dst)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: target)
        ActionLog.write("COPIÉ \(src.path) → \(target.path)")
        return target
    }

    @discardableResult
    static func move(_ src: URL, to dst: URL) throws -> URL {
        guard !DemoData.isEnabled else { throw Failure.demo }
        let target = uniqueURL(dst)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: src, to: target)
        ActionLog.write("DÉPLACÉ \(src.path) → \(target.path)")
        return target
    }

    /// Renames in place (same folder), never over an existing file.
    @discardableResult
    static func rename(_ src: URL, to newName: String) throws -> URL {
        try move(src, to: src.deletingLastPathComponent().appendingPathComponent(newName))
    }
}
