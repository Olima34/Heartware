import Foundation
import AppKit
import Observation

enum AppFilter: String, CaseIterable, Identifiable {
    case all, unused, intel, appStore, leftovers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Toutes"
        case .unused: return "Inutilisées"
        case .intel: return "Intel"
        case .appStore: return "App Store"
        case .leftovers: return "Restes"
        }
    }
}

enum AppSort: String, CaseIterable, Identifiable {
    case size, name, lastUsed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .size: return "Taille"
        case .name: return "Nom"
        case .lastUsed: return "Dernière utilisation"
        }
    }
}

@Observable
@MainActor
final class AppsModel {
    var apps: [InstalledApp] = []
    var isScanning = false
    var progress: Double = 0
    var lastScan: Date?
    var filter: AppFilter = .all
    var sort: AppSort = .size
    var search = ""

    var orphans: [CleanupItem] = []
    var orphanSelection: Set<String> = []
    var isScanningOrphans = false
    var orphansScanned = false

    var uninstallTarget: InstalledApp?
    var leftovers: [CleanupItem] = []
    var leftoverSelection: Set<String> = []
    var isFindingLeftovers = false
    var isRemoving = false
    var message: String?
    /// False when `message` reports a failure (shown as a warning, not as "done").
    var messageOK = true


    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        message = nil
        progress = 0
        let running = RunningApps.snapshot()
        apps = await Task.detached(priority: .userInitiated) {
            AppInventory.scan(running: running) { p in
                Task { @MainActor in self.progress = max(self.progress, p) }
            }
        }.value
        lastScan = Date()
        isScanning = false
    }

    var visible: [InstalledApp] {
        var list = apps
        switch filter {
        case .all, .leftovers: break
        case .unused: list = list.filter { $0.isUnused && !$0.isApple }
        case .intel: list = list.filter { $0.architecture == .intel }
        case .appStore: list = list.filter(\.fromAppStore)
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(q) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(q) } }
        switch sort {
        case .size: list.sort { $0.size > $1.size }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastUsed: list.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
        return list
    }

    var totalSize: Int64 { apps.reduce(0) { $0 + $1.size } }
    var unused: [InstalledApp] { apps.filter { $0.isUnused && !$0.isApple } }
    var intel: [InstalledApp] { apps.filter { $0.architecture == .intel } }

    // MARK: Uninstall

    func prepareUninstall(_ app: InstalledApp) async {
        var app = app
        // The app may have been opened since the last scan: an open app must be quit first.
        if !DemoData.isEnabled, let id = app.bundleID {
            app.isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
            if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i].isRunning = app.isRunning }
        }
        uninstallTarget = app
        leftovers = []
        isFindingLeftovers = true
        let found = await Task.detached(priority: .userInitiated) { Leftovers.find(for: app) }.value
        guard uninstallTarget?.id == app.id else { return }
        leftovers = found
        leftoverSelection = Set(found.map(\.id))
        isFindingLeftovers = false
    }

    func quitTarget() {
        guard !DemoData.isEnabled else {
            message = DemoData.refusal
            messageOK = false
            return
        }
        guard let app = uninstallTarget, let id = app.bundleID else { return }
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == id }.forEach { $0.terminate() }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
            if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i].isRunning = running }
            uninstallTarget?.isRunning = running
        }
    }

    func uninstall() async {
        guard let app = uninstallTarget, !isRemoving else { return }
        isRemoving = true
        let chosen = leftovers.filter { leftoverSelection.contains($0.id) }
        let report = await Task.detached(priority: .userInitiated) { Leftovers.uninstall(app, leftovers: chosen) }.value
        isRemoving = false
        uninstallTarget = nil
        if !report.failures.contains(where: { $0.path == app.path }) && !FS.exists(app.path) {
            apps.removeAll { $0.id == app.id }
            messageOK = true
            message = "\(app.name) est désinstallée : \(Fmt.bytes(report.freed)) envoyés à la Corbeille."
            ActionLog.write("DÉSINSTALLÉ \(app.name) (\(app.path))")
        } else if DemoData.isEnabled {
            message = DemoData.refusal
            messageOK = false
        } else {
            messageOK = false
            message = "\(app.name) n'a pas pu être supprimée. Glisse-la dans la Corbeille depuis le Finder."
        }
    }

    // MARK: Leftovers of removed apps

    func scanOrphans(fullDiskAccess: Bool) async {
        guard !isScanningOrphans else { return }
        isScanningOrphans = true
        if apps.isEmpty { await scan() }
        let installed = apps
        orphans = await Task.detached(priority: .userInitiated) {
            OrphanFinder.scan(installed: installed, includeContainers: fullDiskAccess)
        }.value
        orphanSelection = []
        orphansScanned = true
        isScanningOrphans = false
    }

    func removeOrphans() async {
        let chosen = orphans.filter { orphanSelection.contains($0.id) }
        guard !chosen.isEmpty, !isRemoving else { return }
        isRemoving = true
        let report = await Task.detached(priority: .userInitiated) {
            Remover.remove(chosen.map { RemovalEntry(path: $0.path, size: $0.size) }, mode: .trash)
        }.value
        let failed = Set(report.failures.map(\.path))
        orphans.removeAll { orphanSelection.contains($0.id) && !failed.contains($0.id) }
        orphanSelection = []
        messageOK = report.failures.isEmpty
        message = "Restes envoyés à la Corbeille : \(report.summary)"
        isRemoving = false
    }
}
