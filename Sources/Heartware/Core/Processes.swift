import Foundation
import AppKit

/// What is running right now, to avoid cleaning the files of an open app.
struct RunningApps {
    var bundleIDs: Set<String> = []
    var names: Set<String> = []
    var byBundleID: [String: String] = [:]

    static func snapshot() -> RunningApps {
        if DemoData.isEnabled { return DemoData.running() }
        var r = RunningApps()
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier {
                r.bundleIDs.insert(id)
                r.byBundleID[id] = app.localizedName ?? id
                if let last = id.split(separator: ".").last { r.names.insert(last.lowercased()) }
            }
            if let n = app.localizedName { r.names.insert(n.lowercased()) }
            if let url = app.bundleURL {
                r.names.insert(url.deletingPathExtension().lastPathComponent.lowercased())
                if let n = Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String { r.names.insert(n.lowercased()) }
            }
            if let exe = app.executableURL?.lastPathComponent { r.names.insert(exe.lowercased()) }
        }
        return r
    }

    func isRunning(_ bundleID: String) -> Bool { bundleIDs.contains(bundleID) }

    /// Whether an app whose support folder is called `folder` seems to be open.
    func matches(folder: String) -> Bool { names.contains(folder.lowercased()) }

    func name(of bundleID: String) -> String { byBundleID[bundleID] ?? AppNames.name(for: bundleID) ?? bundleID }
}

enum AppNames {
    /// The display name of an installed app, from its bundle identifier.
    static func name(for bundleID: String) -> String? {
        guard bundleID.contains("."),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// One line of the "who is using my Mac" table: an app and all its helper processes.
struct ProcessGroup: Identifiable, Hashable {
    var id: String
    var name: String
    var appPath: String?
    var pids: [Int32]
    var cpu: Double          // percent, 100 = one full core
    var memory: UInt64       // resident bytes
    var isMine: Bool         // owned by the current user

    var processCount: Int { pids.count }
}

enum ProcessList {
    /// Samples `ps` and groups helper processes under their app.
    static func sample() -> [ProcessGroup] {
        if DemoData.isEnabled { return DemoData.processes() }
        let out = Shell.run("/bin/ps", ["-axo", "pid=,pcpu=,rss=,uid=,comm="], timeout: 5).out
        let me = getuid()
        var groups: [String: ProcessGroup] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
                  let rss = UInt64(parts[2]),
                  let uid = UInt32(parts[3]) else { continue }
            let path = String(parts[4])
            let (key, name, app) = identity(of: path)
            if var g = groups[key] {
                g.pids.append(pid)
                g.cpu += cpu
                g.memory += rss * 1024
                g.isMine = g.isMine && uid == me
                groups[key] = g
            } else {
                groups[key] = ProcessGroup(id: key, name: name, appPath: app, pids: [pid], cpu: cpu,
                                           memory: rss * 1024, isMine: uid == me)
            }
        }
        return Array(groups.values)
    }

    /// The outermost .app bundle of an executable, or the executable itself.
    static func identity(of path: String) -> (key: String, name: String, app: String?) {
        if let r = path.range(of: ".app/") {
            let app = String(path[..<r.lowerBound]) + ".app"
            return (app, (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""), app)
        }
        let name = (path as NSString).lastPathComponent
        return (path, name.isEmpty ? path : name, nil)
    }

    /// Politely asks an app (or the processes of the current user) to quit.
    @MainActor
    static func quit(_ g: ProcessGroup, force: Bool = false) -> Bool {
        // Demo PIDs are made up: they could belong to anything.
        if DemoData.isEnabled { return false }
        if let app = g.appPath {
            let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == app }
            if !apps.isEmpty {
                return apps.map { force ? $0.forceTerminate() : $0.terminate() }.allSatisfy { $0 }
            }
        }
        guard g.isMine else { return false }
        return g.pids.map { kill($0, force ? SIGKILL : SIGTERM) == 0 }.allSatisfy { $0 }
    }
}
