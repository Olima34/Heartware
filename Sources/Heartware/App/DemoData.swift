import Foundation

/// Fictional but plausible data for the demo mode (`--demo`) and the README screenshots.
/// Every scanner returns these instead of reading the disk, `Shell` runs nothing and `Remover` refuses everything.
/// Deterministic: dates are relative to the launch and the live curves come from a fixed seed.
enum DemoData {
    static let isEnabled = Entry.arguments.contains("--demo")

    // MARK: - The fictional Mac

    static let home = "/Users/camille"
    static let firstName = "Camille"
    static let chipName = "Apple M4 Pro"
    static let modelName = "Mac16,8"
    static let osVersion = "27.1"
    static let refusal = "Mode démo : rien n'est modifié sur ce Mac."
    static let seed: UInt64 = 0xC1EA_4C1A_0DE3_02B7

    private static let now = Date()
    private static func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
    private static func gb(_ v: Double) -> Int64 { Int64(v * 1_000_000_000) }
    private static var lib: String { home + "/Library" }

    static let bootDate = ago(3.3)
    static let history = CleanupHistory(totalFreed: gb(46.8), runs: 9, last: ago(12))
    static let lastScan = now.addingTimeInterval(-4 * 60)
    static let maintenanceRuns: [String: Date] = ["dns": ago(19), "quicklook": ago(64), "dock": ago(3)]

    // MARK: - Apps

    /// The look of an app icon drawn by `FileIcon` (gradient tile and SF Symbol, or the app's mascot).
    struct Icon {
        let symbol: String
        let top: UInt32
        let bottom: UInt32
        /// The app's own icon: the mascot on the tile.
        var brand = false
    }

    private struct App {
        let name: String
        let bundleID: String
        let version: String
        let size: Double            // Go
        let icon: Icon
        var lastUsed: Double? = 1   // days ago, nil = never opened
        var arch: Architecture = .appleSilicon
        var appStore = false
        var running = false
        var folder = "/Applications"
        var installed = true

        var path: String { "\(folder)/\(name).app" }
    }

    private static let catalog: [App] = [
        App(name: "Xcode", bundleID: "com.apple.dt.Xcode", version: "26.1", size: 12.84,
            icon: Icon(symbol: "hammer.fill", top: 0x5AAEF8, bottom: 0x1D5FD1), lastUsed: 0.4, arch: .universal, appStore: true),
        App(name: "Monteur", bundleID: "com.monteur.studio", version: "5.2.1", size: 4.62,
            icon: Icon(symbol: "film.stack", top: 0x5B5F7A, bottom: 0x23253A), lastUsed: 0.1, running: true),
        App(name: "Cadence Studio", bundleID: "net.cadence.studio", version: "11.0.3", size: 3.71,
            icon: Icon(symbol: "waveform", top: 0xF2994A, bottom: 0xC0392B), lastUsed: 6),
        App(name: "iMovie", bundleID: "com.apple.iMovieApp", version: "10.4.3", size: 3.12,
            icon: Icon(symbol: "star.fill", top: 0xA66BD3, bottom: 0x5B2C83), lastUsed: 260, appStore: true),
        App(name: "Fresque 3D", bundleID: "com.fresque3d.Fresque", version: "4.8", size: 2.68,
            icon: Icon(symbol: "cube.transparent", top: 0x9B59B6, bottom: 0x4A235A), lastUsed: 140, arch: .intel),
        App(name: "GarageBand", bundleID: "com.apple.garageband10", version: "10.4.12", size: 2.04,
            icon: Icon(symbol: "guitars.fill", top: 0xF5A623, bottom: 0xD35400), lastUsed: 410, appStore: true),
        App(name: "Pixelune", bundleID: "com.pixelune.Pixelune", version: "3.8.2", size: 1.86,
            icon: Icon(symbol: "camera.aperture", top: 0xE84393, bottom: 0x6C5CE7), lastUsed: 2, appStore: true),
        App(name: "Rétro Arcade", bundleID: "com.retroarcade.app", version: "2.3", size: 1.12,
            icon: Icon(symbol: "gamecontroller.fill", top: 0x2ECC71, bottom: 0x145A32), lastUsed: 230, arch: .intel),
        App(name: "Keynote", bundleID: "com.apple.iWork.Keynote", version: "14.4", size: 0.98,
            icon: Icon(symbol: "play.rectangle.fill", top: 0x4DA3F5, bottom: 0x0A5BD3), lastUsed: 21, appStore: true),
        App(name: "Cartographe", bundleID: "fr.cartographe.desktop", version: "7.1", size: 0.94,
            icon: Icon(symbol: "map.fill", top: 0x1ABC9C, bottom: 0x0E5E4F), lastUsed: 310, arch: .intel),
        App(name: "Hélios Code", bundleID: "com.helios.code", version: "1.104.2", size: 0.62,
            icon: Icon(symbol: "chevron.left.forwardslash.chevron.right", top: 0x3BA7E8, bottom: 0x1B4F8C), lastUsed: 0, running: true),
        App(name: "Claude", bundleID: "com.anthropic.claudefordesktop", version: "1.4.2", size: 0.61,
            icon: Icon(symbol: "sparkle", top: 0xE08A68, bottom: 0xC4603F), lastUsed: 0, running: true),
        App(name: "Ruche", bundleID: "com.ruche.desktop", version: "4.42.0", size: 0.51,
            icon: Icon(symbol: "bubble.left.and.bubble.right.fill", top: 0xF7C948, bottom: 0xD68910), lastUsed: 0, running: true),
        App(name: "Tisserand", bundleID: "app.tisserand.mac", version: "2.9", size: 0.36,
            icon: Icon(symbol: "point.3.connected.trianglepath.dotted", top: 0x48C9B0, bottom: 0x117864), lastUsed: 9),
        App(name: "Nuage Drive", bundleID: "io.nuagedrive.client", version: "3.12", size: 0.31,
            icon: Icon(symbol: "cloud.fill", top: 0x8CC8FF, bottom: 0x0984E3), lastUsed: 0, running: true),
        App(name: "Ardoise", bundleID: "fr.ardoise.notes", version: "6.2", size: 0.29,
            icon: Icon(symbol: "square.and.pencil", top: 0x3D566E, bottom: 0x1A252F), lastUsed: 3, appStore: true),
        App(name: "Sonar Podcasts", bundleID: "fr.sonar.podcasts", version: "2.6", size: 0.21,
            icon: Icon(symbol: "antenna.radiowaves.left.and.right", top: 0xB37FD6, bottom: 0x6C3483), lastUsed: 120),
        App(name: "Carnet de bord", bundleID: "fr.carnetdebord.app", version: "1.8", size: 0.148,
            icon: Icon(symbol: "book.closed.fill", top: 0xD1B27E, bottom: 0x8D6E3F), lastUsed: 200, appStore: true),
        App(name: "Lanterne", bundleID: "com.lanterne.recorder", version: "3.1.2", size: 0.12,
            icon: Icon(symbol: "record.circle", top: 0xF0675A, bottom: 0x922B21), lastUsed: 14),
        App(name: "Boussole VPN", bundleID: "com.boussolevpn.client", version: "2.14", size: 0.092,
            icon: Icon(symbol: "location.north.circle.fill", top: 0x26D0A8, bottom: 0x00695C), lastUsed: 0.5, running: true),
        App(name: "Plume", bundleID: "fr.plume.editor", version: "4.0.1", size: 0.074,
            icon: Icon(symbol: "pencil.tip", top: 0xFDCB6E, bottom: 0xE17055), lastUsed: 30, appStore: true),
        App(name: "Zéphyr Météo", bundleID: "fr.zephyr.meteo", version: "1.12", size: 0.058,
            icon: Icon(symbol: "cloud.sun.fill", top: 0x81D4FA, bottom: 0x0984E3), lastUsed: 95, appStore: true),
        App(name: "Archiviste", bundleID: "fr.archiviste.app", version: "4.6", size: 0.031,
            icon: Icon(symbol: "archivebox.fill", top: 0xB2BEC3, bottom: 0x636E72), lastUsed: 18, appStore: true),
        App(name: "Mosaïque", bundleID: "fr.mosaique.windows", version: "1.5", size: 0.022,
            icon: Icon(symbol: "square.grid.2x2.fill", top: 0x8C7AE6, bottom: 0x341F97), lastUsed: 0, running: true),
        App(name: "Heartware", bundleID: "io.github.olima34.cleanmyclaude", version: "1.0", size: 0.009,
            icon: Icon(symbol: "", top: 0x5FA8EC, bottom: 0x2C6FB8, brand: true), lastUsed: 0, running: true),
        // Shipped with macOS: not listed in the inventory, but they run and get permissions.
        App(name: "Safari", bundleID: "com.apple.Safari", version: "27.1", size: 0,
            icon: Icon(symbol: "safari.fill", top: 0x5AC8FA, bottom: 0x1E6FD9), lastUsed: 0, running: true, installed: false),
        App(name: "Terminal", bundleID: "com.apple.Terminal", version: "2.15", size: 0,
            icon: Icon(symbol: "terminal.fill", top: 0x4A4A48, bottom: 0x1F1F1E), lastUsed: 0, running: true,
            folder: "/System/Applications/Utilities", installed: false),
        App(name: "Finder", bundleID: "com.apple.finder", version: "27.1", size: 0,
            icon: Icon(symbol: "face.smiling", top: 0x6EC1FF, bottom: 0x1F7AE0), lastUsed: 0, running: true,
            folder: "/System/Library/CoreServices", installed: false)
    ]

    private static func app(_ name: String) -> App { catalog.first { $0.name == name }! }

    /// The icon to draw for a fictional app bundle, nil for anything else.
    static func icon(for path: String) -> Icon? {
        if let a = catalog.first(where: { $0.path == path }) { return a.icon }
        guard path.hasSuffix(".app") else { return nil }
        return Icon(symbol: "app.dashed", top: 0x9A9890, bottom: 0x5F5D57)
    }

    static func running() -> RunningApps {
        var r = RunningApps()
        for a in catalog where a.running {
            r.bundleIDs.insert(a.bundleID)
            r.byBundleID[a.bundleID] = a.name
            r.names.insert(a.name.lowercased())
        }
        return r
    }

    static func apps() -> [InstalledApp] {
        catalog.filter(\.installed).map { a in
            InstalledApp(path: a.path, name: a.name, bundleID: a.bundleID, version: a.version, size: gb(a.size),
                         lastUsed: a.lastUsed.map(ago), added: ago(400), architecture: a.arch, fromAppStore: a.appStore,
                         isApple: a.bundleID.hasPrefix("com.apple."), isRunning: a.running)
        }
        .sorted { $0.size > $1.size }
    }

    /// What an app left in ~/Library, for the uninstall sheet.
    static func leftovers(for app: InstalledApp) -> [CleanupItem] {
        guard let b = app.bundleID else { return [] }
        let parts: [(String, String, Double)] = [
            ("/Application Support/" + b, "Données", 0.11), ("/Caches/" + b, "Cache", 0.06),
            ("/Logs/" + app.name, "Journaux", 0.004), ("/Preferences/" + b + ".plist", "Préférences", 0.00002),
            ("/Saved Application State/" + b + ".savedState", "État des fenêtres", 0.000004)
        ]
        return parts.map { rel, kind, share in
            CleanupItem(path: lib + rel, name: (rel as NSString).lastPathComponent, detail: kind,
                        size: max(4096, Int64(Double(app.size) * share)), modified: ago(3))
        }
        .sorted { $0.size > $1.size }
    }

    /// Settings and caches of apps that are gone.
    static func orphans() -> [CleanupItem] {
        let list: [(String, String, String, Double, Double)] = [
            ("Application Support", "com.retroplay.emulator", "Données", 0.412, 240),
            ("Containers", "com.vieuxlecteur.player", "Conteneur", 0.286, 410),
            ("Caches", "net.planif.mac", "Cache", 0.064, 180),
            ("Application Support", "com.clavier.magique", "Données", 0.038, 520),
            ("Preferences", "com.retroplay.emulator.plist", "Préférences", 0.000012, 240),
            ("Saved Application State", "io.photosync.helper.savedState", "État des fenêtres", 0.0006, 95)
        ]
        return list.map { folder, file, kind, size, days in
            var id = file
            for ext in [".plist", ".savedState"] where id.hasSuffix(ext) { id = String(id.dropLast(ext.count)) }
            return CleanupItem(path: lib + "/" + folder + "/" + file, name: id, detail: "\(kind) · modifié \(Fmt.relative(ago(days)))",
                               size: gb(size), modified: ago(days), defaultOn: false)
        }
        .sorted { $0.size > $1.size }
    }

    // MARK: - Cleanup

    private struct Junk {
        var path: String
        var name: String
        var detail: String? = nil
        var size: Double
        var on = true
        var lockedBy: String? = nil
        var days: Double = 2
    }

    static func cleanupTargets() -> [CleanupTarget] {
        let caches = lib + "/Caches", support = lib + "/Application Support", dev = lib + "/Developer"
        let downloads = home + "/Downloads", trash = home + "/.Trash"
        func locked(_ app: String) -> String { "Quitte \(app) pour nettoyer ceci" }
        func cache(_ id: String, _ name: String?, _ size: Double) -> Junk {
            Junk(path: caches + "/" + id, name: name ?? id, detail: name == nil ? nil : id, size: size)
        }
        let derived = dev + "/Xcode/DerivedData"
        let device = dev + "/Xcode/iOS DeviceSupport"
        let mail = lib + "/Containers/com.apple.mail/Data/Library/Mail Downloads"
        let cli = caches + "/claude-cli-nodejs"

        var items: [String: [Junk]] = [:]
        items["appCaches"] = [
            cache("com.monteur.studio", "Monteur", 1.24), cache("com.pixelune.Pixelune", "Pixelune", 0.86),
            cache("fr.sonar.podcasts", "Sonar Podcasts", 0.53), cache("net.cadence.studio", "Cadence Studio", 0.31),
            cache("io.nuagedrive.client", "Nuage Drive", 0.21), cache("com.fresque3d.Fresque", "Fresque 3D", 0.128),
            cache("app.tisserand.mac", "Tisserand", 0.072), cache("com.lanterne.recorder", "Lanterne", 0.041),
            cache("com.retroplay.emulator", nil, 0.018), cache("fr.zephyr.meteo", "Zéphyr Météo", 0.0083)
        ]
        let apple: [(String, Double)] = [("com.apple.Music", 0.296), ("GeoServices", 0.188), ("com.apple.dt.Xcode", 0.142),
                                         ("com.apple.python", 0.091), ("SiriTTS", 0.064), ("com.apple.helpd", 0.038)]
        items["appleCaches"] = apple.map { Junk(path: caches + "/" + $0.0, name: $0.0, size: $0.1, on: false) }
        items["logs"] = [
            Junk(path: lib + "/Logs/DiagnosticReports", name: "Rapports de diagnostic", size: 0.182),
            Junk(path: lib + "/Logs/CoreSimulator", name: "CoreSimulator", size: 0.096),
            Junk(path: lib + "/Logs/Monteur", name: "Monteur", size: 0.044),
            Junk(path: lib + "/Logs/Hélios Code", name: "Hélios Code", size: 0.023),
            Junk(path: lib + "/Logs/Nuage Drive", name: "Nuage Drive", size: 0.011)
        ]
        items["derivedData"] = [
            Junk(path: derived + "/Boussole-dqkzvhxpnrbtfjgyemcalwsoiuex", name: "Boussole", size: 1.84),
            Junk(path: derived + "/Potager-bgmlfhkwqzcxjnrtsyvdpaeoiuha", name: "Potager", size: 0.86),
            Junk(path: derived + "/CarnetDeBord-hzqxkmwvbcnrjtfplgyedasoi", name: "CarnetDeBord", size: 0.52),
            Junk(path: derived + "/MeteoWidget-ckwqzmxrtpbvhnjflgydseoaiq", name: "MeteoWidget", size: 0.31)
        ]
        items["deviceSupport"] = [
            Junk(path: device + "/iPhone17,1 27.0.1 (24A350)", name: "iPhone17,1 27.0.1 (24A350)",
                 detail: "iOS · le plus récent, gardé par défaut", size: 4.12, on: false),
            Junk(path: device + "/iPhone14,5 26.4 (23E244)", name: "iPhone14,5 26.4 (23E244)", detail: "iOS", size: 1.96)
        ]
        items["simulators"] = [
            Junk(path: dev + "/CoreSimulator/Caches/dyld", name: "dyld", detail: "Simulateurs", size: 1.21),
            Junk(path: dev + "/Xcode/UserData/Previews", name: "Aperçus SwiftUI", size: 0.64)
        ]
        items["archives"] = [
            Junk(path: dev + "/Xcode/Archives/\(isoDay(ago(38)))/Boussole 2.3.xcarchive", name: "Boussole 2.3",
                 detail: isoDay(ago(38)), size: 0.41, on: false),
            Junk(path: dev + "/Xcode/Archives/\(isoDay(ago(141)))/Boussole 2.2.xcarchive", name: "Boussole 2.2",
                 detail: isoDay(ago(141)), size: 0.388, on: false)
        ]
        let packages: [(String, String, Double, Bool)] = [
            ("npm", home + "/.npm/_cacache", 1.62, true), ("Homebrew", caches + "/Homebrew", 0.94, true),
            ("pip", caches + "/pip", 0.41, true), ("Yarn", caches + "/Yarn", 0.27, true),
            ("Swift Package Manager", caches + "/org.swift.swiftpm", 0.19, true),
            ("Playwright (navigateurs de test)", caches + "/ms-playwright", 1.18, false)
        ]
        items["packageCaches"] = packages.map { Junk(path: $0.1, name: $0.0, detail: FS.pretty($0.1), size: $0.2, on: $0.3) }
        items["staleDeps"] = [
            Junk(path: home + "/Developer/potager-api/target", name: "potager-api",
                 detail: "Cargo target · ~/Developer/potager-api", size: 3.2, on: false),
            Junk(path: home + "/Developer/jeux-retro/node_modules", name: "jeux-retro",
                 detail: "node_modules · ~/Developer/jeux-retro", size: 0.86, on: false)
        ]
        items["claudeApp"] = [
            Junk(path: support + "/Claude/Cache", name: "Cache", size: 0.312, lockedBy: "Claude"),
            Junk(path: support + "/Claude/Code Cache", name: "Code Cache", size: 0.096, lockedBy: "Claude"),
            Junk(path: support + "/Claude/GPUCache", name: "GPUCache", size: 0.004, lockedBy: "Claude"),
            Junk(path: caches + "/com.anthropic.claudefordesktop.ShipIt", name: "Mises à jour téléchargées",
                 detail: "~/Library/Caches/com.anthropic.claudefordesktop.ShipIt", size: 0.268),
            Junk(path: caches + "/com.anthropic.claudefordesktop", name: "Cache système",
                 detail: "~/Library/Caches/com.anthropic.claudefordesktop", size: 0.041)
        ]
        items["claudeCode"] = [
            Junk(path: cli + "/-Users-camille-Developer-boussole-ios", name: "Journaux MCP",
                 detail: "-Users-camille-Developer-boussole-ios", size: 0.148),
            Junk(path: cli + "/-Users-camille-Developer-site-atelier", name: "Journaux MCP",
                 detail: "-Users-camille-Developer-site-atelier", size: 0.062),
            Junk(path: home + "/.claude/debug/8c2f41d0-5b7e-4e1a-9d3c-2f6a7b8e9c01.txt", name: "Débogage",
                 detail: "8c2f41d0-5b7e-4e1a-9d3c-2f6a7b8e9c01.txt", size: 0.018),
            Junk(path: home + "/.claude/shell-snapshots/snapshot-zsh-1758201342-x7k2.sh", name: "Instantané de shell",
                 detail: "snapshot-zsh-1758201342-x7k2.sh", size: 0.0004)
        ]
        items["claudeHistory"] = [
            Junk(path: home + "/.claude/file-history/3f9a2c1e-77b4-4c0e-a1d2-5e6f7a8b9c0d", name: "Session 3f9a2c1e",
                 detail: Fmt.day(ago(45)), size: 0.21, on: false),
            Junk(path: home + "/.claude/file-history/8b41d07f-2c3d-4e5f-9a0b-1c2d3e4f5a6b", name: "Session 8b41d07f",
                 detail: Fmt.day(ago(73)), size: 0.096, on: false)
        ]
        items["browserCaches"] = [
            Junk(path: caches + "/com.apple.Safari", name: "Safari", detail: "Cache disque", size: 0.412, lockedBy: "Safari")
        ]
        items["electronCaches"] = [
            Junk(path: support + "/Hélios Code/CachedData", name: "Hélios Code", detail: "CachedData", size: 0.418, lockedBy: "Hélios Code"),
            Junk(path: support + "/Hélios Code/Cache", name: "Hélios Code", detail: "Cache", size: 0.121, lockedBy: "Hélios Code"),
            Junk(path: support + "/Ruche/Cache", name: "Ruche", detail: "Cache", size: 0.264, lockedBy: "Ruche"),
            Junk(path: support + "/Ruche/Service Worker/CacheStorage", name: "Ruche", detail: "Service Worker/CacheStorage",
                 size: 0.188, lockedBy: "Ruche"),
            Junk(path: support + "/Tisserand/Code Cache", name: "Tisserand", detail: "Code Cache", size: 0.096),
            Junk(path: support + "/Sonar Podcasts/GPUCache", name: "Sonar Podcasts", detail: "GPUCache", size: 0.012)
        ]
        items["trash"] = [
            Junk(path: trash + "/Ancien montage.mov", name: "Ancien montage.mov", size: 1.62),
            Junk(path: trash + "/Pixelune-3.7.dmg", name: "Pixelune-3.7.dmg", size: 0.398),
            Junk(path: trash + "/Photos à trier", name: "Photos à trier", size: 0.312),
            Junk(path: trash + "/Capture d'écran 2026-09-02 à 18.41.07.png", name: "Capture d'écran 2026-09-02 à 18.41.07.png", size: 0.0031)
        ]
        items["mailDownloads"] = [
            Junk(path: mail + "/Photos mariage Léa & Hugo.zip", name: "Photos mariage Léa & Hugo.zip", size: 0.186),
            Junk(path: mail + "/Programme séminaire.pptx", name: "Programme séminaire.pptx", size: 0.0124),
            Junk(path: mail + "/Devis cuisine.pdf", name: "Devis cuisine.pdf", size: 0.0031)
        ]
        let installers: [(String, Double, Double)] = [
            ("Ubuntu-24.04.2-desktop-arm64.iso", 3.2, 205), ("Cadence-Studio-11.pkg", 1.9, 64),
            ("Monteur-Installer-5.2.dmg", 1.38, 33), ("Pixelune-3.8.dmg", 0.412, 12)
        ]
        items["installers"] = installers.map {
            Junk(path: downloads + "/" + $0.0, name: $0.0, detail: "Téléchargé le \(Fmt.day(ago($0.2)))", size: $0.1, on: false, days: $0.2)
        }
        items["oldDownloads"] = [
            Junk(path: downloads + "/Vidéos à trier", name: "Vidéos à trier", detail: "Modifié \(Fmt.relative(ago(152)))",
                 size: 8.1, on: false, days: 152),
            Junk(path: downloads + "/Archives 2023.zip", name: "Archives 2023.zip", detail: "Modifié \(Fmt.relative(ago(610)))",
                 size: 2.4, on: false, days: 610)
        ]
        items["iosBackups"] = [
            Junk(path: support + "/MobileSync/Backup/00008110-001A2D3C4E5F6789", name: "iPhone de Camille",
                 detail: "Sauvegarde du \(Fmt.day(ago(218)))", size: 21.4, on: false)
        ]

        return CleanupCatalog.specs().map { spec in
            var t = CleanupTarget(id: spec.id, group: spec.group, title: spec.title, explanation: spec.explanation,
                                  symbol: spec.symbol, mode: spec.mode, defaultOn: spec.defaultOn)
            t.items = (items[spec.id] ?? []).map { j in
                CleanupItem(path: j.path, name: j.name, detail: j.detail, size: gb(j.size), modified: ago(j.days),
                            defaultOn: j.on && spec.defaultOn, blockedReason: j.lockedBy.map(locked))
            }
            .sorted { $0.size > $1.size }
            return t
        }
    }

    static let claudeFootprint = ClaudeFootprint(transcripts: gb(1.84), vm: gb(7.9), codeVersions: gb(0.9))

    private static func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // MARK: - Protection

    static func securityChecks() -> [SecurityCheck] {
        func c(_ id: String, _ title: String, _ symbol: String, _ status: Status, _ detail: String, advice: String? = nil,
               url: String? = nil, scored: Bool = true, fix: SecurityFix? = nil) -> SecurityCheck {
            SecurityCheck(id: id, title: title, symbol: symbol, status: status, detail: detail, advice: advice, settingsURL: url, scored: scored, fix: fix)
        }
        func admin(_ title: String, _ what: String) -> SecurityFix {
            SecurityFix(title: title, explanation: what, action: .admin("/usr/bin/true"))
        }
        let list = [
            c("filevault", "Chiffrement FileVault", "lock.doc", .ok, "Ton disque est chiffré : sans ton mot de passe, ses données sont illisibles.", url: SettingsPane.fileVault),
            c("sip", "Protection de l'intégrité du système", "cpu", .ok, "Les fichiers de macOS ne peuvent pas être modifiés, même par un administrateur."),
            c("gatekeeper", "Gatekeeper", "checkmark.shield", .ok, "Seules les apps signées et vérifiées par Apple s'ouvrent sans avertissement.", url: SettingsPane.security),
            c("ssv", "Volume système scellé", "seal", .ok, "macOS vérifie à chaque démarrage que son volume système n'a pas été modifié d'un seul octet."),
            c("firewall", "Coupe-feu", "flame", .warn, "Le coupe-feu est désactivé.",
              advice: "Sur un Wi-Fi public, il empêche les autres appareils de se connecter à tes services.", url: SettingsPane.firewall,
              fix: admin("Activer le coupe-feu", "Le coupe-feu de macOS sera activé. macOS te demande ton mot de passe d'administrateur.")),
            c("stealth", "Mode furtif", "eye.slash", .warn, "Ton Mac se signale à qui le sonde sur le réseau.",
              advice: "Le mode furtif le rend invisible aux balayages sur un Wi-Fi public. Il demande le coupe-feu.", url: SettingsPane.firewall,
              fix: admin("Activer le mode furtif", "Le coupe-feu passe en mode furtif. macOS te demande ton mot de passe d'administrateur.")),
            c("xprotect", "Antimalware intégré (XProtect)", "ant", .ok, "Actif. Définitions version 5367, installées \(Fmt.relative(ago(4)))."),
            c("backup", "Sauvegarde Time Machine", "clock.arrow.circlepath", .ok, "Ton Mac est sauvegardé par Time Machine.", url: SettingsPane.timeMachine),
            c("lockdown", "Mode Isolement", "lock.trianglebadge.exclamationmark", .info,
              "Désactivé. Il protège les personnes visées par des attaques ciblées (journalistes, militants…).", scored: false),
            c("updates", "Réponses de sécurité automatiques", "arrow.triangle.2.circlepath", .ok,
              "Les correctifs de sécurité et les signatures antimalware s'installent tout seuls.", url: SettingsPane.updates),
            c("autoinstall", "Mises à jour de macOS automatiques", "square.and.arrow.down.on.square", .info,
              "Les mises à jour de macOS sont téléchargées et attendent ton feu vert.", url: SettingsPane.updates),
            c("screenlock", "Mot de passe au réveil", "lock.display", .ok, "Le mot de passe est demandé immédiatement après la veille.", url: SettingsPane.lockScreen),
            c("idle", "Verrouillage après inactivité", "timer", .warn,
              "L'écran ne s'éteint jamais tout seul (au moins sur secteur) : ton Mac reste ouvert si tu t'absentes.",
              advice: "Règle l'économiseur d'écran ou l'extinction de l'écran sur 20 minutes au plus dans Écran verrouillé.", url: SettingsPane.lockScreen),
            c("autologin", "Ouverture de session automatique", "person.badge.key", .ok, "Désactivée : il faut un mot de passe au démarrage.", url: SettingsPane.users),
            c("guest", "Compte invité", "person.crop.circle.badge.questionmark", .ok, "Désactivé.", url: SettingsPane.users),
            c("root", "Compte root", "person.badge.shield.checkmark", .ok, "Désactivé, comme il se doit."),
            c("hints", "Indices de mot de passe", "questionmark.key.filled", .ok, "L'écran de connexion ne donne aucun indice."),
            c("admin", "Compte du quotidien", "person.fill.checkmark", .warn,
              "Tu travailles avec un compte administrateur : un logiciel malveillant qui obtient ton mot de passe a les pleins pouvoirs.",
              advice: "Pour une protection renforcée, crée un compte administrateur séparé et passe le tien en compte standard.", url: SettingsPane.users),
            c("ssh", "Connexion à distance (SSH)", "terminal", .ok, "Désactivé."),
            c("screensharing", "Partage d'écran", "rectangle.on.rectangle", .ok, "Désactivé."),
            c("ard", "Gestion à distance", "desktopcomputer.and.arrow.down", .ok, "Désactivé."),
            c("remoteevents", "Événements Apple à distance", "applescript", .ok, "Désactivé."),
            c("filesharing", "Partage de fichiers", "folder.badge.person.crop", .info, "Des dossiers de ton Mac sont partagés sur le réseau.",
              advice: "Désactive « Partage de fichiers » si tu ne t'en sers pas.", url: SettingsPane.sharing),
            c("printers", "Partage d'imprimantes", "printer", .ok, "Désactivé."),
            c("internetsharing", "Partage de connexion", "wifi.router", .ok, "Désactivé."),
            c("bluetooth", "Partage Bluetooth", "dot.radiowaves.left.and.right", .ok, "Désactivé."),
            c("airplay", "Récepteur AirPlay", "airplayvideo", .warn, "Ton Mac accepte les diffusions AirPlay et écoute sur le réseau (ports 5000 et 7000).",
              advice: "Désactive « Récepteur AirPlay » dans AirDrop et Handoff si tu ne diffuses jamais vers ce Mac.", url: SettingsPane.airDrop),
            c("airdrop", "AirDrop", "airplayaudio", .ok, "Visible de tes contacts seulement.", url: SettingsPane.airDrop),
            c("media", "Partage de médias", "music.note.house", .ok, "Désactivé."),
            c("proxy", "Proxy réseau", "arrow.triangle.branch", .ok, "Aucun proxy : ton trafic web va directement aux sites."),
            c("dns", "Serveurs DNS", "point.3.connected.trianglepath.dotted", .ok, "Ton Mac demande les adresses des sites à : 192.168.1.254 (local)."),
            c("certificates", "Certificats racine ajoutés", "checkmark.seal.text.page", .ok, "Aucun certificat ajouté n'est autorisé à signer des sites web."),
            c("hosts", "Fichier hosts", "doc.text.magnifyingglass", .ok, "D'origine : aucun site n'est détourné."),
            c("profiles", "Profils de configuration", "person.text.rectangle", .warn, "Installé : Chrome Search Settings.",
              advice: "Si tu ne reconnais pas ce profil, supprime-le dans Réglages › Général › Gestion des appareils : les logiciels publicitaires s'en servent pour imposer leur moteur de recherche.",
              url: SettingsPane.profiles),
            c("policies", "Navigateurs détournés", "globe.badge.chevron.backward", .bad,
              "Réglé de force : Chrome (ExtensionInstallForcelist, DefaultSearchProviderSearchURL).",
              advice: "Hors entreprise, c'est la marque d'un logiciel publicitaire (Adload, Pirrit…). Supprime son profil dans Réglages › Général › Gestion des appareils, puis lance l'analyse des menaces.",
              url: SettingsPane.profiles),
            c("sshkeys", "Clés SSH", "key.horizontal", .warn,
              "Sans phrase de passe : id_ed25519. Un voleur de données qui copie le fichier peut s'en servir tel quel.",
              advice: "Ajoute une phrase de passe avec « ssh-keygen -p -f ~/.ssh/id_ed25519 », puis « ssh-add --apple-use-keychain » pour ne pas la retaper."),
            c("credentials", "Identifiants en clair", "doc.badge.ellipsis", .ok, "Aucun mot de passe ni jeton écrit en clair dans les fichiers des outils courants."),
            c("history", "Secrets dans l'historique du Terminal", "terminal", .ok, "Aucune clé d'API ni mot de passe repéré dans tes historiques."),
            c("extensions", "Extensions des fichiers", "doc.questionmark", .ok,
              "Le Finder montre toutes les extensions : « facture.pdf.app » ne passe pas pour un PDF."),
            c("safaridownloads", "Ouverture des fichiers téléchargés", "arrow.down.app", .warn,
              "Safari ouvre tout seul les fichiers « fiables » téléchargés (PDF, images, archives décompressées).",
              advice: "Décoche « Ouvrir les fichiers fiables après téléchargement » dans Safari › Réglages › Général."),
            c("fraud", "Alerte sites frauduleux (Safari)", "exclamationmark.shield", .ok, "Safari t'avertit avant d'ouvrir un site d'hameçonnage connu.")
        ]
        return SecurityCategory.allCases.flatMap { cat in list.filter { $0.category == cat } }
    }

    static func pendingUpdates() -> SecurityCheck {
        SecurityCheck(id: "pending", title: "Mises à jour en attente", symbol: "square.and.arrow.down", status: .warn,
                      detail: "macOS 27.1.1-26B92, Safari 27.1.1-21623.1.12",
                      advice: "Installe-les : la plupart corrigent des failles de sécurité.", settingsURL: SettingsPane.updates)
    }

    static func grants() -> [PermissionGrant] {
        let list: [(String, String, Double)] = [
            ("kTCCServiceSystemPolicyAllFiles", "Heartware", 30), ("kTCCServiceSystemPolicyAllFiles", "Terminal", 400),
            ("kTCCServiceSystemPolicyAllFiles", "Hélios Code", 210), ("kTCCServiceSystemPolicyAllFiles", "Nuage Drive", 380),
            ("kTCCServiceScreenCapture", "Lanterne", 120), ("kTCCServiceScreenCapture", "Ruche", 260),
            ("kTCCServiceScreenCapture", "Claude", 45),
            ("kTCCServiceAccessibility", "Mosaïque", 300), ("kTCCServiceAccessibility", "Claude", 45),
            ("kTCCServiceAccessibility", "Lanterne", 120),
            ("kTCCServiceCamera", "Ruche", 260), ("kTCCServiceCamera", "Lanterne", 120),
            ("kTCCServiceMicrophone", "Ruche", 260), ("kTCCServiceMicrophone", "Cadence Studio", 340),
            ("kTCCServiceMicrophone", "Claude", 45), ("kTCCServiceMicrophone", "Lanterne", 120),
            ("kTCCServiceAppleEvents", "Hélios Code", 90), ("kTCCServiceAppleEvents", "Terminal", 400),
            ("kTCCServiceAddressBook", "Ruche", 260), ("kTCCServicePhotos", "Pixelune", 150),
            ("kTCCServiceSystemPolicyDocumentsFolder", "Hélios Code", 210),
            ("kTCCServiceSystemPolicyDocumentsFolder", "Tisserand", 70),
            ("kTCCServiceSystemPolicyDocumentsFolder", "Nuage Drive", 380),
            ("kTCCServiceSystemPolicyDownloadsFolder", "Archiviste", 18),
            ("kTCCServiceSystemPolicyDownloadsFolder", "Hélios Code", 210),
            ("kTCCServiceBluetoothAlways", "Cadence Studio", 340)
        ]
        let services = Dictionary(uniqueKeysWithValues: TCCService.all.map { ($0.key, $0) })
        return list.compactMap { key, name, days in
            guard let s = services[key] else { return nil }
            let a = app(name)
            return PermissionGrant(service: s, client: a.bundleID, name: a.name, path: a.path, lastModified: ago(days))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func traces() -> [PrivacyTrace] {
        let sfl = lib + "/Application Support/com.apple.sharedfilelist"
        return [
            PrivacyTrace(id: "recent", group: "Système", title: "Éléments récents",
                         detail: "Documents, apps et serveurs du menu Pomme › Éléments récents et des menus « Ouvrir récent ».",
                         symbol: "clock", paths: [sfl + "/com.apple.LSSharedFileList.RecentDocuments.sfl3"], size: 1_240_000,
                         count: 38, action: .recentItems, defaultOn: true),
            PrivacyTrace(id: "quarantine", group: "Système", title: "Historique des téléchargements",
                         detail: "macOS note l'adresse d'origine de chaque fichier téléchargé, depuis toujours.",
                         symbol: "arrow.down.doc", size: 3_276_800, count: 2_814, action: .quarantineEvents, defaultOn: true),
            PrivacyTrace(id: "quicklook", group: "Système", title: "Vignettes Coup d'œil",
                         detail: "Miniatures des fichiers prévisualisés, y compris ceux supprimés depuis.",
                         symbol: "eye", size: 186_000_000, action: .quickLook, defaultOn: true),
            PrivacyTrace(id: "shell", group: "Système", title: "Historique du Terminal",
                         detail: "Les commandes tapées dans zsh, bash, Python, Node… (y compris d'éventuels secrets collés).",
                         symbol: "terminal", paths: [home + "/.zsh_history", home + "/.python_history"], size: 2_400_000, count: 23),
            PrivacyTrace(id: "clipboard", group: "Système", title: "Presse-papiers",
                         detail: "Ce que tu as copié en dernier (un mot de passe, peut-être).", symbol: "doc.on.clipboard",
                         action: .clipboard)
        ]
    }

    static func launchItems() -> [LaunchItem] {
        func agent(_ label: String, _ domain: LaunchDomain, app: String?, exe: String? = nil, args: [String] = [],
                   signature: SignatureKind, keepAlive: Bool = false, disabled: Bool = false, running: Bool = false,
                   flags: [LaunchFlag] = []) -> LaunchItem {
            let a = app.map(self.app)
            let program = exe ?? (domain == .globalDaemon ? "/Library/PrivilegedHelperTools/" + label
                                                          : (a?.path ?? "") + "/Contents/Library/LaunchServices/" + label)
            return LaunchItem(label: label, plistPath: domain.folder + "/" + label + ".plist", domain: domain, program: program,
                              arguments: args.isEmpty ? [program] : args, runAtLoad: true, keepAlive: keepAlive,
                              disabled: disabled, running: running, signature: signature, vendor: signature.label,
                              appPath: a?.path, flags: flags)
        }
        return [
            agent("com.nuagedrive.sync-agent", .userAgent, app: "Nuage Drive", signature: .developerID("Nuage Drive SAS"),
                  keepAlive: true, running: true),
            agent("com.helios.code.updater", .userAgent, app: "Hélios Code", signature: .developerID("Helios Labs Inc.")),
            agent("fr.sonar.podcasts.helper", .userAgent, app: "Sonar Podcasts", signature: .developerID("Sonar Audio"), disabled: true),
            agent("com.pixelune.licensing", .userAgent, app: "Pixelune", signature: .appStore, running: true),
            agent("com.lanterne.recorder.helper", .userAgent, app: "Lanterne", signature: .developerID("Lanterne Software"), running: true),
            agent("local.camille.sauvegarde-photos", .userAgent, app: nil, exe: "/bin/zsh",
                  args: ["/bin/zsh", home + "/Scripts/sauvegarde-photos.sh"], signature: .apple, flags: [.script]),
            agent("com.retroplay.updater", .userAgent, app: nil, exe: lib + "/Application Support/RetroPlay/updater",
                  signature: .missing, flags: [.orphan]),
            agent("com.boussolevpn.client", .globalAgent, app: "Boussole VPN", signature: .developerID("Boussole Networks"),
                  keepAlive: true, running: true),
            agent("net.cadence.studio.audiohelper", .globalAgent, app: "Cadence Studio", signature: .developerID("Cadence Audio GmbH"),
                  running: true),
            agent("com.boussolevpn.helper", .globalDaemon, app: "Boussole VPN", signature: .developerID("Boussole Networks"),
                  keepAlive: true, running: true),
            agent("net.cadence.studio.driver", .globalDaemon, app: "Cadence Studio", signature: .developerID("Cadence Audio GmbH")),
            agent("com.fresque3d.licensed", .globalDaemon, app: nil, exe: "/Library/Application Support/Fresque3D/licensed",
                  signature: .unsigned, running: true, flags: [.unsigned]),
            // The adware of the Protection demo: hidden in Application Support, and a fake Apple updater.
            agent("com.SearchDaemon", .userAgent, app: nil,
                  exe: lib + "/Application Support/.a7f3c2e1/Services/com.SearchDaemon.service.app/Contents/MacOS/com.SearchDaemon.service",
                  signature: .adhoc, keepAlive: true, running: true, flags: [.unusualLocation, .adhoc, .recent]),
            agent("com.apple.updates.helper", .userAgent, app: nil, exe: "/Users/Shared/.cache/updater",
                  args: ["/Users/Shared/.cache/updater", "--daemon"], signature: .unsigned, running: true,
                  flags: [.impersonatesApple, .unusualLocation, .unsigned, .recent])
        ]
    }

    // MARK: - Processes

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n - 1 }
    }
    private static let processSamples = Counter()

    /// The first sample is always the same; later ones wobble a little, like a live `ps`.
    static func processes() -> [ProcessGroup] {
        let list: [(String, Bool, Int, Double, Double)] = [
            ("Monteur", true, 3, 142.0, 2.64), ("Hélios Code", true, 9, 64.8, 1.92), ("WindowServer", false, 1, 28.6, 0.61),
            ("Safari", true, 14, 18.9, 2.18), ("Claude", true, 7, 12.4, 1.21), ("Ruche", true, 5, 9.1, 0.84),
            ("kernel_task", false, 1, 6.8, 0.052), ("mds_stores", false, 1, 4.9, 0.096), ("Nuage Drive", true, 2, 3.2, 0.31),
            ("Terminal", true, 1, 2.6, 0.128), ("Finder", true, 1, 1.9, 0.24), ("coreaudiod", false, 1, 1.2, 0.022),
            ("Boussole VPN", true, 2, 0.9, 0.064), ("Mosaïque", true, 1, 0.6, 0.048), ("Heartware", true, 1, 0.4, 0.086),
            ("bluetoothd", false, 1, 0.2, 0.014), ("cloudd", false, 1, 0.1, 0.038)
        ]
        let tick = processSamples.next()
        return list.enumerated().map { i, p in
            let (name, isApp, count, cpu, mem) = p
            let wobble = tick == 0 ? 1 : 0.75 + 0.5 * noise(tick * 64 + i, salt: 7)
            let path = isApp ? app(name).path : nil
            return ProcessGroup(id: path ?? "/usr/libexec/" + name, name: name, appPath: path,
                                pids: (0..<count).map { Int32(400 + i * 97 + $0 * 13) }, cpu: cpu * wobble,
                                memory: UInt64(mem * 1_000_000_000 * (0.97 + 0.03 * wobble)), isMine: isApp)
        }
    }

    // MARK: - System monitor

    /// Fills the monitor with the values of tick `t`. The curves are pure functions of the tick:
    /// the history is the 60 latest values, so it is full from the first sample.
    @MainActor
    static func sample(_ m: SystemMonitor, tick t: Int) {
        let window = (t - SystemMonitor.historyLength + 1)...t
        m.cpu = cpu(t)
        m.cpuUser = m.cpu * 0.68
        m.cpuSystem = m.cpu - m.cpuUser
        m.cpuHistory = window.map(cpu)
        m.coreCount = 12
        m.loadAverage = 2.1 + 5 * m.cpu

        let total: UInt64 = 24 << 30
        let used = UInt64(Double(total) * memory(t))
        m.memTotal = total
        m.memWired = 3_120_000_000
        m.memCompressed = 1_380_000_000
        m.memApp = used - m.memWired - m.memCompressed
        m.memCached = 5_640_000_000
        m.memFree = total - used - m.memCached
        m.memHistory = window.map(memory)
        m.swapUsed = 1_310_000_000
        m.swapTotal = 2 << 30
        m.pressure = .normal

        m.netIn = netIn(t)
        m.netOut = netOut(t)
        m.netInHistory = window.map(netIn)
        m.netOutHistory = window.map(netOut)
        m.netTotalIn = 48_200_000_000
        m.netTotalOut = 6_900_000_000

        sampleDisk(m)
        m.battery = BatteryInfo(level: 0.82, isCharging: false, onAC: false, minutesLeft: 404, cycleCount: 187,
                                health: 0.93, temperature: 31.2)
        m.thermal = .nominal
        m.bootDate = bootDate
        m.lastSample = Date()
    }

    @MainActor
    static func sampleDisk(_ m: SystemMonitor) {
        m.diskTotal = 994_662_584_320
        m.diskFree = 311_408_000_000
        m.diskFreeStrict = 286_930_000_000
    }

    private static func cpu(_ t: Int) -> Double {
        let x = Double(t)
        let spike = noise(t, salt: 1) > 0.9 ? 0.2 * noise(t, salt: 2) : 0
        return min(0.95, max(0.05, 0.24 + 0.05 * sin(x / 5.3) + 0.12 * (smooth(x / 3, salt: 3) - 0.5) + spike))
    }

    private static func memory(_ t: Int) -> Double { 0.6 + 0.04 * (smooth(Double(t) / 9, salt: 4) - 0.5) }

    private static func netIn(_ t: Int) -> Double {
        let burst = noise(t, salt: 5) > 0.82 ? 1_500_000 + 3_500_000 * noise(t, salt: 6) : 0
        return 38_000 + 60_000 * smooth(Double(t) / 4, salt: 8) + burst
    }

    private static func netOut(_ t: Int) -> Double {
        let burst = noise(t, salt: 9) > 0.9 ? 250_000 + 400_000 * noise(t, salt: 10) : 0
        return 9_000 + 22_000 * smooth(Double(t) / 4, salt: 11) + burst
    }

    /// A reproducible number in [0, 1) for tick `t`.
    private static func noise(_ t: Int, salt: UInt64) -> Double {
        var r = SeededRNG(state: seed ^ (UInt64(bitPattern: Int64(t)) &* 0x9E37_79B9_7F4A_7C15) ^ (salt &* 0xD1B5_4A32_D192_ED03))
        return r.unit()
    }

    /// Value noise: `noise` smoothly interpolated between whole numbers.
    private static func smooth(_ x: Double, salt: UInt64) -> Double {
        let i = Int(x.rounded(.down))
        let f = x - Double(i)
        let s = f * f * (3 - 2 * f)
        return noise(i, salt: salt) * (1 - s) + noise(i + 1, salt: salt) * s
    }

    // MARK: - Storage

    private indirect enum Node {
        case folder(String, loose: Double, days: Double, [Node])
        case file(String, Double, days: Double)

        var name: String {
            switch self {
            case .folder(let n, _, _, _), .file(let n, _, _): return n
            }
        }
    }

    private static func dir(_ name: String, _ loose: Double, _ kids: [Node] = [], days: Double = 20) -> Node {
        .folder(name, loose: loose, days: days, kids)
    }

    private static func file(_ name: String, _ size: Double, days: Double) -> Node { .file(name, size, days: days) }

    private static var homeTree: Node {
        dir((home as NSString).lastPathComponent, 0.9, [
            dir("Library", 2.1, [
                dir("Application Support", 1.3, [
                    dir("MobileSync", 0, [dir("Backup", 0, [dir("00008110-001A2D3C4E5F6789", 21.4, days: 218)])]),
                    dir("Cadence Studio", 0.4, [dir("Bibliothèques de sons", 11.6), dir("Presets", 0.8)]),
                    dir("Claude", 0.6, [dir("vm_bundles", 7.9), dir("claude-code", 0.9)]),
                    dir("Pixelune", 6.2), dir("Monteur", 3.1), dir("Hélios Code", 1.4), dir("Ruche", 0.9), dir("Nuage Drive", 0.6)
                ]),
                dir("Developer", 0.2, [
                    dir("CoreSimulator", 0.3, [dir("Devices", 14.2), dir("Caches", 1.21)]),
                    dir("Xcode", 0.4, [dir("iOS DeviceSupport", 6.08), dir("DerivedData", 3.53), dir("Archives", 0.8),
                                       dir("UserData", 0.9)])
                ]),
                dir("Containers", 0.8, [dir("com.apple.mail", 4.6), dir("com.pixelune.Pixelune", 3.1), dir("com.apple.Notes", 0.7)]),
                dir("Caches", 1.1, [dir("com.monteur.studio", 1.24), dir("Homebrew", 0.94), dir("com.pixelune.Pixelune", 0.86),
                                    dir("fr.sonar.podcasts", 0.53), dir("pip", 0.41), dir("Yarn", 0.27)]),
                dir("Group Containers", 3.6), dir("Messages", 2.8), dir("Mail", 3.4), dir("Logs", 0.36)
            ]),
            dir("Pictures", 0.3, [
                dir("Bibliothèque Photos.photoslibrary", 68.4, days: 1),
                dir("Exports Pixelune", 0.4, [file("Panorama Dolomites.tif", 0.912, days: 160), file("Affiche expo.psd", 0.61, days: 48)]),
                dir("Captures d'écran", 1.1, days: 2)
            ]),
            dir("Movies", 0.4, [
                dir("Vacances Crète 2025", 0.6, [
                    dir("Rushes", 1.2, [file("DJI_0142.MP4", 4.8, days: 420), file("DJI_0157.MP4", 3.9, days: 420),
                                        file("DJI_0163.MP4", 2.6, days: 419)]),
                    dir("Exports", 0.3, [file("Crète — montage final.mov", 2.9, days: 395)])
                ], days: 395),
                dir("Montages", 0.8, [file("Court-métrage v3.mov", 3.4, days: 75), dir("Projet Atelier Lune", 9.6, days: 1)]),
                dir("Mariage Léa & Hugo", 0.5, [file("Film complet.mp4", 5.2, days: 520), dir("Rushes", 14.1, days: 530)], days: 520)
            ]),
            dir("Developer", 0.6, [
                dir("boussole-ios", 0.8, [dir(".build", 2.1), dir("Pods", 1.3)], days: 1),
                dir("jeux-retro", 1.2, [file("roms-backup.zip", 2.7, days: 300), dir("node_modules", 0.86)], days: 95),
                dir("potager-api", 0.4, [dir("target", 3.2)], days: 64),
                dir("site-atelier", 0.6, [dir("node_modules", 1.9)], days: 3),
                dir("notes-app", 0.9, days: 12), dir("dotfiles", 0.01, days: 30)
            ]),
            dir("Documents", 0.8, [
                dir("Projets clients", 1.2, [dir("Atelier Lune", 0.9, [file("Export final 4K.mov", 6.1, days: 34)]),
                                             dir("Boulangerie Martin", 2.3, days: 90)]),
                dir("Machines virtuelles", 0, [file("Linux de test.qcow2", 12.4, days: 180)]),
                dir("Cours de piano", 4.8, [file("Masterclass.m4v", 1.6, days: 260)]),
                dir("Administratif", 1.4), dir("Factures", 0.6)
            ]),
            dir("Downloads", 1.8, [
                dir("Vidéos à trier", 1.0, [file("Conférence enregistrée.mp4", 2.2, days: 152), file("Atelier poterie.mov", 1.7, days: 160),
                                           file("Tuto aquarelle.mp4", 0.84, days: 170)], days: 152),
                file("Ubuntu-24.04.2-desktop-arm64.iso", 3.2, days: 205), file("Archives 2023.zip", 2.4, days: 610),
                file("Cadence-Studio-11.pkg", 1.9, days: 64), file("Monteur-Installer-5.2.dmg", 1.38, days: 33),
                file("Pixelune-3.8.dmg", 0.412, days: 12)
            ]),
            dir("Music", 0.2, [dir("Cadence Studio", 2.1, [dir("Sessions", 3.4, [file("Album 2024 — bounce.wav", 1.1, days: 290)])]),
                               dir("Musique", 5.8, days: 60)]),
            dir("Desktop", 1.2, [file("Sauvegarde téléphone.zip", 1.9, days: 230), dir("Tri", 0.6, days: 5)], days: 1),
            dir(".Trash", 0, [file("Ancien montage.mov", 1.62, days: 9), file("Pixelune-3.7.dmg", 0.398, days: 12),
                              dir("Photos à trier", 0.312, days: 9)]),
            dir(".npm", 1.7), dir(".cache", 2.1), dir(".cargo", 0.9), dir("Applications", 1.2, days: 60)
        ], days: 0)
    }

    /// The tree of the whole fictional disk, cut at the folder asked for (the home folder if it does not exist there).
    static func storage(_ path: String) -> StorageScanResult {
        var rng = SeededRNG(state: seed)
        var big: [BigFile] = []
        let apps = catalog.filter { $0.installed && $0.folder == "/Applications" }.map { dir($0.name + ".app", $0.size, days: 30) }
        let disk = dir("Macintosh HD", 0.3, [
            dir("Users", 0, [homeTree]), dir("Applications", 0, apps),
            dir("Library", 21.6), dir("System", 17.8), dir("private", 9.2), dir("opt", 4.2), dir("usr", 1.1)
        ])
        let full = build(disk, path: "/", rng: &rng, big: &big)
        guard let root = find(path, in: full) ?? find(home, in: full) else { fatalError("the demo disk has no home folder") }
        root.parent = nil
        root.finalize()
        let prefix = root.path == "/" ? "/" : root.path + "/"
        // Like the real scanner, what is already in the Trash is not a big file to clear.
        return StorageScanResult(root: root, bigFiles: big.filter { $0.path.hasPrefix(prefix) && !$0.path.hasPrefix(home + "/.Trash/") }
                                    .sorted { $0.size > $1.size },
                                 unreadable: 0, scannedFiles: max(1, root.files))
    }

    private static func build(_ spec: Node, path: String, rng: inout SeededRNG, big: inout [BigFile]) -> StorageNode {
        switch spec {
        case .file(let name, let size, let days):
            let n = StorageNode(name: name, path: path, isDirectory: false)
            n.size = gb(size)
            n.files = 1
            n.modified = ago(days)
            big.append(BigFile(path: path, size: n.size, modified: ago(days), accessed: ago(days * rng.double(0.2...1))))
            return n
        case .folder(let name, let loose, let days, let kids):
            let n = StorageNode(name: name, path: path, isDirectory: true)
            n.looseBytes = gb(loose)
            n.files = Int(loose * rng.double(300...2400))
            n.modified = ago(days)
            for k in kids {
                let child = build(k, path: (path == "/" ? "" : path) + "/" + k.name, rng: &rng, big: &big)
                child.parent = n
                n.children.append(child)
                if !child.isDirectory { n.files += 1 }
            }
            return n
        }
    }

    private static func find(_ path: String, in node: StorageNode) -> StorageNode? {
        if node.path == path { return node }
        for c in node.children where c.isDirectory && path.hasPrefix(c.path + "/") || c.path == path {
            if let hit = find(path, in: c) { return hit }
        }
        return nil
    }

    // MARK: - Duplicates

    private static let duplicateSpecs: [(size: Double, copies: [(String, Double)])] = [
        (3.4, [("Movies/Montages/Court-métrage v3.mov", 75), ("Desktop/Tri/Court-métrage v3 (copie).mov", 41)]),
        (1.1, [("Music/Cadence Studio/Sessions/Album 2024 — bounce.wav", 290), ("Downloads/Album 2024 — bounce.wav", 288)]),
        (0.412, [("Downloads/Pixelune-3.8.dmg", 12), ("Downloads/Pixelune-3.8 (1).dmg", 12)]),
        (0.086, [("Documents/Projets clients/Atelier Lune/Présentation client.key", 40),
                 ("Desktop/Présentation client.key", 38)]),
        (0.0042, [("Pictures/Exports Pixelune/IMG_4821.HEIC", 160), ("Downloads/IMG_4821.HEIC", 158), ("Desktop/Tri/IMG_4821.HEIC", 20)]),
        (0.0021, [("Documents/Administratif/Contrat de location.pdf", 700), ("Downloads/Contrat de location.pdf", 699)]),
        (0.0013, [("Documents/Factures/Facture-2026-031.pdf", 110), ("Downloads/Facture-2026-031.pdf", 111)])
    ]

    static func duplicates() -> [DuplicateGroup] {
        var rng = SeededRNG(state: seed &+ 1)
        return duplicateSpecs.map { d in
            DuplicateGroup(id: String(rng.next(), radix: 16), size: gb(d.size), paths: d.copies.map { home + "/" + $0.0 })
        }
    }

    private static let dates: [String: Date] = Dictionary(
        duplicateSpecs.flatMap { $0.copies.map { (home + "/" + $0.0, ago($0.1)) } }, uniquingKeysWith: { a, _ in a })

    /// Stands in for the file system's modification date.
    static func modified(_ path: String) -> Date? { dates[path] }

    // MARK: - Filling the app

    /// Puts the app in the state of a smart scan that ended a few minutes ago.
    @MainActor
    static func populate(_ app: AppModel) {
        app.fullDiskAccess = true
        app.showOnboarding = false
        app.history = history
        app.smartScanDate = lastScan

        app.cleanup.apply(cleanupTargets())
        app.cleanup.claude = claudeFootprint
        app.cleanup.lastScan = lastScan
        app.cleanup.expanded = ["appCaches"]

        let p = app.protection
        p.checks = securityChecks()
        p.pending = pendingUpdates()
        p.grants = grants()
        p.traces = traces()
        p.traceSelection = Set(p.traces.filter(\.defaultOn).map(\.id))
        p.lastAudit = lastScan

        app.startup.items = launchItems()
        app.startup.lastScan = lastScan

        app.apps.apps = apps()
        app.apps.lastScan = lastScan
        app.apps.orphans = orphans()
        app.apps.orphansScanned = true

        app.performance.processes = processes()
        app.performance.snapshotCount = 2

        let s = app.storage
        let r = storage(home)
        s.rootPath = home
        s.root = r.root
        s.current = r.root
        s.bigFiles = r.bigFiles
        s.lastScan = lastScan
        s.dupGroups = duplicates()
        s.dupsScanned = true
        s.autoSelectDuplicates()
    }
}

/// SplitMix64: small, fast, and the same numbers on every Mac.
struct SeededRNG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func double(_ r: ClosedRange<Double>) -> Double { r.lowerBound + unit() * (r.upperBound - r.lowerBound) }
}
