import Foundation
import AppKit

/// Sombre partout, the dark mode tool, was removed in the redesign. What it had changed on this Mac outside the app is
/// put back once, at launch, from what it noted itself in the app's folder; nothing else is touched:
/// - an app forced dark or light: `NSRequiresAquaSystemAppearance` in its preferences (`darkmode.json` keeps the choice
///   and the value found before it) → that value again, or no key at all;
/// - Chromium's "Auto Dark Mode for Web Contents" switched on in a browser's Local State (`DarkMode/Copies` keeps the
///   file as it was before the first change) → switched off, unless it was already on then; only while the browser is
///   closed, since it rewrites the file when it quits;
/// - the style sheet it once wrote for Safari (`DarkMode/Sombre partout.css`) → emptied if a version older than v0.3.62
///   left its rules in it, so that a Safari still pointing to it inverts nothing.
/// What cannot be done yet (a browser open, a preference macOS refuses) is tried again at the next launch. The Mac's own
/// appearance and the colour inversion are macOS switches the user flipped and can flip back: they are left as they are.
enum RetiredDarkMode {
    static let doneKey = "retired.darkmode.done"
    static let key = "NSRequiresAquaSystemAppearance"
    static let flag = "enable-force-dark"
    static let copySuffix = " Local State.json"

    /// The Chromium browsers Sombre partout could change, and where each keeps its Local State (in ~/Library/Application Support).
    static let localStates: [String: String] = [
        "com.google.Chrome": "Google/Chrome/Local State",
        "com.microsoft.edgemac": "Microsoft Edge/Local State",
        "com.brave.Browser": "BraveSoftware/Brave-Browser/Local State",
        "com.vivaldi.Vivaldi": "Vivaldi/Local State",
        "com.operasoftware.Opera": "com.operasoftware.Opera/Local State",
        "company.thebrowser.Browser": "Arc/User Data/Local State",
        "org.chromium.Chromium": "Chromium/Local State"
    ]

    /// Called once the app has started. Off the main thread: a few `defaults` calls at most.
    @MainActor
    static func restore() {
        guard !DemoData.isEnabled, !Snapshot.isActive, !UserDefaults.standard.bool(forKey: doneKey) else { return }
        // The browsers open right now are left for another launch.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        Task.detached(priority: .utility) {
            let apps = restoreApps()
            let browsers = restoreBrowsers(running: running)
            retireStyleSheet()
            if apps && browsers { UserDefaults.standard.set(true, forKey: doneKey) }
        }
    }

    // MARK: Apps

    private struct Saved: Codable {
        var choices: [String: String]?
        var originals: [String: Original]?
        var names: [String: String]?
    }

    private struct Original: Codable {
        var value: Bool?
    }

    /// True when no app is left to put back.
    private static func restoreApps() -> Bool {
        let file = DataStore.url("darkmode.json")
        guard let data = try? Data(contentsOf: file) else { return true }
        guard var saved = try? JSONDecoder().decode(Saved.self, from: data) else { return true }
        var left: [String: String] = [:]
        // "Inversée" and "Auto" wrote nothing in the app's preferences.
        for (id, choice) in saved.choices ?? [:] where (choice == "dark" || choice == "light") && isBundleID(id) {
            let original = saved.originals?[id]?.value
            let name = saved.names?[id] ?? id
            if writePreference(id, original) {
                ActionLog.write("SOMBRE PARTOUT retiré : \(name) (\(id)) remise dans son apparence d'origine")
            } else {
                left[id] = choice
            }
        }
        guard !left.isEmpty else {
            Remover.removeInternal(file.path)
            return true
        }
        saved.choices = left
        saved.originals = saved.originals?.filter { left[$0.key] != nil }
        saved.names = saved.names?.filter { left[$0.key] != nil }
        if let out = try? JSONEncoder().encode(saved), (try? out.write(to: file, options: .atomic)) != nil {
            DataStore.protect(file)
        }
        return false
    }

    /// The value found before the first change, or no key when there was none. True when it is in place.
    private static func writePreference(_ id: String, _ value: Bool?) -> Bool {
        let args = value.map { ["write", id, key, "-bool", $0 ? "true" : "false"] } ?? ["delete", id, key]
        let r = Shell.run("/usr/bin/defaults", args, timeout: 8)
        if r.ok { return true }
        // Removing a key that is not there is what was wanted.
        let e = r.all.lowercased()
        return value == nil && (e.contains("does not exist") || e.contains("not found"))
    }

    /// A bundle identifier, never something `defaults` could read as an option.
    static func isBundleID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    // MARK: Browsers

    /// True when no browser is left to put back.
    private static func restoreBrowsers(running: Set<String>) -> Bool {
        let folder = DataStore.url("DarkMode/Copies")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return true }
        var left = false
        for name in names where name.hasSuffix(copySuffix) {
            let id = String(name.dropLast(copySuffix.count))
            guard let relative = localStates[id] else { continue }
            let copy = folder.appendingPathComponent(name)
            let state = URL(fileURLWithPath: FS.home + "/Library/Application Support/" + relative)
            let before = (try? Data(contentsOf: copy)).flatMap(isForced)
            // Off now, already on before Heartware, or a copy that cannot be read: nothing of Heartware's to undo.
            guard let now = try? Data(contentsOf: state), isForced(now) == true, before == false else {
                Remover.removeInternal(copy.path)
                continue
            }
            guard !running.contains(id) else {
                left = true
                continue
            }
            guard let edited = switchedOff(now), (try? edited.write(to: state, options: .atomic)) != nil else {
                left = true
                continue
            }
            ActionLog.write("SOMBRE PARTOUT retiré : pages sombres de \(id) rendues aux sites · \(state.path)")
            Remover.removeInternal(copy.path)
        }
        return !left
    }

    /// True when the switch is on (any of its "Enabled…" variants), nil when the file is not a JSON object.
    static func isForced(_ data: Data) -> Bool? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let list = ((root["browser"] as? [String: Any])?["enabled_labs_experiments"] as? [String]) ?? []
        return list.contains { e in
            guard e.hasPrefix(flag + "@"), let n = Int(e.dropFirst(flag.count + 1)) else { return false }
            return (1...8).contains(n)
        }
    }

    /// The same Local State with the switch back to "Default"; everything else untouched. nil if it is not a JSON object.
    static func switchedOff(_ data: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var browser = root["browser"] as? [String: Any] ?? [:]
        let list = (browser["enabled_labs_experiments"] as? [String]) ?? []
        browser["enabled_labs_experiments"] = list.filter { $0 != flag && !$0.hasPrefix(flag + "@") }
        root["browser"] = browser
        return try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
    }

    // MARK: Safari

    /// What the style sheet keeps: no rule, and how to unselect it in Safari.
    static let emptySheet = """
    /* Sombre partout · Heartware
       Cette feuille de style n'est plus utilisée : Safari n'en applique plus rien.
       Dans Safari › Réglages… › Avancées, choisis Feuille de style : « Aucune ». */

    """

    private static func retireStyleSheet() {
        let url = DataStore.url("DarkMode/Sombre partout.css")
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("{") else { return }
        // The app's own file, already replaced in place by every change of tone: replaced once more.
        if (try? Data(emptySheet.utf8).write(to: url, options: .atomic)) != nil {
            ActionLog.write("SOMBRE PARTOUT retiré : feuille de style Safari vidée · \(url.path)")
        }
    }

    // MARK: Self-tests

    static func selfTest() -> [String] {
        var f: [String] = []
        func expect(_ ok: Bool, _ message: String) { if !ok { f.append("[Sombre partout retiré] " + message) } }
        expect(isBundleID("com.google.Chrome") && isBundleID("fr.cartographe.desktop") && isBundleID("app-1_x"),
               "identifiant d'app refusé à tort")
        expect(!isBundleID("-delete") && !isBundleID("") && !isBundleID("com.x y") && !isBundleID("../x"), "identifiant douteux accepté")
        let state = Data(#"{"browser":{"enabled_labs_experiments":["smooth-scrolling@2","enable-force-dark@1"],"x":1},"metrics":{"y":2}}"#.utf8)
        expect(isForced(state) == true, "pages sombres de Chrome non reconnues")
        if let off = switchedOff(state), let root = (try? JSONSerialization.jsonObject(with: off)) as? [String: Any],
           let browser = root["browser"] as? [String: Any] {
            expect(browser["enabled_labs_experiments"] as? [String] == ["smooth-scrolling@2"], "réglage de Chrome mal remis")
            expect(browser["x"] as? Int == 1 && root["metrics"] != nil, "réglages voisins de Chrome perdus")
            expect(isForced(off) == false, "pages sombres de Chrome encore forcées")
        } else {
            f.append("[Sombre partout retiré] Local State de Chrome non réécrit")
        }
        expect(isForced(Data(#"{"browser":{"enabled_labs_experiments":["enable-force-dark@0"]}}"#.utf8)) == false,
               "« Default » de Chrome pris pour activé")
        expect(isForced(Data("oups".utf8)) == nil && switchedOff(Data("[1]".utf8)) == nil, "Local State illisible accepté")
        expect(!emptySheet.contains("{"), "la feuille de style vidée garde une règle")
        return f
    }
}
