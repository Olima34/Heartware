import Foundation
import Security

/// Secrets (API keys) in the user's login keychain. Never in UserDefaults or a file.
/// With an ad-hoc signature, macOS may ask again after each rebuild whether the app can read its item.
enum Keychain {
    static let service = AppEdition.isLab ? AppEdition.labID : AppEdition.regularID

    static func get(_ account: String) -> String? {
        guard !DemoData.isEnabled else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether the item exists, read from its attributes only: macOS asks nothing, even when the app may not read the secret.
    static func exists(_ account: String) -> Bool {
        guard !DemoData.isEnabled else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        guard !DemoData.isEnabled else { return false }
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "\(AppEdition.name) · \(account)",
            kSecValueData as String: Data(value.utf8)
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        guard !DemoData.isEnabled else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Every item of the app, account → secret. macOS asks only for an item this copy may not read.
    static func all() -> [String: String] {
        guard !DemoData.isEnabled else { return [:] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [:] }
        var secrets: [String: String] = [:]
        for account in items.compactMap({ $0[kSecAttrAccount as String] as? String }) {
            if let value = get(account) { secrets[account] = value }
        }
        return secrets
    }
}
