import Foundation
import Observation

/// Thread-safe slots filled by concurrent workers.
final class Slots<T>: @unchecked Sendable {
    private var values: [T?]
    private let lock = NSLock()
    private(set) var done = 0

    init(count: Int) { values = Array(repeating: nil, count: count) }

    func set(_ i: Int, _ v: T) -> Int {
        lock.lock()
        defer { lock.unlock() }
        values[i] = v
        done += 1
        return done
    }

    var all: [T] {
        lock.lock()
        defer { lock.unlock() }
        return values.compactMap { $0 }
    }
}

/// Sizes of the Claude data that the app deliberately keeps.
struct ClaudeFootprint {
    var transcripts: Int64 = 0
    var vm: Int64 = 0
    var codeVersions: Int64 = 0
}

enum CleanupScanner {
    static func scan(running: RunningApps, progress: @escaping (Double, String) -> Void = { _, _ in }) -> [CleanupTarget] {
        if DemoData.isEnabled { return DemoData.cleanupTargets() }
        let specs = CleanupCatalog.specs()
        let slots = Slots<CleanupTarget>(count: specs.count)
        DispatchQueue.concurrentPerform(iterations: specs.count) { i in
            let t = build(specs[i], running: running)
            let n = slots.set(i, t)
            progress(Double(n) / Double(specs.count), specs[i].title)
        }
        let byID = Dictionary(uniqueKeysWithValues: slots.all.map { ($0.id, $0) })
        return specs.compactMap { byID[$0.id] }
    }

    static func build(_ spec: TargetSpec, running: RunningApps) -> CleanupTarget {
        var target = CleanupTarget(id: spec.id, group: spec.group, title: spec.title, explanation: spec.explanation,
                                   symbol: spec.symbol, mode: spec.mode, defaultOn: spec.defaultOn)
        if let probe = spec.accessProbe, FS.exists(probe) || spec.id == "trash", !FS.canList(probe) {
            target.needsFullDiskAccess = true
            return target
        }
        var items: [CleanupItem] = []
        for c in spec.collect() {
            let size = FileSizer.size(of: c.path)
            guard size > 0 else { continue }
            var blocked: String?
            if let id = c.requiresClosed, running.isRunning(id) {
                blocked = "Quitte \(running.name(of: id)) pour nettoyer ceci"
            } else if let folder = c.requiresClosedFolder, running.matches(folder: folder) {
                blocked = "Quitte \(folder) pour nettoyer ceci"
            }
            items.append(CleanupItem(path: c.path, name: c.name, detail: c.detail, size: size,
                                     modified: FS.modified(c.path), defaultOn: c.defaultOn && spec.defaultOn,
                                     blockedReason: blocked))
        }
        target.items = items.sorted { $0.size > $1.size }
        return target
    }

    static func claudeFootprint() -> ClaudeFootprint {
        if DemoData.isEnabled { return DemoData.claudeFootprint }
        return ClaudeFootprint(
            transcripts: FileSizer.size(of: FS.home + "/.claude/projects"),
            vm: FileSizer.size(of: CleanupCatalog.support + "/Claude/vm_bundles"),
            codeVersions: FileSizer.size(of: CleanupCatalog.support + "/Claude/claude-code")
        )
    }
}

@Observable
@MainActor
final class CleanupModel {
    var targets: [CleanupTarget] = []
    var selection: Set<String> = []
    var isScanning = false
    var isCleaning = false
    var progress: Double = 0
    var progressLabel = ""
    var lastScan: Date?
    var lastReport: RemovalReport?
    var claude = ClaudeFootprint()
    var expanded: Set<String> = []
    /// Categories unfolded on the page (a category also shows open while one of its lines is).
    var openGroups: Set<CleanupGroup> = []

    /// Called with the number of bytes freed after each cleanup.
    @ObservationIgnored var onFreed: (Int64) -> Void = { _ in }

    var hasResults: Bool { lastScan != nil }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        lastReport = nil
        progress = 0
        progressLabel = "Préparation…"
        let running = RunningApps.snapshot()
        let (result, footprint) = await Task.detached(priority: .userInitiated) { () -> ([CleanupTarget], ClaudeFootprint) in
            let r = CleanupScanner.scan(running: running) { p, label in
                Task { @MainActor in
                    guard self.isScanning else { return }
                    self.progress = max(self.progress, p)
                    self.progressLabel = label
                }
            }
            return (r, CleanupScanner.claudeFootprint())
        }.value
        apply(result)
        claude = footprint
        lastScan = Date()
        isScanning = false
    }

    func apply(_ result: [CleanupTarget]) {
        targets = result
        selection = Set(result.flatMap { t in t.cleanable.filter(\.defaultOn).map(\.id) })
    }

    /// Removes the selected items and returns what happened.
    @discardableResult
    func clean() async -> RemovalReport {
        guard !isCleaning else { return RemovalReport() }
        isCleaning = true
        var batches: [(RemovalMode, [RemovalEntry])] = []
        for mode in [RemovalMode.delete, .trash] {
            let entries = targets.filter { $0.mode == mode }.flatMap { t in
                t.cleanable.filter { selection.contains($0.id) }.map { RemovalEntry(path: $0.path, size: $0.size) }
            }
            if !entries.isEmpty { batches.append((mode, entries)) }
        }
        let (report, deleted) = await Task.detached(priority: .userInitiated) { () -> (RemovalReport, Int64) in
            var total = RemovalReport()
            var deleted: Int64 = 0
            for (mode, entries) in batches {
                let r = Remover.remove(entries, mode: mode)
                if mode == .delete && !Preferences.alwaysTrash { deleted += r.freed }
                total.merge(r)
            }
            return (total, deleted)
        }.value

        let failed = Set(report.failures.map(\.path))
        let removed = selection.subtracting(failed)
        for i in targets.indices {
            targets[i].items.removeAll { removed.contains($0.id) }
        }
        selection = selection.intersection(failed)
        lastReport = report
        isCleaning = false
        // Only what really left the disk counts (items sent to the Trash are counted when it is emptied).
        onFreed(deleted)
        return report
    }

    // MARK: Totals

    var totalSize: Int64 { targets.reduce(0) { $0 + $1.size } }
    var selectedItems: [CleanupItem] { targets.flatMap { $0.cleanable.filter { selection.contains($0.id) } } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var selectedCount: Int { selectedItems.count }
    /// What a one-click cleanup would free (items checked by default).
    var recommendedSize: Int64 { targets.flatMap { $0.cleanable.filter(\.defaultOn) }.reduce(0) { $0 + $1.size } }

    var selectedNeedsTrash: Bool { targets.contains { $0.mode == .trash && $0.items.contains { selection.contains($0.id) } } }
    var selectedDeletesForGood: Bool { targets.contains { $0.mode == .delete && $0.items.contains { selection.contains($0.id) } } }

    func targets(in group: CleanupGroup) -> [CleanupTarget] {
        targets.filter { $0.group == group && (!$0.items.isEmpty || $0.needsFullDiskAccess) }
    }

    func size(of group: CleanupGroup) -> Int64 { targets(in: group).reduce(0) { $0 + $1.size } }

    func selectedSize(of group: CleanupGroup) -> Int64 {
        targets(in: group).flatMap(\.cleanable).filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func selectedSize(of t: CleanupTarget) -> Int64 {
        t.cleanable.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    // MARK: Selection

    func state(of t: CleanupTarget) -> CheckState {
        let ids = t.cleanable.map(\.id)
        guard !ids.isEmpty else { return .off }
        let n = ids.filter { selection.contains($0) }.count
        return n == 0 ? .off : (n == ids.count ? .on : .mixed)
    }

    func state(of group: CleanupGroup) -> CheckState {
        let ids = targets(in: group).flatMap(\.cleanable).map(\.id)
        guard !ids.isEmpty else { return .off }
        let n = ids.filter { selection.contains($0) }.count
        return n == 0 ? .off : (n == ids.count ? .on : .mixed)
    }

    func toggle(_ t: CleanupTarget) {
        let ids = Set(t.cleanable.map(\.id))
        if state(of: t) == .on { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    func toggle(_ group: CleanupGroup) {
        let ids = Set(targets(in: group).flatMap(\.cleanable).map(\.id))
        if state(of: group) == .on { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    func toggle(_ item: CleanupItem) {
        guard item.blockedReason == nil else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func selectRecommended() {
        selection = Set(targets.flatMap { $0.cleanable.filter(\.defaultOn).map(\.id) })
    }

    func clearSelection() { selection.removeAll() }
}
