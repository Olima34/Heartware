import Foundation

// The pure side of the automations: rules, schedules and plans. Nothing here touches a file
// except `list`, `execute` and `empty`, which run off the main thread.

// MARK: - Schedules

enum AutomationFrequency: String, Codable, CaseIterable, Identifiable {
    case hourly, daily, weekly, monthly

    var id: String { rawValue }

    var interval: TimeInterval {
        switch self {
        case .hourly: return 3600
        case .daily: return 86400
        case .weekly: return 7 * 86400
        case .monthly: return 30 * 86400
        }
    }

    var title: String {
        switch self {
        case .hourly: return "Toutes les heures"
        case .daily: return "Chaque jour"
        case .weekly: return "Chaque semaine"
        case .monthly: return "Chaque mois"
        }
    }

    var short: String {
        switch self {
        case .hourly: return "Chaque heure"
        case .daily: return "Chaque jour"
        case .weekly: return "Hebdo"
        case .monthly: return "Mensuel"
        }
    }
}

enum AutomationSchedule {
    /// A couple of minutes of slack, so a job checked a bit early is not pushed back by a whole period.
    static let slack: TimeInterval = 120

    static func isDue(last: Date?, every interval: TimeInterval, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval - slack
    }

    static func next(last: Date?, every interval: TimeInterval, now: Date) -> Date {
        guard let last else { return now }
        return max(now, last.addingTimeInterval(interval))
    }
}

// MARK: - Files and rules

enum AutomationFileKind: String, Codable, CaseIterable, Identifiable {
    case images, documents, archives, installers, videos, audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .images: return "Images"
        case .documents: return "Documents"
        case .archives: return "Archives"
        case .installers: return "Installeurs"
        case .videos: return "Vidéos"
        case .audio: return "Audio"
        }
    }

    var symbol: String {
        switch self {
        case .images: return "photo"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        case .installers: return "shippingbox"
        case .videos: return "film"
        case .audio: return "music.note"
        }
    }

    var extensions: Set<String> {
        switch self {
        case .images: return ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "avif", "psd", "raw", "dng", "cr2", "cr3", "nef", "arw"]
        case .documents: return ["pdf", "doc", "docx", "odt", "rtf", "txt", "md", "pages", "key", "numbers", "xls", "xlsx", "ods", "ppt", "pptx", "odp", "csv", "epub"]
        case .archives: return ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst"]
        case .installers: return ["dmg", "pkg", "mpkg", "iso"]
        case .videos: return ["mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv"]
        case .audio: return ["mp3", "m4a", "aac", "wav", "flac", "aif", "aiff", "ogg", "opus"]
        }
    }
}

enum AutomationRuleAction: String, Codable, CaseIterable, Identifiable {
    case move, trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .move: return "Déplacer vers un dossier"
        case .trash: return "Mettre à la Corbeille"
        }
    }
}

/// Minimum ages offered by the rule editor, in days.
enum AutomationAge: Int, CaseIterable, Identifiable {
    case now = 0, day = 1, threeDays = 3, week = 7, month = 30, quarter = 90

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .now: return "Dès l'arrivée"
        case .day: return "1 j"
        case .threeDays: return "3 j"
        case .week: return "7 j"
        case .month: return "30 j"
        case .quarter: return "90 j"
        }
    }
}

/// "If a file is of these types and older than N days, then move it there (or to the Trash)".
struct AutomationRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var enabled = true
    var kinds: [AutomationFileKind] = []
    /// Extra extensions typed by the user ("torrent, epub").
    var extensions: [String] = []
    var minAgeDays = 0
    var action: AutomationRuleAction = .trash
    /// A folder, `~` allowed (expanded at run time). Ignored for the Trash.
    var destination = ""

    init(name: String, enabled: Bool = true, kinds: [AutomationFileKind], extensions: [String] = [], minAgeDays: Int,
         action: AutomationRuleAction, destination: String = "") {
        self.name = name
        self.enabled = enabled
        self.kinds = kinds
        self.extensions = extensions
        self.minAgeDays = minAgeDays
        self.action = action
        self.destination = destination
    }

    /// Tolerant reading: an unknown file kind or a missing field never loses the user's rules.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Règle"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        kinds = (try c.decodeIfPresent([String].self, forKey: .kinds) ?? []).compactMap(AutomationFileKind.init(rawValue:))
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions) ?? []
        minAgeDays = try c.decodeIfPresent(Int.self, forKey: .minAgeDays) ?? 0
        action = (try? c.decodeIfPresent(AutomationRuleAction.self, forKey: .action)) ?? .trash
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? ""
    }

    /// "torrent, .EPUB" → ["torrent", "epub"]
    static func parseExtensions(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).compactMap { raw in
            let e = raw.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
            guard !e.isEmpty, e.allSatisfy({ $0.isLetter || $0.isNumber }), seen.insert(e).inserted else { return nil }
            return e
        }
    }

    var allExtensions: Set<String> {
        kinds.reduce(into: Set(extensions.map { $0.lowercased() })) { $0.formUnion($1.extensions) }
    }

    /// The user still has to pick a folder.
    var isIncomplete: Bool {
        (kinds.isEmpty && extensions.isEmpty) || (action == .move && destination.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func matches(_ f: AutomationFile, now: Date) -> Bool {
        guard enabled, !isIncomplete, !f.ext.isEmpty, allExtensions.contains(f.ext) else { return false }
        let since = f.added ?? f.modified ?? now
        return now.timeIntervalSince(since) >= Double(minAgeDays) * 86400
    }

    /// "Images, .torrent · plus de 7 jours"
    var condition: String {
        var what = kinds.map(\.title)
        what += extensions.map { "." + $0 }
        let types = what.isEmpty ? "Aucun type choisi" : what.joined(separator: ", ")
        return minAgeDays == 0 ? types : "\(types) · plus de \(Fmt.plural(minAgeDays, "jour", "jours"))"
    }

    var outcome: String {
        switch action {
        case .trash: return "Corbeille"
        case .move: return destination.isEmpty ? "Dossier à choisir" : FS.pretty(FS.expand(destination))
        }
    }

    /// A starting set, all inside the automation that is itself off by default.
    static var defaults: [AutomationRule] {
        [
            AutomationRule(name: "Installeurs déjà utilisés", kinds: [.installers], minAgeDays: 7, action: .trash),
            AutomationRule(name: "Images", kinds: [.images], minAgeDays: 1, action: .move, destination: "~/Pictures/Téléchargements"),
            AutomationRule(name: "Documents", enabled: false, kinds: [.documents], minAgeDays: 3, action: .move,
                           destination: "~/Documents/Téléchargements"),
            AutomationRule(name: "Vieilles archives", kinds: [.archives], minAgeDays: 30, action: .trash)
        ]
    }
}

/// A file at the top of the watched folder.
struct AutomationFile: Hashable {
    var path: String
    var name: String
    var size: Int64
    /// When it arrived in the folder (`addedToDirectoryDate`), the best measure of a download's age.
    var added: Date?
    var modified: Date?
    var isDirectory = false
    var isPackage = false

    var ext: String { (name as NSString).pathExtension.lowercased() }
}

/// What one rule will do to one file.
struct AutomationMove: Identifiable, Hashable {
    var id: String { file.path }
    var file: AutomationFile
    var ruleID: UUID
    var ruleName: String
    var action: AutomationRuleAction
    /// Expanded destination folder (nil for the Trash).
    var destination: String?
}

struct AutomationRunResult {
    var moved = 0
    var trashed = 0
    var bytes: Int64 = 0
    var skipped = 0
    var failures: [(path: String, reason: String)] = []

    var summary: String {
        if DemoData.isEnabled { return DemoData.refusal }
        var parts: [String] = []
        if moved > 0 { parts.append("\(Fmt.plural(moved, "fichier rangé", "fichiers rangés"))") }
        if trashed > 0 { parts.append("\(Fmt.plural(trashed, "mis à la Corbeille", "mis à la Corbeille"))") }
        if parts.isEmpty && failures.isEmpty { return "Rien à ranger : tout est déjà en ordre." }
        var s = parts.isEmpty ? "" : parts.joined(separator: ", ") + " (\(Fmt.bytes(bytes)))."
        if !failures.isEmpty {
            s += (s.isEmpty ? "" : " ") + "\(Fmt.plural(failures.count, "fichier n'a", "fichiers n'ont")) pas pu être traité\(failures.count > 1 ? "s" : "")."
        }
        return s
    }
}

// MARK: - Downloads

enum AutomationDownloads {
    /// Downloads in progress (Safari, Chrome, Firefox, Edge, Opera).
    static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]
    /// A file touched less than 10 minutes ago may still be written or opened.
    static let settleDelay: TimeInterval = 600

    static var defaultFolder: String { FS.home + "/Downloads" }

    /// Folders that are documents or libraries for macOS (an app, a Photos or Music library, a Final Cut bundle…):
    /// never watched nor filled by a rule, even before they exist.
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "prefpane", "saver", "xpc", "pkg", "mpkg", "dsym",
        "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "musiclibrary", "tvlibrary", "imovielibrary",
        "theater", "fcpbundle", "logicx", "band", "lrlibrary", "rtfd", "pages", "numbers", "key", "sparsebundle",
        "xcodeproj", "xcworkspace", "xcarchive", "playground", "scptd", "wdgt"
    ]

    /// A folder the automations may watch or fill: inside the home folder, never the home itself, a hidden folder,
    /// ~/Library or a package; on the disk, none of its folders may be a symbolic link (a folder of the home that leads
    /// to /tmp) or a package. Folders not created yet are judged by their names.
    static func isAllowedFolder(_ path: String, home: String = FS.home) -> Bool {
        let p = (path as NSString).standardizingPath
        guard p.hasPrefix(home + "/") else { return false }
        let parts = p.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard let first = parts.first, first != "Library",
              !parts.contains(where: { $0.hasPrefix(".") || packageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) else {
            return false
        }
        var current = home
        for part in parts {
            current += "/" + part
            // Stops at the first folder that does not exist yet (FileOps creates the rest).
            guard let v = try? URL(fileURLWithPath: current).resourceValues(forKeys: [.isSymbolicLinkKey, .isPackageKey]) else { break }
            if v.isSymbolicLink == true || v.isPackage == true { return false }
        }
        return true
    }

    /// The watched folder: Téléchargements, or a folder the user picked on the page (see `AutomationSeal`).
    static func isAllowedSource(_ path: String, home: String = FS.home) -> Bool {
        isAllowedFolder(path, home: home)
    }

    /// Where a rule may move files (`~` allowed).
    static func isAllowedDestination(_ path: String, home: String = FS.home) -> Bool {
        let d = path.trimmingCharacters(in: .whitespaces)
        let expanded = d.hasPrefix("~/") ? home + String(d.dropFirst(1)) : d
        return isAllowedFolder(expanded, home: home)
    }

    static func isIgnored(_ f: AutomationFile, now: Date) -> Bool {
        if f.name.hasPrefix(".") || partialExtensions.contains(f.ext) { return true }
        if f.isDirectory && !f.isPackage { return true }
        if let m = f.modified, now.timeIntervalSince(m) < settleDelay { return true }
        if let a = f.added, now.timeIntervalSince(a) < settleDelay { return true }
        return false
    }

    /// The first matching rule wins; each file is handled once. A rule whose folder is not allowed moves nothing.
    static func plan(_ files: [AutomationFile], rules: [AutomationRule], source: String, now: Date, home: String = FS.home) -> [AutomationMove] {
        let src = (source as NSString).standardizingPath
        return files.compactMap { f -> AutomationMove? in
            guard !isIgnored(f, now: now), let rule = rules.first(where: { $0.matches(f, now: now) }) else { return nil }
            var dest: String?
            if rule.action == .move {
                let d = (FS.expand(rule.destination.trimmingCharacters(in: .whitespaces)) as NSString).standardizingPath
                // Never into the watched folder itself (nothing would change) nor into the file (a package).
                guard d.hasPrefix("/"), d != src, !d.hasPrefix(f.path + "/"), isAllowedFolder(d, home: home) else { return nil }
                dest = d
            }
            return AutomationMove(file: f, ruleID: rule.id, ruleName: rule.name, action: rule.action, destination: dest)
        }
        .sorted { $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending }
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .addedToDirectoryDateKey, .contentModificationDateKey]

    /// The top level of `folder`, or nil when macOS does not let the app read it.
    static func list(_ folder: String) -> [AutomationFile]? {
        guard !DemoData.isEnabled else { return [] }
        let url = URL(fileURLWithPath: folder)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return nil
        }
        return urls.compactMap(file(at:))
    }

    static func file(at url: URL) -> AutomationFile? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let isDir = v.isDirectory ?? false, isPackage = v.isPackage ?? false
        let size = isDir ? (isPackage ? FileSizer.size(of: url.path) : 0) : Int64(v.fileSize ?? 0)
        return AutomationFile(path: url.path, name: url.lastPathComponent, size: size, added: v.addedToDirectoryDate,
                              modified: v.contentModificationDate, isDirectory: isDir, isPackage: isPackage)
    }

    /// Moves through `FileOps` (never over an existing file), trashes through `Remover`.
    /// Each file is looked at again just before: one that changed in the meantime is left alone.
    static func execute(_ moves: [AutomationMove], isCancelled: () -> Bool = { false }) -> AutomationRunResult {
        var r = AutomationRunResult()
        guard !DemoData.isEnabled else { return r }
        for m in moves {
            if isCancelled() { break }
            let url = URL(fileURLWithPath: m.file.path)
            guard let fresh = file(at: url), !isIgnored(fresh, now: Date()) else {
                r.skipped += 1
                continue
            }
            switch m.action {
            case .move:
                guard let dest = m.destination else { r.skipped += 1; continue }
                do {
                    try FileOps.move(url, to: URL(fileURLWithPath: dest).appendingPathComponent(fresh.name))
                    r.moved += 1
                    r.bytes += fresh.size
                } catch {
                    r.failures.append((m.file.path, error.localizedDescription))
                }
            case .trash:
                let report = Remover.remove([RemovalEntry(path: fresh.path, size: fresh.size)], mode: .trash)
                r.trashed += report.removed
                r.bytes += report.freed
                r.failures += report.failures
            }
        }
        return r
    }
}

// MARK: - Trash

enum AutomationTrash {
    struct Item: Identifiable, Hashable {
        var id: String { path }
        var path: String
        var name: String
        var size: Int64
        /// When it was put in the Trash (nil when macOS does not say: such items are kept).
        var added: Date?
    }

    static var folder: String { FS.home + "/.Trash" }

    /// What the Trash holds, or nil without Full Disk Access.
    static func list() -> [Item]? {
        guard !DemoData.isEnabled else { return [] }
        let url = URL(fileURLWithPath: folder)
        guard FS.canList(folder),
              let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.addedToDirectoryDateKey], options: []) else {
            return nil
        }
        return urls.compactMap { u in
            let name = u.lastPathComponent
            guard name != ".DS_Store", name != ".localized" else { return nil }
            let added = (try? u.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
            return Item(path: u.path, name: name, size: FileSizer.size(of: u.path), added: added)
        }
    }

    static func expired(_ items: [Item], days: Int, now: Date) -> [Item] {
        items.filter { item in
            guard let added = item.added else { return false }
            return now.timeIntervalSince(added) >= Double(days) * 86400
        }
        .sorted { ($0.added ?? .distantPast) < ($1.added ?? .distantPast) }
    }

    /// For good: these items are already in the Trash.
    static func empty(_ items: [Item]) -> RemovalReport {
        Remover.remove(items.map { RemovalEntry(path: $0.path, size: $0.size) }, mode: .delete)
    }
}

// MARK: - Scheduled cleanup

/// The scheduled cleanup takes only what the Cleanup page checks by default, and never the Trash
/// (the Trash automation has its own rule) nor personal files.
enum AutomationCleanupPlan {
    static let excludedGroups: Set<CleanupGroup> = [.trash, .personal]

    static func items(_ targets: [CleanupTarget]) -> [CleanupItem] {
        targets.filter { !excludedGroups.contains($0.group) }.flatMap { $0.cleanable.filter(\.defaultOn) }
    }

    static func selection(_ targets: [CleanupTarget]) -> Set<String> {
        Set(items(targets).map(\.id))
    }

    struct Line: Identifiable, Hashable {
        var id: String
        var title: String
        var symbol: String
        var count: Int
        var size: Int64
    }

    static func lines(_ targets: [CleanupTarget]) -> [Line] {
        targets.filter { !excludedGroups.contains($0.group) }.compactMap { t in
            let picked = t.cleanable.filter(\.defaultOn)
            let size = picked.reduce(Int64(0)) { $0 + $1.size }
            guard size > 0 else { return nil }
            return Line(id: t.id, title: t.title, symbol: t.symbol, count: picked.count, size: size)
        }
        .sorted { $0.size > $1.size }
    }
}
