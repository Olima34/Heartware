import Foundation
import AppKit
import CoreGraphics

/// A program that receives every key typed on the Mac (an event tap on the keyboard), like ReiKey shows them.
struct ProtectionKeyboardTap: Identifiable, Hashable {
    var id: String { "\(pid)-\(path)" }
    let pid: Int32
    let name: String
    let path: String
    let signature: SignatureKind
    /// Listen only (it reads) or active (it can also change or swallow keys).
    let canModify: Bool
    var appPath: String? { path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } }

    var risk: Status {
        switch signature {
        case .apple, .appStore: return .ok
        case .developerID: return .info
        default: return .bad
        }
    }
}

/// A browser extension and what it may do.
struct ProtectionBrowserExtension: Identifiable, Hashable {
    var id: String { browser + "|" + identifier }
    let browser: String
    let identifier: String
    let name: String
    /// It can read and change every page (all sites, cookies, requests…).
    let readsEverything: Bool
    /// Installed by a policy (an administrator, or adware), not by the user.
    let forced: Bool
    let enabled: Bool
    var container: String
    var team: String? = nil
}

enum ProtectionExposure {
    // MARK: Keyboard

    static func keyboardTaps() -> [ProtectionKeyboardTap] {
        if DemoData.isEnabled { return ProtectionDemo.keyboardTaps() }
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &list, &count) == .success else { return [] }
        let keys: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        var seen = Set<String>()
        var out: [ProtectionKeyboardTap] = []
        for t in list.prefix(Int(count)) where t.enabled && t.eventsOfInterest & keys != 0 {
            let pid = Int32(t.tappingProcess)
            guard pid > 0, let path = NetworkPorts.executablePath(pid) else { continue }
            guard seen.insert("\(pid)|\(path)").inserted else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            let name = app?.localizedName ?? (path as NSString).lastPathComponent
            out.append(ProtectionKeyboardTap(pid: pid, name: name, path: path, signature: Signature.check(path),
                                             canModify: t.options.rawValue == 0))
        }
        return out.sorted { a, b in a.risk != b.risk ? a.risk > b.risk : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
    }

    // MARK: Browser extensions

    /// Chromium browsers: name, folder of their profiles under Application Support.
    static let chromium: [(name: String, folder: String, policy: String)] = [
        ("Chrome", "Google/Chrome", "com.google.Chrome"), ("Edge", "Microsoft Edge", "com.microsoft.Edge"),
        ("Brave", "BraveSoftware/Brave-Browser", "com.brave.Browser"), ("Arc", "Arc/User Data", "company.thebrowser.Browser"),
        ("Vivaldi", "Vivaldi", "com.vivaldi.Vivaldi"), ("Opera", "com.operasoftware.Opera", "com.operasoftware.Opera")
    ]

    static func browserExtensions() -> [ProtectionBrowserExtension] {
        if DemoData.isEnabled { return ProtectionDemo.browserExtensions() }
        var out: [ProtectionBrowserExtension] = []
        let support = FS.home + "/Library/Application Support/"
        for b in chromium {
            let root = support + b.folder
            let profiles = FS.children(root).filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            var forced = Set<String>()
            for policies in ["/Library/Managed Preferences/" + b.policy + ".plist", "/Library/Managed Preferences/" + NSUserName() + "/" + b.policy + ".plist"] {
                if let d = NSDictionary(contentsOfFile: policies) as? [String: Any], let list = d["ExtensionInstallForcelist"] as? [String] {
                    forced.formUnion(list.compactMap { $0.split(separator: ";").first.map(String.init) })
                }
            }
            for profile in profiles {
                let prefs = chromiumPreferences(root + "/" + profile)
                for id in FS.children(root + "/" + profile + "/Extensions") where id.count == 32 {
                    let dir = root + "/" + profile + "/Extensions/" + id
                    guard let version = FS.children(dir).last,
                          let manifest = (try? Data(contentsOf: URL(fileURLWithPath: dir + "/" + version + "/manifest.json")))
                            .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { continue }
                    let name = localizedName(manifest, dir: dir + "/" + version)
                    // The browser's own components (Web Store, payments…) are part of it.
                    let state = prefs[id]
                    if state?.component == true { continue }
                    out.append(ProtectionBrowserExtension(browser: b.name, identifier: id, name: name,
                                                          readsEverything: readsEverything(manifest),
                                                          forced: forced.contains(id) || state?.policy == true,
                                                          enabled: state?.enabled ?? true, container: dir))
                }
            }
        }
        out += firefoxExtensions()
        out += safariExtensions()
        var unique: [String: ProtectionBrowserExtension] = [:]
        for e in out where unique[e.id] == nil { unique[e.id] = e }
        return unique.values.sorted { a, b in
            (a.forced ? 0 : 1, a.readsEverything ? 0 : 1, a.browser, a.name) < (b.forced ? 0 : 1, b.readsEverything ? 0 : 1, b.browser, b.name)
        }
    }

    /// From a Chromium profile's Preferences: which extensions are enabled, installed by policy, or part of the browser.
    static func chromiumPreferences(_ profile: String) -> [String: (enabled: Bool, policy: Bool, component: Bool)] {
        var out: [String: (enabled: Bool, policy: Bool, component: Bool)] = [:]
        for file in ["Secure Preferences", "Preferences"] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: profile + "/" + file)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let settings = (json["extensions"] as? [String: Any])?["settings"] as? [String: Any] else { continue }
            for (id, raw) in settings {
                guard let s = raw as? [String: Any], out[id] == nil else { continue }
                // Chromium's ManifestLocation: 5 and 10, the browser's own components; 7 and 9, a policy; 2 and 6, another
                // program's "external extensions" file (an adware's favourite way in). 1 is the Web Store, 4 unpacked.
                let location = s["location"] as? Int ?? 1
                let disabled = (s["disable_reasons"] as? [Any]).map { !$0.isEmpty } ?? ((s["disable_reasons"] as? Int ?? 0) != 0)
                out[id] = (!disabled && (s["state"] as? Int ?? 1) != 0, [2, 6, 7, 9].contains(location), location == 5 || location == 10)
            }
        }
        return out
    }

    /// "__MSG_appName__" names live in _locales: French first, then English.
    static func localizedName(_ manifest: [String: Any], dir: String) -> String {
        let raw = manifest["name"] as? String ?? "?"
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__") else { return raw }
        let key = String(raw.dropFirst(6).dropLast(2)).lowercased()
        let locales = [manifest["default_locale"] as? String, "fr", "en", "en_US"].compactMap { $0 }
        for l in locales {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/_locales/" + l + "/messages.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let entry = json.first(where: { $0.key.lowercased() == key })?.value as? [String: Any],
               let message = entry["message"] as? String { return message }
        }
        return raw
    }

    /// Host access to every site: it sees (and may change) everything the user does on the web.
    static func readsEverything(_ manifest: [String: Any]) -> Bool {
        let wide: Set<String> = ["<all_urls>", "*://*/*", "http://*/*", "https://*/*", "http://*/", "https://*/"]
        var perms = (manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        perms += (manifest["host_permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        for cs in manifest["content_scripts"] as? [[String: Any]] ?? [] { perms += cs["matches"] as? [String] ?? [] }
        return perms.contains { wide.contains($0) }
    }

    static func firefoxExtensions() -> [ProtectionBrowserExtension] {
        let root = FS.home + "/Library/Application Support/Firefox/Profiles"
        var out: [ProtectionBrowserExtension] = []
        for profile in FS.children(root) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: root + "/" + profile + "/extensions.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let addons = json["addons"] as? [[String: Any]] else { continue }
            for a in addons where (a["type"] as? String) == "extension" && (a["location"] as? String) != "app-builtin"
                && (a["location"] as? String) != "app-system-defaults" {
                let id = a["id"] as? String ?? "?"
                let name = ((a["defaultLocale"] as? [String: Any])?["name"] as? String) ?? id
                let hosts = ((a["userPermissions"] as? [String: Any])?["origins"] as? [String]) ?? []
                out.append(ProtectionBrowserExtension(browser: "Firefox", identifier: id, name: name,
                                                      readsEverything: hosts.contains { ["<all_urls>", "*://*/*", "https://*/*"].contains($0) },
                                                      forced: (a["location"] as? String) == "app-system-addons" || (a["installTelemetryInfo"] as? [String: Any])?["source"] as? String == "enterprise-policy",
                                                      enabled: a["active"] as? Bool ?? true, container: root + "/" + profile))
            }
        }
        return out
    }

    /// Safari extensions registered on this Mac (pluginkit), with the developer who signed them.
    static func safariExtensions() -> [ProtectionBrowserExtension] {
        if DemoData.isEnabled { return [] }
        var out: [ProtectionBrowserExtension] = []
        for point in ["com.apple.Safari.web-extension", "com.apple.Safari.extension", "com.apple.Safari.content-blocker"] {
            let text = Shell.run("/usr/bin/pluginkit", ["-mAv", "-p", point]).out
            for line in text.split(separator: "\n") {
                // "  +    com.example.Ext(1.2)\tUUID\tdate\t/Applications/Example.app/Contents/PlugIns/Ext.appex"
                let cols = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
                guard cols.count >= 4, let path = cols.last, path.hasSuffix(".appex") else { continue }
                var id = cols[0]
                let disabled = id.hasPrefix("-")
                id = id.trimmingCharacters(in: CharacterSet(charactersIn: "+-=! "))
                if let p = id.firstIndex(of: "(") { id = String(id[..<p]) }
                let app = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } ?? path
                let name = (NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleDisplayName"] as? String)
                    ?? ((app as NSString).lastPathComponent as NSString).deletingPathExtension
                var team: String?
                var code: SecStaticCode?
                if SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code {
                    var info: CFDictionary?
                    SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                    team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
                }
                out.append(ProtectionBrowserExtension(browser: "Safari", identifier: id, name: name,
                                                      readsEverything: point == "com.apple.Safari.web-extension",
                                                      forced: false, enabled: !disabled, container: app, team: team))
            }
        }
        return out
    }

    // MARK: Network

    /// Ports of this user's programs reachable from the network (lsof sees only the user's own without a password).
    static func exposedPorts() -> [NetworkPort] {
        if DemoData.isEnabled { return ProtectionDemo.exposedPorts() }
        guard case .success(let ports) = NetworkPorts.scan() else { return [] }
        return ports.filter(\.isExposed)
    }

    static func selfTest() -> [String] {
        var f: [String] = []
        if !readsEverything(["host_permissions": ["<all_urls>"]]) { f.append("Extension lisant tous les sites non repérée") }
        if !readsEverything(["content_scripts": [["matches": ["https://*/*"]]]]) { f.append("Script de contenu sur tous les sites non repéré") }
        if readsEverything(["permissions": ["storage", "https://example.com/*"]]) { f.append("Extension limitée prise pour une extension qui lit tout") }
        return f
    }
}
