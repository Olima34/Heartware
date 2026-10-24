import Foundation

/// Apple's malware signatures, read from the XProtect bundle macOS keeps up to date by itself (Réglages › Mise à jour
/// de logiciels › Réponses de sécurité), compiled once per version. Nothing is downloaded by the app.
enum ProtectionSignatures {
    struct Loaded: @unchecked Sendable {
        let version: Int
        let installed: Date?
        let bundlePath: String
        /// XProtect.yara: executables, installers, scripts.
        let binary: ProtectionYaraRuleset
        /// XPScripts.yr: AppleScript and JavaScript for Automation run by osascript.
        let scripts: ProtectionYaraRuleset?
        /// Safari extensions Apple blocks: bundle identifier → developer team identifiers.
        let blockedExtensions: [String: Set<String>]

        var ruleCount: Int { binary.publicRuleCount + (scripts?.publicRuleCount ?? 0) }
        var skipped: [String] { binary.skipped + (scripts?.skipped ?? []) }
    }

    static let bundles = ["/Library/Apple/System/Library/CoreServices/XProtect.bundle",
                          "/private/var/protected/xprotect/XProtect.bundle"]

    /// The most recent of the XProtect bundles on this Mac.
    static func newest() -> (path: String, version: Int, date: Date?)? {
        if DemoData.isEnabled { return (bundles[0], 5367, Date().addingTimeInterval(-4 * 86400)) }
        var best: (path: String, version: Int, date: Date?)?
        for b in bundles {
            let info = b + "/Contents/Info.plist"
            guard let dict = NSDictionary(contentsOfFile: info),
                  let v = Int(dict["CFBundleShortVersionString"] as? String ?? ""),
                  FS.exists(b + "/Contents/Resources/XProtect.yara") else { continue }
            if best == nil || v > best!.version { best = (b, v, FS.modified(info)) }
        }
        return best
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var loaded: Loaded?
        var lastUse = Date.distantPast
        var forgetScheduled = false
    }
    private static let cache = Cache()

    /// Compiled signatures weigh a dozen megabytes: they are let go after ten minutes without a file to check.
    static let keptFor: TimeInterval = 600

    /// Compiles the signatures (about a second), or hands back the ones already compiled for this version.
    static func load() -> Loaded? {
        guard let found = newest() else { return nil }
        cache.lock.lock()
        defer { cache.lock.unlock() }
        cache.lastUse = Date()
        scheduleForget()
        if let l = cache.loaded, l.version == found.version, l.bundlePath == found.path { return l }
        let res = found.path + "/Contents/Resources/"
        guard let yara = try? String(contentsOfFile: res + "XProtect.yara", encoding: .utf8) else { return nil }
        let scripts = (try? String(contentsOfFile: res + "XPScripts.yr", encoding: .utf8)).map { ProtectionYaraRuleset(source: $0) }
        var blocked: [String: Set<String>] = [:]
        if let meta = NSDictionary(contentsOfFile: res + "XProtect.meta.plist") as? [String: Any],
           let list = (meta["ExtensionBlacklist"] as? [String: Any])?["Extensions"] as? [[String: Any]] {
            for e in list {
                guard let id = e["CFBundleIdentifier"] as? String else { continue }
                blocked[id, default: []].insert(e["Developer Identifier"] as? String ?? "*")
            }
        }
        let l = Loaded(version: found.version, installed: found.date, bundlePath: found.path,
                       binary: ProtectionYaraRuleset(source: yara), scripts: scripts, blockedExtensions: blocked)
        cache.loaded = l
        return l
    }

    /// Called with the lock held.
    private static func scheduleForget() {
        guard !cache.forgetScheduled else { return }
        cache.forgetScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + keptFor) {
            cache.lock.lock()
            defer { cache.lock.unlock() }
            cache.forgetScheduled = false
            if Date().timeIntervalSince(cache.lastUse) >= keptFor - 1 {
                cache.loaded = nil
            } else {
                scheduleForget()
            }
        }
    }
}

/// What kind of file the signatures apply to, judged from its first bytes.
enum ProtectionFileKind: Equatable {
    case macho
    case script(interpreter: String)
    case appleScript
    case installer

    /// The biggest file of each kind worth reading (malware is small; a big framework costs seconds).
    var maxSize: Int64 {
        switch self {
        case .macho: return 200 << 20
        case .installer: return 120 << 20
        case .script, .appleScript: return 8 << 20
        }
    }

    static func of(header h: [UInt8], path: String) -> ProtectionFileKind? {
        guard h.count >= 4 else { return nil }
        let le = UInt32(h[0]) | UInt32(h[1]) << 8 | UInt32(h[2]) << 16 | UInt32(h[3]) << 24
        // Mach-O 32/64 bits in both byte orders, and universal binaries (0xcafebabe is also a Java class: only
        // a universal binary has a small architecture count right after).
        if [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe].contains(le) { return .macho }
        if le == 0xbebafeca, h.count >= 8, h[4] == 0, h[5] == 0, h[6] == 0, (1...16).contains(h[7]) { return .macho }
        if h.starts(with: Array("xar!".utf8)) { return .installer }
        if h.starts(with: Array("FasdUAS".utf8)) || h.starts(with: Array("JsOsaDAS".utf8)) { return .appleScript }
        if h[0] == UInt8(ascii: "#"), h[1] == UInt8(ascii: "!") {
            let line = String(decoding: h.prefix { $0 != 0x0A }.dropFirst(2), as: UTF8.self)
            var words = line.split(separator: " ").map(String.init)
            if let first = words.first, (first as NSString).lastPathComponent == "env" {
                words.removeFirst()
                while words.first?.hasPrefix("-") == true { words.removeFirst() }
            }
            let interpreter = (words.first.map { ($0 as NSString).lastPathComponent } ?? "sh")
            return .script(interpreter: interpreter)
        }
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "applescript" { return .appleScript }
        return nil
    }
}

/// A signature that recognized a file.
struct ProtectionSignatureHit: Hashable {
    /// What Apple calls it ("MACOS.644e18d", "OSX.Bundlore.D"…).
    let detection: String
    let rule: String
}

enum ProtectionSignatureScanner {
    /// Extensions read even without the executable bit (a script or an installer just downloaded).
    static let extensions: Set<String> = ["dylib", "so", "pkg", "mpkg", "scpt", "applescript", "sh", "command", "tool",
                                          "zsh", "bash", "py", "rb", "pl", "php", "terminal", "workflow"]

    /// The first bytes of a regular file, its kind and size; nil for anything not worth reading.
    /// Only executables and the extensions above are opened at all.
    static func probe(_ path: String) -> (kind: ProtectionFileKind, size: Int64)? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size >= 16 else { return nil }
        // A file iCloud keeps online only: reading it would download it.
        if st.st_flags & 0x4000_0000 != 0 { return nil }
        guard st.st_mode & 0o111 != 0 || extensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 256) else { return nil }
        guard let kind = ProtectionFileKind.of(header: Array(head), path: path), Int64(st.st_size) <= kind.maxSize else { return nil }
        return (kind, Int64(st.st_size))
    }

    /// Runs the signatures that apply to this file. Must not run on the main thread.
    static func scan(_ path: String, with sig: ProtectionSignatures.Loaded) -> [ProtectionSignatureHit] {
        // Read into memory: a mapped file that shrinks while it is read (a download restarted, a disk unplugged) would
        // crash the app. Only the big ones are mapped.
        guard let (kind, size) = probe(path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: size > 32 << 20 ? [.alwaysMapped, .uncached] : [.uncached])
        else { return [] }
        return scan(data, kind: kind, with: sig)
    }

    static func scan(_ data: Data, kind: ProtectionFileKind, with sig: ProtectionSignatures.Loaded) -> [ProtectionSignatureHit] {
        var rules = sig.binary.scan(data)
        // The script signatures are written for what osascript runs: applied to anything else they would see
        // the names of browsers or wallets in a perfectly normal app.
        let osascript: Bool
        switch kind {
        case .appleScript: osascript = true
        case .script(let interpreter): osascript = interpreter == "osascript"
        default: osascript = false
        }
        if osascript, let scripts = sig.scripts { rules += scripts.scan(data) }
        return rules.map { ProtectionSignatureHit(detection: $0.detection, rule: $0.name) }
    }
}
