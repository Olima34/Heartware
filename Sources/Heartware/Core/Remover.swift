import Foundation
import AppKit

enum RemovalMode: String {
    /// Deleted for good: only for files apps rebuild by themselves (caches, logs…).
    case delete
    /// Moved to the Trash: anything that might matter to the user.
    case trash
}

struct RemovalEntry {
    var path: String
    var size: Int64
}

struct RemovalReport {
    var removed = 0
    var freed: Int64 = 0
    var failures: [(path: String, reason: String)] = []

    mutating func merge(_ o: RemovalReport) {
        removed += o.removed
        freed += o.freed
        failures += o.failures
    }

    var summary: String {
        if DemoData.isEnabled { return "Mode démo : rien n'a été supprimé, ces fichiers sont fictifs." }
        var s = "\(Fmt.plural(removed, "élément traité", "éléments traités")), \(Fmt.bytes(freed)) libérés."
        if !failures.isEmpty {
            s += " \(Fmt.plural(failures.count, "élément n'a", "éléments n'ont")) pas pu être supprimé\(failures.count > 1 ? "s" : "") (fichiers en cours d'utilisation ou protégés)."
        }
        return s
    }
}

/// The only place where the app deletes anything. Every path goes through `isSafe` and is written to a log.
enum Remover {
    /// Files at the root of the home folder that may be cleared (shell histories).
    static let homeRootFiles: Set<String> = [
        ".zsh_history", ".bash_history", ".python_history", ".node_repl_history", ".lesshst",
        ".viminfo", ".sqlite_history", ".psql_history", ".mysql_history", ".wget-hsts"
    ]

    /// ~/Library folders that are never touched, whatever happens.
    static let protectedLibrary: Set<String> = [
        "Keychains", "Mail", "Messages", "Mobile Documents", "CloudStorage", "Photos", "Accounts",
        "Calendars", "Reminders", "Safari", "Sharing", "Biome", "IdentityServices", "Passes", "PersonalizationPortrait"
    ]

    static func isSafe(_ raw: String) -> Bool {
        let path = (raw as NSString).standardizingPath
        guard path.hasPrefix("/"), !path.contains("/../") else { return false }
        if isExcluded(path) { return false }
        if path.hasPrefix(ActionLog.folder) || path == DataStore.folder || path.hasPrefix(DataStore.folder + "/") { return false }

        let home = FS.home
        if path.hasPrefix(home + "/") {
            let rel = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
            if rel.count == 1 { return homeRootFiles.contains(rel[0]) }
            if rel[0] == "Library" {
                if rel.count < 3 { return false }
                if protectedLibrary.contains(rel[1]) { return false }
            }
            return true
        }
        // Whole app bundles only (uninstaller, old macOS installers).
        if path.hasPrefix("/Applications/") { return path.hasSuffix(".app") }
        if let tmp = FS.userTempDir.map({ ($0 as NSString).standardizingPath }), path.hasPrefix(tmp + "/") { return true }
        return false
    }

    /// An excluded path is never touched, nor is a folder that holds one.
    private static func isExcluded(_ path: String) -> Bool {
        Preferences.exclusions.map { ($0 as NSString).standardizingPath }
            .contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
    }

    enum Refusal: LocalizedError {
        case protected

        var errorDescription: String? { "Heartware ne touche pas à cet emplacement." }
    }

    /// Moves to the Trash a file the user chose (dropped on the wheel) and says where it went, so that it can come back.
    /// Wherever `isSafe` allows, and also inside iCloud Drive or on another disk, never their top folder.
    static func trashChosen(_ url: URL) throws -> URL {
        guard !DemoData.isEnabled else { throw FileOps.Failure.demo }
        // The folder's links resolved ("/Volumes/Macintosh HD/Users/…" is the home folder), not the file's own.
        let path = (url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
                    as NSString).standardizingPath
        let cloud = FS.home + "/Library/Mobile Documents/com~apple~CloudDocs/"
        let elsewhere = (path.hasPrefix(cloud) && path.count > cloud.count)
            || (path.hasPrefix("/Volumes/") && !path.contains("/../") && path.split(separator: "/").count >= 3)
        guard isSafe(path) || (elsewhere && !isExcluded(path)) else {
            ActionLog.write("REFUSÉ \(path)")
            throw Refusal.protected
        }
        var trashed: NSURL?
        try FS.fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &trashed)
        ActionLog.write("CORBEILLE (choisi) \(path)")
        // Always given back on a success; without it « Annuler » says the file did not come back.
        return (trashed as URL?) ?? URL(fileURLWithPath: path)
    }

    static func remove(_ entries: [RemovalEntry], mode: RemovalMode) -> RemovalReport {
        // The demo shows fictional paths: nothing may ever be deleted, whatever they point to.
        if DemoData.isEnabled { return RemovalReport(failures: entries.map { ($0.path, DemoData.refusal) }) }
        let trash = FS.home + "/.Trash/"
        var report = RemovalReport()
        for e in entries {
            // "Always use the Trash" cannot apply to what is already in it: emptying the Trash still deletes.
            let effective: RemovalMode = Preferences.alwaysTrash && !e.path.hasPrefix(trash) ? .trash : mode
            guard isSafe(e.path) else {
                report.failures.append((e.path, "Emplacement protégé"))
                ActionLog.write("REFUSÉ \(e.path)")
                continue
            }
            guard FS.exists(e.path) || FS.isSymlink(e.path) else { continue }
            do {
                switch effective {
                case .delete:
                    try FS.fm.removeItem(atPath: e.path)
                case .trash:
                    try FS.fm.trashItem(at: URL(fileURLWithPath: e.path), resultingItemURL: nil)
                }
                report.removed += 1
                report.freed += e.size
                ActionLog.write("\(effective == .delete ? "SUPPRIMÉ" : "CORBEILLE") \(Fmt.bytes(e.size)) \(e.path)")
            } catch {
                if effective == .trash, recycle(e.path) {
                    report.removed += 1
                    report.freed += e.size
                    ActionLog.write("CORBEILLE \(Fmt.bytes(e.size)) \(e.path)")
                    continue
                }
                // A folder may be partly deleted: count what really went away.
                let left = FS.exists(e.path) ? FileSizer.size(of: e.path) : 0
                report.freed += max(0, e.size - left)
                report.failures.append((e.path, error.localizedDescription))
                ActionLog.write("ÉCHEC \(e.path) : \(error.localizedDescription)")
            }
        }
        return report
    }

    /// Deletes one of the app's own data files (a module's thumbnails, caches…) inside `DataStore.folder`.
    /// The data folder itself and anything outside it are refused.
    @discardableResult
    static func removeInternal(_ raw: String) -> Bool {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return false }
        let path = (raw as NSString).standardizingPath
        guard path.hasPrefix(DataStore.folder + "/"), !path.contains("/../"), FS.exists(path) || FS.isSymlink(path) else { return false }
        do {
            try FS.fm.removeItem(atPath: path)
            ActionLog.write("INTERNE \(path)")
            return true
        } catch {
            ActionLog.write("ÉCHEC \(path) : \(error.localizedDescription)")
            return false
        }
    }

    /// Deletes a half-written output after a failure or a cancel. Allowed anywhere (an external disk too),
    /// but only for a name `FileOps` handed out during this run that was created after that, or for a safe path.
    @discardableResult
    static func discardOutput(_ url: URL) -> Bool {
        let path = (url.path as NSString).standardizingPath
        guard !DemoData.isEnabled, FS.exists(path) || FS.isSymlink(path) else { return false }
        guard FileOps.isOwnOutput(url) || isSafe(path) else {
            ActionLog.write("REFUSÉ \(path)")
            return false
        }
        do {
            try FS.fm.removeItem(atPath: path)
            ActionLog.write("ABANDONNÉ \(path)")
            return true
        } catch {
            ActionLog.write("ÉCHEC \(path) : \(error.localizedDescription)")
            return false
        }
    }

    /// Moves to the Trash a copy the app made during this run, when the user takes it back (the wheel's « Annuler »).
    /// Allowed anywhere, like `discardOutput`, but to the Trash: the user can still put it back.
    @discardableResult
    static func trashOwnOutput(_ url: URL) -> Bool {
        let path = (url.path as NSString).standardizingPath
        guard !DemoData.isEnabled, FS.exists(path) else { return false }
        guard FileOps.isOwnOutput(url) || isSafe(path) else {
            ActionLog.write("REFUSÉ \(path)")
            return false
        }
        do {
            try FS.fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            ActionLog.write("CORBEILLE (copie reprise) \(path)")
            return true
        } catch {
            ActionLog.write("ÉCHEC \(path) : \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Threats

    /// Whether a threat found by the Protection scan may go to the Trash. Wider than `isSafe` (a piece of malware also
    /// lives in /Library, /Users/Shared or /tmp) but never macOS, this app, its data, another user's folder, a folder
    /// such as ~/Documents or /Library/LaunchAgents itself, or a protected ~/Library folder.
    static func isQuarantinable(_ raw: String, isDirectory: Bool? = nil) -> Bool {
        let path = (raw as NSString).standardizingPath
        guard path.hasPrefix("/"), !path.contains("/../") else { return false }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return false }
        let dir = isDirectory ?? (FS.isDirectory(path) && !FS.isSymlink(path))
        let own = [Bundle.main.bundlePath, DataStore.folder, ActionLog.folder].map { ($0 as NSString).standardizingPath }
        if own.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) { return false }
        if isExcluded(path) { return false }
        let home = FS.home
        if path.hasPrefix(home + "/") {
            let rel = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
            if rel[0] == "Library" {
                if rel.count < 2 || (rel.count == 2 && dir) { return false }
                return !protectedLibrary.contains(rel[1])
            }
            // ~/.client is fine, ~/Documents is not; ~/Documents/x.app is.
            return rel.count >= 2 || rel[0].hasPrefix(".") || !dir
        }
        switch parts[0] {
        case "Applications":
            return parts.count >= 2 && (!dir || path.hasSuffix(".app") || parts.count >= 3)
        case "Library":
            let denied: Set<String> = ["Apple", "Keychains", "Preferences", "Updates", "Receipts", "Frameworks", "Extensions",
                                       "SystemExtensions", "Filesystems", "Managed Preferences", "Caches", "Logs", "Fonts"]
            if denied.contains(parts[1]) { return false }
            return parts.count >= 3 || !dir
        case "Users":
            return parts.count >= 3 && parts[1] == "Shared"
        // standardizingPath turns an existing /private/tmp/x into /tmp/x.
        case "private":
            return parts.count >= 3 && (parts[1] == "tmp" || (parts.count >= 4 && parts[1] == "var" && parts[2] == "tmp"))
        case "tmp":
            return parts.count >= 2
        case "var":
            return parts.count >= 3 && parts[1] == "tmp"
        case "usr":
            return parts.count >= 4 && parts[1] == "local"
        case "opt":
            return parts.count >= 4 && !dir
        default:
            return false
        }
    }

    /// Moves a threat to the Trash (never deletes it: the user can look at it, or put it back). Items owned by the
    /// administrator go through the Finder, which asks for the password. Must not run on the main thread.
    static func quarantine(_ raw: String, reason: String) -> RemovalReport {
        if DemoData.isEnabled { return RemovalReport(failures: [(raw, DemoData.refusal)]) }
        let path = (raw as NSString).standardizingPath
        guard FS.exists(path) || FS.isSymlink(path) else { return RemovalReport() }
        guard isQuarantinable(path) else {
            ActionLog.write("REFUSÉ (menace) \(path)")
            return RemovalReport(failures: [(path, "Emplacement protégé")])
        }
        let size = FileSizer.size(of: path)
        do {
            try FS.fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            guard recycle(path) else {
                ActionLog.write("ÉCHEC (menace \(reason)) \(path) : \(error.localizedDescription)")
                return RemovalReport(failures: [(path, error.localizedDescription)])
            }
        }
        ActionLog.write("CORBEILLE (menace \(reason)) \(Fmt.bytes(size)) \(path)")
        return RemovalReport(removed: 1, freed: size)
    }

    /// Asks Finder to move an item to the Trash (handles files owned by root with an admin prompt).
    /// Must not be called from the main thread.
    static func recycle(_ path: String) -> Bool {
        final class Flag: @unchecked Sendable { var ok = false }
        let flag = Flag()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { _, error in
                flag.ok = error == nil
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 120)
        if flag.ok { return true }
        // Items owned by the administrator (apps installed with a .pkg): the Finder itself moves them,
        // and macOS asks for the password exactly like a drag to the Trash would.
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let r = Shell.appleScript("tell application \"Finder\" to delete (POSIX file \"\(escaped)\" as alias)")
        return r.ok && !FS.exists(path)
    }
}

/// A plain text journal of everything the app removed: ~/Library/Logs/Heartware/actions.log
enum ActionLog {
    static let folder = FS.home + "/Library/Logs/Heartware"
    static var file: String { folder + "/actions.log" }
    private static let queue = DispatchQueue(label: "heartware.log")
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private final class Quiet: @unchecked Sendable {
        let lock = NSLock()
        var prefixes: [String] = []
    }
    private static let quiet = Quiet()

    /// Lines about paths under `folder` are not written (a module's scratch folder, such as the converter's previews).
    static func quiet(under folder: String) {
        quiet.lock.lock()
        if !quiet.prefixes.contains(folder) { quiet.prefixes.append(folder) }
        quiet.lock.unlock()
    }

    static func write(_ line: String) {
        quiet.lock.lock()
        let muted = quiet.prefixes.contains { line.contains($0) }
        quiet.lock.unlock()
        if muted { return }
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            try? FS.fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            if let h = FileHandle(forWritingAtPath: file) {
                h.seekToEndOfFile()
                h.write(Data(text.utf8))
                try? h.close()
            } else {
                try? Data(text.utf8).write(to: URL(fileURLWithPath: file))
            }
        }
    }

    /// Waits for the lines written so far (a second at most): the app is about to end on its own.
    static func flush() {
        let written = DispatchGroup()
        queue.async(group: written) {}
        _ = written.wait(timeout: .now() + 1)
    }
}

/// User settings shared by the UI (@AppStorage) and the background code.
enum Preferences {
    static let alwaysTrashKey = "cleanup.alwaysTrash"
    static let exclusionsKey = "cleanup.exclusions"
    static let menuMetricKey = "menubar.metric"
    static let refreshKey = "monitor.refresh"
    static let onboardedKey = "app.onboarded"
    static let alertsKey = "monitor.alerts"

    static var alwaysTrash: Bool { UserDefaults.standard.bool(forKey: alwaysTrashKey) }

    static var exclusions: [String] {
        get { UserDefaults.standard.stringArray(forKey: exclusionsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: exclusionsKey) }
    }
}
