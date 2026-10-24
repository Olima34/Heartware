import Foundation
import Security
import Observation

enum LaunchDomain: String, CaseIterable {
    case userAgent, globalAgent, globalDaemon

    var title: String {
        switch self {
        case .userAgent: return "Agents de ta session"
        case .globalAgent: return "Agents de tous les utilisateurs"
        case .globalDaemon: return "Services système"
        }
    }

    var folder: String {
        switch self {
        case .userAgent: return FS.home + "/Library/LaunchAgents"
        case .globalAgent: return "/Library/LaunchAgents"
        case .globalDaemon: return "/Library/LaunchDaemons"
        }
    }

    var needsAdmin: Bool { self == .globalDaemon }
}

enum SignatureKind: Hashable {
    case apple, appStore, developerID(String), adhoc, unsigned, invalid, missing, unknown
    /// Signed with a certificate Apple did not issue (self-made, or from another authority): nobody vouches for it.
    case personal(String)

    var label: String {
        switch self {
        case .apple: return "Apple"
        case .appStore: return "App Store"
        case .developerID(let name): return name
        case .personal(let name): return "Certificat personnel (\(name))"
        case .adhoc: return "Signature locale"
        case .unsigned: return "Non signé"
        case .invalid: return "Signature invalide"
        case .missing: return "Programme introuvable"
        case .unknown: return "Non vérifiable"
        }
    }

    var isTrusted: Bool {
        switch self {
        case .apple, .appStore, .developerID: return true
        default: return false
        }
    }
}

enum LaunchFlag: String, Hashable {
    case knownMalware = "Logiciel malveillant connu"
    case impersonatesApple = "Se fait passer pour Apple"
    case downloader = "Télécharge et exécute du code"
    case orphan = "Programme introuvable"
    case unsigned = "Non signé"
    case invalidSignature = "Signature invalide"
    case unusualLocation = "Emplacement inhabituel"
    case script = "Lance un script"
    case adhoc = "Signature locale"
    case recent = "Ajouté récemment"

    var severity: Status {
        switch self {
        case .knownMalware, .impersonatesApple, .invalidSignature, .unusualLocation: return .bad
        case .downloader, .unsigned, .orphan, .script, .adhoc: return .warn
        case .recent: return .info
        }
    }
}

struct LaunchItem: Identifiable, Hashable {
    var id: String { plistPath }
    let label: String
    let plistPath: String
    let domain: LaunchDomain
    let program: String?
    let arguments: [String]
    let runAtLoad: Bool
    let keepAlive: Bool
    var disabled: Bool
    var running: Bool
    var signature: SignatureKind
    var vendor: String
    var appPath: String?
    var flags: [LaunchFlag]

    var risk: Status {
        flags.map(\.severity).filter { $0 != .info }.max() ?? (signature == .apple ? .ok : .info)
    }

    /// Worth a look: a flag above "information".
    var isFlagged: Bool { flags.contains { $0.severity >= .warn } }

    var commandLine: String {
        arguments.isEmpty ? (program ?? "—") : arguments.joined(separator: " ")
    }
}

/// Lists what launchd starts on its own (LaunchAgents / LaunchDaemons) and checks who signed it.
enum LaunchItemScanner {
    static let interpreters: Set<String> = ["sh", "bash", "zsh", "dash", "python", "python3", "perl", "ruby", "osascript",
                                            "node", "php", "tclsh", "pwsh"]

    static func scan() -> [LaunchItem] {
        if DemoData.isEnabled { return DemoData.launchItems() }
        let uid = getuid()
        let guiDisabled = parseDisabled(Shell.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]).out)
        let sysDisabled = parseDisabled(Shell.run("/bin/launchctl", ["print-disabled", "system"]).out)
        let loaded = parseList(Shell.run("/bin/launchctl", ["list"]).out)

        var plists: [(String, LaunchDomain)] = []
        for d in LaunchDomain.allCases {
            for name in FS.children(d.folder) where name.hasSuffix(".plist") {
                plists.append((d.folder + "/" + name, d))
            }
        }
        let slots = Slots<LaunchItem>(count: plists.count)
        DispatchQueue.concurrentPerform(iterations: plists.count) { i in
            let (path, domain) = plists[i]
            if let item = parse(path, domain: domain, guiDisabled: guiDisabled, sysDisabled: sysDisabled, loaded: loaded) {
                _ = slots.set(i, item)
            }
        }
        return slots.all.sorted { a, b in
            a.risk != b.risk ? a.risk > b.risk : a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
    }

    static func parse(_ path: String, domain: LaunchDomain, guiDisabled: [String: Bool], sysDisabled: [String: Bool],
                      loaded: [String: Bool]) -> LaunchItem? {
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
        let label = dict["Label"] as? String ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let args = dict["ProgramArguments"] as? [String] ?? []
        let program = (dict["Program"] as? String) ?? args.first
        let keepAlive = (dict["KeepAlive"] as? Bool) ?? (dict["KeepAlive"] is [String: Any])
        let runAtLoad = dict["RunAtLoad"] as? Bool ?? false
        let overrides = domain == .globalDaemon ? sysDisabled : guiDisabled
        let disabled = overrides[label] ?? (dict["Disabled"] as? Bool ?? false)

        var flags: [LaunchFlag] = []
        var signature = SignatureKind.unknown
        var appPath: String?
        if let program, program.hasPrefix("/") {
            let exe = (program as NSString).lastPathComponent
            if !FS.exists(program) {
                signature = .missing
                flags.append(.orphan)
            } else {
                signature = Signature.check(program)
                switch signature {
                case .unsigned: flags.append(.unsigned)
                case .invalid: flags.append(.invalidSignature)
                case .adhoc: flags.append(.adhoc)
                default: break
                }
                if interpreters.contains(exe) { flags.append(.script) }
            }
            let unusual = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", "/Users/Shared/"]
            let devHidden = ["/.venv/", "/.pyenv/", "/.nvm/", "/.local/", "/.cargo/", "/.bun/", "/.deno/", "/.rbenv/",
                             "/.asdf/", "/.volta/", "/.npm-global/", "/.orbstack/", "/.docker/", "/.nix-profile/", "/.mise/",
                             "/.fnm/", "/.sdkman/", "/.jenv/", "/.proto/", "/.rustup/", "/.goenv/", "/.colima/", "/.lima/"]
            let hidden = program.contains("/.") && !devHidden.contains(where: { program.contains($0) })
            if unusual.contains(where: { program.hasPrefix($0) }) || hidden {
                flags.append(.unusualLocation)
            }
            if let r = program.range(of: ".app/") { appPath = String(program[..<r.lowerBound]) + ".app" }
        }
        // A third-party item named like Apple's own (com.apple.questd, com.apple.iCloud.sync.daemon…): Apple's agents
        // are signed by Apple, and the real ones live in /System.
        if label.lowercased().hasPrefix("com.apple.") || (path as NSString).lastPathComponent.lowercased().hasPrefix("com.apple."),
           let program, program.hasPrefix("/"), signature != .apple || flags.contains(.script) {
            flags.append(.impersonatesApple)
        }
        if ProtectionHeuristics.isDownloader(args.joined(separator: " ")) ||
            (flags.contains(.script) && ProtectionHeuristics.scriptDownloads(arguments: args)) {
            flags.append(.downloader)
        }
        if ProtectionKnownMalware.match(path) != nil || program.flatMap(ProtectionKnownMalware.match) != nil {
            flags.insert(.knownMalware, at: 0)
        }
        if let added = FS.modified(path), Date().timeIntervalSince(added) < 7 * 86400, signature != .apple {
            flags.append(.recent)
        }
        let vendor: String = {
            if case .developerID(let n) = signature { return n }
            if signature == .apple { return "Apple" }
            if let appPath { return (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }
            return label.split(separator: ".").dropFirst().first.map(String.init) ?? label
        }()
        return LaunchItem(label: label, plistPath: path, domain: domain, program: program, arguments: args,
                          runAtLoad: runAtLoad, keepAlive: keepAlive, disabled: disabled,
                          running: loaded[label] ?? false, signature: signature, vendor: vendor, appPath: appPath, flags: flags)
    }

    /// `"label" => disabled|enabled|true|false` lines.
    static func parseDisabled(_ text: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let v = parts[1].trimmingCharacters(in: .whitespaces)
            out[label] = v == "disabled" || v == "true"
        }
        return out
    }

    /// `launchctl list`: PID, status, label. A PID means it runs now.
    static func parseList(_ text: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }
            out[String(cols[2])] = cols[0] != "-"
        }
        return out
    }

    // MARK: Actions

    /// A label or plist path safe to hand to a root shell: letters, digits, dots, dashes and underscores only
    /// (the label comes from a file anyone with the right access may have written).
    static func isPlainLabel(_ label: String) -> Bool {
        !label.isEmpty && label.count <= 200 && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
    }

    static func adminCommand(label: String, plist: String, disable: Bool) -> String? {
        guard isPlainLabel(label), plist.hasPrefix(LaunchDomain.globalDaemon.folder + "/"),
              isPlainLabel((plist as NSString).lastPathComponent), !plist.contains("/../") else { return nil }
        let target = "'system/\(label)'"
        return disable
            ? "/bin/launchctl disable \(target); /bin/launchctl bootout \(target) 2>/dev/null; true"
            : "/bin/launchctl enable \(target); /bin/launchctl bootstrap system '\(plist)' 2>/dev/null; true"
    }

    static func setDisabled(_ item: LaunchItem, _ disable: Bool) -> String? {
        let uid = getuid()
        if item.domain == .globalDaemon {
            guard let cmd = adminCommand(label: item.label, plist: item.plistPath, disable: disable) else {
                return "son nom contient des caractères inhabituels : je ne le confie pas à une commande administrateur."
            }
            let r = Shell.runAsAdmin(cmd)
            return r.ok ? nil : r.err
        }
        let target = "gui/\(uid)/\(item.label)"
        if disable {
            let r = Shell.run("/bin/launchctl", ["disable", target])
            _ = Shell.run("/bin/launchctl", ["bootout", target])
            return r.ok ? nil : r.all
        } else {
            let r = Shell.run("/bin/launchctl", ["enable", target])
            _ = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", item.plistPath])
            return r.ok ? nil : r.all
        }
    }

    /// Stops a user agent and moves its plist to the Trash.
    static func remove(_ item: LaunchItem) -> RemovalReport {
        guard item.domain == .userAgent else { return RemovalReport() }
        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(item.label)"])
        return Remover.remove([RemovalEntry(path: item.plistPath, size: FileSizer.size(of: item.plistPath))], mode: .trash)
    }
}

/// Code signature checks through the Security framework.
enum Signature {
    static func check(_ path: String) -> SignatureKind {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return .unknown
        }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        let validity = SecStaticCodeCheckValidity(code, flags, nil)
        if validity == errSecCSUnsigned { return .unsigned }

        var req: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &req) == errSecSuccess,
           SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess {
            return .apple
        }
        guard validity == errSecSuccess else { return .invalid }

        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let dict = info as? [String: Any] ?? [:]
        guard let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first else {
            return .adhoc
        }
        let summary = SecCertificateCopySubjectSummary(leaf) as String? ?? ""
        if summary.hasPrefix("Apple Mac OS Application Signing") || summary.hasPrefix("Apple iPhone OS Application Signing") {
            return .appStore
        }
        // A Developer ID certificate is issued by Apple: anything else is a certificate someone made for themselves.
        var generic: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &generic) == errSecSuccess,
              SecStaticCodeCheckValidity(code, flags, generic) == errSecSuccess else {
            return .personal(summary.isEmpty ? "?" : summary)
        }
        // "Developer ID Application: Company (TEAMID)" → "Company"
        var name = summary.replacingOccurrences(of: "Developer ID Application: ", with: "")
        if let r = name.range(of: " (", options: .backwards) { name = String(name[..<r.lowerBound]) }
        return .developerID(name.isEmpty ? (dict[kSecCodeInfoTeamIdentifier as String] as? String ?? "Développeur") : name)
    }
}

/// Shared by Protection (security view) and Optimisation (startup view).
@Observable
@MainActor
final class StartupModel {
    var items: [LaunchItem] = []
    var isScanning = false
    var lastScan: Date?
    var busy: Set<String> = []
    var message: String?
    /// False when `message` reports a failure (shown as a warning, not as "done").
    var messageOK = true

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        message = nil
        items = await Task.detached(priority: .userInitiated) { LaunchItemScanner.scan() }.value
        lastScan = Date()
        isScanning = false
    }

    var thirdParty: [LaunchItem] { items.filter { $0.signature != .apple } }
    var flagged: [LaunchItem] { items.filter(\.isFlagged) }
    var activeCount: Int { thirdParty.filter { !$0.disabled }.count }

    func setDisabled(_ item: LaunchItem, _ disable: Bool) async {
        busy.insert(item.id)
        let error = await Task.detached { LaunchItemScanner.setDisabled(item, disable) }.value
        busy.remove(item.id)
        if let error, !error.isEmpty {
            messageOK = false
            message = "Impossible de modifier « \(item.label) » : \(error)"
        } else if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i].disabled = disable
            if disable { items[i].running = false }
        }
    }

    func remove(_ item: LaunchItem) async {
        busy.insert(item.id)
        let report = await Task.detached { LaunchItemScanner.remove(item) }.value
        busy.remove(item.id)
        if report.removed > 0 {
            items.removeAll { $0.id == item.id }
            messageOK = true
            message = "« \(item.label) » est arrêté et son fichier est dans la Corbeille."
        } else {
            messageOK = false
            message = "Impossible de supprimer « \(item.label) »."
        }
    }
}
