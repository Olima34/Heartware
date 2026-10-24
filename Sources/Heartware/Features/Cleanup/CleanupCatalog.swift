import Foundation

enum CleanupGroup: String, CaseIterable, Identifiable {
    case system, developer, claude, browsers, apps, trash, personal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Système"
        case .developer: return "Développement"
        case .claude: return "Claude"
        case .browsers: return "Navigateurs"
        case .apps: return "Caches d'apps"
        case .trash: return "Corbeille"
        case .personal: return "Fichiers personnels"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "gearshape.2"
        case .developer: return "hammer"
        case .claude: return "sparkle"
        case .browsers: return "globe"
        case .apps: return "square.stack.3d.up"
        case .trash: return "trash"
        case .personal: return "person.crop.square"
        }
    }

    var blurb: String {
        switch self {
        case .system: return "Caches et journaux que macOS et tes apps recréent tout seuls."
        case .developer: return "Xcode, simulateurs, npm, Homebrew, pip… et les dépendances de projets endormis."
        case .claude: return "Les caches de l'app Claude et les journaux de Claude Code. Tes conversations ne sont jamais touchées."
        case .browsers: return "Caches web de Safari, Chrome, Firefox, Edge, Brave, Arc… Historique et cookies restent intacts."
        case .apps: return "Caches des apps construites sur Electron ou Chromium (Slack, Discord, VS Code, Teams…)."
        case .trash: return "Ce que tu as déjà jeté, mais qui occupe toujours de la place."
        case .personal: return "Tes fichiers à toi : rien n'est coché d'office et tout part dans la Corbeille."
        }
    }

    var tint: Int {
        switch self {
        case .system: return 0
        case .developer: return 6
        case .claude: return 3
        case .browsers: return 1
        case .apps: return 4
        case .trash: return 8
        case .personal: return 5
        }
    }
}

struct CleanupItem: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    var detail: String?
    let size: Int64
    var modified: Date?
    var defaultOn: Bool = true
    var blockedReason: String?
}

struct CleanupTarget: Identifiable {
    let id: String
    let group: CleanupGroup
    let title: String
    let explanation: String
    let symbol: String
    let mode: RemovalMode
    let defaultOn: Bool
    var items: [CleanupItem] = []
    var needsFullDiskAccess = false

    var size: Int64 { items.reduce(0) { $0 + $1.size } }
    var cleanable: [CleanupItem] { items.filter { $0.blockedReason == nil } }
}

/// A file or folder that a target may clean, before sizing.
struct Candidate {
    var path: String
    var name: String
    var detail: String? = nil
    var defaultOn = true
    /// Bundle identifier of an app that must be closed first.
    var requiresClosed: String? = nil
    /// Name of a support folder whose app must be closed (Electron apps).
    var requiresClosedFolder: String? = nil
}

struct TargetSpec {
    var id: String
    var group: CleanupGroup
    var title: String
    var explanation: String
    var symbol: String
    var mode: RemovalMode = .delete
    var defaultOn = true
    /// Folder that must be readable, otherwise Full Disk Access is missing.
    var accessProbe: String? = nil
    var collect: () -> [Candidate]
}

/// Everything the cleaner knows how to find. Each rule is deliberately narrow.
enum CleanupCatalog {
    static let home = FS.home
    static var caches: String { home + "/Library/Caches" }
    static var support: String { home + "/Library/Application Support" }

    /// Folders of ~/Library/Caches handled by a more specific rule.
    static let claimedCaches: Set<String> = [
        "Homebrew", "pip", "pypoetry", "Yarn", "pnpm", "CocoaPods", "go-build", "org.swift.swiftpm", "bun", "deno",
        "node-gyp", "ms-playwright", "electron", "electron-builder", "typescript", "JetBrains", "Cypress", "composer",
        "com.apple.Safari", "Google", "Firefox", "Microsoft Edge", "BraveSoftware", "Arc", "com.operasoftware.Opera",
        "Vivaldi", "com.anthropic.claudefordesktop", "com.anthropic.claudefordesktop.ShipIt", "claude-cli-nodejs",
        AppEdition.regularID, AppEdition.labID
    ]

    /// Caches that hold state macOS or iCloud rely on: never offered.
    static let neverTouch: Set<String> = [
        "CloudKit", "FamilyCircle", "familycircled", "PassKit", "com.apple.bird", "com.apple.cloudd", "com.apple.nsurlsessiond",
        "com.apple.containermanagerd", "com.apple.HomeKit", "com.apple.homed", "com.apple.akd", "com.apple.passd",
        "com.apple.findmy.fmipcore", "com.apple.icloud.fmfd", "com.apple.CloudPhotosConfiguration",
        "com.apple.photoanalysisd", "com.apple.mediaanalysisd", "com.apple.ap.adprivacyd", "com.apple.iCloudHelper",
        "com.apple.amsaccountsd", "com.apple.accountsd", "com.apple.Safari.SafeBrowsing"
    ]

    /// Apple folders in ~/Library/Caches that do not start with "com.apple.".
    static let appleCacheNames: Set<String> = [
        "GameKit", "GeoServices", "SiriTTS", "Animoji", "PHTPhenotype", "EnergyKit", "askpermissiond",
        "AMSDataMigratorTool", "JetPackCache", "INSTALLATION", "GIPPseudonymousID", "storeassetd", "Metal",
        "icloudmailagent", "ssu", "installer_telemetry"
    ]

    /// Chromium cache folder names, inside an app or browser profile folder.
    static let chromiumCacheNames = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GraphiteDawnCache",
        "GPUPersistentCache", "ShaderCache", "GrShaderCache", "CachedData", "CachedExtensionVSIXs",
        "Service Worker/CacheStorage", "Service Worker/ScriptCache"
    ]

    static func specs() -> [TargetSpec] {
        [
            // MARK: Système
            TargetSpec(id: "appCaches", group: .system, title: "Caches des applications",
                       explanation: "Fichiers temporaires que chaque app régénère à la demande.",
                       symbol: "internaldrive") {
                FS.children(caches).compactMap { name in
                    guard !name.hasPrefix("com.apple."), !appleCacheNames.contains(name), !neverTouch.contains(name),
                          !claimedCaches.contains(name) else { return nil }
                    return Candidate(path: caches + "/" + name, name: AppNames.name(for: name) ?? name,
                                     detail: AppNames.name(for: name) != nil ? name : nil)
                }
            },
            TargetSpec(id: "appleCaches", group: .system, title: "Caches de macOS",
                       explanation: "Caches des services Apple. Sans danger, mais macOS les reconstruira (un peu de calcul au début).",
                       symbol: "apple.logo", defaultOn: false) {
                FS.children(caches).compactMap { name in
                    guard name.hasPrefix("com.apple.") || appleCacheNames.contains(name),
                          !neverTouch.contains(name), !claimedCaches.contains(name) else { return nil }
                    return Candidate(path: caches + "/" + name, name: name, defaultOn: false)
                }
            },
            TargetSpec(id: "logs", group: .system, title: "Journaux et rapports de plantage",
                       explanation: "Les journaux des apps et les rapports de diagnostic déjà envoyés.",
                       symbol: "doc.text.magnifyingglass") {
                let logs = home + "/Library/Logs"
                return FS.children(logs).filter { $0 != "Heartware" }.map {
                    Candidate(path: logs + "/" + $0, name: $0 == "DiagnosticReports" ? "Rapports de diagnostic" : $0)
                }
            },
            TargetSpec(id: "temp", group: .system, title: "Fichiers temporaires anciens",
                       explanation: "Restes de plus de 3 jours dans ton dossier temporaire.",
                       symbol: "clock.arrow.circlepath", defaultOn: false) {
                guard let tmp = FS.userTempDir else { return [] }
                let limit = Date().addingTimeInterval(-3 * 86400)
                return FS.children(tmp, hidden: false).compactMap { name in
                    let p = (tmp as NSString).appendingPathComponent(name)
                    guard let m = FS.modified(p), m < limit else { return nil }
                    return Candidate(path: p, name: name, defaultOn: false)
                }
            },
            TargetSpec(id: "savedState", group: .system, title: "États enregistrés des fenêtres",
                       explanation: "Ce qui permet aux apps de rouvrir leurs fenêtres à l'identique.",
                       symbol: "macwindow.on.rectangle", defaultOn: false) {
                let dir = home + "/Library/Saved Application State"
                return FS.children(dir).map { name in
                    let id = name.replacingOccurrences(of: ".savedState", with: "")
                    return Candidate(path: dir + "/" + name, name: AppNames.name(for: id) ?? id, defaultOn: false)
                }
            },

            // MARK: Développement
            TargetSpec(id: "derivedData", group: .developer, title: "Xcode · Données dérivées",
                       explanation: "Index et produits de compilation. Xcode les reconstruit au prochain build.",
                       symbol: "hammer") {
                let dir = home + "/Library/Developer/Xcode/DerivedData"
                return FS.children(dir).map { name in
                    let project = name.split(separator: "-").dropLast().joined(separator: "-")
                    return Candidate(path: dir + "/" + name, name: project.isEmpty ? name : project,
                                     requiresClosed: nil)
                }
            },
            TargetSpec(id: "deviceSupport", group: .developer, title: "Xcode · Prise en charge des appareils",
                       explanation: "Symboles copiés depuis chaque iPhone, iPad ou Watch branché un jour.",
                       symbol: "iphone") {
                ["iOS", "watchOS", "tvOS", "visionOS", "macOS"].flatMap { os -> [Candidate] in
                    let dir = home + "/Library/Developer/Xcode/\(os) DeviceSupport"
                    let names = FS.children(dir)
                    // The most recent one is probably the device in your pocket: unchecked by default.
                    let newest = names.max { (FS.modified(dir + "/" + $0) ?? .distantPast) < (FS.modified(dir + "/" + $1) ?? .distantPast) }
                    return names.map { name in
                        Candidate(path: dir + "/" + name, name: name,
                                  detail: name == newest ? "\(os) · le plus récent, gardé par défaut" : os,
                                  defaultOn: name != newest)
                    }
                }
            },
            TargetSpec(id: "simulators", group: .developer, title: "Simulateurs et aperçus",
                       explanation: "Caches des simulateurs et des aperçus SwiftUI.",
                       symbol: "ipad.and.iphone") {
                var out: [Candidate] = []
                let simCaches = home + "/Library/Developer/CoreSimulator/Caches"
                out += FS.children(simCaches).map { Candidate(path: simCaches + "/" + $0, name: $0, detail: "Simulateurs") }
                let previews = home + "/Library/Developer/Xcode/UserData/Previews"
                if FS.exists(previews) { out.append(Candidate(path: previews, name: "Aperçus SwiftUI")) }
                return out
            },
            TargetSpec(id: "archives", group: .developer, title: "Xcode · Archives",
                       explanation: "Builds archivés. Garde ceux des versions publiées si tu dois symboliser des plantages.",
                       symbol: "archivebox", mode: .trash, defaultOn: false) {
                let dir = home + "/Library/Developer/Xcode/Archives"
                return FS.children(dir).flatMap { day -> [Candidate] in
                    FS.children(dir + "/" + day).map {
                        Candidate(path: dir + "/" + day + "/" + $0, name: $0.replacingOccurrences(of: ".xcarchive", with: ""),
                                  detail: day, defaultOn: false)
                    }
                }
            },
            TargetSpec(id: "packageCaches", group: .developer, title: "Caches des gestionnaires de paquets",
                       explanation: "npm, Yarn, pip, Homebrew, CocoaPods, Go, Cargo… Ils retéléchargent ce qui manque.",
                       symbol: "shippingbox") {
                let list: [(String, String, Bool)] = [
                    ("npm", "~/.npm/_cacache", true), ("Yarn", "~/Library/Caches/Yarn", true),
                    ("pnpm", "~/Library/Caches/pnpm", true), ("pip", "~/Library/Caches/pip", true),
                    ("Poetry", "~/Library/Caches/pypoetry", true), ("uv", "~/.cache/uv", true),
                    ("Homebrew", "~/Library/Caches/Homebrew", true), ("CocoaPods", "~/Library/Caches/CocoaPods", true),
                    ("Swift Package Manager", "~/Library/Caches/org.swift.swiftpm", true),
                    ("Go", "~/Library/Caches/go-build", true), ("Bun", "~/.bun/install/cache", true),
                    ("Bun", "~/Library/Caches/bun", true), ("Deno", "~/Library/Caches/deno", true),
                    ("Cargo", "~/.cargo/registry/cache", true), ("node-gyp", "~/Library/Caches/node-gyp", true),
                    ("TypeScript", "~/Library/Caches/typescript", true), ("Electron", "~/Library/Caches/electron", true),
                    ("electron-builder", "~/Library/Caches/electron-builder", true),
                    ("Composer", "~/Library/Caches/composer", true),
                    ("Playwright (navigateurs de test)", "~/Library/Caches/ms-playwright", false),
                    ("Cypress", "~/Library/Caches/Cypress", false), ("Gradle", "~/.gradle/caches", false),
                    ("Maven", "~/.m2/repository", false), ("JetBrains", "~/Library/Caches/JetBrains", false)
                ]
                return list.compactMap { name, raw, on in
                    let p = FS.expand(raw)
                    return FS.exists(p) ? Candidate(path: p, name: name, detail: FS.pretty(p), defaultOn: on) : nil
                }
            },
            TargetSpec(id: "staleDeps", group: .developer, title: "Dépendances de projets endormis",
                       explanation: "node_modules, .build, Pods et target de projets non modifiés depuis 30 jours. Un « npm install » les recrée.",
                       symbol: "moon.zzz", defaultOn: false) {
                StaleDependencies.find(olderThan: 30)
            },

            // MARK: Claude
            TargetSpec(id: "claudeApp", group: .claude, title: "App Claude · caches",
                       explanation: "Caches web et graphiques de l'app de bureau, et téléchargements de mises à jour.",
                       symbol: "sparkle") {
                let dir = support + "/Claude"
                var out = chromiumCacheNames.compactMap { name -> Candidate? in
                    let p = dir + "/" + name
                    return FS.exists(p) ? Candidate(path: p, name: name, requiresClosed: "com.anthropic.claudefordesktop") : nil
                }
                for name in ["com.anthropic.claudefordesktop", "com.anthropic.claudefordesktop.ShipIt"] {
                    let p = caches + "/" + name
                    if FS.exists(p) {
                        out.append(Candidate(path: p, name: name.hasSuffix("ShipIt") ? "Mises à jour téléchargées" : "Cache système",
                                             detail: FS.pretty(p)))
                    }
                }
                return out
            },
            TargetSpec(id: "claudeCode", group: .claude, title: "Claude Code · journaux",
                       explanation: "Journaux des serveurs MCP, traces de débogage et instantanés de shell de plus de 7 jours.",
                       symbol: "terminal") {
                var out: [Candidate] = []
                let cli = caches + "/claude-cli-nodejs"
                out += FS.children(cli).map { Candidate(path: cli + "/" + $0, name: "Journaux MCP", detail: $0) }
                let debug = home + "/.claude/debug"
                out += FS.children(debug).map { Candidate(path: debug + "/" + $0, name: "Débogage", detail: $0) }
                let snaps = home + "/.claude/shell-snapshots"
                let limit = Date().addingTimeInterval(-7 * 86400)
                out += FS.children(snaps).compactMap { name in
                    let p = snaps + "/" + name
                    guard let m = FS.modified(p), m < limit else { return nil }
                    return Candidate(path: p, name: "Instantané de shell", detail: name)
                }
                return out
            },
            TargetSpec(id: "claudeHistory", group: .claude, title: "Claude Code · points de restauration anciens",
                       explanation: "Copies de fichiers gardées pour « rembobiner » les sessions de plus de 30 jours.",
                       symbol: "clock.arrow.circlepath", defaultOn: false) {
                let dir = home + "/.claude/file-history"
                let limit = Date().addingTimeInterval(-30 * 86400)
                return FS.children(dir).compactMap { name in
                    let p = dir + "/" + name
                    guard let m = FS.modified(p), m < limit else { return nil }
                    return Candidate(path: p, name: "Session \(name.prefix(8))", detail: FS.modified(p).map(Fmt.day), defaultOn: false)
                }
            },

            // MARK: Navigateurs
            TargetSpec(id: "browserCaches", group: .browsers, title: "Caches web",
                       explanation: "Pages et images gardées en mémoire. Le navigateur doit être fermé.",
                       symbol: "globe") {
                browserCandidates()
            },

            // MARK: Caches d'apps
            TargetSpec(id: "electronCaches", group: .apps, title: "Caches Electron et Chromium",
                       explanation: "Chaque app web empaquetée garde son propre cache de navigateur. L'app doit être fermée.",
                       symbol: "square.stack.3d.up") {
                electronCandidates()
            },

            // MARK: Corbeille
            TargetSpec(id: "trash", group: .trash, title: "Éléments de la Corbeille",
                       explanation: "Les vider est définitif : vérifie qu'il n'y a rien à repêcher.",
                       symbol: "trash", accessProbe: home + "/.Trash") {
                let dir = home + "/.Trash"
                return FS.children(dir, hidden: true).filter { $0 != ".DS_Store" && $0 != ".localized" }.map {
                    Candidate(path: dir + "/" + $0, name: $0)
                }
            },

            // MARK: Fichiers personnels
            TargetSpec(id: "mailDownloads", group: .personal, title: "Pièces jointes ouvertes dans Mail",
                       explanation: "Copies des pièces jointes que tu as ouvertes. Les originaux restent dans tes e-mails.",
                       symbol: "paperclip", mode: .trash, defaultOn: false,
                       accessProbe: home + "/Library/Containers/com.apple.mail") {
                let dir = home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
                return FS.children(dir).map { Candidate(path: dir + "/" + $0, name: $0, defaultOn: false) }
            },
            TargetSpec(id: "installers", group: .personal, title: "Installeurs téléchargés",
                       explanation: "Images disque et paquets (.dmg, .pkg, .iso) qui restent dans Téléchargements après l'installation.",
                       symbol: "shippingbox.and.arrow.backward", mode: .trash, defaultOn: false) {
                let dir = home + "/Downloads"
                let exts: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
                return FS.children(dir).compactMap { name in
                    guard exts.contains((name as NSString).pathExtension.lowercased()) else { return nil }
                    let p = dir + "/" + name
                    return Candidate(path: p, name: name, detail: FS.modified(p).map { "Téléchargé le \(Fmt.day($0))" }, defaultOn: false)
                }
            },
            TargetSpec(id: "oldDownloads", group: .personal, title: "Téléchargements oubliés",
                       explanation: "Éléments de Téléchargements que tu n'as pas modifiés depuis plus de 90 jours.",
                       symbol: "arrow.down.circle", mode: .trash, defaultOn: false) {
                let dir = home + "/Downloads"
                let limit = Date().addingTimeInterval(-90 * 86400)
                let exts: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
                return FS.children(dir).compactMap { name in
                    guard !exts.contains((name as NSString).pathExtension.lowercased()) else { return nil }
                    let p = dir + "/" + name
                    guard let m = FS.modified(p), m < limit else { return nil }
                    return Candidate(path: p, name: name, detail: "Modifié \(Fmt.relative(m))", defaultOn: false)
                }
            },
            TargetSpec(id: "iosBackups", group: .personal, title: "Sauvegardes d'iPhone et d'iPad",
                       explanation: "Sauvegardes locales faites par le Finder. Vérifie qu'elles ne sont plus utiles avant de les jeter.",
                       symbol: "iphone.gen3", mode: .trash, defaultOn: false,
                       accessProbe: support + "/MobileSync") {
                let dir = support + "/MobileSync/Backup"
                return FS.children(dir).map { id in
                    let info = NSDictionary(contentsOfFile: dir + "/" + id + "/Info.plist")
                    let device = info?["Device Name"] as? String ?? id
                    let date = (info?["Last Backup Date"] as? Date).map { "Sauvegarde du \(Fmt.day($0))" }
                    return Candidate(path: dir + "/" + id, name: device, detail: date, defaultOn: false)
                }
            },
            TargetSpec(id: "macInstallers", group: .personal, title: "Installeurs de macOS",
                       explanation: "Les apps « Installer macOS » restent après la mise à jour et pèsent plus de 12 Go.",
                       symbol: "apple.logo", mode: .trash, defaultOn: false) {
                FS.children("/Applications").compactMap { name in
                    guard name.hasPrefix("Install macOS"), name.hasSuffix(".app") else { return nil }
                    return Candidate(path: "/Applications/" + name, name: name.replacingOccurrences(of: ".app", with: ""), defaultOn: false)
                }
            }
        ]
    }

    // MARK: Browsers

    static func browserCandidates() -> [Candidate] {
        var out: [Candidate] = []
        let simple: [(String, String, String)] = [
            ("Safari", "com.apple.Safari", "com.apple.Safari"),
            ("Chrome", "Google/Chrome", "com.google.Chrome"),
            ("Firefox", "Firefox", "org.mozilla.firefox"),
            ("Edge", "Microsoft Edge", "com.microsoft.edgemac"),
            ("Brave", "BraveSoftware", "com.brave.Browser"),
            ("Arc", "Arc", "company.thebrowser.Browser"),
            ("Opera", "com.operasoftware.Opera", "com.operasoftware.Opera"),
            ("Vivaldi", "Vivaldi", "com.vivaldi.Vivaldi")
        ]
        for (name, folder, id) in simple {
            let p = caches + "/" + folder
            if FS.exists(p) { out.append(Candidate(path: p, name: name, detail: "Cache disque", requiresClosed: id)) }
        }
        // Chromium profiles keep more caches next to the user data.
        let profiles: [(String, String, String)] = [
            ("Chrome", "Google/Chrome", "com.google.Chrome"),
            ("Edge", "Microsoft Edge", "com.microsoft.edgemac"),
            ("Brave", "BraveSoftware/Brave-Browser", "com.brave.Browser"),
            ("Arc", "Arc/User Data", "company.thebrowser.Browser"),
            ("Vivaldi", "Vivaldi", "com.vivaldi.Vivaldi")
        ]
        for (name, folder, id) in profiles {
            let root = support + "/" + folder
            guard FS.exists(root) else { continue }
            for shared in ["GrShaderCache", "ShaderCache", "GraphiteDawnCache"] where FS.exists(root + "/" + shared) {
                out.append(Candidate(path: root + "/" + shared, name: name, detail: shared, requiresClosed: id))
            }
            for profile in FS.children(root) where profile == "Default" || profile.hasPrefix("Profile ") {
                for cache in ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
                              "Service Worker/CacheStorage", "Service Worker/ScriptCache"] {
                    let p = root + "/" + profile + "/" + cache
                    if FS.exists(p) {
                        out.append(Candidate(path: p, name: name, detail: "\(profile) · \(cache)", requiresClosed: id))
                    }
                }
            }
        }
        return out
    }

    // MARK: Electron apps

    static func electronCandidates() -> [Candidate] {
        let skip: Set<String> = ["Claude", "Google", "BraveSoftware", "Microsoft Edge", "Vivaldi", "Arc", "Firefox",
                                 "com.operasoftware.Opera", "MobileSync", "AddressBook", "CallHistoryDB", "Knowledge"]
        var out: [Candidate] = []
        for app in FS.children(support) where !skip.contains(app) && !app.hasPrefix("com.apple.") {
            let root = support + "/" + app
            for cache in chromiumCacheNames {
                let p = root + "/" + cache
                if FS.isDirectory(p) {
                    out.append(Candidate(path: p, name: app, detail: cache, requiresClosedFolder: app))
                }
            }
            // Some apps (Teams, Slack) keep one Chromium partition per account.
            let partitions = root + "/Partitions"
            for part in FS.children(partitions) {
                for cache in ["Cache", "Code Cache", "GPUCache", "Service Worker/CacheStorage"] {
                    let p = partitions + "/" + part + "/" + cache
                    if FS.isDirectory(p) {
                        out.append(Candidate(path: p, name: app, detail: "\(part) · \(cache)", requiresClosedFolder: app))
                    }
                }
            }
        }
        return out
    }
}

/// Finds heavy, rebuildable dependency folders in projects nobody touched lately.
enum StaleDependencies {
    static let roots = ["Developer", "Projects", "Code", "code", "dev", "src", "GitHub", "Sites", "workspace", "repos", "Dev"]

    static func find(olderThan days: Int) -> [Candidate] {
        let limit = Date().addingTimeInterval(-Double(days) * 86400)
        var out: [Candidate] = []
        var seen = Set<String>()
        // Names as they really are on disk: on a case-insensitive volume "code" would find "Code" a second time.
        let present = Set(FS.children(FS.home))
        for r in roots where present.contains(r) {
            let root = FS.home + "/" + r
            guard FS.isDirectory(root), !FS.isSymlink(root) else { continue }
            let real = (root as NSString).resolvingSymlinksInPath
            guard seen.insert(real).inserted else { continue }
            visit(root, depth: 0, limit: limit, out: &out)
        }
        return out
    }

    private static func visit(_ dir: String, depth: Int, limit: Date, out: inout [Candidate]) {
        guard depth <= 5 else { return }
        let names = FS.children(dir, hidden: true)
        let set = Set(names)
        // Which dependency folders this project has, with the file proving what it is.
        let deps: [(folder: String, marker: String, label: String)] = [
            ("node_modules", "package.json", "node_modules"),
            (".build", "Package.swift", "SwiftPM .build"),
            ("Pods", "Podfile", "CocoaPods"),
            ("target", "Cargo.toml", "Cargo target")
        ]
        var handled = Set<String>()
        for d in deps where set.contains(d.folder) && set.contains(d.marker) {
            handled.insert(d.folder)
            let p = dir + "/" + d.folder
            guard !FS.isSymlink(p) else { continue }
            if projectAge(dir, names: names) < limit {
                out.append(Candidate(path: p, name: (dir as NSString).lastPathComponent, detail: "\(d.label) · \(FS.pretty(dir))",
                                     defaultOn: false))
            }
        }
        for name in names where !name.hasPrefix(".") && !handled.contains(name) && name != "node_modules" {
            let p = dir + "/" + name
            if FS.isDirectory(p) && !FS.isSymlink(p) && !name.hasSuffix(".app") && !name.hasSuffix(".xcodeproj") {
                visit(p, depth: depth + 1, limit: limit, out: &out)
            }
        }
    }

    /// Latest modification among the project's own top-level files (dependency folders excluded).
    private static func projectAge(_ dir: String, names: [String]) -> Date {
        let ignored: Set<String> = ["node_modules", ".build", "Pods", "target", ".DS_Store"]
        var latest = Date.distantPast
        for n in names where !ignored.contains(n) {
            if let m = FS.modified(dir + "/" + n), m > latest { latest = m }
        }
        return latest
    }
}
