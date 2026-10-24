import Foundation
import ServiceManagement
import WebKit

/// The names the app had before Heartware, and what a copy updated from those versions brings along the first time:
/// its bundle's file name, its data and log folders, a few settings, the ad-free player's compiled rules. Moved once, at
/// launch; nothing else in the app knows the old names. What never changed, on purpose: the bundle identifier, the
/// signing certificates and the ad blocker's profile identifier, so that macOS keeps the permissions, the keychain items
/// and the installed profile.
enum HeartwareLegacy {
    /// The bundle's file names of the versions that updated themselves in place.
    static let bundleNames = ["Clean My Claude.app", "Chamois.app"]
    static let dataFolder = AppEdition.isLab ? "CleanMyClaude Labo" : "CleanMyClaude"
    static let logFolder = "CleanMyClaude"
    /// Settings saved under "CleanMyClaude.…" (the ad-free player's accounts, Détacher la vidéo…), and their windows' frames.
    static let settingsPrefix = "CleanMyClaude."
    static let ruleList = "cleanmyclaude-adfree-2"
    /// Set when the renamed copy was a login item: registered again from its new place at the next launch.
    static let loginKey = "app.loginItemAfterRename"
    static let ruleListKey = "app.legacyRulesRemoved"

    /// A copy still under an old file name, in a folder it can change, becomes Heartware.app and opens again from there:
    /// true when this process must quit now. Not for the Labo (its own script names it), a copy run from its archive or a
    /// disk image, or when a Heartware.app is already beside it.
    static func renameBundleIfNeeded() -> Bool {
        guard !DemoData.isEnabled, !AppEdition.isLab else { return false }
        let current = URL(fileURLWithPath: Bundle.main.bundlePath)
        guard bundleNames.contains(current.lastPathComponent), !current.path.contains("/AppTranslocation/") else { return false }
        let folder = current.deletingLastPathComponent()
        let target = folder.appendingPathComponent(UpdatesSelfInstaller.appName)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path), fm.isWritableFile(atPath: folder.path), fm.isWritableFile(atPath: current.path) else {
            return false
        }
        let wasLoginItem = LoginItem.isEnabled
        do {
            _ = try FileOps.move(current, to: target)
        } catch {
            ActionLog.write("NOUVEAU NOM : \(current.path) n'a pas pu devenir \(target.lastPathComponent) (\(error.localizedDescription))")
            return false
        }
        UpdatesSelfInstaller.register(target)
        if wasLoginItem { UserDefaults.standard.set(true, forKey: loginKey) }
        ActionLog.write("NOUVEAU NOM : \(current.path) → \(target.path)")
        return UpdatesSelfInstaller.relaunch(target)
    }

    /// The folders, settings and rules left under the old names, taken over by the new ones. Only for the assembled app:
    /// a binary run from a terminal never moves the data of the copy installed.
    static func migrate() {
        guard !DemoData.isEnabled, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        // The logs first: anything written to the journal creates its new folder.
        let logs = mergeLogs(FS.home + "/Library/Logs/" + logFolder)
        let data = takeOverData(FS.home + "/Library/Application Support/" + dataFolder)
        for line in [logs, data].compactMap({ $0 }) { ActionLog.write(line) }

        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation()
        where key.hasPrefix(settingsPrefix) || key.hasPrefix("NSWindow Frame " + settingsPrefix) {
            let renamed = key.replacingOccurrences(of: settingsPrefix, with: "Heartware.")
            if defaults.object(forKey: renamed) == nil { defaults.set(value, forKey: renamed) }
            defaults.removeObject(forKey: key)
        }
        if !defaults.bool(forKey: ruleListKey) {
            defaults.set(true, forKey: ruleListKey)
            DispatchQueue.main.async {
                WKContentRuleListStore.default().removeContentRuleList(forIdentifier: ruleList) { _ in }
            }
        }
        if defaults.bool(forKey: loginKey) {
            defaults.removeObject(forKey: loginKey)
            try? SMAppService.mainApp.unregister()
            if LoginItem.set(true) == nil { ActionLog.write("NOUVEAU NOM : ouverture à la connexion reprise depuis \(Bundle.main.bundlePath)") }
        }
    }

    /// The old log folder: moved whole, or its files moved one by one into the new one (the published app and the Labo
    /// share it, one may have created it first), never over a file; the empty old folder then goes to the Trash.
    private static func mergeLogs(_ old: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old) else { return nil }
        guard fm.fileExists(atPath: ActionLog.folder) else { return move(old, to: ActionLog.folder) }
        for name in (try? fm.contentsOfDirectory(atPath: old)) ?? [] {
            _ = try? FileOps.move(URL(fileURLWithPath: old + "/" + name), to: URL(fileURLWithPath: ActionLog.folder + "/" + name))
        }
        guard ((try? fm.contentsOfDirectory(atPath: old)) ?? ["?"]).isEmpty else { return "NOUVEAU NOM : \(old) n'a pas pu être vidé" }
        let report = Remover.remove([RemovalEntry(path: old, size: 0)], mode: .trash)
        return report.removed == 1 ? "NOUVEAU NOM : \(old) versé dans \(ActionLog.folder)" : "NOUVEAU NOM : \(old) vidé, resté en place"
    }

    /// The old data folder takes the new place. Both there means the new one was made without the app's data (a test, a
    /// command run from a terminal, macOS's own folder made before): the old one's files take their place one by one, a
    /// file of the same name in the new one going first, and the emptied old folder goes to the Trash. The app protects its
    /// own data folder from the Trash, hence file by file.
    private static func takeOverData(_ old: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old) else { return nil }
        guard fm.fileExists(atPath: DataStore.folder) else { return move(old, to: DataStore.folder) }
        var moved = 0
        for name in (try? fm.contentsOfDirectory(atPath: old)) ?? [] {
            let target = DataStore.folder + "/" + name
            if fm.fileExists(atPath: target) || FS.isSymlink(target), !Remover.removeInternal(target) { continue }
            if (try? FileOps.move(URL(fileURLWithPath: old + "/" + name), to: URL(fileURLWithPath: target))) != nil { moved += 1 }
        }
        let left = (try? fm.contentsOfDirectory(atPath: old)) ?? ["?"]
        guard left.isEmpty else { return "NOUVEAU NOM : \(moved) éléments de \(old) repris, \(left.count) restés en place" }
        let report = Remover.remove([RemovalEntry(path: old, size: 0)], mode: .trash)
        return "NOUVEAU NOM : \(old) repris dans \(DataStore.folder) (\(moved) éléments)" + (report.removed == 1 ? "" : ", le dossier vide reste en place")
    }

    /// The old folder moves to the new place unless that one exists already; what happened, for the journal.
    private static func move(_ old: String, to new: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old) else { return nil }
        guard !fm.fileExists(atPath: new) else { return "NOUVEAU NOM : \(old) reste en place, \(new) existe déjà" }
        do {
            _ = try FileOps.move(URL(fileURLWithPath: old), to: URL(fileURLWithPath: new))
            return "NOUVEAU NOM : \(old) → \(new)"
        } catch {
            return "NOUVEAU NOM : \(old) n'a pas pu devenir \(new) (\(error.localizedDescription))"
        }
    }
}
