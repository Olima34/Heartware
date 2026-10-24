import Foundation
import Security

// MARK: - Heuristics

/// Behaviours that betray a dropper whatever its name: download then run, decode then run.
enum ProtectionHeuristics {
    private static let patterns: [NSRegularExpression] = [
        // curl … https://… | sh
        #"(curl|wget)\b[^|;&\n]*https?://[^|;&\n]*\|\s*(sudo\s+)?(/bin/|/usr/bin/(env\s+)?)?(ba|z|da|k)?sh\b"#,
        // … | python3 (or perl, ruby, osascript) reading the download as its program, not `| python3 -m json.tool`
        #"(curl|wget)\b[^|;&\n]*https?://[^|;&\n]*\|\s*(/usr/bin/)?(python3?|perl|ruby|osascript)\s*(-\s*)?($|[;&)'"])"#,
        // a download written to a shared folder, then made executable or run
        #"(curl|wget)\b[^\n]*-o\s*['"]?/(private/)?(tmp|var/tmp|Users/Shared)/[^\n]*(chmod\s+\+?[0-7]*x|&&\s*/(private/)?(tmp|var/tmp|Users/Shared)/|open\s)"#,
        // base64 decoded straight into an interpreter
        #"base64\s+(-d|-D|--decode)[^|\n]*\|\s*(ba|z)?sh\b"#,
        #"echo\s+['"]?[A-Za-z0-9+/=]{60,}['"]?\s*\|\s*base64"#,
        #"eval\s*"?\$\((curl|wget)"#,
        #"python[0-9.]*\s+-c\s+['"][^\n]*(exec|eval)\s*\(\s*[^\n]*(urlopen|b64decode|base64)"#,
        #"osascript\s+-e\s+['"][^\n]*do shell script[^\n]*(curl|base64)"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func isDownloader(_ text: String) -> Bool {
        guard text.count > 8 else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// A launch item that runs an interpreter on a script file: the script's own lines (comments left out).
    static func scriptDownloads(arguments: [String]) -> Bool {
        for a in arguments.dropFirst() where a.hasPrefix("/") {
            // A regular file only: a pipe given as argument would block the scan.
            var st = stat()
            guard lstat(a, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
                  let h = FileHandle(forReadingAtPath: a), let d = try? h.read(upToCount: 64 << 10) else { continue }
            try? h.close()
            let code = String(decoding: d, as: UTF8.self).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
            if isDownloader(code) { return true }
        }
        return false
    }

    private static let libraryInjection = try? NSRegularExpression(pattern: #"^(export\s+)?DYLD_INSERT_LIBRARIES=\S"#)

    /// Lines of a shell startup file (~/.zshrc…) that run code from elsewhere or inject a library into every program.
    static func suspiciousLines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.hasPrefix("#") else { return false }
            return isDownloader(l) || libraryInjection?.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil
        }
    }
}

// MARK: - Known malware

/// Exact files that only a known piece of Mac malware creates (public analyses by Objective-See, Red Canary, Moonlock,
/// SentinelOne…). An exact path is never matched by chance: no false alarm, a family that renamed its files is simply missed.
enum ProtectionKnownMalware {
    struct Indicator {
        let family: String
        let path: String
        /// The file must be an executable (a common name that only matters when it is a program).
        var executable = false
    }

    static let indicators: [Indicator] = [
        Indicator(family: "OSX.SilverSparrow", path: "~/Library/LaunchAgents/init_verx.plist"),
        Indicator(family: "OSX.SilverSparrow", path: "~/Library/LaunchAgents/init_agent.plist"),
        Indicator(family: "OSX.SilverSparrow", path: "~/Library/Application Support/verx_updater"),
        Indicator(family: "OSX.SilverSparrow", path: "~/Library/Application Support/agent_updater/agent.sh"),
        Indicator(family: "OSX.SilverSparrow", path: "~/Library/._insu"),
        Indicator(family: "OSX.EvilQuest", path: "~/Library/AppQuest/com.apple.questd"),
        Indicator(family: "OSX.EvilQuest", path: "~/Library/LaunchAgents/com.apple.questd.plist"),
        Indicator(family: "OSX.EvilQuest", path: "/Library/LaunchDaemons/com.apple.questd.plist"),
        Indicator(family: "OSX.EvilQuest", path: "/Library/AppQuest/com.apple.questd"),
        Indicator(family: "OSX.FruitFly", path: "~/.client", executable: true),
        Indicator(family: "OSX.FruitFly", path: "~/Library/LaunchAgents/com.client.client.plist"),
        Indicator(family: "OSX.Keydnap", path: "~/Library/Application Support/com.apple.iCloud.sync.daemon/icloudsyncd"),
        Indicator(family: "OSX.Keydnap", path: "~/Library/LaunchAgents/com.apple.iCloud.sync.daemon.plist"),
        Indicator(family: "OSX.Proton", path: "~/Library/LaunchAgents/fr.handbrake.activity.plist"),
        Indicator(family: "OSX.Proton", path: "~/Library/RenderFiles/activity_agent.app"),
        Indicator(family: "OSX.CreativeUpdate", path: "~/Library/LaunchAgents/mdworker.plist"),
        Indicator(family: "OSX.CreativeUpdate", path: "~/Library/mdworker/mdworker"),
        Indicator(family: "OSX.AppleJeus", path: "/Library/LaunchDaemons/com.celastradepro.plist"),
        Indicator(family: "OSX.AppleJeus", path: "/Library/CelasTradePro/Updater"),
        Indicator(family: "OSX.AppleJeus", path: "/Library/LaunchDaemons/com.jmttrading.plist"),
        Indicator(family: "OSX.AppleJeus", path: "/Library/JMTTrader/CrashReporter"),
        Indicator(family: "OSX.AppleJeus", path: "/Library/LaunchDaemons/com.unioncryptoupdater.plist"),
        Indicator(family: "OSX.AppleJeus", path: "/Library/UnionCrypto/unioncryptoupdater"),
        Indicator(family: "OSX.Eleanor", path: "~/Library/LaunchAgents/com.getdropbox.dropbox.integritycheck.plist"),
        Indicator(family: "OSX.Eleanor", path: "~/Library/LaunchAgents/com.getdropbox.dropbox.timegrabber.plist"),
        Indicator(family: "OSX.Komplex", path: "/Users/Shared/.local/kextd"),
        Indicator(family: "OSX.Dok", path: "/Users/Shared/AppStore.app"),
        Indicator(family: "MACOS.AMOS (porte dérobée)", path: "/Library/LaunchDaemons/com.finder.helper.plist"),
        Indicator(family: "MACOS.AMOS (porte dérobée)", path: "~/.helper", executable: true)
    ]

    static func expanded(_ i: Indicator) -> String { i.path.hasPrefix("~") ? FS.home + i.path.dropFirst() : i.path }

    /// The family of the indicator at exactly `path`, if any.
    static func match(_ path: String) -> String? {
        let p = (path as NSString).standardizingPath
        return indicators.first { expanded($0) == p }?.family
    }

    /// The indicators present on this Mac.
    static func present() -> [(family: String, path: String)] {
        if DemoData.isEnabled { return [] }
        return indicators.compactMap { i in
            let p = expanded(i)
            guard FS.exists(p) || FS.isSymlink(p) else { return nil }
            if i.executable, !FileManager.default.isExecutableFile(atPath: p) || FS.isDirectory(p) { return nil }
            return (i.family, p)
        }
    }
}

// MARK: - Threats

enum ProtectionThreatKind: String, Codable {
    /// Recognised by Apple's XProtect signatures.
    case signature
    /// A file only a known piece of malware creates.
    case knownMalware
    /// A launch agent or daemon that behaves like malware (impersonates Apple, downloads and runs code…).
    case persistence
    /// An app whose signature is broken: modified after it was signed (cracked, infected).
    case tampered
    /// Signed by a developer, or a Safari extension, that Apple blocks.
    case blocked
    /// A shell startup file that runs code from elsewhere.
    case startup

    var title: String {
        switch self {
        case .signature: return "Reconnu par les signatures d'Apple"
        case .knownMalware: return "Trace d'un logiciel malveillant connu"
        case .persistence: return "Démarrage automatique suspect"
        case .tampered: return "App modifiée après sa signature"
        case .blocked: return "Bloqué par Apple"
        case .startup: return "Fichier de démarrage du Terminal piégé"
        }
    }

    var symbol: String {
        switch self {
        case .signature: return "ant.fill"
        case .knownMalware: return "exclamationmark.octagon"
        case .persistence: return "arrow.clockwise.circle"
        case .tampered: return "seal"
        case .blocked: return "hand.raised.fill"
        case .startup: return "terminal"
        }
    }
}

struct ProtectionThreat: Identifiable, Codable, Hashable {
    var kind: ProtectionThreatKind
    /// `Status` raw value: 3 for malware, 2 for what deserves a look.
    var severity: Int
    /// What it is ("MACOS.644e18d", "OSX.EvilQuest", the agent's label…).
    var name: String
    var detail: String
    /// The file or bundle found.
    var path: String
    /// What goes to the Trash when the user deals with it (the bundle, its launch agents' files…).
    var removable: [String]
    /// launchd services stopped first: "gui/<uid>/<label>" or "system/<label>".
    var services: [String] = []

    var id: String { kind.rawValue + "|" + path }
    var status: Status { Status(rawValue: severity) ?? .warn }
    var title: String { kind.title }
}

/// What the check of one file the user dropped says.
struct ProtectionFileVerdict: Equatable {
    var path: String
    var name: String
    var status: Status
    var title: String
    var detail: String
    var files: Int
    var threat: ProtectionThreat?
}

struct ProtectionScanSummary: Codable, Equatable {
    var date: Date
    var deep: Bool
    var files: Int
    var threats: Int
    var signaturesVersion: Int
    var duration: Double
}

/// Where a scan stands, read by the page at most four times a second.
final class ProtectionScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _phase = ""
    private var _done = 0
    private var _total = 0
    private var _current = ""

    func set(phase: String, total: Int) {
        lock.lock()
        _phase = phase
        _total = total
        _done = 0
        lock.unlock()
    }

    func advance(_ path: String) {
        lock.lock()
        _done += 1
        _current = path
        lock.unlock()
    }

    var snapshot: (phase: String, done: Int, total: Int, current: String) {
        lock.lock()
        defer { lock.unlock() }
        return (_phase, _done, _total, _current)
    }
}

enum ProtectionThreatScanner {
    /// Apps: the main executable, an AppleScript applet's script, helpers and login items inside the bundle.
    static func bundleExecutables(_ app: String) -> [String] {
        var out: [String] = []
        let contents = app + "/Contents"
        if let info = NSDictionary(contentsOfFile: contents + "/Info.plist"), let exe = info["CFBundleExecutable"] as? String {
            out.append(contents + "/MacOS/" + exe)
        }
        for name in FS.children(contents + "/MacOS") { out.append(contents + "/MacOS/" + name) }
        let script = contents + "/Resources/Scripts/main.scpt"
        if FS.exists(script) { out.append(script) }
        for name in FS.children(contents + "/Library/LaunchServices") { out.append(contents + "/Library/LaunchServices/" + name) }
        for sub in ["/Library/LoginItems", "/Helpers", "/Library/Helpers"] {
            for name in FS.children(contents + sub) where name.hasSuffix(".app") {
                if let info = NSDictionary(contentsOfFile: contents + sub + "/" + name + "/Contents/Info.plist"),
                   let exe = info["CFBundleExecutable"] as? String {
                    out.append(contents + sub + "/" + name + "/Contents/MacOS/" + exe)
                }
            }
        }
        return Array(Set(out)).sorted()
    }

    static func appBundles() -> [String] {
        var out: [String] = []
        for root in ["/Applications", FS.home + "/Applications"] {
            for name in FS.children(root) {
                let p = root + "/" + name
                if name.hasSuffix(".app") {
                    out.append(p)
                } else if FS.isDirectory(p), !FS.isSymlink(p) {
                    // One level of folders ("Utilities", "Adobe Photoshop 2026"…).
                    out += FS.children(p).filter { $0.hasSuffix(".app") }.map { p + "/" + $0 }
                }
            }
        }
        return out
    }

    /// Executables of the running processes, outside macOS' own folders.
    static func runningExecutables() -> [String] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var out = Set<String>()
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            if Shell.isThirdParty(path), !path.hasPrefix("/Library/Apple/") { out.insert(path) }
        }
        return out.sorted()
    }

    /// Folders worth a look in a quick scan, walked a few levels deep: where downloads, droppers and hidden helpers land.
    static let quickFolders: [(path: String, depth: Int)] = [
        ("~/Downloads", 3), ("~/Desktop", 2), ("~/Documents", 2), ("/Users/Shared", 4), ("/private/tmp", 3), ("/private/var/tmp", 3),
        ("~/Library/Application Support", 3), ("~/Library/LaunchAgents", 1), ("/Library/Application Support", 2),
        ("/Library/PrivilegedHelperTools", 1), ("~/Library/Services", 2), ("~/Library/Scripts", 3), ("/usr/local/bin", 1)
    ]

    /// Never walked: huge, rebuilt by tools, or someone else's business. A file there that runs at login is still
    /// scanned through the launch items.
    static let skippedNames: Set<String> = [
        "node_modules", ".git", "DerivedData", ".build", "Pods", "Caches", "Containers", "Group Containers", "Mail", "Messages",
        "Mobile Documents", "CloudStorage", "Photos Library.photoslibrary", "CoreSimulator", ".Trash", "Cellar", "site-packages",
        ".cargo", ".rustup", ".npm", ".pnpm-store", ".gradle", ".m2", ".cache"
    ]

    /// `wholeBundles`: every library of an app is read (trojanized copies hide a dylib in Frameworks), except in apps
    /// Apple signed; otherwise only its programs.
    /// `limit`: past that many files found, no folder is entered any more.
    static func walk(_ root: String, depth: Int, wholeBundles: Bool = false, limit: Int = .max, isCancelled: () -> Bool,
                     into out: inout Set<String>) {
        let base = root.split(separator: "/").count
        FileSizer.walk(root, isCancelled: isCancelled) { ent in
            let path = String(cString: ent.pointee.fts_path)
            let name = (path as NSString).lastPathComponent
            if out.count >= limit { return false }
            switch Int32(ent.pointee.fts_info) {
            case FTS_D:
                if path != root && (skippedNames.contains(name) || path.hasSuffix("/Library/Developer")) { return false }
                if path.hasSuffix(".app") && !path.dropLast(4).contains(".app/") {
                    out.formUnion(bundleExecutables(path))
                    return wholeBundles && Signature.check(path) != .apple
                }
                return path.contains(".app/") || path.split(separator: "/").count - base < depth
            case FTS_F:
                guard let st = ent.pointee.fts_statp else { return true }
                if st.pointee.st_mode & 0o111 != 0 || ProtectionSignatureScanner.extensions.contains((name as NSString).pathExtension.lowercased()) {
                    out.insert(path)
                }
                return true
            default:
                return true
            }
        }
    }

    /// Roots of the full scan: everything that can hold a program the user did not install from the App Store.
    static var deepRoots: [String] {
        ["/Applications", FS.home, "/Users/Shared", "/Library/Application Support", "/Library/LaunchAgents", "/Library/LaunchDaemons",
         "/Library/PrivilegedHelperTools", "/Library/Internet Plug-Ins", "/Library/Security/SecurityAgentPlugins", "/Library/ScriptingAdditions",
         "/usr/local", "/opt/homebrew/bin", "/private/tmp", "/private/var/tmp"]
    }

    /// The files to read for a scan, without duplicates.
    static func targets(deep: Bool, launchItems: [LaunchItem], isCancelled: () -> Bool) -> [String] {
        var out = Set<String>()
        for item in launchItems {
            if let p = item.program, p.hasPrefix("/") { out.insert(p) }
            for a in item.arguments.dropFirst() where a.hasPrefix("/") && FS.exists(a) && !FS.isDirectory(a) { out.insert(a) }
        }
        out.formUnion(runningExecutables())
        for app in appBundles() { out.formUnion(bundleExecutables(app)) }
        if deep {
            for root in deepRoots where !isCancelled() { walk(root, depth: 64, wholeBundles: true, isCancelled: isCancelled, into: &out) }
        } else {
            for f in quickFolders where !isCancelled() {
                walk(f.path.hasPrefix("~") ? FS.home + f.path.dropFirst() : f.path, depth: f.depth, isCancelled: isCancelled, into: &out)
            }
        }
        // macOS' own files are sealed and signed by Apple: never read.
        return out.filter { Shell.isThirdParty($0) && !$0.hasPrefix("/Library/Apple/") && !$0.hasPrefix(Bundle.main.bundlePath + "/") }.sorted()
    }

    /// The bundle holding `path` (outermost .app), or the file itself.
    static func container(of path: String) -> String {
        if let r = path.range(of: ".app/") { return String(path[..<r.lowerBound]) + ".app" }
        return path
    }

    // MARK: Scan

    /// Must not run on the main thread. `progress` is updated as files are read.
    static func scan(deep: Bool, launchItems: [LaunchItem], flag: CancelFlag, progress: ProtectionScanProgress)
        -> (threats: [ProtectionThreat], summary: ProtectionScanSummary)? {
        if DemoData.isEnabled { return ProtectionDemo.threatScan(deep: deep) }
        let start = Date()
        progress.set(phase: "Je prépare les signatures d'Apple…", total: 0)
        guard let sig = ProtectionSignatures.load() else { return nil }
        progress.set(phase: deep ? "Je repère tous les programmes du Mac…" : "Je repère les programmes à examiner…", total: 0)
        let files = targets(deep: deep, launchItems: launchItems, isCancelled: { flag.isCancelled })
        guard !flag.isCancelled else { return nil }

        progress.set(phase: "J'analyse", total: files.count)
        final class Found: @unchecked Sendable {
            let lock = NSLock()
            var hits: [(path: String, hit: ProtectionSignatureHit)] = []
            var next = 0
        }
        let found = Found()
        // Half the cores: the Mac stays usable during a scan.
        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while !flag.isCancelled {
                found.lock.lock()
                let i = found.next
                found.next += 1
                found.lock.unlock()
                guard i < files.count else { break }
                let path = files[i]
                let hits = autoreleasepool { ProtectionSignatureScanner.scan(path, with: sig) }
                progress.advance(path)
                guard !hits.isEmpty else { continue }
                found.lock.lock()
                found.hits += hits.map { (path, $0) }
                found.lock.unlock()
            }
        }
        guard !flag.isCancelled else { return nil }

        var threats: [ProtectionThreat] = []
        // Signature matches, one per file.
        let byPath = Dictionary(grouping: found.hits, by: \.path)
        for (path, hits) in byPath {
            let names = Array(Set(hits.map(\.hit.detection))).sorted()
            threats.append(ProtectionThreat(kind: .signature, severity: Status.bad.rawValue, name: names.joined(separator: ", "),
                                            detail: "Les signatures antimalware d'Apple (XProtect \(sig.version)) reconnaissent ce fichier.",
                                            path: path, removable: [container(of: path)]))
        }
        threats += knownMalwareThreats()
        threats += persistenceThreats(launchItems)
        progress.set(phase: "Je vérifie l'intégrité des apps…", total: 0)
        threats += appThreats(blocked: sig.blockedExtensions, isCancelled: { flag.isCancelled })
        threats += startupFileThreats()
        let linked = link(threats, launchItems: launchItems)
        let summary = ProtectionScanSummary(date: Date(), deep: deep, files: files.count, threats: linked.filter { $0.status == .bad }.count,
                                            signaturesVersion: sig.version, duration: Date().timeIntervalSince(start))
        return (merge(linked), summary)
    }

    /// One threat per path, the most serious kind kept.
    static func merge(_ threats: [ProtectionThreat]) -> [ProtectionThreat] {
        var best: [String: ProtectionThreat] = [:]
        for t in threats {
            if let b = best[t.path], b.severity >= t.severity { continue }
            best[t.path] = t
        }
        return best.values.sorted { a, b in a.severity != b.severity ? a.severity > b.severity : a.path < b.path }
    }

    /// Adds to each threat the launch items that start it: their files go with it and their services are stopped first.
    static func link(_ threats: [ProtectionThreat], launchItems: [LaunchItem]) -> [ProtectionThreat] {
        threats.map { t in
            var t = t
            for item in launchItems {
                let program = item.program ?? ""
                let starts = t.removable.contains { r in program == r || program.hasPrefix(r + "/") || item.plistPath == r }
                    || item.arguments.contains { a in t.removable.contains { a == $0 || a.hasPrefix($0 + "/") } }
                guard starts else { continue }
                if !t.removable.contains(item.plistPath) { t.removable.append(item.plistPath) }
                let service = item.domain == .globalDaemon ? "system/\(item.label)" : "gui/\(getuid())/\(item.label)"
                if !t.services.contains(service) { t.services.append(service) }
            }
            return t
        }
    }

    static func knownMalwareThreats() -> [ProtectionThreat] {
        ProtectionKnownMalware.present().map {
            ProtectionThreat(kind: .knownMalware, severity: Status.bad.rawValue, name: $0.family,
                             detail: "Ce fichier porte exactement le nom et l'emplacement utilisés par \($0.family).",
                             path: $0.path, removable: [container(of: $0.path)])
        }
    }

    /// Where shared interpreters and tools live: never removed with a launch item that merely runs them.
    static func isSharedTool(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if LaunchItemScanner.interpreters.contains(name) || name.hasPrefix("python") || name.hasPrefix("node") { return true }
        return !Shell.isThirdParty(path) || Shell.homebrewFolders.contains { path.hasPrefix($0 + "/") }
            || path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/Cellar/")
    }

    static func persistenceThreats(_ items: [LaunchItem]) -> [ProtectionThreat] {
        items.compactMap { item in
            let identity = item.flags.filter { [.knownMalware, .impersonatesApple].contains($0) }
            // Unsigned and hidden, or in a shared folder: the usual hiding place of a dropper.
            let hidden = item.flags.contains(.unusualLocation) && (item.flags.contains(.unsigned) || item.flags.contains(.adhoc) || item.flags.contains(.script))
            let downloads = item.flags.contains(.downloader)
            guard !identity.isEmpty || hidden || downloads else { return nil }
            // One signal alone (downloads, or hides) deserves a look; together, or an identity theft, it is a threat.
            let bad = !identity.isEmpty || (downloads && (hidden || item.flags.contains(.unsigned) || item.flags.contains(.recent)))
            var removable = [item.plistPath]
            if let p = item.program, p.hasPrefix("/"), FS.exists(p), !isSharedTool(p) {
                removable.append(container(of: p))
            } else {
                // An interpreter (python3, node, sh…): the script it runs goes, never the interpreter.
                for a in item.arguments.dropFirst() where a.hasPrefix("/") && FS.exists(a) && !FS.isDirectory(a) && !isSharedTool(a) {
                    removable.append(a)
                }
            }
            let signals = identity + (downloads ? [LaunchFlag.downloader] : []) + (hidden ? [LaunchFlag.unusualLocation] : [])
            let why = signals.map(\.rawValue).joined(separator: ", ")
            return ProtectionThreat(kind: .persistence, severity: (bad ? Status.bad : Status.warn).rawValue, name: item.label,
                                    detail: "Se lance à chaque démarrage. \(why) : \(item.commandLine)", path: item.plistPath,
                                    removable: removable,
                                    services: [item.domain == .globalDaemon ? "system/\(item.label)" : "gui/\(getuid())/\(item.label)"])
        }
    }

    /// Apps whose signature no longer matches their content, and Safari extensions Apple blocks.
    static func appThreats(blocked: [String: Set<String>], isCancelled: () -> Bool) -> [ProtectionThreat] {
        var out: [ProtectionThreat] = []
        for app in appBundles() where !isCancelled() {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: app) as CFURL, [], &code) == errSecSuccess, let code else { continue }
            let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil)
            if status == errSecCSSignatureFailed || status == errSecCSSignatureInvalid {
                out.append(ProtectionThreat(kind: .tampered, severity: Status.warn.rawValue, name: (app as NSString).lastPathComponent,
                                            detail: "Son programme a été modifié après sa signature : version piratée, infectée ou abîmée. Réinstalle-la depuis la source officielle.",
                                            path: app, removable: [app]))
                continue
            }
        }
        // Safari extensions on Apple's block list.
        for ext in ProtectionExposure.safariExtensions() where blocked[ext.identifier] != nil {
            let teams = blocked[ext.identifier] ?? []
            guard teams.contains("*") || ext.team.map(teams.contains) == true else { continue }
            out.append(ProtectionThreat(kind: .blocked, severity: Status.bad.rawValue, name: ext.name,
                                        detail: "Extension Safari bloquée par Apple (\(ext.identifier)).",
                                        path: ext.container, removable: [ext.container]))
        }
        return out
    }

    static func startupFileThreats() -> [ProtectionThreat] {
        ProtectionAnchors.shellFiles.compactMap { name in
            let path = FS.home + "/" + name
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let lines = ProtectionHeuristics.suspiciousLines(text)
            guard let first = lines.first else { return nil }
            return ProtectionThreat(kind: .startup, severity: Status.warn.rawValue, name: name,
                                    detail: "À chaque Terminal ouvert, cette ligne s'exécute : \(first.prefix(160)). Retire-la de ~/\(name).",
                                    path: path, removable: [])
        }
    }

    // MARK: One file

    /// Everything that can be said about one file or app before opening it: Apple's signatures on all its code,
    /// who signed it, whether Apple notarized it, where it was downloaded from. Must not run on the main thread.
    static func inspect(_ raw: String) -> ProtectionFileVerdict {
        // A link (Homebrew's bin folder) is checked through what it points to.
        let path = ((raw as NSString).standardizingPath as NSString).resolvingSymlinksInPath
        let name = (raw as NSString).lastPathComponent
        if DemoData.isEnabled {
            return ProtectionFileVerdict(path: path, name: name, status: .ok, title: "Rien à signaler", detail: DemoData.refusal, files: 0)
        }
        var files: [String] = []
        if FS.isDirectory(path) {
            // A whole folder dropped by mistake (the home folder…) stops at 5 000 programs.
            var found = Set<String>()
            walk(path, depth: 8, wholeBundles: true, limit: 5_000, isCancelled: { false }, into: &found)
            if path.hasSuffix(".app") { found.formUnion(bundleExecutables(path)) }
            files = Array(found.sorted().prefix(5_000))
        } else {
            files = [path]
        }
        var hits: [ProtectionSignatureHit] = []
        if let sig = ProtectionSignatures.load() {
            for f in files { hits += ProtectionSignatureScanner.scan(f, with: sig) }
        }
        let origin = downloadOrigin(path)
        let from = origin.map { " Téléchargé depuis \($0)." } ?? ""
        if let hit = hits.first {
            return ProtectionFileVerdict(path: path, name: name, status: .bad, title: "Logiciel malveillant reconnu : \(hit.detection)",
                                         detail: "Les signatures d'Apple le reconnaissent. Ne l'ouvre pas, mets-le à la Corbeille.\(from)",
                                         files: files.count, threat: ProtectionThreat(kind: .signature, severity: Status.bad.rawValue, name: hit.detection,
                                                                                       detail: "Vérifié à ta demande : les signatures d'Apple le reconnaissent.",
                                                                                       path: path, removable: [container(of: path)]))
        }
        let isCode = path.hasSuffix(".app") || ProtectionSignatureScanner.probe(path)?.kind == .macho
        let sig = Signature.check(path)
        guard isCode else {
            return ProtectionFileVerdict(path: path, name: name, status: .ok, title: "Aucune menace connue",
                                         detail: "\(Fmt.plural(files.count, "fichier analysé", "fichiers analysés")) avec les signatures d'Apple.\(from)", files: files.count)
        }
        switch sig {
        case .invalid:
            return ProtectionFileVerdict(path: path, name: name, status: .warn, title: "Signature abîmée",
                                         detail: "Le contenu a été modifié après la signature : copie piratée, infectée ou corrompue. Télécharge-la depuis le site officiel.\(from)", files: files.count)
        case .unsigned, .adhoc, .personal:
            return ProtectionFileVerdict(path: path, name: name, status: .warn, title: sig == .unsigned ? "Non signée" : "Signée localement, pas par un développeur identifié",
                                         detail: "Aucune signature connue, mais personne ne répond de ce programme : venu d'Internet, macOS refuse de l'ouvrir. Normal pour un outil compilé sur ce Mac (Homebrew, développement) ; sinon, ne force son ouverture que si tu fais confiance à sa source.\(from)",
                                         files: files.count)
        case .developerID(let who):
            let notarized = isNotarized(path)
            return ProtectionFileVerdict(path: path, name: name, status: notarized ? .ok : .warn,
                                         title: notarized ? "Aucune menace connue · signée par \(who), notarisée par Apple" : "Signée par \(who), mais pas notarisée",
                                         detail: notarized ? "Apple a vérifié ce programme avant sa publication, et ses signatures ne le reconnaissent pas.\(from)"
                                                           : "Apple n'a pas vérifié cette version : prudence si elle ne vient pas du site de \(who).\(from)",
                                         files: files.count)
        case .apple, .appStore:
            return ProtectionFileVerdict(path: path, name: name, status: .ok, title: "Aucune menace connue · \(sig.label)",
                                         detail: "Signée par Apple ou distribuée par l'App Store.\(from)", files: files.count)
        case .missing, .unknown:
            return ProtectionFileVerdict(path: path, name: name, status: .ok, title: "Aucune menace connue",
                                         detail: "\(Fmt.plural(files.count, "fichier analysé", "fichiers analysés")) avec les signatures d'Apple.\(from)", files: files.count)
        }
    }

    /// Notarized by Apple (the "notarized" code requirement).
    static func isNotarized(_ path: String) -> Bool {
        var code: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("notarized" as CFString, [], &req) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), req) == errSecSuccess
    }

    /// The site a file came from, as macOS noted it when it was downloaded.
    static func downloadOrigin(_ path: String) -> String? {
        let attr = "com.apple.metadata:kMDItemWhereFroms"
        let size = getxattr(path, attr, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, attr, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size, let list = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String],
              let first = list.first, let host = URL(string: first)?.host else { return nil }
        return host
    }

    // MARK: Removal

    /// Stops what runs (services, processes started from the files), then moves the files to the Trash.
    /// A root service or file makes macOS ask for the administrator password. Must not run on the main thread.
    static func remove(_ t: ProtectionThreat) -> RemovalReport {
        if DemoData.isEnabled { return RemovalReport(failures: t.removable.map { ($0, DemoData.refusal) }) }
        for service in t.services {
            if service.hasPrefix("system/") {
                let label = String(service.dropFirst(7))
                guard LaunchItemScanner.isPlainLabel(label) else { continue }
                // Stopped, not disabled for good: without its file (in the Trash) it does not come back, and put back
                // from the Trash it starts again like before.
                _ = Shell.runAsAdmin("/bin/launchctl bootout 'system/\(label)' 2>/dev/null; true")
            } else {
                _ = Shell.run("/bin/launchctl", ["bootout", service])
            }
        }
        terminateProcesses(under: t.removable)
        var report = RemovalReport()
        for path in t.removable {
            report.merge(Remover.quarantine(path, reason: t.name))
        }
        return report
    }

    /// Ends the user's processes whose executable is one of `paths` or inside one of them: asked to quit first,
    /// forced a second later if still there.
    static func terminateProcesses(under paths: [String]) {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var found: [pid_t] = []
        for pid in pids.prefix(max(0, count)) where pid > 1 && pid != getpid() {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let exe = String(cString: buffer)
            if paths.contains(where: { exe == $0 || exe.hasPrefix($0 + "/") }) { found.append(pid) }
        }
        guard !found.isEmpty else { return }
        found.forEach { kill($0, SIGTERM) }
        Thread.sleep(forTimeInterval: 1)
        found.forEach { kill($0, SIGKILL) }
    }
}
