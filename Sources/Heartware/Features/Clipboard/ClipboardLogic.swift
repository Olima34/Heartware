import Foundation
import SwiftUI

// Pure parts of the clipboard history: what an item is, what is never recorded, how the list is kept tidy.

enum ClipboardKind: String, Codable, CaseIterable {
    case text, image, files
}

struct ClipboardImageInfo: Codable, Hashable {
    /// File names inside the module's data folder (never paths).
    var file: String
    var thumb: String
    var width: Int
    var height: Int
    var bytes: Int
}

struct ClipboardItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: ClipboardKind
    var text: String? = nil
    var files: [String]? = nil
    var image: ClipboardImageInfo? = nil
    /// SHA-256 of the content: copying the same thing again moves it up instead of adding a twin.
    var digest: String
    var date: Date
    var firstDate: Date
    var count = 1
    var pinned = false
    var appName: String? = nil
    var appBundleID: String? = nil
    var appPath: String? = nil

    /// What the item weighs in the history (text in the JSON file, images in the data folder).
    var bytes: Int {
        switch kind {
        case .text: return text?.utf8.count ?? 0
        case .image: return (image?.bytes ?? 0) + 8_000
        case .files: return (files ?? []).reduce(0) { $0 + $1.utf8.count }
        }
    }

    var textKind: ClipboardTextKind { kind == .text ? ClipboardText.kind(of: text ?? "") : .plain }

    /// One line for lists and the launcher.
    var title: String {
        switch kind {
        case .text: return ClipboardText.title(text ?? "")
        case .image:
            guard let i = image else { return "Image" }
            return "Image \(Fmt.int(i.width)) × \(Fmt.int(i.height))"
        case .files:
            let f = files ?? []
            guard let first = f.first else { return "Fichiers" }
            let name = (first as NSString).lastPathComponent
            return f.count == 1 ? name : "\(name) et \(Fmt.plural(f.count - 1, "autre", "autres"))"
        }
    }

    /// Accent and case insensitive text that searches look into.
    var searchKey: String {
        var parts: [String] = []
        switch kind {
        case .text: parts.append(String((text ?? "").prefix(4000)))
        case .image: parts.append("image photo capture")
        case .files: parts += (files ?? []).map { ($0 as NSString).lastPathComponent } + ["fichier"]
        }
        if let appName { parts.append(appName) }
        if textKind == .link { parts.append("lien url") }
        return Fuzzy.fold(parts.joined(separator: " "))
    }
}

enum ClipboardTextKind: Equatable {
    case plain, link, color, code
}

enum ClipboardText {
    /// The first non-empty line, spaces squeezed, cut at 300 characters.
    static func title(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) } ?? ""
        let squeezed = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return squeezed.count > 300 ? String(squeezed.prefix(300)) + "…" : squeezed
    }

    static func lineCount(_ s: String) -> Int {
        s.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).count
    }

    static func kind(of raw: String) -> ClipboardTextKind {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .plain }
        if s.count < 2048, !s.contains(where: \.isWhitespace), let url = URL(string: s), let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp", "mailto", "ssh", "file"].contains(scheme), url.host != nil || scheme == "mailto" {
            return .link
        }
        if color(s) != nil { return .color }
        let lines = s.split(whereSeparator: \.isNewline)
        if lines.count >= 2 {
            let symbols = s.reduce(0) { $0 + ("{}();=<>[]".contains($1) ? 1 : 0) }
            let indented = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
            if Double(symbols) / Double(s.count) > 0.03 || indented * 3 >= lines.count { return .code }
        }
        return .plain
    }

    /// "#RGB", "#RRGGBB" or "#RRGGBBAA" as a color (for the swatch next to the item).
    static func color(_ s: String) -> Color? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("#") else { return nil }
        var hex = String(t.dropFirst())
        guard [3, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let v = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 8 {
            return Color(.sRGB, red: Double((v >> 24) & 0xFF) / 255, green: Double((v >> 16) & 0xFF) / 255,
                         blue: Double((v >> 8) & 0xFF) / 255, opacity: Double(v & 0xFF) / 255)
        }
        return Color(hex: UInt32(v))
    }
}

struct ClipboardExcludedApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

/// What must never land in the history.
enum ClipboardFilter {
    /// The nspasteboard.org markers that password managers and well-behaved apps put on secrets and temporary data.
    static let concealed = "org.nspasteboard.ConcealedType"
    static let transient = "org.nspasteboard.TransientType"
    static let autoGenerated = "org.nspasteboard.AutoGeneratedType"
    static let sensitiveTypes: Set<String> = [
        concealed, transient, autoGenerated,
        // Older markers still used by some apps.
        "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping", "Pasteboard generator type"
    ]

    static func isSensitive(_ types: [String]) -> Bool {
        types.contains { sensitiveTypes.contains($0) }
    }

    /// The markers of `types`, to declare again when the clipboard is rewritten (as plain text).
    static func markers(in types: [String]) -> [String] {
        types.filter { sensitiveTypes.contains($0) }
    }

    static let plainTextTypes: Set<String> = [
        "public.utf8-plain-text", "public.plain-text", "public.utf16-plain-text", "public.utf16-external-plain-text", "NSStringPboardType"
    ]

    /// Nothing but plain text and markers: there is no formatting to remove.
    static func isPlainTextOnly(_ types: [String]) -> Bool {
        types.allSatisfy { plainTextTypes.contains($0) || sensitiveTypes.contains($0) }
    }

    /// Password managers: nothing copied while one of them is in front is kept (the list can be edited).
    static let passwordManagers: [ClipboardExcludedApp] = [
        ClipboardExcludedApp(bundleID: "com.1password.1password", name: "1Password"),
        ClipboardExcludedApp(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
        ClipboardExcludedApp(bundleID: "com.apple.Passwords", name: "Mots de passe"),
        ClipboardExcludedApp(bundleID: "com.apple.keychainaccess", name: "Trousseau d'accès"),
        ClipboardExcludedApp(bundleID: "com.bitwarden.desktop", name: "Bitwarden"),
        ClipboardExcludedApp(bundleID: "org.keepassxc.keepassxc", name: "KeePassXC"),
        ClipboardExcludedApp(bundleID: "com.markmcguill.strongbox.mac", name: "Strongbox"),
        ClipboardExcludedApp(bundleID: "me.proton.pass.electron", name: "Proton Pass"),
        ClipboardExcludedApp(bundleID: "in.sinew.Enpass-Desktop", name: "Enpass"),
        ClipboardExcludedApp(bundleID: "com.lastpass.LastPass", name: "LastPass"),
        ClipboardExcludedApp(bundleID: "com.nordsec.nordpass", name: "NordPass"),
        ClipboardExcludedApp(bundleID: "com.keepersecurity.passwordmanager", name: "Keeper")
    ]

    static func isExcluded(_ bundleID: String?, list: [ClipboardExcludedApp]) -> Bool {
        guard let bundleID else { return false }
        return list.contains { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Token prefixes of well-known services, with the shortest real token: API keys (Anthropic, OpenAI, Google),
    /// GitHub, GitLab and Slack tokens, AWS access keys.
    static let secretPrefixes: [(prefix: String, minLength: Int)] = [
        ("sk-ant-", 24), ("sk-", 24), ("ghp_", 30), ("gho_", 30), ("ghs_", 30), ("ghu_", 30), ("ghr_", 30), ("github_pat_", 40),
        ("glpat-", 20), ("xoxb-", 20), ("xoxp-", 20), ("xoxa-", 20), ("xoxe-", 20), ("AKIA", 20), ("ASIA", 20), ("AIza", 30)
    ]

    /// A secret copied from a browser or a terminal, without the markers a password manager adds: API key or token,
    /// private key, one-time code, or a string that looks like a password. Not kept in the history
    /// (`ClipboardSettings.skipSecrets`). Links, sentences, paths, numbers and mail addresses are not secrets.
    static func looksSecret(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        if s.contains("PRIVATE KEY-----") || s.lowercased().hasPrefix("otpauth://") { return true }
        // Everything else is a single word.
        guard s.count <= 4096, !s.contains(where: \.isWhitespace) else { return false }
        let tokenChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted
        for (prefix, minLength) in secretPrefixes where s.hasPrefix(prefix) && s.count >= minLength {
            if s.unicodeScalars.allSatisfy({ $0.isASCII }) && s.rangeOfCharacter(from: tokenChars) == nil { return true }
        }
        // A JSON Web Token: three base64url parts, the first one an encoded "{".
        let jwtParts = s.split(separator: ".", omittingEmptySubsequences: false)
        if s.hasPrefix("eyJ"), s.count >= 30, jwtParts.count == 3, !jwtParts[1].isEmpty,
           s.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.=".unicodeScalars.contains($0)) }) {
            return true
        }
        // A one-time code: 6 to 8 digits alone.
        if (6...8).contains(s.count), s.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        // A password: 10 to 64 characters mixing upper case, lower case, digits and symbols, and nothing else it could be.
        guard (10...64).contains(s.count) else { return false }
        if s.contains("://") || s.lowercased().hasPrefix("www.") || s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("./") { return false }
        if s.range(of: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil { return false }
        // "-", "_" and "." also join the words of file names and identifiers: they do not count as symbols.
        let symbol = s.contains { !$0.isLetter && !$0.isNumber && !"-_.".contains($0) }
        return symbol && s.contains(where: \.isUppercase) && s.contains(where: \.isLowercase) && s.contains(where: \.isNumber)
    }
}

/// What "Ouvrir le lien" may do with a copied link.
enum ClipboardLinkAction: Equatable {
    case open(URL)
    case reveal(String)
    case refuse
}

enum ClipboardLinks {
    /// Web pages and mail open; a file:// link is shown in the Finder (never opened: it could be an app or a script);
    /// anything else (heartware://, ssh://, another app's scheme) is left alone.
    static func action(for raw: String) -> ClipboardLinkAction {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return .refuse }
        switch scheme {
        case "http", "https": return url.host?.isEmpty == false ? .open(url) : .refuse
        case "mailto": return .open(url)
        case "file": return url.path.isEmpty ? .refuse : .reveal(url.path)
        default: return .refuse
        }
    }
}

struct ClipboardSettings: Codable, Equatable {
    /// Off until the user turns it on, after reading what it does.
    var enabled = false
    var acknowledged = false
    var maxItems = 200
    var maxStorageMB = 200
    /// Unpinned items older than this go away (0: kept until the caps push them out).
    var retentionDays = 30
    var keepImages = true
    var keepFiles = true
    /// From the launcher, paste into the app in front (needs Accessibility) instead of only copying.
    var pasteDirectly = true
    var excluded: [ClipboardExcludedApp] = ClipboardFilter.passwordManagers
    /// API keys, tokens, private keys, one-time codes and likely passwords are not kept (`ClipboardFilter.looksSecret`).
    var skipSecrets = true

    init() {}

    /// Tolerant reading: a field added later never resets the others (nor turns the history off).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipboardSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        acknowledged = try c.decodeIfPresent(Bool.self, forKey: .acknowledged) ?? d.acknowledged
        maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? d.maxItems
        maxStorageMB = try c.decodeIfPresent(Int.self, forKey: .maxStorageMB) ?? d.maxStorageMB
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
        keepImages = try c.decodeIfPresent(Bool.self, forKey: .keepImages) ?? d.keepImages
        keepFiles = try c.decodeIfPresent(Bool.self, forKey: .keepFiles) ?? d.keepFiles
        pasteDirectly = try c.decodeIfPresent(Bool.self, forKey: .pasteDirectly) ?? d.pasteDirectly
        excluded = try c.decodeIfPresent([ClipboardExcludedApp].self, forKey: .excluded) ?? d.excluded
        skipSecrets = try c.decodeIfPresent(Bool.self, forKey: .skipSecrets) ?? d.skipSecrets
    }
}

/// Keeping the list tidy: no twins, caps on count, weight and age. Pinned items are never dropped.
enum ClipboardHistory {
    /// Bigger texts are not recorded (a whole log file, a database dump…).
    static let maxTextBytes = 1_000_000

    struct Inserted {
        var list: [ClipboardItem]
        /// The new item was a copy of `existing`: its own files (if any) are not needed.
        var duplicate: Bool
    }

    static func insert(_ item: ClipboardItem, into list: [ClipboardItem]) -> Inserted {
        var out = list
        if let i = out.firstIndex(where: { $0.digest == item.digest && $0.kind == item.kind }) {
            var merged = out.remove(at: i)
            merged.date = item.date
            merged.count += 1
            merged.appName = item.appName ?? merged.appName
            merged.appBundleID = item.appBundleID ?? merged.appBundleID
            merged.appPath = item.appPath ?? merged.appPath
            out.insert(merged, at: 0)
            return Inserted(list: out, duplicate: true)
        }
        out.insert(item, at: 0)
        return Inserted(list: out, duplicate: false)
    }

    /// Newest first.
    static func sorted(_ list: [ClipboardItem]) -> [ClipboardItem] {
        list.sorted { $0.date > $1.date }
    }

    static func prune(_ list: [ClipboardItem], maxItems: Int, maxBytes: Int, retentionDays: Int,
                      now: Date = Date()) -> (kept: [ClipboardItem], removed: [ClipboardItem]) {
        var kept: [ClipboardItem] = []
        var removed: [ClipboardItem] = []
        let limit = retentionDays > 0 ? now.addingTimeInterval(-Double(retentionDays) * 86400) : .distantPast
        var count = 0
        var bytes = 0
        for item in sorted(list) {
            if item.pinned {
                kept.append(item)
                continue
            }
            if item.date < limit || count >= maxItems || bytes + item.bytes > maxBytes {
                removed.append(item)
                continue
            }
            count += 1
            bytes += item.bytes
            kept.append(item)
        }
        return (kept, removed)
    }

    /// Items matching every word of `query` (already folded), newest first; pinned ones first when `pinnedFirst`.
    static func search(_ list: [ClipboardItem], query: String, keys: (ClipboardItem) -> String, limit: Int,
                       pinnedFirst: Bool = false) -> [ClipboardItem] {
        let words = query.split(separator: " ").map(String.init)
        var out: [ClipboardItem] = []
        let ordered = pinnedFirst ? list.filter(\.pinned) + list.filter { !$0.pinned } : list
        for item in ordered {
            if words.isEmpty || words.allSatisfy({ keys(item).contains($0) }) {
                out.append(item)
                if out.count >= limit { break }
            }
        }
        return out
    }
}
