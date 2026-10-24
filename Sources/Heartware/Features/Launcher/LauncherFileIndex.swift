import Foundation
import CoreServices

/// An instant index of the file names of the home folder (and iCloud Drive). It is built once in the background
/// (a few seconds), then kept current by FSEvents, which reports the folders whose content changed: only those
/// are read again. A search scans every name in about a millisecond, where a Spotlight query takes a second or more.
/// Left out: hidden items, ~/Library, dependencies (node_modules, Pods…) and the inside of packages (.app, .photoslibrary…).
final class LauncherFileIndex: @unchecked Sendable {
    struct Hit: Equatable {
        let path: String
        let name: String
        let isDir: Bool
        var score: Double
    }

    enum State: Equatable {
        case off, building, ready(count: Int)
    }

    /// Everything a search needs, frozen: names folded into one buffer, each followed by a 0.
    final class Snapshot: @unchecked Sendable {
        let names: [String]
        let folded: [UInt8]
        let offsets: [Int32]
        let parents: [Int32]
        let isDir: [Bool]
        let dirs: [String]
        let foldedDirs: [[UInt8]]
        let dirDepth: [Int]
        let dirBonus: [Double]

        init(names: [String] = [], folded: [UInt8] = [], offsets: [Int32] = [0], parents: [Int32] = [], isDir: [Bool] = [],
             dirs: [String] = [], foldedDirs: [[UInt8]] = [], dirDepth: [Int] = [], dirBonus: [Double] = []) {
            self.names = names
            self.folded = folded
            self.offsets = offsets
            self.parents = parents
            self.isDir = isDir
            self.dirs = dirs
            self.foldedDirs = foldedDirs
            self.dirDepth = dirDepth
            self.dirBonus = dirBonus
        }

        var count: Int { names.count }
    }

    private struct Child {
        let name: String
        let folded: [UInt8]
        let isDir: Bool
    }

    private enum Kind { case skip, file, package, dir }

    static let skippedDirs: Set<String> = ["node_modules", "bower_components", "DerivedData", "Pods", "__pycache__", "site-packages", "Caches"]
    /// Folders macOS shows as a single file: listed, never entered.
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "pkg", "mpkg", "photoslibrary", "photolibrary", "musiclibrary",
        "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "xcodeproj", "xcworkspace", "xcarchive", "xcassets",
        "playground", "dsym", "rtfd", "pages", "numbers", "key", "sparsebundle", "scptd", "workflow", "nib", "storyboardc", "lpdf"
    ]
    /// About 300 bytes a name in memory: bounded by the Mac's memory (500 000 names on 8 GB, ≈ 150 MB at most), so that
    /// a full home folder never pushes a small Mac into swapping.
    static let maxItems: Int = {
        let gigabytes = ProcessInfo.processInfo.physicalMemory >> 30
        return gigabytes <= 8 ? 500_000 : (gigabytes <= 16 ? 1_000_000 : 1_500_000)
    }()

    let roots: [String]
    let home: String
    var onChange: (@Sendable (State) -> Void)?

    private let queue = DispatchQueue(label: "heartware.fileindex", qos: .utility)
    private let lock = NSLock()
    private var current = Snapshot()
    private var tree: [String: [Child]] = [:]
    private var stream: FSEventStreamRef?
    private var snapshotScheduled = false
    /// The launcher shows: the list follows the changes (on `queue`).
    private var showing = false
    /// Seconds the last rebuild of the snapshot took.
    private var lastSnapshotCost = 0.0
    private var running = false

    init(home: String = FS.home) {
        self.home = home
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        roots = [home] + (FileManager.default.fileExists(atPath: iCloud) ? [iCloud] : [])
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    // MARK: Lifecycle

    func start() {
        // Right after the Mac starts, macOS indexes, syncs and loads a lot: the first reading waits a minute.
        let wait: TimeInterval = ProcessInfo.processInfo.systemUptime < 300 ? 60 : 0
        queue.async { [self] in
            guard !running else { return }
            running = true
            onChange?(.building)
            queue.asyncAfter(deadline: .now() + wait) { [self] in
                guard running, tree.isEmpty else { return }
                fullBuild()
                startWatching()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
            tree = [:]
            publish(Snapshot())
            onChange?(.off)
        }
    }

    /// Builds the index right away on the calling thread (`--dump`), without watching for changes.
    func buildNow() -> (count: Int, seconds: Double) {
        let t = Date()
        queue.sync { fullBuild() }
        return (snapshot.count, Date().timeIntervalSince(t))
    }

    /// The file window opens: changes waiting for their rebuild are taken in now (a file just downloaded is found at
    /// once), and the list follows the changes while it shows.
    func catchUp() {
        queue.async { [self] in
            showing = true
            guard running, let stream else { return }
            FSEventStreamFlushAsync(stream)
            queue.asyncAfter(deadline: .now() + 0.2) { [self] in
                guard running, snapshotScheduled else { return }
                snapshotScheduled = false
                makeSnapshot()
            }
        }
    }

    /// The file window closed: the folders changed are still read again as they change (a few names), but the whole
    /// list is rebuilt only at its next opening. A build or a download that writes for an hour costs nothing meanwhile.
    func setShowing(_ on: Bool) {
        queue.async { [self] in showing = on }
    }

    /// Reads everything again (once a day, or on request), without stopping the searches meanwhile.
    func rebuild() {
        queue.async { [self] in
            guard running else { return }
            fullBuild()
        }
    }

    private func fullBuild() {
        // The old tree goes first (the snapshot keeps answering the searches meanwhile): never two trees in memory at once.
        tree = [:]
        var fresh: [String: [Child]] = [:]
        var count = 0
        // The folders that matter most first: if the home folder holds more than the index may keep, it is the rest
        // that is left out, never the Desktop, Documents, Downloads or iCloud Drive.
        let firsts = ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 }.filter(FS.isDirectory)
        Self.throttled {
            for root in firsts + roots.dropFirst() { Self.scan(root, home: home, into: &fresh, count: &count) }
            Self.scan(home, home: home, into: &fresh, count: &count, listedOnly: Set(firsts))
        }
        tree = fresh
        makeSnapshot()
    }

    /// Reads the disk at the lowest priority: the other apps' reads and writes always go first.
    private static func throttled(_ work: () -> Void) {
        let before = getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)
        defer { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, before) }
        work()
    }

    // MARK: Reading the disk

    private static func fold(_ s: String) -> [UInt8] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).utf8)
    }

    private static func kind(_ name: String, isDir: Bool) -> Kind {
        if name.hasPrefix(".") || name == "Icon\r" { return .skip }
        guard isDir else { return .file }
        if skippedDirs.contains(name) { return .skip }
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, packageExtensions.contains(ext) { return .package }
        return .dir
    }

    /// True for a folder the index reads (not hidden, not in ~/Library, not a package nor inside one, not a dependency folder).
    /// A package (.xcodeproj, .pages…) is listed in its parent but never read: FSEvents reports it when its content changes.
    func isIndexable(_ path: String) -> Bool {
        Self.isIndexable(path, roots: roots, home: home)
    }

    static func isIndexable(_ path: String, roots: [String], home: String) -> Bool {
        // The deepest root wins: iCloud Drive lives under ~/Library, which is otherwise left out.
        guard let root = roots.filter({ path == $0 || path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else { return false }
        if path == root { return true }
        let parts = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        if root == home, parts.first == "Library" { return false }
        return !parts.contains { kind($0, isDir: true) != .dir }
    }

    /// Walks a folder with fts(3), without stat (the directory entries say what is a folder). `listedOnly`: folders read
    /// already, only listed in their parent.
    private static func scan(_ root: String, home: String, into tree: inout [String: [Child]], count: inout Int,
                             listedOnly: Set<String> = []) {
        // Known even when the index is full: a later change there must not look like a folder never read.
        if tree[root] == nil { tree[root] = [] }
        guard count < maxItems else { return }
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(root), nil]
        defer { free(argv[0]) }
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_NOSTAT, nil) else { return }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            let info = Int32(ent.pointee.fts_info)
            let level = Int(ent.pointee.fts_level)
            guard level > 0, info != FTS_DP, info != FTS_DNR, info != FTS_ERR, let raw = ent.pointee.fts_path else { continue }
            let pathLength = Int(ent.pointee.fts_pathlen), nameLength = Int(ent.pointee.fts_namelen)
            let path = String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(raw), count: pathLength), as: UTF8.self)
            let name = String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(raw + (pathLength - nameLength)), count: nameLength), as: UTF8.self)
            let parent = String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(raw), count: max(0, pathLength - nameLength - 1)), as: UTF8.self)
            let isDir = info == FTS_D
            var k = kind(name, isDir: isDir)
            // ~/Library holds the system's and the apps' files, not the user's: left out (iCloud Drive is its own root).
            if isDir, level == 1, root == home, name == "Library" { k = .skip }
            if isDir, level == 1, listedOnly.contains(path) {
                fts_set(fts, ent, FTS_SKIP)
                tree[parent, default: []].append(Child(name: name, folded: fold(name), isDir: true))
                continue
            }
            switch k {
            case .skip:
                if isDir { fts_set(fts, ent, FTS_SKIP) }
                continue
            case .package:
                fts_set(fts, ent, FTS_SKIP)
                tree[parent, default: []].append(Child(name: name, folded: fold(name), isDir: false))
            case .file:
                tree[parent, default: []].append(Child(name: name, folded: fold(name), isDir: false))
            case .dir:
                tree[parent, default: []].append(Child(name: name, folded: fold(name), isDir: true))
                if tree[path] == nil { tree[path] = [] }
            }
            count += 1
            if count >= maxItems { return }
        }
    }

    // MARK: Live updates

    private func startWatching() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let index = Unmanaged<LauncherFileIndex>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self)
            var events: [(String, FSEventStreamEventFlags)] = []
            for i in 0..<count {
                if let p = list[i] as? String { events.append((p, flags[i])) }
            }
            index.handle(events)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        // Changes are gathered for 2 s: a download or an unzip wakes the index a few times, not at every file.
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, roots as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else { return }
        // The folders of ~/Library where the apps write all day long (never indexed): the system no longer wakes the
        // index for them. iCloud Drive (~/Library/Mobile Documents) is still watched.
        let busy = ["Caches", "Containers", "Group Containers", "Application Support", "Logs", "Developer", "Saved Application State",
                    "HTTPStorages"].map { home + "/Library/" + $0 }
        _ = FSEventStreamSetExclusionPaths(s, busy as CFArray)
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    /// Called on `queue`: FSEvents gives the folders whose content changed.
    private func handle(_ events: [(String, FSEventStreamEventFlags)]) {
        guard running else { return }
        Self.throttled { apply(events) }
    }

    private func apply(_ events: [(String, FSEventStreamEventFlags)]) {
        let deep = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        var seen = Set<String>()
        var changed = false
        for (raw, flag) in events {
            let path = raw.hasSuffix("/") && raw.count > 1 ? String(raw.dropLast()) : raw
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                fullBuild()
                return
            }
            guard seen.insert(path).inserted, isIndexable(path) else { continue }
            if flag & deep != 0 {
                rescanSubtree(path)
                changed = true
            } else if rescanFolder(path) {
                changed = true
            }
        }
        // Apps write in ~/Library and in hidden folders all the time, and files change without being renamed:
        // the whole list is rebuilt only when an indexed name appeared or went away.
        if changed { scheduleSnapshot() }
    }

    /// Reads one folder again. Returns whether its indexed names changed.
    @discardableResult
    private func rescanFolder(_ dir: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            let known = tree[dir] != nil
            forget(dir)
            return known
        }
        guard tree[dir] != nil else {
            // A folder the index did not know yet (just created or moved in): read it whole.
            rescanSubtree(dir)
            return true
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let before = (tree[dir] ?? []).map { "\($0.isDir ? "d" : "f")\($0.name)" }
        var oldDirs = Set((tree[dir] ?? []).filter(\.isDir).map(\.name))
        var children: [Child] = []
        for name in names {
            // ~/Library is never indexed (iCloud Drive inside it is its own root): a change in the home folder, the
            // shell's history for instance, must not read all of it.
            if dir == home, name == "Library" { continue }
            var childIsDir: ObjCBool = false
            let full = dir + "/" + name
            FileManager.default.fileExists(atPath: full, isDirectory: &childIsDir)
            switch Self.kind(name, isDir: childIsDir.boolValue) {
            case .skip: continue
            case .file, .package: children.append(Child(name: name, folded: Self.fold(name), isDir: false))
            case .dir:
                children.append(Child(name: name, folded: Self.fold(name), isDir: true))
                oldDirs.remove(name)
                if tree[full] == nil {
                    var count = 0
                    Self.scan(full, home: home, into: &tree, count: &count)
                }
            }
        }
        for gone in oldDirs { removeSubtree(dir + "/" + gone) }
        tree[dir] = children
        return !oldDirs.isEmpty || Set(before) != Set(children.map { "\($0.isDir ? "d" : "f")\($0.name)" })
    }

    private func rescanSubtree(_ dir: String) {
        removeSubtree(dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            forget(dir)
            return
        }
        var count = 0
        Self.scan(dir, home: home, into: &tree, count: &count)
        // Make sure the parent lists it.
        let parent = (dir as NSString).deletingLastPathComponent
        let name = (dir as NSString).lastPathComponent
        if var siblings = tree[parent], !siblings.contains(where: { $0.name == name }) {
            siblings.append(Child(name: name, folded: Self.fold(name), isDir: true))
            tree[parent] = siblings
        }
    }

    /// A folder that is gone: its content and its line in its parent.
    private func forget(_ dir: String) {
        removeSubtree(dir)
        let parent = (dir as NSString).deletingLastPathComponent
        let name = (dir as NSString).lastPathComponent
        if var siblings = tree[parent] {
            siblings.removeAll { $0.name == name }
            tree[parent] = siblings
        }
    }

    private func removeSubtree(_ dir: String) {
        tree[dir] = nil
        let prefix = dir + "/"
        for key in tree.keys where key.hasPrefix(prefix) { tree[key] = nil }
    }

    private func scheduleSnapshot() {
        guard !snapshotScheduled else { return }
        snapshotScheduled = true
        // File window closed: noted only, rebuilt when it opens (`catchUp`).
        guard showing else { return }
        // A burst of changes (a download, an unzip, a build) costs one rebuild, not one per second; and a big index,
        // whose rebuild takes long, waits ten times that long before the next one (a build that never stops writing
        // costs a tenth of a core at most).
        queue.asyncAfter(deadline: .now() + max(1.5, lastSnapshotCost * 10)) { [self] in
            // Taken in already (the file window opened meanwhile).
            guard snapshotScheduled else { return }
            snapshotScheduled = false
            makeSnapshot()
        }
    }

    private func makeSnapshot() {
        let start = DispatchTime.now().uptimeNanoseconds
        publish(Self.snapshot(of: tree, home: home))
        lastSnapshotCost = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        onChange?(.ready(count: snapshot.count))
    }

    private func publish(_ s: Snapshot) {
        lock.lock()
        current = s
        lock.unlock()
    }

    private static func snapshot(of tree: [String: [Child]], home: String) -> Snapshot {
        var names: [String] = [], folded: [UInt8] = [], offsets: [Int32] = [], parents: [Int32] = [], isDir: [Bool] = []
        var dirs: [String] = [], foldedDirs: [[UInt8]] = [], depth: [Int] = [], bonus: [Double] = []
        let total = tree.values.reduce(0) { $0 + $1.count }
        names.reserveCapacity(total)
        offsets.reserveCapacity(total + 1)
        parents.reserveCapacity(total)
        isDir.reserveCapacity(total)
        folded.reserveCapacity(total * 20)
        let favourites = ["/Desktop", "/Documents", "/Downloads", "/Library/Mobile Documents/com~apple~CloudDocs"].map { home + $0 }
        for (dir, children) in tree where !children.isEmpty {
            let index = Int32(dirs.count)
            dirs.append(dir)
            let relative = dir.hasPrefix(home) ? String(dir.dropFirst(home.count)) : dir
            foldedDirs.append(fold(relative))
            depth.append(relative.split(separator: "/").count)
            bonus.append(favourites.contains { dir == $0 || dir.hasPrefix($0 + "/") } ? 25 : 0)
            for c in children {
                names.append(c.name)
                offsets.append(Int32(folded.count))
                folded.append(contentsOf: c.folded)
                folded.append(0)
                parents.append(index)
                isDir.append(c.isDir)
            }
        }
        offsets.append(Int32(folded.count))
        return Snapshot(names: names, folded: folded, offsets: offsets, parents: parents, isDir: isDir,
                        dirs: dirs, foldedDirs: foldedDirs, dirDepth: depth, dirBonus: bonus)
    }

    /// An index made from a list of paths, without touching the disk (demo mode and self-tests).
    static func snapshot(paths: [(path: String, isDir: Bool)], home: String) -> Snapshot {
        var tree: [String: [Child]] = [:]
        for p in paths {
            let parent = (p.path as NSString).deletingLastPathComponent
            let name = (p.path as NSString).lastPathComponent
            tree[parent, default: []].append(Child(name: name, folded: fold(name), isDir: p.isDir))
        }
        return snapshot(of: tree, home: home)
    }

    // MARK: Search

    /// Names that contain every word of `query` (accents and case ignored); a word may also match a parent folder.
    /// Ranked by how well the name matches, then by recent changes, location and depth.
    static func search(_ query: String, in s: Snapshot, limit: Int = 40, now: Date = Date(), checkDates: Bool = true) -> [Hit] {
        let tokens = query.split(separator: " ").map { fold(String($0)) }.filter { !$0.isEmpty }
        guard s.count > 0, !tokens.isEmpty else { return [] }
        let whole = fold(query.trimmingCharacters(in: .whitespaces))
        // One word must be in the name itself: the longest first (the fewest candidates), then the next ones,
        // until something matches ("administratif avis" finds Administratif/Avis d'imposition.pdf).
        var tried: [[UInt8]] = []
        // Only the best ones are kept while scanning: two letters match hundreds of thousands of names, never all sorted.
        let keep = checkDates ? max(160, limit) : limit
        var candidates: [(index: Int, score: Double)] = []
        for primary in tokens.sorted(by: { $0.count > $1.count }) where !tried.contains(primary) {
            tried.append(primary)
            candidates = matches(in: s, primary: primary, others: tokens.filter { $0 != primary }, whole: whole, keep: keep)
            if !candidates.isEmpty { break }
        }
        // Dates only for the best candidates: a stat each, a few microseconds.
        candidates.sort { $0.score > $1.score }
        var hits: [Hit] = []
        for c in candidates.prefix(keep) {
            let dir = s.dirs[Int(s.parents[c.index])]
            let path = dir + "/" + s.names[c.index]
            var score = c.score
            if checkDates {
                var st = stat()
                if stat(path, &st) == 0 {
                    let age = now.timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec)
                    if age < 86_400 { score += 90 } else if age < 7 * 86_400 { score += 60 } else if age < 30 * 86_400 { score += 30 } else if age < 365 * 86_400 { score += 10 }
                }
            }
            hits.append(Hit(path: path, name: s.names[c.index], isDir: s.isDir[c.index], score: score))
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    /// The `keep` best names that contain `primary`, whose other words are in the name or its folder, with their base score.
    private static func matches(in s: Snapshot, primary: [UInt8], others: [[UInt8]], whole: [UInt8], keep: Int) -> [(index: Int, score: Double)] {
        var best = LauncherFileTop(keep)
        s.folded.withUnsafeBufferPointer { buf in
            let n = primary.count
            let first = primary[0]
            for i in 0..<s.count {
                let start = Int(s.offsets[i]), end = Int(s.offsets[i + 1]) - 1
                guard end - start >= n else { continue }
                var position = -1
                var j = start
                let last = end - n
                while j <= last {
                    if buf[j] == first {
                        var k = 1
                        while k < n && buf[j + k] == primary[k] { k += 1 }
                        if k == n { position = j; break }
                    }
                    j += 1
                }
                guard position >= 0 else { continue }
                var inFolder = 0
                var ok = true
                for t in others {
                    if contains(buf, start, end, t) { continue }
                    if contains(s.foldedDirs[Int(s.parents[i])], t) { inFolder += 1; continue }
                    ok = false
                    break
                }
                guard ok else { continue }
                best.add(i, baseScore(buf, start: start, end: end, position: position, primary: primary, whole: whole,
                                      inFolder: inFolder, snapshot: s, index: i))
            }
        }
        return best.items
    }

    private static func baseScore(_ buf: UnsafeBufferPointer<UInt8>, start: Int, end: Int, position: Int, primary: [UInt8], whole: [UInt8],
                                  inFolder: Int, snapshot s: Snapshot, index: Int) -> Double {
        let length = end - start
        // Name without its extension.
        var stem = end
        var k = end - 1
        while k > start {
            if buf[k] == UInt8(ascii: ".") { stem = k; break }
            k -= 1
        }
        var score: Double
        if equals(buf, start, end, whole) || equals(buf, start, stem, whole) {
            score = 1000
        } else if position == start {
            score = 720
        } else if !isWordByte(buf[position - 1]) {
            score = 560
        } else {
            score = 400
        }
        score -= min(60, Double(max(0, length - primary.count)) * 0.6)
        score -= Double(inFolder) * 40
        let dir = Int(s.parents[index])
        score -= Double(max(0, s.dirDepth[dir] - 3)) * 6
        score += s.dirBonus[dir]
        if s.isDir[index] { score += 8 }
        return score
    }

    private static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || b >= 0x80
    }

    private static func equals(_ buf: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, _ t: [UInt8]) -> Bool {
        guard end - start == t.count else { return false }
        for i in 0..<t.count where buf[start + i] != t[i] { return false }
        return true
    }

    private static func contains(_ buf: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, _ t: [UInt8]) -> Bool {
        let n = t.count
        guard n > 0, end - start >= n else { return n == 0 }
        var j = start
        while j <= end - n {
            if buf[j] == t[0] {
                var k = 1
                while k < n && buf[j + k] == t[k] { k += 1 }
                if k == n { return true }
            }
            j += 1
        }
        return false
    }

    private static func contains(_ hay: [UInt8], _ t: [UInt8]) -> Bool {
        hay.withUnsafeBufferPointer { contains($0, 0, hay.count, t) }
    }
}

/// The `capacity` best scores seen, without keeping the others: a heap whose root is the weakest one kept.
struct LauncherFileTop {
    private(set) var items: [(index: Int, score: Double)] = []
    let capacity: Int

    init(_ capacity: Int) {
        self.capacity = max(1, capacity)
        items.reserveCapacity(self.capacity)
    }

    mutating func add(_ index: Int, _ score: Double) {
        if items.count < capacity {
            items.append((index, score))
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard items[i].score < items[parent].score else { break }
                items.swapAt(i, parent)
                i = parent
            }
        } else if score > items[0].score {
            items[0] = (index, score)
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var low = i
                if l < items.count, items[l].score < items[low].score { low = l }
                if r < items.count, items[r].score < items[low].score { low = r }
                if low == i { break }
                items.swapAt(i, low)
                i = low
            }
        }
    }
}
