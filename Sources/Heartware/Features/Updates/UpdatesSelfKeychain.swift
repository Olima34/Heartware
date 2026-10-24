import Foundation
import Security

/// The app's keychain items (the automations' seal, the API key) across an update.
///
/// The list of applications of an item names Heartware by its designated requirement, the same for every version
/// signed with the release certificate. But without a Team ID from Apple, macOS also ties each item to the exact code of
/// the program that created it (its "cdhash" partition), which changes with every version: after each update, the new
/// version had to be allowed again with the session password, and "Toujours autoriser" only covered the version on
/// screen. And an item made with another partition list gets its creator's added on top.
///
/// So just before the swap, this copy, which reads its items without a prompt, hands them to the new version: it
/// launches the new executable with `--keychain-adopt`, the secrets on its standard input (a pipe between the two, never
/// a file or an argument). The new code checks that its parent is Heartware signed like itself, then writes them
/// again as their creator; once launched, it reads them without a prompt. If anything fails, this copy writes back what
/// was not adopted, and macOS asks once, as before.
enum UpdatesSelfKeychain {
    static let flag = "--keychain-adopt"

    /// In the running copy, before the swap: `app` is the verified new version, signed as it will be installed (the move
    /// keeps its code, hence its cdhash). Returns how many items it adopted. Runs tools: not on the main thread.
    static func handOver(to app: URL) -> Int {
        guard !DemoData.isEnabled else { return 0 }
        let secrets = Keychain.all()
        guard !secrets.isEmpty,
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let name = info["CFBundleExecutable"] as? String,
              let payload = try? JSONEncoder().encode(secrets) else { return 0 }
        let executable = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
        // The new version creates them: they must not exist any more (it may not delete what this one made).
        for account in secrets.keys { Keychain.delete(account) }
        // Not disclaimed: it answers to macOS as part of this app, which lets it read its command line (Entry).
        let run = Shell.run(executable.path, [flag], input: String(decoding: payload, as: UTF8.self), timeout: 30, disclaim: false)
        var adopted = 0
        for (account, value) in secrets {
            if Keychain.exists(account) {
                adopted += 1
            } else {
                // Never lose a secret: written back for this copy, and the new version will ask once.
                Keychain.set(value, for: account)
            }
        }
        if run.status != 0 {
            ActionLog.write("MISE À JOUR trousseau : la nouvelle version n'a pas repris ses clés (\(run.err.trimmingCharacters(in: .whitespacesAndNewlines)))")
        }
        return adopted
    }

    /// In the new version, launched by `handOver`: writes its parent's items again as their creator.
    /// Exit status 0 when all of them were written.
    static func adopt() -> Int32 {
        guard parentIsSignedLikeThisCode() else {
            FileHandle.standardError.write(Data("Refusé : seul Heartware, signé comme cette version, peut lui passer ses clés.\n".utf8))
            return 1
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count < 1 << 16, let secrets = try? JSONDecoder().decode([String: String].self, from: data) else {
            FileHandle.standardError.write(Data("Clés illisibles.\n".utf8))
            return 1
        }
        let written = secrets.filter { Keychain.set($0.value, for: $0.key) }.count
        return written == secrets.count ? 0 : 1
    }

    /// Whether the parent process satisfies this code's designated requirement: Heartware signed by the same
    /// certificate. An ad hoc signature designates its exact code, which the parent (another version) never has.
    static func parentIsSignedLikeThisCode() -> Bool {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return false }
        var staticMe: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess, let requirement else { return false }
        var parent: SecCode?
        let attributes = [kSecGuestAttributePid: getppid()] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &parent) == errSecSuccess, let parent else { return false }
        return SecCodeCheckValidity(parent, [], requirement) == errSecSuccess
    }

    /// Run from a terminal, the parent is a shell: never allowed to hand keys over.
    static func selfTest() -> [String] {
        parentIsSignedLikeThisCode() ? ["Trousseau : un programme qui n'est pas Heartware pourrait lui passer des clés"] : []
    }
}
