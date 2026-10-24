import Foundation
import AppKit
import SQLite3

/// Minimal read/write access to a SQLite file.
enum SQLite {
    static func query(_ path: String, _ sql: String, readOnly: Bool = true) -> [[String]]? {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String] = []
            for i in 0..<sqlite3_column_count(stmt) {
                if let t = sqlite3_column_text(stmt, i) { row.append(String(cString: t)) } else { row.append("") }
            }
            rows.append(row)
        }
        return rows
    }

    static func exec(_ path: String, _ sql: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}

// MARK: - App permissions (TCC)

struct TCCService: Hashable {
    let key: String
    let title: String
    let symbol: String
    let anchor: String
    let sensitive: Bool

    static let all: [TCCService] = [
        TCCService(key: "kTCCServiceSystemPolicyAllFiles", title: "Accès complet au disque", symbol: "externaldrive", anchor: "Privacy_AllFiles", sensitive: true),
        TCCService(key: "kTCCServiceScreenCapture", title: "Enregistrement de l'écran", symbol: "rectangle.dashed.badge.record", anchor: "Privacy_ScreenCapture", sensitive: true),
        TCCService(key: "kTCCServiceAccessibility", title: "Accessibilité (contrôle du Mac)", symbol: "accessibility", anchor: "Privacy_Accessibility", sensitive: true),
        TCCService(key: "kTCCServiceListenEvent", title: "Surveillance de la saisie", symbol: "keyboard", anchor: "Privacy_ListenEvent", sensitive: true),
        TCCService(key: "kTCCServiceCamera", title: "Caméra", symbol: "camera", anchor: "Privacy_Camera", sensitive: true),
        TCCService(key: "kTCCServiceMicrophone", title: "Micro", symbol: "mic", anchor: "Privacy_Microphone", sensitive: true),
        TCCService(key: "kTCCServiceAppleEvents", title: "Automatisation", symbol: "gearshape.2", anchor: "Privacy_Automation", sensitive: false),
        TCCService(key: "kTCCServiceAddressBook", title: "Contacts", symbol: "person.crop.circle", anchor: "Privacy_Contacts", sensitive: false),
        TCCService(key: "kTCCServiceCalendar", title: "Calendriers", symbol: "calendar", anchor: "Privacy_Calendars", sensitive: false),
        TCCService(key: "kTCCServiceReminders", title: "Rappels", symbol: "checklist", anchor: "Privacy_Reminders", sensitive: false),
        TCCService(key: "kTCCServicePhotos", title: "Photos", symbol: "photo", anchor: "Privacy_Photos", sensitive: false),
        TCCService(key: "kTCCServiceSystemPolicyDesktopFolder", title: "Dossier Bureau", symbol: "menubar.dock.rectangle", anchor: "Privacy_FilesAndFolders", sensitive: false),
        TCCService(key: "kTCCServiceSystemPolicyDocumentsFolder", title: "Dossier Documents", symbol: "doc", anchor: "Privacy_FilesAndFolders", sensitive: false),
        TCCService(key: "kTCCServiceSystemPolicyDownloadsFolder", title: "Dossier Téléchargements", symbol: "arrow.down.circle", anchor: "Privacy_FilesAndFolders", sensitive: false),
        TCCService(key: "kTCCServiceSystemPolicyAppData", title: "Données des autres apps", symbol: "square.on.square", anchor: "Privacy_AppBundles", sensitive: false),
        TCCService(key: "kTCCServiceBluetoothAlways", title: "Bluetooth", symbol: "dot.radiowaves.left.and.right", anchor: "Privacy_Bluetooth", sensitive: false),
        TCCService(key: "kTCCServiceSpeechRecognition", title: "Reconnaissance vocale", symbol: "waveform", anchor: "Privacy_SpeechRecognition", sensitive: false),
        TCCService(key: "kTCCServiceMediaLibrary", title: "Musique et médias", symbol: "music.note", anchor: "Privacy_Media", sensitive: false),
        TCCService(key: "kTCCServiceDeveloperTool", title: "Outils de développement", symbol: "hammer", anchor: "Privacy_DevTools", sensitive: false)
    ]
}

struct PermissionGrant: Identifiable, Hashable {
    var id: String { service.key + "|" + client }
    let service: TCCService
    let client: String
    let name: String
    let path: String?
    let lastModified: Date?
}

/// Reads who was granted what in macOS' privacy databases (needs Full Disk Access).
enum TCCReader {
    static let userDB = FS.home + "/Library/Application Support/com.apple.TCC/TCC.db"
    static let systemDB = "/Library/Application Support/com.apple.TCC/TCC.db"

    static func read() -> [PermissionGrant]? {
        if DemoData.isEnabled { return DemoData.grants() }
        let services = Dictionary(uniqueKeysWithValues: TCCService.all.map { ($0.key, $0) })
        var grants: [String: PermissionGrant] = [:]
        var readable = false
        for db in [systemDB, userDB] {
            guard let rows = SQLite.query(db, "SELECT service, client, client_type, auth_value, last_modified FROM access") else { continue }
            readable = true
            for r in rows where r.count == 5 {
                guard let service = services[r[0]], r[3] == "2" || r[3] == "3" else { continue }
                let client = r[1]
                var name = client
                var path: String?
                if r[2] == "0" {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: client) {
                        path = url.path
                        name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                    }
                } else {
                    path = client
                    name = (client as NSString).lastPathComponent
                }
                let date = Double(r[4]).map { Date(timeIntervalSince1970: $0) }
                let g = PermissionGrant(service: service, client: client, name: name, path: path, lastModified: date)
                grants[g.id] = g
            }
        }
        return readable ? grants.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } : nil
    }
}

// MARK: - Privacy traces

enum TraceAction: Hashable {
    case deleteFiles
    case recentItems
    case quarantineEvents
    case quickLook
    case clipboard
}

struct PrivacyTrace: Identifiable, Hashable {
    let id: String
    let group: String
    let title: String
    let detail: String
    let symbol: String
    var paths: [String] = []
    var size: Int64 = 0
    var count: Int? = nil
    var action: TraceAction = .deleteFiles
    var blockedReason: String? = nil
    var needsFullDiskAccess = false
    var defaultOn = false
}

enum PrivacyScanner {
    static let quarantineDB = FS.home + "/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"

    static func scan(running: RunningApps) -> [PrivacyTrace] {
        if DemoData.isEnabled { return DemoData.traces() }
        var out: [PrivacyTrace] = []

        // Recent documents, apps and servers.
        let sfl = FS.home + "/Library/Application Support/com.apple.sharedfilelist"
        if FS.canList(sfl) {
            var files = FS.children(sfl).filter { $0.contains("LSSharedFileList.Recent") }.map { sfl + "/" + $0 }
            let perApp = sfl + "/com.apple.LSSharedFileList.ApplicationRecentDocuments"
            files += FS.children(perApp).map { perApp + "/" + $0 }
            out.append(PrivacyTrace(id: "recent", group: "Système", title: "Éléments récents",
                                    detail: "Documents, apps et serveurs du menu Pomme › Éléments récents et des menus « Ouvrir récent ».",
                                    symbol: "clock", paths: files, size: files.reduce(0) { $0 + FileSizer.size(of: $1) },
                                    count: files.count, action: .recentItems, defaultOn: true))
        } else {
            out.append(PrivacyTrace(id: "recent", group: "Système", title: "Éléments récents",
                                    detail: "Documents, apps et serveurs récemment ouverts.", symbol: "clock",
                                    action: .recentItems, needsFullDiskAccess: true))
        }

        // Every file ever downloaded, logged by Gatekeeper.
        if let rows = SQLite.query(quarantineDB, "SELECT COUNT(*) FROM LSQuarantineEvent"), let n = Int(rows.first?.first ?? "") {
            out.append(PrivacyTrace(id: "quarantine", group: "Système", title: "Historique des téléchargements",
                                    detail: "macOS note l'adresse d'origine de chaque fichier téléchargé, depuis toujours.",
                                    symbol: "arrow.down.doc", paths: [quarantineDB], size: FileSizer.size(of: quarantineDB),
                                    count: n, action: .quarantineEvents, defaultOn: n > 0))
        }

        // Quick Look thumbnails reveal files you previewed, even deleted ones.
        if let cache = FS.userCacheDir {
            let size = ["com.apple.QuickLook.thumbnailcache", "com.apple.quicklook.ThumbnailsAgent"]
                .map { FileSizer.size(of: (cache as NSString).appendingPathComponent($0)) }.reduce(0, +)
            out.append(PrivacyTrace(id: "quicklook", group: "Système", title: "Vignettes Coup d'œil",
                                    detail: "Miniatures des fichiers prévisualisés, y compris ceux supprimés depuis.",
                                    symbol: "eye", paths: [], size: size, action: .quickLook, defaultOn: true))
        }

        // Terminal histories.
        var shell = Remover.homeRootFiles.map { FS.home + "/" + $0 }.filter { FS.exists($0) }
        let sessions = FS.home + "/.zsh_sessions"
        shell += FS.children(sessions).map { sessions + "/" + $0 }
        if !shell.isEmpty {
            out.append(PrivacyTrace(id: "shell", group: "Système", title: "Historique du Terminal",
                                    detail: "Les commandes tapées dans zsh, bash, Python, Node… (y compris d'éventuels secrets collés).",
                                    symbol: "terminal", paths: shell.sorted(), size: shell.reduce(0) { $0 + FileSizer.size(of: $1) },
                                    count: shell.count))
        }

        out.append(PrivacyTrace(id: "clipboard", group: "Système", title: "Presse-papiers",
                                detail: "Ce que tu as copié en dernier (un mot de passe, peut-être).", symbol: "doc.on.clipboard",
                                action: .clipboard))

        // Chromium browsers.
        let browsers: [(String, String, String)] = [
            ("Chrome", "Google/Chrome", "com.google.Chrome"),
            ("Edge", "Microsoft Edge", "com.microsoft.edgemac"),
            ("Brave", "BraveSoftware/Brave-Browser", "com.brave.Browser"),
            ("Arc", "Arc/User Data", "company.thebrowser.Browser"),
            ("Vivaldi", "Vivaldi", "com.vivaldi.Vivaldi")
        ]
        for (name, folder, id) in browsers {
            let root = CleanupCatalog.support + "/" + folder
            let profiles = FS.children(root).filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            guard !profiles.isEmpty else { continue }
            let blocked = running.isRunning(id) ? "Quitte \(name) d'abord" : nil
            let history = profiles.flatMap { p in
                ["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal", "Shortcuts", "Shortcuts-journal"]
                    .map { root + "/" + p + "/" + $0 }
            }.filter { FS.exists($0) }
            let cookies = profiles.flatMap { p in
                ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"].map { root + "/" + p + "/" + $0 }
            }.filter { FS.exists($0) }
            if !history.isEmpty {
                out.append(PrivacyTrace(id: "\(name)-history", group: name, title: "Historique de navigation",
                                        detail: "Sites visités, suggestions de la barre d'adresse et sites fréquents.",
                                        symbol: "clock.arrow.circlepath", paths: history,
                                        size: history.reduce(0) { $0 + FileSizer.size(of: $1) }, blockedReason: blocked))
            }
            if !cookies.isEmpty {
                out.append(PrivacyTrace(id: "\(name)-cookies", group: name, title: "Cookies",
                                        detail: "Traceurs publicitaires, mais aussi tes connexions : tu devras te reconnecter aux sites.",
                                        symbol: "circle.hexagongrid", paths: cookies,
                                        size: cookies.reduce(0) { $0 + FileSizer.size(of: $1) }, blockedReason: blocked))
            }
        }

        // Firefox: cookies and form history (history lives with the bookmarks, so it stays).
        let ff = CleanupCatalog.support + "/Firefox/Profiles"
        let ffProfiles = FS.children(ff)
        if !ffProfiles.isEmpty {
            let blocked = running.isRunning("org.mozilla.firefox") ? "Quitte Firefox d'abord" : nil
            let cookies = ffProfiles.flatMap { p in ["cookies.sqlite", "cookies.sqlite-wal", "cookies.sqlite-shm"].map { ff + "/" + p + "/" + $0 } }
                .filter { FS.exists($0) }
            let forms = ffProfiles.flatMap { p in ["formhistory.sqlite"].map { ff + "/" + p + "/" + $0 } }.filter { FS.exists($0) }
            if !cookies.isEmpty {
                out.append(PrivacyTrace(id: "firefox-cookies", group: "Firefox", title: "Cookies",
                                        detail: "Tu devras te reconnecter aux sites.", symbol: "circle.hexagongrid", paths: cookies,
                                        size: cookies.reduce(0) { $0 + FileSizer.size(of: $1) }, blockedReason: blocked))
            }
            if !forms.isEmpty {
                out.append(PrivacyTrace(id: "firefox-forms", group: "Firefox", title: "Saisies de formulaires",
                                        detail: "Ce que tu as tapé dans les champs des sites.", symbol: "character.cursor.ibeam", paths: forms,
                                        size: forms.reduce(0) { $0 + FileSizer.size(of: $1) }, blockedReason: blocked))
            }
        }
        return out
    }

    /// Erases the given traces. Must run off the main thread.
    static func clean(_ traces: [PrivacyTrace]) -> RemovalReport {
        // Some traces are erased without Remover (SQL, clipboard): the demo must stop here.
        if DemoData.isEnabled { return RemovalReport(failures: traces.map { ($0.title, DemoData.refusal) }) }
        var report = RemovalReport()
        for t in traces where t.blockedReason == nil {
            switch t.action {
            case .deleteFiles:
                report.merge(Remover.remove(t.paths.map { RemovalEntry(path: $0, size: FileSizer.size(of: $0)) }, mode: .delete))
            case .recentItems:
                report.merge(Remover.remove(t.paths.map { RemovalEntry(path: $0, size: FileSizer.size(of: $0)) }, mode: .delete))
                _ = Shell.run("/usr/bin/killall", ["sharedfilelistd"])
            case .quarantineEvents:
                if SQLite.exec(quarantineDB, "DELETE FROM LSQuarantineEvent; VACUUM;") {
                    report.removed += t.count ?? 1
                    ActionLog.write("EFFACÉ historique des téléchargements (\(t.count ?? 0) entrées)")
                } else {
                    report.failures.append((quarantineDB, "Base verrouillée"))
                }
            case .quickLook:
                let r = Shell.run("/usr/bin/qlmanage", ["-r", "cache"])
                if r.ok {
                    report.removed += 1
                    report.freed += t.size
                    ActionLog.write("EFFACÉ vignettes Coup d'œil")
                }
            case .clipboard:
                _ = DispatchQueue.main.sync { NSPasteboard.general.clearContents() }
                report.removed += 1
            }
        }
        return report
    }
}
