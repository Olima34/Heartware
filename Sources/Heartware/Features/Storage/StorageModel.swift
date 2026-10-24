import Foundation
import AppKit
import Observation

enum StorageTab: String, CaseIterable, Identifiable {
    case explorer, bigFiles, duplicates
    var id: String { rawValue }
    var title: String {
        switch self {
        case .explorer: return "Explorateur"
        case .bigFiles: return "Gros fichiers"
        case .duplicates: return "Doublons"
        }
    }
}

struct SizeFilter: Identifiable, Hashable {
    let bytes: Int64
    var id: Int64 { bytes }
    var title: String { "> " + Fmt.bytes(bytes) }
    static let all = [50_000_000, 100_000_000, 500_000_000, 1_000_000_000].map { SizeFilter(bytes: Int64($0)) }
}

struct AgeFilter: Identifiable, Hashable {
    let days: Int
    var id: Int { days }
    var title: String {
        switch days {
        case 0: return "Peu importe"
        case 180: return "> 6 mois"
        default: return "> \(days / 365) an\(days >= 730 ? "s" : "")"
        }
    }
    static let all = [0, 180, 365, 730].map(AgeFilter.init)
}

@Observable
@MainActor
final class StorageModel {
    var tab: StorageTab = .explorer
    var rootPath: String = FS.home
    var root: StorageNode?
    var current: StorageNode?
    /// Bumped whenever the (non-observable) tree changes.
    var version = 0
    var isScanning = false
    var scannedCount = 0
    var scanningPath = ""
    var unreadable = 0
    var lastScan: Date?
    var message: String?
    /// False when `message` reports a failure (shown as a warning, not as "done").
    var messageOK = true

    var bigFiles: [BigFile] = []
    var bigSelection: Set<String> = []
    var sizeFilter = SizeFilter.all[1]
    var ageFilter = AgeFilter.all[0]
    var kindFilter: FileKind = .all

    var dupRoots: [String] = ["Downloads", "Desktop", "Documents", "Pictures", "Movies", "Music"]
        .map { FS.home + "/" + $0 }.filter { DemoData.isEnabled || FS.exists($0) }
    var dupGroups: [DuplicateGroup] = []
    var dupSelection: Set<String> = []
    var isFindingDups = false
    var dupProgress = ""
    var dupsScanned = false
    var isRemoving = false

    @ObservationIgnored private var cancelFlag = CancelFlag()
    /// The duplicate search has its own: cancelling it must not stop the explorer, and the other way round.
    @ObservationIgnored private var dupFlag = CancelFlag()

    var rootTitle: String {
        switch rootPath {
        case FS.home: return "Dossier personnel"
        case "/Applications": return "Applications"
        case "/": return "Disque entier"
        default: return (rootPath as NSString).lastPathComponent
        }
    }

    // MARK: Explorer

    func scan(_ path: String? = nil) async {
        if let path { rootPath = path }
        guard !isScanning else { return }
        isScanning = true
        scannedCount = 0
        scanningPath = ""
        message = nil
        Permissions.hasFullDiskAccessCached = Permissions.hasFullDiskAccess
        let flag = CancelFlag()
        cancelFlag = flag
        let target = rootPath
        let result = await Task.detached(priority: .userInitiated) {
            StorageScanner.scan(target, isCancelled: { flag.isCancelled }) { n, p in
                Task { @MainActor in
                    self.scannedCount = n
                    self.scanningPath = p
                }
            }
        }.value
        // A scan cancelled then replaced by a newer one must not mark the newer one as finished.
        if cancelFlag === flag { isScanning = false }
        guard !flag.isCancelled else { return }
        root = result.root
        rootPath = result.root.path
        current = result.root
        bigFiles = result.bigFiles
        bigSelection = []
        unreadable = result.unreadable
        lastScan = Date()
        version += 1
    }

    func cancel() {
        cancelFlag.cancel()
        isScanning = false
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Explorer"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await scan(url.path) }
        }
    }

    func open(_ node: StorageNode) {
        guard node.isDirectory else {
            Finder.reveal(node.path)
            return
        }
        current = node
        version += 1
        if !node.complete { Task { await deepen(node) } }
    }

    func goUp() {
        if let p = current?.parent { current = p; version += 1 }
    }

    /// Scans a folder that was beyond the first pass' depth and grafts the result.
    private func deepen(_ node: StorageNode) async {
        isScanning = true
        let flag = CancelFlag()
        cancelFlag = flag
        let path = node.path
        let result = await Task.detached(priority: .userInitiated) {
            StorageScanner.scan(path, isCancelled: { flag.isCancelled }) { _, _ in }
        }.value
        if cancelFlag === flag { isScanning = false }
        guard !flag.isCancelled else { return }
        node.children = result.root.children
        node.children.forEach { $0.parent = node }
        node.looseBytes = result.root.looseBytes
        node.complete = true
        version += 1
    }

    func trash(_ node: StorageNode) async {
        let entry = RemovalEntry(path: node.path, size: node.size)
        let report = await Task.detached { Remover.remove([entry], mode: .trash) }.value
        if report.removed > 0 {
            if current === node { current = node.parent }
            node.detach()
            bigFiles.removeAll { $0.path == node.path || $0.path.hasPrefix(node.path + "/") }
            bigSelection = bigSelection.filter { $0 != node.path && !$0.hasPrefix(node.path + "/") }
            messageOK = true
            message = "« \(node.name) » est dans la Corbeille (\(Fmt.bytes(node.size)))."
        } else {
            messageOK = false
            message = "Impossible de mettre « \(node.name) » à la Corbeille : \(report.failures.first?.reason ?? "emplacement protégé")."
        }
        version += 1
    }

    // MARK: Big files

    var visibleBigFiles: [BigFile] {
        let limit = Date().addingTimeInterval(-Double(ageFilter.days) * 86400)
        return bigFiles.filter { f in
            f.size >= sizeFilter.bytes && (ageFilter.days == 0 || f.lastUse < limit) && (kindFilter == .all || f.kind == kindFilter)
        }
    }

    var selectedBigSize: Int64 { bigFiles.filter { bigSelection.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func trashBigFiles() async {
        let chosen = bigFiles.filter { bigSelection.contains($0.id) }
        guard !chosen.isEmpty, !isRemoving else { return }
        isRemoving = true
        let report = await Task.detached { Remover.remove(chosen.map { RemovalEntry(path: $0.path, size: $0.size) }, mode: .trash) }.value
        let failed = Set(report.failures.map(\.path))
        bigFiles.removeAll { bigSelection.contains($0.id) && !failed.contains($0.id) }
        bigSelection = bigSelection.intersection(failed)
        messageOK = report.failures.isEmpty
        message = "Gros fichiers : \(report.summary)"
        isRemoving = false
    }

    // MARK: Duplicates

    func addDupRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Ajouter"
        if panel.runModal() == .OK {
            for url in panel.urls where !dupRoots.contains(url.path) { dupRoots.append(url.path) }
        }
    }

    func findDuplicates() async {
        guard !isFindingDups, !dupRoots.isEmpty else { return }
        isFindingDups = true
        dupProgress = "Inventaire des fichiers…"
        let roots = dupRoots
        let flag = CancelFlag()
        dupFlag = flag
        let groups = await Task.detached(priority: .userInitiated) {
            DuplicateFinder.find(in: roots, isCancelled: { flag.isCancelled }) { text in
                Task { @MainActor in self.dupProgress = text }
            }
        }.value
        if dupFlag === flag { isFindingDups = false }
        guard !flag.isCancelled else { return }
        dupGroups = groups
        dupsScanned = true
        autoSelectDuplicates()
    }

    /// In each group, keeps the oldest copy and selects the others.
    func autoSelectDuplicates() {
        var sel = Set<String>()
        for g in dupGroups {
            let keep = g.paths.min { (FS.modified($0) ?? .distantFuture) < (FS.modified($1) ?? .distantFuture) } ?? g.paths[0]
            for p in g.paths where p != keep { sel.insert(p) }
        }
        dupSelection = sel
    }

    var dupWasted: Int64 { dupGroups.reduce(0) { $0 + $1.wasted } }

    var selectedDupSize: Int64 {
        dupGroups.reduce(0) { total, g in total + Int64(g.paths.filter { dupSelection.contains($0) }.count) * g.size }
    }

    /// True if a group would lose every copy.
    var dupSelectionUnsafe: Bool { dupGroups.contains { g in g.paths.allSatisfy { dupSelection.contains($0) } } }

    func trashDuplicates() async {
        guard !dupSelectionUnsafe, !isRemoving else { return }
        let entries = dupGroups.flatMap { g in g.paths.filter { dupSelection.contains($0) }.map { RemovalEntry(path: $0, size: g.size) } }
        guard !entries.isEmpty else { return }
        isRemoving = true
        let report = await Task.detached { Remover.remove(entries, mode: .trash) }.value
        let failed = Set(report.failures.map(\.path))
        for i in dupGroups.indices {
            dupGroups[i].paths.removeAll { dupSelection.contains($0) && !failed.contains($0) }
        }
        dupGroups.removeAll { $0.paths.count < 2 }
        dupSelection = dupSelection.intersection(failed)
        messageOK = report.failures.isEmpty
        message = "Doublons : \(report.summary)"
        isRemoving = false
    }

    func cancelDuplicates() {
        dupFlag.cancel()
        isFindingDups = false
    }
}
