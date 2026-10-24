import Foundation
import AppKit
import CoreServices

enum Architecture: String {
    case appleSilicon, universal, intel, unknown

    var label: String {
        switch self {
        case .appleSilicon: return "Apple Silicon"
        case .universal: return "Universelle"
        case .intel: return "Intel"
        case .unknown: return "—"
        }
    }
}

struct InstalledApp: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String?
    let version: String?
    let size: Int64
    let lastUsed: Date?
    let added: Date?
    let architecture: Architecture
    let fromAppStore: Bool
    let isApple: Bool
    var isRunning: Bool

    var isUnused: Bool {
        guard let d = lastUsed ?? added else { return true }
        return Date().timeIntervalSince(d) > 90 * 86400
    }
}

enum AppInventory {
    static let roots = ["/Applications", FS.home + "/Applications"]

    static func bundlePaths() -> [String] {
        var out: [String] = []
        for root in roots {
            for name in FS.children(root) {
                let p = root + "/" + name
                if FS.isSymlink(p) { continue }
                if name.hasSuffix(".app") {
                    out.append(p)
                } else if FS.isDirectory(p) {
                    // One level of folders ("Microsoft Office", "Utilities"…).
                    for sub in FS.children(p) where sub.hasSuffix(".app") && !FS.isSymlink(p + "/" + sub) {
                        out.append(p + "/" + sub)
                    }
                }
            }
        }
        return out
    }

    static func scan(running: RunningApps, progress: @escaping (Double) -> Void = { _ in }) -> [InstalledApp] {
        if DemoData.isEnabled { return DemoData.apps() }
        let paths = bundlePaths()
        let slots = Slots<InstalledApp>(count: paths.count)
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            let app = inspect(paths[i], running: running)
            let n = slots.set(i, app)
            if n % 5 == 0 { progress(Double(n) / Double(max(1, paths.count))) }
        }
        return slots.all.sorted { $0.size > $1.size }
    }

    static func inspect(_ path: String, running: RunningApps) -> InstalledApp {
        let url = URL(fileURLWithPath: path)
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]
        let id = bundle?.bundleIdentifier
        let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        let version = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String
        var arch = Architecture.unknown
        if let archs = bundle?.executableArchitectures?.map(\.intValue) {
            let arm = archs.contains(NSBundleExecutableArchitectureARM64)
            let x86 = archs.contains(NSBundleExecutableArchitectureX86_64)
            arch = arm && x86 ? .universal : (arm ? .appleSilicon : (x86 ? .intel : .unknown))
        }
        var lastUsed: Date?
        var added: Date?
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            added = MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
        }
        return InstalledApp(path: path, name: name, bundleID: id, version: version, size: FileSizer.size(of: path),
                            lastUsed: lastUsed, added: added, architecture: arch,
                            fromAppStore: FS.exists(path + "/Contents/_MASReceipt/receipt"),
                            isApple: id?.hasPrefix("com.apple.") ?? false,
                            isRunning: id.map(running.isRunning) ?? false)
    }
}

/// Finds what an app scattered in ~/Library.
enum Leftovers {
    static func find(for app: InstalledApp) -> [CleanupItem] {
        if DemoData.isEnabled { return DemoData.leftovers(for: app) }
        let lib = FS.home + "/Library"
        var paths: [(String, String)] = [] // path, kind
        let names = Set([app.name, (app.path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")])
            .filter { $0.count >= 4 }
        if let b = app.bundleID {
            paths += [
                (lib + "/Application Support/" + b, "Données"), (lib + "/Caches/" + b, "Cache"),
                (lib + "/Preferences/" + b + ".plist", "Préférences"), (lib + "/Containers/" + b, "Conteneur"),
                (lib + "/Saved Application State/" + b + ".savedState", "État des fenêtres"),
                (lib + "/HTTPStorages/" + b, "Données web"), (lib + "/HTTPStorages/" + b + ".binarycookies", "Cookies"),
                (lib + "/WebKit/" + b, "Données web"), (lib + "/Cookies/" + b + ".binarycookies", "Cookies"),
                (lib + "/Logs/" + b, "Journaux"), (lib + "/Application Scripts/" + b, "Scripts")
            ]
            for n in FS.children(lib + "/Preferences/ByHost") where n.hasPrefix(b + ".") {
                paths.append((lib + "/Preferences/ByHost/" + n, "Préférences"))
            }
            for n in FS.children(lib + "/Containers") where n.hasPrefix(b + ".") {
                paths.append((lib + "/Containers/" + n, "Extension"))
            }
            for n in FS.children(lib + "/Application Scripts") where n.hasPrefix(b + ".") {
                paths.append((lib + "/Application Scripts/" + n, "Scripts"))
            }
            for n in FS.children(lib + "/Group Containers") where n.hasSuffix("." + b) || n == "group." + b {
                paths.append((lib + "/Group Containers/" + n, "Conteneur partagé"))
            }
            for n in FS.children(lib + "/LaunchAgents") where n.hasPrefix(b) {
                paths.append((lib + "/LaunchAgents/" + n, "Agent de démarrage"))
            }
        }
        for n in names {
            paths += [(lib + "/Application Support/" + n, "Données"), (lib + "/Caches/" + n, "Cache"), (lib + "/Logs/" + n, "Journaux")]
        }
        var seen = Set<String>()
        return paths.compactMap { p, kind in
            guard seen.insert(p).inserted, FS.exists(p) else { return nil }
            return CleanupItem(path: p, name: (p as NSString).lastPathComponent, detail: kind, size: FileSizer.size(of: p),
                               modified: FS.modified(p))
        }
        .sorted { $0.size > $1.size }
    }

    static func uninstall(_ app: InstalledApp, leftovers: [CleanupItem]) -> RemovalReport {
        // Stop the app's agents before their files go.
        for agent in leftovers where agent.path.contains("/LaunchAgents/") {
            let label = ((agent.path as NSString).lastPathComponent as NSString).deletingPathExtension
            _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        }
        var report = Remover.remove(leftovers.map { RemovalEntry(path: $0.path, size: $0.size) }, mode: .trash)
        report.merge(Remover.remove([RemovalEntry(path: app.path, size: app.size)], mode: .trash))
        return report
    }
}

/// Settings and caches of apps that are no longer installed.
enum OrphanFinder {
    static func scan(installed: [InstalledApp], includeContainers: Bool) -> [CleanupItem] {
        if DemoData.isEnabled { return DemoData.orphans() }
        let lib = FS.home + "/Library"
        var places: [(String, String)] = [
            ("Application Support", "Données"), ("Caches", "Cache"), ("Preferences", "Préférences"),
            ("Saved Application State", "État des fenêtres"), ("HTTPStorages", "Données web"), ("WebKit", "Données web"),
            ("Logs", "Journaux")
        ]
        if includeContainers { places.append(("Containers", "Conteneur")) }

        let installedIDs = installed.compactMap(\.bundleID)
        let vendors = Set(installedIDs.map(vendor))
        let ignoredVendors: Set<String> = ["com.apple", "org.swift", "com.github", "io.sentry", "com.crashlytics",
                                           "com.plausiblelabs", "org.sparkle-project", "group.com", "systemgroup.com"]
        let recent = Date().addingTimeInterval(-14 * 86400)
        var out: [CleanupItem] = []
        for (folder, kind) in places {
            let dir = lib + "/" + folder
            for name in FS.children(dir) {
                var id = name
                for ext in [".plist", ".savedState", ".binarycookies"] where id.hasSuffix(ext) {
                    id = String(id.dropLast(ext.count))
                }
                let parts = id.split(separator: ".")
                guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }), parts[0].count <= 4,
                      parts[0].allSatisfy({ $0.isLowercase }) else { continue }
                let v = vendor(id)
                guard !ignoredVendors.contains(v), !vendors.contains(v) else { continue }
                guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil else { continue }
                let p = dir + "/" + name
                guard let m = FS.modified(p), m < recent else { continue }
                let size = FileSizer.size(of: p)
                guard size > 0 else { continue }
                out.append(CleanupItem(path: p, name: id, detail: "\(kind) · modifié \(Fmt.relative(m))", size: size,
                                       modified: m, defaultOn: false))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// "com.google.Chrome.helper" → "com.google"
    static func vendor(_ id: String) -> String {
        id.split(separator: ".").prefix(2).joined(separator: ".").lowercased()
    }
}
