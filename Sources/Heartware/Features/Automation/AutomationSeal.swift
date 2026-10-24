import Foundation
import CryptoKit

// automation.json says what the app does on its own, with Full Disk Access: which folder it empties, where it moves
// files, when it deletes the Trash for good. Any program of the user can rewrite that file. So every value is checked
// when it is read (`AutomationSettings.sanitized`), and the file carries a seal: an HMAC-SHA256 of its exact bytes, with
// a random key kept in the login keychain, written by the app each time it saves the settings. A file that does not
// match its seal (changed outside the app) turns the automations off: each one comes back only after a new dry run, and the
// watched folder goes back to Téléchargements. The first launch of a version with seals seals the settings as they are.

/// The seal of automation.json, in automation-seal.json.
struct AutomationSealRecord: Codable, Equatable {
    var mac = ""
}

enum AutomationSeal {
    static let keyAccount = "automation-seal"

    /// The key, or nil when the keychain has none (or refuses it). `create` makes one when there is none.
    static func key(create: Bool) -> SymmetricKey? {
        if let saved = Keychain.get(keyAccount), let data = Data(base64Encoded: saved), data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        let text = key.withUnsafeBytes { Data($0).base64EncodedString() }
        return Keychain.set(text, for: keyAccount) ? key : nil
    }

    static func mac(_ data: Data, key: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key)).base64EncodedString()
    }

    /// Constant-time comparison of `data`'s HMAC with the saved one.
    static func isValid(_ saved: String, for data: Data, key: SymmetricKey) -> Bool {
        guard let code = Data(base64Encoded: saved), code.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: data, using: key)
    }

    /// The bytes `JSONStore` writes for these settings (same encoder, sorted keys): what the seal covers.
    static func bytes(_ s: AutomationSettings) -> Data? {
        try? JSONEncoder.store.encode(s)
    }

    static func selfTest() -> [String] {
        var f: [String] = []
        let key = SymmetricKey(size: .bits256)
        var s = AutomationSettings()
        s.downloadsEnabled = true
        guard let data = bytes(s) else { return ["réglages illisibles pour le sceau"] }
        let seal = mac(data, key: key)
        if !isValid(seal, for: data, key: key) { f.append("sceau valide refusé") }
        s.downloadsFolder = "~/Documents"
        if let other = bytes(s), isValid(seal, for: other, key: key) { f.append("réglages modifiés acceptés par le sceau") }
        if isValid(seal, for: data, key: SymmetricKey(size: .bits256)) { f.append("sceau accepté avec une autre clé") }
        if isValid("", for: data, key: key) || isValid("pas du base64", for: data, key: key) { f.append("sceau absent accepté") }
        return f
    }
}

extension AutomationSettings {
    /// Every value back within what the page offers: the Trash rule keeps 7 to 365 days; a rule moving files outside
    /// the home folder, into a hidden folder, ~/Library or a package is switched off and loses its folder; a watched folder
    /// that is not allowed goes back to Téléchargements.
    func sanitized(home: String = FS.home) -> AutomationSettings {
        var s = self
        s.trashDays = min(max(s.trashDays, 7), 365)
        for i in s.rules.indices {
            s.rules[i].minAgeDays = min(max(s.rules[i].minAgeDays, 0), 3650)
            let d = s.rules[i].destination.trimmingCharacters(in: .whitespaces)
            if !d.isEmpty, !AutomationDownloads.isAllowedDestination(d, home: home) {
                s.rules[i].enabled = false
                s.rules[i].destination = ""
            }
        }
        let folder = s.downloadsFolder.trimmingCharacters(in: .whitespaces)
        let expanded = folder.hasPrefix("~/") ? home + String(folder.dropFirst(1)) : folder
        if !folder.isEmpty, !AutomationDownloads.isAllowedSource(expanded, home: home) { s.downloadsFolder = "" }
        return s
    }
}
