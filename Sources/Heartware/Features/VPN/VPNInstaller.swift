import AppKit

/// Gets Windscribe's official installer and opens it: by Homebrew when it is there (`brew install --cask windscribe`
/// downloads the disk image, checks its checksum and leaves `WindscribeInstaller.app` in the Caskroom: the cask's
/// installer is "manual"), otherwise from windscribe.com. Either way the installer must carry Windscribe's Developer ID
/// signature before it is opened; the user finishes in its window (macOS asks for the password there).
enum VPNInstaller {
    /// windscribe.com's own link to the latest macOS disk image (skills/windscribe-cli/references/install.md).
    static let downloadURL = URL(string: "https://windscribe.com/install/desktop/osx")!
    static let downloadPage = "https://windscribe.com/download"
    static let installerName = "WindscribeInstaller.app"
    static let folderName = "Windscribe"

    // MARK: Homebrew

    static func brewPath() -> String? {
        guard !DemoData.isEnabled else { return nil }
        return Shell.which("brew")
    }

    /// The installer Homebrew left: `<prefix>/Caskroom/windscribe/<version>/WindscribeInstaller.app`, the newest version.
    static func stagedInstaller(brew: String) -> URL? {
        let prefix = URL(fileURLWithPath: brew).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let room = prefix.appendingPathComponent("Caskroom/windscribe")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: room.path)) ?? []
        let sorted = versions.filter { !$0.hasPrefix(".") }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in sorted {
            let app = room.appendingPathComponent(v).appendingPathComponent(installerName)
            if FileManager.default.fileExists(atPath: app.path) { return app }
        }
        return nil
    }

    // MARK: Disk image

    /// Attaches the downloaded disk image (out of the Finder's sight) and returns the volume and its installer.
    static func mount(_ dmg: URL) -> (volume: String, installer: URL)? {
        let out = Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-plist", dmg.path], timeout: 120)
        guard out.ok, let volume = mountPoint(plist: out.out) else { return nil }
        let direct = URL(fileURLWithPath: volume).appendingPathComponent(installerName)
        if FileManager.default.fileExists(atPath: direct.path) { return (volume, direct) }
        // One level down, should the image ever put it in a folder.
        let items = (try? FileManager.default.contentsOfDirectory(atPath: volume)) ?? []
        for item in items {
            let nested = URL(fileURLWithPath: volume).appendingPathComponent(item).appendingPathComponent(installerName)
            if FileManager.default.fileExists(atPath: nested.path) { return (volume, nested) }
        }
        return nil
    }

    /// The "mount-point" of `hdiutil attach -plist`.
    static func mountPoint(plist: String) -> String? {
        guard let data = plist.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first { $0.hasPrefix("/Volumes/") }
    }

    static func detach(_ volume: String) {
        guard volume.hasPrefix("/Volumes/") else { return }
        _ = Shell.run("/usr/bin/hdiutil", ["detach", volume, "-quiet"], timeout: 30)
    }

    // MARK: Signature

    /// nil when the installer is intact and signed by Windscribe's Developer ID; otherwise why it is not opened.
    static func verify(_ installer: URL) -> String? {
        let check = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", installer.path], timeout: 90)
        guard check.ok else { return "La signature de l'installateur ne tient pas : Heartware ne l'ouvre pas." }
        let info = Shell.run("/usr/bin/codesign", ["-dvv", installer.path], timeout: 30).all
        return isWindscribeSignature(info) ? nil : "L'installateur n'est pas signé par Windscribe : Heartware ne l'ouvre pas."
    }

    /// `codesign -dvv` names the signer on its "Authority=" lines: the first must be Windscribe's Developer ID.
    static func isWindscribeSignature(_ codesignInfo: String) -> Bool {
        let authorities = codesignInfo.components(separatedBy: .newlines).filter { $0.hasPrefix("Authority=") }
        guard let leaf = authorities.first else { return false }
        return leaf.hasPrefix("Authority=Developer ID Application: Windscribe")
            && authorities.contains("Authority=Apple Root CA")
    }

    static func openInstaller(_ installer: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: installer, configuration: config)
        ActionLog.write("VPN installateur de Windscribe ouvert · \(installer.path)")
    }
}
