import SwiftUI
import AppKit
import Carbon.HIToolbox

/// What the panel shows: the search, the translator, or the capture of a shortcut for a result.
enum LauncherMode: Equatable {
    case search
    case translator
    case assign(target: HotkeysTarget, title: String)
    /// "Coup d'œil": the whole panel shows the file, like the space bar in the Finder.
    case quickLook(path: String)
}

/// Which window the model drives: the launcher itself, or the file search in its own window.
enum LauncherScope: Equatable {
    case all
    case files
}

/// One block of the results list.
struct LauncherSection: Identifiable {
    let id: String
    let title: String
    let items: [AppCommand]
}

@Observable
@MainActor
final class LauncherModel: AppModule {
    static let hotKeyID = "launcher"
    /// ⌥Espace, like Alfred or Raycast. macOS 27 accepts it; Raccourcis › Heartware lets the user pick another one.
    static let defaultCombo = KeyCombo(keyCode: KeyCombo.space, modifiers: UInt32(optionKey))

    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    /// Keys coming faster than anyone types (a burst, a tool typing for the user): the list is computed once they stop.
    @ObservationIgnored private var lastRefresh: UInt64 = 0
    @ObservationIgnored private var pendingRefresh: DispatchWorkItem?
    var sections: [LauncherSection] = []
    var selection = 0
    /// Set by the arrow keys: only then does the list scroll to the selection (never while the trackpad scrolls it).
    @ObservationIgnored var scrollToSelection = false
    @ObservationIgnored private var lastScroll = Date.distantPast
    @ObservationIgnored private var scrollMonitor: Any?
    var isOpen = false
    /// The launcher (apps, commands, calculations…) or the file search window: each has its own panel.
    var scope: LauncherScope = .all
    /// The file window waits for Spotlight (content searches, index not ready).
    var fileSearchPending = false
    var mode: LauncherMode = .search
    /// What the shortcut capture has to say (a key without modifier, keys already taken…).
    var assignMessage: String?
    var combo: KeyCombo?
    var hotKeyActive = false
    /// Why the last shortcut typed on the page was refused (already used elsewhere in Heartware).
    var comboRefusal: String?
    /// The instant index of file names for the file window (off: Spotlight answers, more slowly).
    var includeFiles = UserDefaults.standard.object(forKey: "launcher.files") as? Bool ?? true {
        didSet {
            guard !DemoData.isEnabled else { return }
            UserDefaults.standard.set(includeFiles, forKey: "launcher.files")
            if includeFiles { startIndexIfAllowed() } else { fileIndex.stop() }
        }
    }
    /// The instant file index: off, being built, or ready with its number of items.
    var indexState: LauncherFileIndex.State = .off
    /// The user asked for the index (without Full Disk Access, reading Documents or Desktop makes macOS ask first).
    var indexConsent = UserDefaults.standard.bool(forKey: "launcher.indexConsent") {
        didSet { if !DemoData.isEnabled { UserDefaults.standard.set(indexConsent, forKey: "launcher.indexConsent") } }
    }
    /// The pane with the preview and the details of the selected file (⇧⌘D).
    var showDetails = UserDefaults.standard.object(forKey: "launcher.details") as? Bool ?? true {
        didSet { if !DemoData.isEnabled { UserDefaults.standard.set(showDetails, forKey: "launcher.details") } }
    }
    /// ⌘K: the result whose actions panel is open, and its actions (read once, when it opens).
    var actionsTarget: LauncherActionTarget?
    var actionsList: [LauncherAction] = []
    @ObservationIgnored var actionsCommand: AppCommand?
    /// Shown first when the search is empty.
    var favoriteItems = LauncherSaved.favorites.value {
        didSet { LauncherSaved.favorites.value = favoriteItems }
    }
    /// Apps and commands taken out of the search.
    var hiddenIDs = LauncherSaved.hidden.value {
        didSet { LauncherSaved.hidden.value = hiddenIDs }
    }
    /// What is typed in the panel's own search field.
    var actionFilter = "" {
        didSet { if actionFilter != oldValue { actionSelection = 0 } }
    }
    var actionSelection = 0
    /// "Ouvrir avec…": the panel lists the apps instead of the actions.
    var openWithApps: [LauncherOpenWithApp]?
    /// The file window: the files and folders picked with ⌘-click or ⌘↩, in that order. They stay picked from one
    /// search to the next (gathered from several folders), until the window closes; dragged together, they are copied.
    var marked: [String] = []
    /// Where each row of the results is, and the visible part of the list (window points): where a dragged file takes off.
    @ObservationIgnored var rowFrames: [Int: CGRect] = [:]
    @ObservationIgnored var listViewport: CGRect = .zero
    /// `--tab glisser`: the pile of dragged files, drawn over the panel.
    @ObservationIgnored var snapshotStack: LauncherDragStack?
    @ObservationIgnored var shareDelegate: NSObject?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private var filesPanel: FloatingPanel?
    /// Files opened lately (Spotlight), shown when the file window opens with nothing typed.
    @ObservationIgnored private var recentFiles: [(path: String, isDir: Bool)] = []
    @ObservationIgnored private var recentQuery: NSMetadataQuery?
    @ObservationIgnored private var recentObserver: NSObjectProtocol?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var catalog: [AppCommand] = [] {
        didSet {
            // Folded again only for what changed since the last opening (a new app, a renamed command).
            var kept: [String: LauncherSearchable.Texts] = [:]
            searchable = catalog.map { c in
                let key = LauncherSearchable.key(c)
                let texts = preparedTexts[key] ?? LauncherSearchable.Texts(c)
                kept[key] = texts
                return LauncherSearchable(command: c, texts: texts)
            }
            preparedTexts = kept
        }
    }
    @ObservationIgnored private var preparedTexts: [String: LauncherSearchable.Texts] = [:]
    /// The catalogue with its texts folded once: a keystroke only compares them to what is typed.
    @ObservationIgnored private var searchable: [LauncherSearchable] = []
    /// Favourite files and folders found missing when the panel opened (looked for off the main thread: a favourite on
    /// a disk that is gone must never hold the keyboard).
    @ObservationIgnored private var missingFavorites: Set<String> = []
    @ObservationIgnored private var apps: [LauncherApp] = []
    @ObservationIgnored private var appsIndexedAt = Date.distantPast
    @ObservationIgnored private var fileResults: [AppCommand] = []
    /// Files whose text holds what is typed (Spotlight), under those whose name does.
    @ObservationIgnored private var contentResults: [AppCommand] = []
    @ObservationIgnored private var contentResultsQuery = ""
    @ObservationIgnored private var fileQuery: NSMetadataQuery?
    @ObservationIgnored private var fileObserver: NSObjectProtocol?
    @ObservationIgnored private var fileWork: DispatchWorkItem?
    /// The query `fileResults` answer (a Spotlight answer must not stay under another query).
    @ObservationIgnored private var fileResultsQuery = ""
    /// Set while re-ranking after an asynchronous answer: the pending Spotlight search is left alone.
    @ObservationIgnored private var keepFileSearch = false
    @ObservationIgnored let fileIndex = LauncherFileIndex()
    /// The demo's fictional files, searched like the real index.
    @ObservationIgnored private var demoFiles: LauncherFileIndex.Snapshot?
    @ObservationIgnored private var fileKinds: [String: Bool] = [:]
    /// The file window's searches run on their own queue: a name looked for among a million never holds the keyboard.
    @ObservationIgnored private let fileQueue = DispatchQueue(label: "heartware.launcher.files", qos: .userInitiated)
    /// The folders typed in the file window are read here: a volume that does not answer holds this queue alone.
    @ObservationIgnored private let folderQueue = DispatchQueue(label: "heartware.launcher.folders", qos: .userInitiated)
    /// The folder typed is still being read: ↩, ⇥ and the shortcuts wait for it (they would act on the previous list).
    @ObservationIgnored private var folderPending = false
    /// Where the Spotlight queries gather and sort their results, away from the main thread.
    @ObservationIgnored private let spotlightQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "heartware.launcher.spotlight"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    /// Moves on at each new text of the file window: an answer computed for an older one is dropped.
    @ObservationIgnored private let fileTicket = LauncherTicket()
    /// The answer being computed, done right away when ↩ comes first (never a result of the previous text).
    @ObservationIgnored private var fileSettle: (() -> Void)?

    /// Flat list of what is shown, in order (for keyboard navigation).
    var flat: [AppCommand] { sections.flatMap(\.items) }

    // MARK: Module

    func start(app: AppModel) {
        self.app = app
        combo = HotKeyCenter.shared.combo(for: Self.hotKeyID, fallback: Self.defaultCombo)
        hotKeyActive = HotKeyCenter.shared.register(Self.hotKeyID, combo: combo) { [weak self] in self?.toggle() }
        reindexApps()
        fileIndex.onChange = { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Written only when it changes: the pages that show it are not redrawn for nothing.
                    if self.indexState != state { self.indexState = state }
                    // Only the file window searches the index: the launcher has nothing to redo.
                    if self.isOpen, self.scope == .files, case .ready = state { self.refreshKeepingSelection() }
                }
            }
        }
        startIndexIfAllowed()
    }

    func stop() {
        fileIndex.stop()
    }

    /// With Full Disk Access, or once the user asked for it: no surprise macOS prompt at launch.
    private func startIndexIfAllowed() {
        guard includeFiles, !DemoData.isEnabled, !Snapshot.isActive, let app else { return }
        if app.fullDiskAccess || indexConsent { fileIndex.start() }
    }

    func enableIndex() {
        indexConsent = true
        includeFiles = true
        startIndexIfAllowed()
    }

    /// Saves the panel's shortcut, unless another part of Heartware already uses it.
    func setCombo(_ newCombo: KeyCombo?) {
        comboRefusal = nil
        if let newCombo, let other = (app ?? AppContext.model)?.hotkeys.owner(of: newCombo, except: .launcher) {
            comboRefusal = "\(newCombo.display) est déjà utilisé par \(other) : choisis-en un autre."
            return
        }
        combo = newCombo
        hotKeyActive = HotKeyCenter.shared.change(Self.hotKeyID, to: newCombo) { [weak self] in self?.toggle() }
    }

    func applySnapshotTab(_ tab: String) {
        if tab == "attente" {
            // The file window while Spotlight looks (no instant index yet).
            scope = .files
            query = "devis cuisine"
            indexState = .off
            sections = []
            fileSearchPending = true
            return
        }
        // "actions:corb": the panel open, its search field holding "corb".
        let parts = tab.split(separator: ":", maxSplits: 1).map(String.init)
        // The file window (`--tab files --query facture`); the actions of a file are shown there too.
        if ["files", "actions", "openwith", "quicklook", "nodetails", "selection", "glisser"].contains(parts.first ?? tab) {
            scope = .files
            if query.isEmpty { loadRecentFiles() }
            refresh()
        }
        switch parts.first ?? tab {
        case "translator", "traducteur":
            // The translator in the panel (`--tab traducteur:reglages` for its settings).
            mode = .translator
            if parts.count > 1 { app?.translator.applySnapshotTab(parts[1]) }
        case "youtube":
            // A YouTube link pasted, its pane at the right (`--tab youtube:outils`, `installation`, `audio`, `attente`…).
            if parts.count > 1 { app?.youtube.applySnapshotTab(parts[1]) }
            query = YouTubeModel.demoLink
            refresh()
        case "lanceur":
            // Raccourcis › Heartware, the instant index being built or off (`lanceur:indexation`, `lanceur:sans-index`).
            if parts.count > 1 { indexState = parts[1] == "indexation" ? .building : .off }
        case "telechargements":
            // The download list, from its launcher result.
            query = "téléchargements youtube"
            refresh()
            if let i = flat.firstIndex(where: { $0.id == YouTubeModel.listCommandID }) { selection = i }
        case "assign":
            let target = apps.first.map { HotkeysTarget.app(path: $0.path, name: $0.name) } ?? .command(id: "open_translator", title: "Traducteur")
            mode = .assign(target: target, title: target.title)
            assignMessage = "⌃⌥⌘M est déjà utilisé par Monteur : choisis-en un autre."
        case "selection":
            // Three results picked with ⌘-click, the second one under the selection.
            let paths = flat.compactMap(Self.filePath(of:))
            marked = [1, 3, 4].compactMap { paths.indices.contains($0) ? paths[$0] : nil }
            selection = 1
        case "glisser":
            snapshotStack = snapshotDrag()
            selection = 0
        case "actions", "openwith", "quicklook", "nodetails":
            // The first file of the results (or the first result), its actions panel open (`--query facture --tab actions`).
            let items = flat
            guard let i = items.firstIndex(where: { Self.filePath(of: $0).map { !isFolder($0) } ?? false })
                    ?? items.indices.first else { return }
            selection = i
            if parts[0] == "nodetails" { showDetails = false; return }
            openActions()
            if let target = actionsTarget, parts[0] != "actions",
               let action = actionsList.first(where: { $0.kind == (parts[0] == "openwith" ? .openWith : .quickLook) }) {
                perform(action, on: target, command: actionsCommand)
            }
            if parts.count > 1 { actionFilter = parts[1] }
        default:
            break
        }
    }

    func loadDemo() {
        combo = Self.defaultCombo
        hotKeyActive = true
        apps = DemoData.apps().map { LauncherApp(name: $0.name, path: $0.path, keywords: []) }
        appsIndexedAt = Date()
        for (id, n) in [("act_smart_scan", 14), ("open_wheel", 9), ("sys_darkmode", 7), ("set_com_apple_wifi_settings_extension", 4)] {
            CommandRunner.usage.value[id] = .init(count: n, last: Date().addingTimeInterval(-3600))
        }
        demoFiles = LauncherFileIndex.snapshot(paths: LauncherDemoFiles.paths, home: FS.home)
        indexState = .ready(count: 148_312)
        // A fictional app and file in the favourites, a command taken out of the search.
        let devis = FS.home + "/Documents/Atelier/Devis Atelier Lumen.pdf"
        favoriteItems = apps.filter { $0.name == "Monteur" }.map { LauncherFavorite(id: LauncherAppIndex.commandID(for: $0.path)) }
            + [LauncherFavorite(id: Self.fileID(devis), path: devis)]
        hiddenIDs = ["sys_screensaver"]
    }

    func commands(app: AppModel) -> [AppCommand] {
        LauncherSystem.commands() + LauncherSettings.commands() + LauncherAppActions.commands(app) + [
            AppCommand(id: "launcher_open", title: "Ouvrir le lanceur", keywords: ["lanceur", "launcher", "recherche"],
                       icon: .spark, group: .actions, urlSafe: true) { ctx in
                ctx.app.launcher.show()
                return .done
            },
            // Its window replaces the launcher (which closes itself): `staysInLauncher` keeps the launcher from closing first.
            AppCommand(id: Self.filesCommandID, title: "Rechercher des fichiers", subtitle: "Fichiers et dossiers, dans leur propre fenêtre",
                       keywords: ["fichiers", "fichier", "dossiers", "documents", "finder", "spotlight", "trouver", "chercher"],
                       icon: .symbol("doc.text.magnifyingglass", Theme.accent), group: .actions, assistantSafe: true, urlSafe: true,
                       hint: "Ouvrir", staysInLauncher: true) { ctx in
                ctx.app.launcher.toggleFiles()
                return .done
            }
        ]
    }

    func results(for query: String, app: AppModel) -> [AppCommand] {
        LauncherDynamic.results(query)
    }

    func selfTest() -> [String] {
        var failures: [String] = []
        let calc: [(String, Double?)] = [
            ("2+2", 4), ("3*(4+1)", 15), ("2^10", 1024), ("1,5*2", 3), ("10/4", 2.5), ("20%", 0.2), ("sqrt(16)", 4),
            ("-3+5", 2), ("2x3", 6), ("2++", nil), ("bonjour", nil), ("2024", nil), ("(1+2", nil), ("1/0", nil),
            // A percentage after + or − is a share of what comes before it.
            ("1250*1,2 + 15%", 1725), ("50-20%", 40), ("100+10%", 110), ("(100+10%)*2", 220), ("10%*50", 5), ("100+10%+10%", 121),
            // The minus sign binds after ^, as in mathematics.
            ("-2^2", -4), ("2^-1", 0.5), ("2^3^2", 512), ("(-2)^2", 4),
            // Spaces between groups of three digits (the calculator's own display) are thousands separators.
            ("1 000*2", 2000), ("1 500,15*2", 3000.3), ("1\u{202F}000*2", 2000), ("1\u{00A0}234\u{00A0}567+1", 1234568),
            ("2 3", nil), ("12 34*2", nil)
        ]
        for (input, expected) in calc {
            let got = LauncherCalculator.evaluate(input)
            if let e = expected {
                if got == nil || abs(got! - e) > 1e-9 { failures.append("calcul « \(input) » = \(got.map { "\($0)" } ?? "rien"), attendu \(e)") }
            } else if got != nil {
                failures.append("calcul « \(input) » aurait dû être refusé")
            }
        }
        let units: [(String, Double)] = [("10 km en mi", 6.2137), ("100 °F en °C", 37.7778), ("5 Go en Mo", 5000),
                                          ("1 Gio en Mo", 1073.7418), ("2 h en min", 120), ("3 jours en h", 72), ("8 Mb en MB", 1),
                                          ("1 000 km en mi", 621.3712)]
        for (input, expected) in units {
            let got = LauncherUnits.convert(input)?.value
            if got == nil || abs(got! - expected) > 0.001 { failures.append("conversion « \(input) » = \(got.map { "\($0)" } ?? "rien")") }
        }
        if LauncherUnits.convert("10 km en kg") != nil { failures.append("conversion km → kg aurait dû être refusée") }
        // French symbols, and the digits of a large result.
        let hours = LauncherUnits.convert("2 h en min")
        if hours?.from != "2 h" || hours?.to != "120 min" { failures.append("conversion : « \(hours.map { "\($0.from) = \($0.to)" } ?? "rien") » au lieu de « 2 h = 120 min »") }
        let tera = LauncherUnits.convert("5 To en Go")
        if tera?.from != "5 To" || tera?.to.hasSuffix(" Go") != true { failures.append("conversion : unités en anglais (\(tera?.to ?? "rien"))") }
        if LauncherUnits.convert("1 kcal en kj")?.from != "1 kcal" { failures.append("conversion : symbole kcal") }
        let big = LauncherCalculator.format(12_345_678_901 * 10)
        if big.filter(\.isNumber) != "123456789010" { failures.append("calcul : « \(big) » tronqué") }
        if LauncherCalculator.format(0.1 + 0.2) != "0,3" { failures.append("calcul : 0,1 + 0,2 affiché « \(LauncherCalculator.format(0.1 + 0.2)) »") }
        for v in [1500.15, 1_234_567.5, 123_456_789_010] {
            let back = LauncherCalculator.evaluate(LauncherCalculator.format(v) + "*1")
            if back == nil || abs(back! - v) > 1e-6 { failures.append("calcul : « \(LauncherCalculator.format(v)) » n'est pas relu") }
        }
        for (city, expected) in [("new york", "New York"), ("le caire", "Le Caire"), ("pointe-à-pitre", "Pointe-à-Pitre")]
        where LauncherWorldClock.title(city) != expected {
            failures.append("heure : « \(LauncherWorldClock.title(city)) » au lieu de « \(expected) »")
        }
        if LauncherDynamic.volumeLevel("volume 40 %") != 40 || LauncherDynamic.volumeLevel("volume 30") != 30 || LauncherDynamic.volumeLevel("volume 140") != nil {
            failures.append("volume : « volume 40 % » mal lu")
        }
        if "AT&T".addingPercentEncoding(withAllowedCharacters: LauncherDynamic.queryValueAllowed) != "AT%26T"
            || "a+b=c?d#e".addingPercentEncoding(withAllowedCharacters: LauncherDynamic.queryValueAllowed) != "a%2Bb%3Dc%3Fd%23e" {
            failures.append("recherche web : & + = ? # doivent être encodés")
        }
        for c in LauncherDynamic.results("wiki chat") + LauncherDynamic.results(":coeur") where !AppCommand.isValidID(c.id) {
            failures.append("identifiant invalide : \(c.id)")
        }
        let hearts = LauncherDynamic.results(":coeur").map(\.id)
        if Set(hearts).count != hearts.count { failures.append("emoji : identifiants en double") }
        if !AppCommand.isValidID(LauncherDynamic.processID("com.tinyspeck.slackmacgap", force: true))
            || LauncherDynamic.processID("Café Été", force: false) != "quit_cafe_ete" {
            failures.append("quitter : identifiant stable invalide")
        }
        if let ok = LauncherEmoji.search("ok").first, !ok.name.split(separator: " ").contains("OK") {
            failures.append("emoji : « :ok » propose d'abord \(ok.name)")
        }
        for t in MaintenanceTask.all {
            let confirms: Bool
            if case .confirm = LauncherAppActions.maintenanceRisk(t) { confirms = true } else { confirms = false }
            if confirms == ["dock", "quicklook"].contains(t.id) { failures.append("maintenance : confirmation de « \(t.title) »") }
        }
        if Fuzzy.score("reglages", in: "Réglages Système") == nil { failures.append("recherche sans accents") }
        if Fuzzy.score("vsc", in: "Visual Studio Code") == nil { failures.append("recherche par initiales") }
        if LauncherEmoji.search("coeur").isEmpty { failures.append("emoji introuvables") }
        failures += Self.fileIndexChecks()
        failures += LauncherActions.checks()
        failures += LauncherDragPhysics.checks()
        if Self.dragOrder("/b", marked: ["/a", "/b", "/c"]) != ["/b", "/a", "/c"] || Self.dragOrder("/d", marked: ["/a"]) != ["/d"] {
            failures.append("glisser : le fichier saisi passe en premier, avec la sélection seulement s'il en fait partie")
        }
        return failures
    }

    /// The launcher, the file window and the clipboard history each show their own results (demo data only).
    static func windowChecks(_ app: AppModel) -> [String] {
        var failures: [String] = []
        let l = app.launcher
        l.preview("facture", app: app)
        let inLauncher = l.flat
        if inLauncher.contains(where: { filePath(of: $0) != nil }) { failures.append("le lanceur montre des fichiers au lieu de proposer la fenêtre Fichiers") }
        if inLauncher.first?.id != "files_find" { failures.append("« facture » : la ligne qui ouvre la fenêtre Fichiers devrait venir en premier") }
        l.preview("~/Documents/", app: app)
        if l.flat.map(\.id) != ["files_find"] { failures.append("« ~/Documents/ » dans le lanceur : seule la fenêtre Fichiers devrait être proposée") }
        l.preview("cb lumiere", app: app)
        if l.flat.first?.id != "clip_r_open" || l.flat.contains(where: { $0.id.hasPrefix("clip_r_") && $0.id != "clip_r_open" || $0.id == "files_find" }) {
            failures.append("« cb lumiere » : le lanceur devrait proposer la fenêtre du presse-papiers, pas ses éléments")
        }
        l.scope = .files
        l.preview("facture", app: app)
        let files = l.flat
        if files.isEmpty || !files.allSatisfy({ filePath(of: $0) != nil }) { failures.append("la fenêtre Fichiers ne montre pas que des fichiers (\(files.count) résultats)") }
        l.preview("", app: app)
        l.scope = .all
        l.preview("", app: app)
        return failures
    }

    /// The index's rules and ranking, on made-up paths (nothing is read from the disk).
    static func fileIndexChecks() -> [String] {
        var failures: [String] = []
        let h = "/Users/test"
        let roots = [h, h + "/Library/Mobile Documents/com~apple~CloudDocs"]
        let indexable: [(String, Bool)] = [
            (h + "/Documents/Factures", true), (h + "/Library/Caches", false), (h + "/Developer/app/node_modules/x", false),
            (h + "/.config", false), (h + "/Developer/site/.git", false), (h + "/Pictures/Photos.photoslibrary/originals", false),
            (h + "/Library/Mobile Documents/com~apple~CloudDocs/Notes", true), ("/private/tmp", false),
            // A package is listed in its folder, never read (FSEvents reports it when its content changes).
            (h + "/Developer/app/App.xcodeproj", false), (h + "/Documents/Rapport.pages", false), (h + "/Documents/Notes.rtfd", false)
        ]
        for (path, expected) in indexable where LauncherFileIndex.isIndexable(path, roots: roots, home: h) != expected {
            failures.append("index : « \(path) » \(expected ? "aurait dû être indexé" : "n'aurait pas dû l'être")")
        }
        let snapshot = LauncherFileIndex.snapshot(paths: [
            (h + "/Documents/Factures", true), (h + "/Documents/Factures/EDF", true),
            (h + "/Documents/Factures/EDF/mars 2026.pdf", false), (h + "/Documents/Résumé.pdf", false),
            (h + "/Documents/Archives/vieux/très/loin/facture.pdf", false), (h + "/Desktop/facture.pdf", false),
            (h + "/Documents/préfacture.txt", false), (h + "/Documents/Rapport annuel.pages", false),
            (h + "/Documents/Administratif", true), (h + "/Documents/Administratif/Avis d'imposition 2026.pdf", false)
        ], home: h)
        func first(_ q: String) -> String? {
            LauncherFileIndex.search(q, in: snapshot, checkDates: false).first.map { ($0.path as NSString).lastPathComponent }
        }
        if first("facture") != "facture.pdf" { failures.append("index : « facture » devrait d'abord trouver facture.pdf (\(first("facture") ?? "rien"))") }
        if LauncherFileIndex.search("facture", in: snapshot, checkDates: false).first?.path != h + "/Desktop/facture.pdf" {
            failures.append("index : le fichier du Bureau devrait passer avant celui rangé très loin")
        }
        if first("resume") != "Résumé.pdf" { failures.append("index : recherche sans accents") }
        if first("edf mars") != "mars 2026.pdf" { failures.append("index : un mot peut viser le dossier (« edf mars »)") }
        if first("rapport annuel") != "Rapport annuel.pages" { failures.append("index : plusieurs mots") }
        if first("administratif avis") != "Avis d'imposition 2026.pdf" {
            failures.append("index : le mot le plus long peut viser le dossier (« administratif avis » → \(first("administratif avis") ?? "rien"))")
        }
        if !LauncherFileIndex.search("zzz", in: snapshot, checkDates: false).isEmpty { failures.append("index : résultat inventé") }
        if Self.contentPredicate("numéro siret").predicateFormat != #"kMDItemTextContent BEGINSWITH[cd] "numéro" AND kMDItemTextContent BEGINSWITH[cd] "siret""# {
            failures.append("contenu : chaque mot doit commencer un mot du texte (\(Self.contentPredicate("numéro siret").predicateFormat))")
        }
        if Self.isUserFile(h + "/Library/Mail/V10/x.emlx", home: h) || Self.isUserFile(h + "/Documents/.cache/a.txt", home: h)
            || !Self.isUserFile(h + "/Library/Mobile Documents/com~apple~CloudDocs/Kbis.pdf", home: h) || !Self.isUserFile(h + "/Documents/Kbis.pdf", home: h) {
            failures.append("contenu : les courriels et caches doivent rester hors des résultats, iCloud Drive dedans")
        }
        let order = LauncherFileIndex.search("fact", in: snapshot, checkDates: false).map(\.name)
        if let pre = order.firstIndex(of: "préfacture.txt"), let start = order.firstIndex(of: "Factures"), pre < start {
            failures.append("index : un nom qui commence par la recherche passe avant un nom qui la contient")
        }
        if LauncherModel.fileID("/a/b") == LauncherModel.fileID("/a/c") || !AppCommand.isValidID(LauncherModel.fileID("/a/b é")) {
            failures.append("index : identifiants de fichiers")
        }
        return failures
    }

    func dump() -> [String] {
        // The demo shows its made-up apps, never the ones installed on this Mac.
        let apps = DemoData.isEnabled ? DemoData.apps().map { LauncherApp(name: $0.name, path: $0.path, keywords: []) } : LauncherAppIndex.scan()
        var lines: [String] = []
        if !DemoData.isEnabled {
            let built = fileIndex.buildNow()
            lines.append("index des fichiers : \(Fmt.int(built.count)) éléments en \(String(format: "%.2f", built.seconds)) s")
            for q in ["facture", "rapport annuel", "png", "a"] {
                let t = Date()
                let hits = LauncherFileIndex.search(q, in: fileIndex.snapshot, limit: 5)
                lines.append("« \(q) » : \(String(format: "%.1f", Date().timeIntervalSince(t) * 1000)) ms → \(hits.prefix(3).map { FS.pretty($0.path) }.joined(separator: " · "))")
            }
            indexState = .ready(count: built.count)
        }
        if let app = AppContext.model { lines += typingBench(app) }
        return lines + ["\(apps.count) apps indexées : \(apps.prefix(8).map(\.name).joined(separator: ", "))…",
                "2,5*(3+1) = \(LauncherCalculator.evaluate("2,5*(3+1)").map(LauncherCalculator.format) ?? "?")",
                "10 km en miles : \(LauncherUnits.convert("10 km en miles")?.to ?? "?")",
                "heure Tokyo : \(LauncherWorldClock.answer("heure Tokyo")?.time ?? "?")",
                "⌘K sur un PDF : " + LauncherActions.all(for: .file(path: FS.home + "/Documents/Facture.pdf"), LauncherActionContext())
                    .map { "\($0.title) \($0.shortcut?.keys.joined() ?? "")" }.joined(separator: " · "),
                "⌘K sur une app : " + LauncherActions.all(for: .app(path: "/Applications/Exemple.app", name: "Exemple"),
                                                         LauncherActionContext(bundleID: "fr.exemple", running: true, uninstallable: true))
                    .map { "\($0.title) \($0.shortcut?.keys.joined() ?? "")" }.joined(separator: " · ")]
    }

    /// What each keystroke costs the main thread, words typed letter by letter in both windows (`--dump --only launcher`).
    private func typingBench(_ app: AppModel) -> [String] {
        self.app = app
        catalog = ModuleRegistry.commands(app) + LauncherAppIndex.commands(DemoData.isEnabled ? apps : LauncherAppIndex.scan())
        var lines = ["catalogue : \(catalog.count) commandes"]
        for (window, words) in [(LauncherScope.all, ["chrome", "réglages wifi", "facture edf", "2*3+4", ":coeur", "dans devis"]),
                                (.files, ["facture", "de", "rapport annuel", "~/Documents/"])] {
            scope = window
            var worst = (ms: 0.0, typed: ""), total = 0.0, keys = 0
            for word in words {
                query = ""
                for end in word.indices {
                    let t = DispatchTime.now().uptimeNanoseconds
                    query = String(word[...end])
                    // A burst waits for its last key, and the file window searches on its own queue: both done right
                    // here, to measure the work itself.
                    if pendingRefresh != nil { settleRefresh() }
                    fileSettle?()
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
                    if ms > worst.ms { worst = (ms, query) }
                    total += ms
                    keys += 1
                }
            }
            lines.append("frappe (\(window == .all ? "lanceur" : "fichiers")) : \(String(format: "%.1f", total / Double(max(1, keys)))) ms en moyenne, \(String(format: "%.1f", worst.ms)) ms au pire (« \(worst.typed) »), \(keys) touches")
        }
        // The slowest modules for one letter, the widest search.
        var slow: [(String, Double)] = []
        for e in ModuleRegistry.modules(app) {
            let t = DispatchTime.now().uptimeNanoseconds
            for q in ["c", "ch", "fa"] { _ = e.module.results(for: q, app: app) }
            slow.append((e.title, Double(DispatchTime.now().uptimeNanoseconds - t) / 3e6))
        }
        lines.append("résultats des modules : " + slow.sorted { $0.1 > $1.1 }.prefix(5).map { "\($0.0) \(String(format: "%.2f", $0.1)) ms" }.joined(separator: " · "))
        stopFileSearch()
        query = ""
        scope = .all
        return lines
    }

    /// Fills the results as if the user had typed `text` (for `--snapshot`).
    func preview(_ text: String, app: AppModel) {
        self.app = app
        catalog = ModuleRegistry.commands(app) + LauncherAppIndex.commands(apps)
        query = text
        refresh()
    }

    // MARK: Panel

    static let filesCommandID = "launcher_files"

    /// What a keyboard shortcut of the file window is saved as (in the Raccourcis section).
    static let filesHotkeyTarget = HotkeysTarget.command(id: filesCommandID, title: "Rechercher des fichiers")

    /// The shortcut pressed again closes the launcher; pressed over the file window, it brings the launcher back.
    func toggle() {
        isOpen && scope == .all ? hide() : show()
    }

    func toggleFiles() {
        isOpen && scope == .files ? hide() : showFiles()
    }

    /// The launcher, empty or with a text already typed (a YouTube link copied, for its download).
    func show(query text: String = "") {
        open(.all, query: text)
    }

    /// The file search in its own window, `text` already typed (from the launcher's "Chercher « … » dans les fichiers").
    func showFiles(query text: String = "") {
        open(.files, query: text)
    }

    private func open(_ newScope: LauncherScope, query text: String) {
        guard let app = app ?? AppContext.model else { return }
        self.app = app
        // One floating window at a time: the other one, or the clipboard history, steps aside.
        if isOpen { activePanel?.close() }
        if app.clipboard.window.isOpen { app.clipboard.window.close() }
        scope = newScope
        if !DemoData.isEnabled, Date().timeIntervalSince(appsIndexedAt) > 600 { reindexApps() }
        catalog = ModuleRegistry.commands(app) + LauncherAppIndex.commands(apps)
        leaveMode()
        if newScope == .files, text.isEmpty { loadRecentFiles() }
        // Only the file window searches the index; its list is rebuilt while it shows: the changes since come in now.
        if newScope == .files { fileIndex.catchUp() }
        checkFavorites()
        // Set once: a new text already refreshes the results by itself.
        if query == text { refresh() } else { query = text }
        let p = activePanel ?? makePanel(for: newScope)
        p.setContent(LauncherView().environment(app))
        p.present()
        isOpen = true
        installKeyMonitor()
        installScrollMonitor()
    }

    func hide() {
        activePanel?.close()
    }

    /// The window on screen (or the one about to open).
    private var activePanel: FloatingPanel? { scope == .files ? filesPanel : panel }

    /// The translator right in the panel: from the "Traducteur" result, "trad …", the clipboard or a global shortcut.
    func showTranslator(text: String? = nil, target: String? = nil, claude: Bool = false) {
        guard let app = app ?? AppContext.model else { return }
        // Its shortcut pressed again closes it, like the launcher's own.
        if isOpen, mode == .translator, text == nil, !claude {
            hide()
            return
        }
        // In the launcher itself, not in the file window.
        if !isOpen || scope != .all { show() }
        mode = .translator
        app.translator.enterPanel(text: text, target: target, claude: claude)
    }

    /// ↩ or the "Copier la traduction" button of the translator: copied, and the panel makes way for the paste.
    func copyTranslation() {
        guard let t = app?.translator, !t.resultText.isEmpty else { return }
        if case .copied = CommandRunner.copy(t.resultText) {
            HUD.show("Traduction copiée", symbol: "doc.on.clipboard.fill")
        } else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
        }
        hide()
    }

    /// Back to the search, in the same panel.
    func backToSearch() {
        leaveMode()
        refresh()
    }

    private func leaveMode() {
        mode = .search
        assignMessage = nil
        closeActions()
        app?.translator.panelActive = false
        app?.translator.showSettings = false
    }

    /// The apps the launcher knows (read only: the Raccourcis page lists them).
    var installedApps: [LauncherApp] { apps }

    /// ⌘K: the selected result gets a keyboard shortcut (an app, a file, a folder or an action of the app).
    func startAssign() {
        let items = flat
        guard items.indices.contains(selection) else { return }
        let command = items[selection]
        guard let target = HotkeysModel.target(for: command, catalogIDs: Set(catalog.map(\.id))) else {
            HUD.show("Ce résultat change avec ta saisie : pas de raccourci possible", symbol: "keyboard")
            return
        }
        assignMessage = nil
        mode = .assign(target: target, title: command.title)
    }

    private func makePanel(for scope: LauncherScope) -> FloatingPanel {
        let p = FloatingPanel(size: NSSize(width: LauncherView.width, height: LauncherView.height))
        p.onClose = { [weak self, weak p] in
            MainActor.assumeIsolated {
                // A window that closes late (once the other one is open) leaves the open one alone.
                guard let self, let p, p === self.activePanel else { return }
                self.isOpen = false
                self.fileIndex.setShowing(false)
                self.marked = []
                self.leaveMode()
                self.removeKeyMonitor()
                self.stopFileSearch()
                self.stopSpotlight(self.recentQuery)
                self.recentQuery = nil
                self.folderPending = false
                self.pendingRefresh?.cancel()
                self.pendingRefresh = nil
                self.fileTicket.next()
                self.fileSettle = nil
                // Refilled by the next search: the paths of a whole session never pile up.
                self.fileKinds = [:]
                self.app?.translator.launcherClosed()
                // The closed panel keeps no view: nothing in it is redrawn behind the scenes (nor a Quick Look preview
                // played) until it opens again with a new one.
                DispatchQueue.main.async { [weak p] in
                    if let p, !p.isVisible { p.contentView = nil }
                }
            }
        }
        if scope == .files { filesPanel = p } else { panel = p }
        return p
    }

    /// Arrows, Return and Esc are caught before the text field sees them.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.activePanel, event.window === panel else { return event }
            // A held ↩ runs its result once, not once per key repeat (each one could start a scan or a Claude process).
            if event.isARepeat, [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)),
               self.mode != .translator || event.modifierFlags.intersection([.shift, .option]).isEmpty { return nil }
            switch self.mode {
            case .search: return self.searchKey(event)
            case .translator: return self.translatorKey(event)
            case .assign(let target, let title): return self.assignKey(event, target: target, title: title)
            case .quickLook(let path): return self.quickLookKey(event, path: path)
            }
        }
    }

    private func searchKey(_ event: NSEvent) -> NSEvent? {
            // ⇥, ↩, the arrows and the shortcuts act on the answer to what is typed, not on a list of the previous text.
            // Never ⌥ alone: it types characters (~, |, [ on a French keyboard).
            let acting = !event.modifierFlags.intersection([.command, .control]).isEmpty
                || [kVK_Tab, kVK_Return, kVK_ANSI_KeypadEnter, kVK_UpArrow, kVK_DownArrow, kVK_Escape].contains(Int(event.keyCode))
            if acting {
                if pendingRefresh != nil { settleRefresh() }
                fileSettle?()
                // A folder still being read (a slow disk): nothing opens rather than the wrong file (⎋ and the arrows still work).
                let opens = !event.modifierFlags.intersection([.command, .control]).isEmpty
                    || [kVK_Tab, kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode))
                if folderPending, opens { return nil }
            }
            if actionsTarget != nil { return actionsKey(event) }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "k" {
                // The actions of the selected result: an app, a file, a folder or a command each get their own.
                openActions()
                return nil
            }
            if resultShortcut(event) { return nil }
            switch Int(event.keyCode) {
            case kVK_DownArrow:
                self.move(1); return nil
            case kVK_UpArrow:
                self.move(-1); return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                // ⌘↩ in the file window picks the file; elsewhere it runs the result's secondary action.
                if event.modifierFlags.contains(.command), toggleMarkSelected() { return nil }
                self.runSelected(alternate: event.modifierFlags.contains(.command)); return nil
            case kVK_Escape:
                // What is typed first, then the picked files (they took longer to gather), then the window.
                if !self.query.isEmpty {
                    self.query = ""
                } else if !self.marked.isEmpty {
                    self.marked = []
                } else {
                    self.hide()
                }
                return nil
            case kVK_Tab:
                // Tab enters the selected folder ("~/Documents/Factures/"), or completes a path being typed.
                if let path = self.selectedFile, self.isPathQuery(self.query) || self.fileKinds[path] == true {
                    self.browse(FS.pretty(path) + (self.fileKinds[path] == true ? "/" : ""))
                    return nil
                }
                return event
            default:
                return event
            }
    }

    /// ↩ copies the translation, ⌘↩ asks Claude, ⇥ changes the language, ⌘, opens the settings, ⎋ clears then goes
    /// back to the search. In the settings, ⎋ (or ⌘,) goes back to the translation.
    private func translatorKey(_ event: NSEvent) -> NSEvent? {
        guard let t = app?.translator else { return event }
        let flags = event.modifierFlags
        let settingsKey = flags.contains(.command) && event.charactersIgnoringModifiers == ","
        if t.showSettings {
            switch Int(event.keyCode) {
            case kVK_Escape:
                t.showSettings = false
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                return nil
            default:
                if settingsKey { t.showSettings = false; return nil }
                return event
            }
        }
        if settingsKey {
            t.showSettings = true
            return nil
        }
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if flags.contains(.option) || flags.contains(.shift) { return event } // a new line in the text
            if flags.contains(.command) {
                Task { await t.translateWithClaude() }
                return nil
            }
            if !t.resultText.isEmpty, !t.isTranslating {
                copyTranslation()
            } else {
                t.translate()
            }
            return nil
        case kVK_Tab:
            t.cycleTarget(flags.contains(.shift) ? -1 : 1)
            return nil
        case kVK_Escape:
            if t.sourceText.isEmpty { backToSearch() } else { t.sourceText = ""; t.resultText = "" }
            return nil
        default:
            return event
        }
    }

    /// ⎋ or ⌘Y closes the preview, ↑↓ go to the previous or next file, ↩ opens it, ⌘↩ shows it in the Finder.
    private func quickLookKey(_ event: NSEvent, path: String) -> NSEvent? {
        let press = LauncherKeyPress(event)
        let plain = !press.command && !press.option && !press.control && !press.shift
        if press.command, press.base.lowercased() == "y" {
            leaveMode()
            return nil
        }
        switch Int(event.keyCode) {
        case kVK_Escape:
            leaveMode()
            return nil
        case kVK_DownArrow where plain, kVK_UpArrow where plain:
            let items = flat
            var i = selection
            for _ in items.indices {
                i = (i + (Int(event.keyCode) == kVK_DownArrow ? 1 : -1) + items.count) % items.count
                if let next = Self.filePath(of: items[i]) {
                    selection = i
                    scrollToSelection = true
                    mode = .quickLook(path: next)
                    break
                }
            }
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let i = flat.firstIndex(where: { Self.filePath(of: $0) == path }) { selection = i }
            mode = .search
            runSelected(alternate: press.command)
            return nil
        default:
            return event
        }
    }

    /// The next key with ⌘, ⌃ or ⌥ becomes the shortcut; ⌫ removes the current one, ⎋ cancels.
    private func assignKey(_ event: NSEvent, target: HotkeysTarget, title: String) -> NSEvent? {
        guard let app else { return nil }
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        switch Int(event.keyCode) {
        case kVK_Escape:
            backToSearch()
            return nil
        case kVK_Delete where plain, kVK_ForwardDelete where plain:
            if app.hotkeys.binding(for: target)?.combo != nil {
                app.hotkeys.unbind(target)
                HUD.show("Raccourci retiré : \(title)", symbol: "keyboard")
            }
            backToSearch()
            return nil
        default:
            let combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: KeyCombo.carbon(from: event.modifierFlags))
            guard combo.hasModifier else {
                assignMessage = "Ajoute ⌘, ⌃ ou ⌥ à la touche (⌃⌥⌘ + une lettre est rarement pris)."
                return nil
            }
            if let other = app.hotkeys.bind(target, combo: combo) {
                assignMessage = "\(combo.display) est déjà utilisé par \(other). Choisis-en un autre."
                return nil
            }
            HUD.show("\(combo.display) → \(title)", symbol: "keyboard")
            let keep = selection
            backToSearch()
            selection = min(keep, max(0, flat.count - 1))
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    /// The trackpad moves the rows under a still pointer: those hovers must not change the selection.
    private func installScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self, event.window === self.activePanel { self.lastScroll = Date() }
            return event
        }
    }

    /// A row under the pointer: selected when the pointer moved, not when the list scrolled under it.
    func hover(_ index: Int) {
        guard actionsTarget == nil, selection != index, Date().timeIntervalSince(lastScroll) > 0.15 else { return }
        scrollToSelection = false
        selection = index
    }

    func move(_ delta: Int) {
        let count = flat.count
        guard count > 0 else { return }
        scrollToSelection = true
        selection = (selection + delta + count) % count
    }

    /// The file or folder under the selection, for the preview pane.
    var selectedFile: String? {
        let items = flat
        guard items.indices.contains(selection), items[selection].group == .files,
              case .file(let path) = items[selection].icon else { return nil }
        return path
    }

    /// The view a module shows at the right of the selected result (a YouTube video and its settings).
    var selectedPane: (@MainActor () -> AnyView)? {
        let items = flat
        return items.indices.contains(selection) ? items[selection].pane : nil
    }

    /// A plain folder (an app or another package is opened, not entered).
    func isFolder(_ path: String) -> Bool {
        if let known = fileKinds[path] { return known }
        return DemoData.isEnabled ? (path as NSString).pathExtension.isEmpty : HotkeysModel.isPlainFolder(path)
    }

    /// A fixed result of the catalogue (not one that changes with what is typed).
    func inCatalog(_ id: String) -> Bool {
        catalog.contains { $0.id == id }
    }

    var catalogIDs: Set<String> { Set(catalog.map(\.id)) }

    /// Where the share menu is anchored.
    var panelView: NSView? { activePanel?.contentView }

    /// The caret after what is already typed (an opening search is not selected as a whole, typing goes on).
    func moveCursorToEnd() {
        (activePanel?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
    }

    /// The panel takes the keyboard back after an alert.
    func refocus() {
        if isOpen { activePanel?.makeKeyAndOrderFront(nil) }
    }

    func runSelected(alternate: Bool = false) {
        // ↩ right after a keystroke: the answer to what is typed, not a result of the previous text.
        if pendingRefresh != nil { settleRefresh() }
        fileSettle?()
        let items = flat
        guard items.indices.contains(selection) else { return }
        run(items[selection], alternate: alternate)
    }

    func run(_ command: AppCommand, alternate: Bool = false) {
        guard let app else { return }
        let q = query
        // A command with its own view (the translator) replaces the results instead of closing the panel.
        if !command.staysInLauncher { hide() }
        Task { await CommandRunner.execute(command, app: app, query: q, alternate: alternate) }
    }

    // MARK: Search

    private func reindexApps() {
        appsIndexedAt = Date()
        Task {
            let found = await Task.detached(priority: .utility) { LauncherAppIndex.scan() }.value
            apps = found
            if isOpen, let app { catalog = ModuleRegistry.commands(app) + LauncherAppIndex.commands(found); refresh() }
        }
    }

    /// A new text: the list follows at once, or 30 ms after the last of a burst of keys.
    private func queryChanged() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard isOpen, !Snapshot.isActive, now &- lastRefresh < 30_000_000 else {
            settleRefresh()
            return
        }
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settleRefresh() }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    /// The list for what is typed now (also before a key acts on it: ↩, the arrows, the shortcuts).
    private func settleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        refresh()
    }

    func refresh() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        lastRefresh = DispatchTime.now().uptimeNanoseconds
        guard let app else { sections = []; return }
        let q = query.trimmingCharacters(in: .whitespaces)
        selection = 0
        if scope == .files {
            refreshFiles(q)
            return
        }
        if q.isEmpty {
            sections = suggestions()
            return
        }
        // Folders and searches inside the files belong to the file window: one row takes them there.
        if isPathQuery(q) || isContentQuery(q) {
            sections = [LauncherSection(id: "files", title: CommandSection.files.title, items: [filesRow(q)])]
            return
        }
        var scored: [(AppCommand, Double)] = []
        let hidden = Set(hiddenIDs)
        let typed = Fuzzy.Query(q)
        for entry in searchable where !hidden.contains(entry.command.id) {
            if let s = Fuzzy.best(typed, title: entry.title, keywords: entry.keywords) {
                scored.append((entry.command, s + CommandRunner.frecency(entry.command.id) + entry.command.boost))
            }
        }
        let answers = ModuleRegistry.results(for: q, app: app)
        for c in answers {
            scored.append((c, c.boost + CommandRunner.frecency(c.id)))
        }
        // Not when a module claims what is typed ("cb …", "trad …", a calculation): that is not a file name.
        if q.count >= 2, !q.hasPrefix(":"), !answers.contains(where: { $0.boost >= 1900 }) {
            let row = filesRow(q)
            scored.append((row, row.boost))
        }
        scored.sort { $0.1 > $1.1 }
        sections = arrange(scored.map(\.0))
    }

    /// The file window: the index (or Spotlight) for a name, the folders for a path, recent files when nothing is typed.
    private func refreshFiles(_ q: String) {
        fileTicket.next()
        fileSettle = nil
        folderPending = false
        if contentResultsQuery != q {
            contentResults = []
            contentResultsQuery = q
        }
        if q.isEmpty {
            stopFileSearch()
            fileResults = []
            fileResultsQuery = ""
            sections = fileSuggestions()
            return
        }
        // "~/Documents/fa" or "/Applications": browse the folders, nothing else.
        if isPathQuery(q) {
            stopFileSearch()
            if DemoData.isEnabled || Snapshot.isActive {
                showFolder(Self.folderRows(q, demo: DemoData.isEnabled))
            } else {
                answerFiles({ Self.folderRows(q, demo: false) }, onDisk: true) { [weak self] rows in self?.showFolder(rows) }
            }
            return
        }
        switch fileSource(q) {
        case .none:
            stopFileSearch()
            fileResults = []
            fileResultsQuery = q
            showFileResults(instant: true)
        case .index(let snapshot):
            // The names from the index at once, the files that hold the word from Spotlight a moment later.
            if !keepFileSearch {
                stopFileSearch()
                scheduleFileSearch(q, namesToo: false)
            }
            let checkDates = !DemoData.isEnabled
            // A small index answers at once; a big one on its own queue, the keyboard never waits for it.
            if DemoData.isEnabled || Snapshot.isActive || snapshot.count < 20_000 {
                showHits(LauncherFileIndex.search(q, in: snapshot, limit: 40, checkDates: checkDates), for: q)
            } else {
                answerFiles({ LauncherFileIndex.search(q, in: snapshot, limit: 40, checkDates: checkDates) }) { [weak self] hits in
                    self?.showHits(hits, for: q)
                }
            }
        case .spotlight:
            if fileResultsQuery != q {
                // Spotlight answers later: until then, nothing rather than the files of the previous query.
                fileResults = []
                fileResultsQuery = q
            }
            showFileResults(instant: false)
            if !keepFileSearch { scheduleFileSearch(q, namesToo: true) }
        }
    }

    /// Where the file window's answer comes from: nothing (too short), the instant index, or Spotlight (content searches,
    /// index not ready).
    private enum FileSource {
        case none, index(LauncherFileIndex.Snapshot), spotlight
    }

    private func fileSource(_ q: String) -> FileSource {
        guard q.count >= 2, !q.hasPrefix(":"), !q.hasPrefix("?") else { return .none }
        if isContentQuery(q) { return .spotlight }
        if let demoFiles { return .index(demoFiles) }
        if case .ready = indexState { return .index(fileIndex.snapshot) }
        return .spotlight
    }

    /// Computes on the file queue, then shows the answer if the text is still the same. Until then ↩ computes it right away
    /// (a search in the index, in memory). `onDisk`: a folder read on the disk queue, which may wait on a slow volume:
    /// never on the file queue (a stuck volume would hold every search) nor on the main thread.
    private func answerFiles<T: Sendable>(_ compute: @escaping @Sendable () -> T, onDisk: Bool = false,
                                          apply: @escaping @MainActor (T) -> Void) {
        let ticket = fileTicket.next()
        folderPending = onDisk
        fileSettle = onDisk ? nil : { [weak self] in
            guard let self, self.fileTicket.isCurrent(ticket) else { return }
            self.fileTicket.next()
            self.fileSettle = nil
            apply(compute())
        }
        let work: @Sendable () -> Void = { [weak self, fileTicket] in
            // Typed on meanwhile: this text is already out of date.
            guard fileTicket.isCurrent(ticket) else { return }
            let answer = compute()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.fileTicket.isCurrent(ticket) else { return }
                    self.fileSettle = nil
                    self.folderPending = false
                    // The arrows may have moved meanwhile: the selection stays where it is.
                    let keep = self.selection
                    apply(answer)
                    self.selection = min(keep, max(0, self.flat.count - 1))
                }
            }
        }
        if onDisk { folderQueue.async(execute: work) } else { fileQueue.async(execute: work) }
    }

    private func showHits(_ hits: [LauncherFileIndex.Hit], for q: String) {
        fileResults = hits.enumerated().map { rank, hit in
            fileKinds[hit.path] = hit.isDir
            return fileCommand(hit.path, isDir: hit.isDir, boost: hit.score * 0.45 - Double(rank) * 0.01)
        }
        fileResultsQuery = q
        showFileResults(instant: true)
    }

    private func showFileResults(instant: Bool) {
        let ranked = fileResults.map { ($0, $0.boost + CommandRunner.frecency($0.id)) }.sorted { $0.1 > $1.1 }.map(\.0)
        let named = Set(ranked.map(\.id))
        let inside = contentResults.filter { !named.contains($0.id) }
        sections = (ranked.isEmpty ? [] : [LauncherSection(id: "files", title: instant ? "Résultats" : "Résultats Spotlight", items: ranked)])
            + (inside.isEmpty ? [] : [LauncherSection(id: "content", title: "Dans le contenu", items: inside)])
    }

    private func showFolder(_ folder: LauncherFolderRows) {
        let items = folder.rows.enumerated().map { rank, row -> AppCommand in
            let path = (folder.dir == "/" ? "" : folder.dir) + "/" + row.name
            fileKinds[path] = row.isDir
            return fileCommand(path, isDir: row.isDir, boost: 400 - Double(rank))
        }
        sections = items.isEmpty ? [] : [LauncherSection(id: "path", title: "Dossier", items: items)]
    }

    private func stopFileSearch() {
        fileWork?.cancel()
        stopSpotlight(fileQuery)
        fileQuery = nil
        fileSearchPending = false
    }

    /// The launcher's way into the file window, what was typed already in its search.
    private func filesRow(_ q: String) -> AppCommand {
        let hotkey = app?.hotkeys.binding(for: Self.filesHotkeyTarget)?.combo?.display
        return AppCommand(id: "files_find", title: isPathQuery(q) ? "Parcourir « \(q) » dans Fichiers" : "Chercher « \(q) » dans les fichiers",
                          subtitle: "Ouvre la recherche de fichiers" + (hotkey.map { " · \($0) de n'importe où" } ?? ""),
                          icon: .symbol("doc.text.magnifyingglass", Theme.accent), group: .files, hint: "Ouvrir la fenêtre",
                          // Under any app or command that matches, over the translation of a lone word and the web.
                          boost: 100, staysInLauncher: true) { ctx in
            ctx.app.launcher.showFiles(query: q)
            return .done
        }
    }

    /// A folder to browse: right here in the file window; from the launcher, the file window opens on it.
    func browse(_ text: String) {
        if scope == .files { query = text } else { showFiles(query: text) }
    }

    /// Re-ranks after an asynchronous answer (files, translation) without moving the selection.
    func refreshKeepingSelection() {
        let keep = selection
        refreshKeepingFiles()
        selection = min(keep, max(0, flat.count - 1))
    }

    /// Best match first, then each kind of result together, capped per kind.
    private func arrange(_ ranked: [AppCommand]) -> [LauncherSection] {
        guard let best = ranked.first else { return [] }
        var out = [LauncherSection(id: "best", title: "Meilleur résultat", items: [best])]
        var byGroup: [CommandSection: [AppCommand]] = [:]
        for c in ranked.dropFirst() { byGroup[c.group, default: []].append(c) }
        let caps: [CommandSection: Int] = [.apps: 6, .files: 12, .emoji: 24, .settings: 4, .web: 2]
        for g in CommandSection.allCases {
            guard let items = byGroup[g], !items.isEmpty else { continue }
            out.append(LauncherSection(id: "\(g.rawValue)", title: g.title, items: Array(items.prefix(caps[g] ?? 5))))
        }
        return out
    }

    /// The file window with nothing typed: the favourite files and folders, then the files opened lately.
    private func fileSuggestions() -> [LauncherSection] {
        let favorites = favoriteCommands().filter { $0.group == .files }
        let shown = Set(favorites.compactMap(Self.filePath(of:)))
        let recent = recentFiles.filter { !shown.contains($0.path) }.map { r -> AppCommand in
            fileKinds[r.path] = r.isDir
            return fileCommand(r.path, isDir: r.isDir, boost: 0)
        }
        var out: [LauncherSection] = []
        if !favorites.isEmpty { out.append(LauncherSection(id: "favorites", title: "Favoris", items: favorites)) }
        if !recent.isEmpty { out.append(LauncherSection(id: "recent", title: "Ouverts récemment", items: recent)) }
        return out
    }

    /// The files opened lately (Spotlight), for the file window's first screen. Only once the user allowed reading
    /// their files (Full Disk Access or the instant index): the preview of one would make macOS ask otherwise.
    private func loadRecentFiles() {
        if DemoData.isEnabled {
            recentFiles = LauncherDemoFiles.recent
            return
        }
        stopSpotlight(recentQuery)
        recentQuery = nil
        if let recentObserver { NotificationCenter.default.removeObserver(recentObserver) }
        guard !Snapshot.isActive, let app, app.fullDiskAccess || indexConsent else { recentFiles = []; return }
        let mq = NSMetadataQuery()
        let since = Date().addingTimeInterval(-30 * 86_400) as NSDate
        mq.predicate = NSPredicate(format: "kMDItemLastUsedDate >= %@ AND NOT (kMDItemContentType == 'com.apple.application-bundle') AND NOT (kMDItemContentType == 'public.folder')", since)
        mq.searchScopes = [NSMetadataQueryUserHomeScope]
        mq.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        // Gathered and sorted on the Spotlight queue: a month of files never weighs on the main thread.
        mq.operationQueue = spotlightQueue
        let ref = LauncherQueryRef(mq)
        recentObserver = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: mq, queue: nil) { [weak self] _ in
            guard let mq = ref.query else { return }
            mq.stop()
            var found: [LauncherSpotlightHit] = []
            for i in 0..<min(mq.resultCount, 80) where found.count < 12 {
                guard let item = mq.result(at: i) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String, Self.isUserFile(path) else { continue }
                found.append(LauncherSpotlightHit(path: path, isDir: false))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let current = self.recentQuery, current === ref.query else { return }
                    self.recentFiles = found.map { ($0.path, $0.isDir) }
                    if self.isOpen, self.scope == .files, self.query.isEmpty { self.refreshKeepingSelection() }
                }
            }
        }
        recentQuery = mq
        spotlightQueue.addOperation { ref.query?.start() }
    }

    /// A query is only touched from its own queue.
    private func stopSpotlight(_ mq: NSMetadataQuery?) {
        guard let mq else { return }
        // Kept until stopped, so that it also goes away on its own queue.
        let ref = LauncherQueryRef(mq, keep: true)
        spotlightQueue.addOperation { ref.query?.stop() }
    }

    private func suggestions() -> [LauncherSection] {
        let favorites = favoriteCommands()
        let skip = Set(hiddenIDs + favorites.map(\.id))
        let shown = catalog.filter { !skip.contains($0.id) }
        let used = shown.filter { CommandRunner.frecency($0.id) > 0 }
            .sorted { CommandRunner.frecency($0.id) > CommandRunner.frecency($1.id) }
            .prefix(6)
        let picks = ["act_smart_scan", "open_wheel", "clip_search", "sys_darkmode", "sys_empty_trash", Self.filesCommandID]
        let defaults = picks.compactMap { id in shown.first { $0.id == id } }.filter { d in !used.contains { $0.id == d.id } }
        var out: [LauncherSection] = []
        if !favorites.isEmpty { out.append(LauncherSection(id: "favorites", title: "Favoris", items: favorites)) }
        if !used.isEmpty { out.append(LauncherSection(id: "recent", title: "Les plus utilisés", items: Array(used))) }
        out.append(LauncherSection(id: "ideas", title: "Suggestions", items: Array(defaults.prefix(6 - min(used.count, 3)))))
        return out
    }

    /// The favourites still there: an app or a command of the catalogue, a file or a folder that was not moved.
    private func favoriteCommands() -> [AppCommand] {
        favoriteItems.compactMap { f in
            guard let path = f.path else { return catalog.first { $0.id == f.id } }
            guard DemoData.isEnabled || !missingFavorites.contains(path) else { return nil }
            fileKinds[path] = f.isDir
            return fileCommand(path, isDir: f.isDir, boost: 0)
        }
    }

    /// Looks for the favourite files and folders off the main thread, once per opening.
    private func checkFavorites() {
        let paths = favoriteItems.compactMap(\.path)
        guard !paths.isEmpty, !DemoData.isEnabled, !Snapshot.isActive else { return }
        Task {
            guard let missing = await DiskQueue.read({ Set(paths.filter { !FS.exists($0) }) }), missing != missingFavorites else { return }
            missingFavorites = missing
            if isOpen, query.trimmingCharacters(in: .whitespaces).isEmpty { refreshKeepingSelection() }
        }
    }

    // MARK: Files

    /// "dans facture edf": only Spotlight, which looks inside the files too (the index is not asked).
    static let contentPrefixes = ["dans ", "in "]

    /// Not hidden, not in ~/Library (Mail, caches…), except iCloud Drive.
    nonisolated static func isUserFile(_ path: String, home: String = FS.home) -> Bool {
        let library = home + "/Library/"
        return !path.contains("/.") && (!path.hasPrefix(library) || path.hasPrefix(library + "Mobile Documents/"))
    }

    /// The files whose text has a word starting with each typed word: "siret" finds "SIRET :" (a word cut at its start
    /// would take Spotlight thirty times longer).
    nonisolated static func contentPredicate(_ text: String) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: text.split(separator: " ").map {
            NSPredicate(format: "kMDItemTextContent BEGINSWITH[cd] %@", String($0))
        })
    }

    func isPathQuery(_ q: String) -> Bool {
        q.hasPrefix("/") || q.hasPrefix("~/") || q == "~"
    }

    func isContentQuery(_ q: String) -> Bool {
        Self.contentPrefixes.contains { q.lowercased().hasPrefix($0) }
    }

    /// The content of the folder being typed, filtered by the last part (on the file queue for a real folder).
    nonisolated static func folderRows(_ q: String, demo: Bool) -> LauncherFolderRows {
        let expanded = FS.expand(q)
        let dir: String, partial: String
        if expanded.hasSuffix("/") || q == "~" {
            dir = q == "~" ? FS.home : String(expanded.dropLast())
            partial = ""
        } else {
            dir = (expanded as NSString).deletingLastPathComponent
            partial = (expanded as NSString).lastPathComponent
        }
        let folder = dir.isEmpty ? "/" : dir
        // The demo browses its fictional files, never this Mac's.
        var entries: [(name: String, isDir: Bool?)] = []
        if demo {
            let demoDirs = Set(LauncherDemoFiles.paths.filter(\.isDir).map(\.path))
            entries = LauncherDemoFiles.paths.map(\.path).filter { ($0 as NSString).deletingLastPathComponent == folder }
                .map { (($0 as NSString).lastPathComponent, demoDirs.contains($0)) }
        } else {
            // One read of the folder with what each entry is (no stat per entry).
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys)
            else { return LauncherFolderRows(dir: dir, rows: []) }
            entries = urls.map { url in
                let v = try? url.resourceValues(forKeys: Set(keys))
                // A link is followed below, only if it is kept.
                return (url.lastPathComponent, v?.isSymbolicLink == true ? nil : v?.isDirectory == true)
            }
        }
        let wanted = Fuzzy.fold(partial)
        var rows: [(name: String, lower: String, isDir: Bool, score: Int)] = []
        for e in entries where partial.hasPrefix(".") || !e.name.hasPrefix(".") {
            let score: Int
            if wanted.isEmpty {
                score = 1
            } else {
                let folded = Fuzzy.fold(e.name)
                score = folded.hasPrefix(wanted) ? 2 : (folded.contains(wanted) ? 1 : 0)
            }
            guard score > 0 else { continue }
            let isDir = e.isDir ?? FS.isDirectory((dir == "/" ? "" : dir) + "/" + e.name)
            rows.append((e.name, e.name.lowercased(), isDir, score))
        }
        rows.sort { ($0.score, $0.isDir ? 1 : 0, $1.lower) > ($1.score, $1.isDir ? 1 : 0, $0.lower) }
        return LauncherFolderRows(dir: dir, rows: rows.prefix(40).map { ($0.name, $0.isDir) })
    }

    /// Spotlight, a moment after the last keystroke: the files that hold the words, and their names too while the index
    /// is not ready (`namesToo`).
    private func scheduleFileSearch(_ q: String, namesToo: Bool) {
        fileWork?.cancel()
        let prefix = Self.contentPrefixes.first { q.lowercased().hasPrefix($0) }
        let text = prefix.map { String(q.dropFirst($0.count)).trimmingCharacters(in: .whitespaces) } ?? q
        // Three letters at least: fewer would ask Spotlight for nearly every file (and their content).
        guard text.count >= 3, !DemoData.isEnabled, !q.hasPrefix(":") else {
            if namesToo, !fileResults.isEmpty { fileResults = [] }
            if DemoData.isEnabled, text.count >= 3 {
                contentResults = LauncherDemoFiles.containing(text).enumerated().map { i, path in
                    fileKinds[path] = false
                    return fileCommand(path, isDir: false, boost: 600 - Double(i) * 5)
                }
            }
            fileSearchPending = false
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.searchSpotlight(text, query: q, namesToo: namesToo) }
        }
        fileWork = work
        fileSearchPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func searchSpotlight(_ text: String, query q: String, namesToo: Bool) {
        stopSpotlight(fileQuery)
        if let fileObserver { NotificationCenter.default.removeObserver(fileObserver) }
        let mq = NSMetadataQuery()
        let content = Self.contentPredicate(text)
        let wanted = namesToo
            ? NSCompoundPredicate(orPredicateWithSubpredicates: [content, NSPredicate(format: "kMDItemDisplayName CONTAINS[cd] %@", text)])
            : content
        mq.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            wanted, NSPredicate(format: "NOT (kMDItemContentType == 'com.apple.application-bundle')")
        ])
        mq.searchScopes = [NSMetadataQueryUserHomeScope]
        mq.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        // Gathered and sorted on the Spotlight queue: thousands of matches never weigh on the main thread.
        mq.operationQueue = spotlightQueue
        let ref = LauncherQueryRef(mq)
        fileObserver = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: mq, queue: nil) { [weak self] _ in
            guard let mq = ref.query else { return }
            mq.stop()
            let folded = Fuzzy.fold(text)
            var named: [LauncherSpotlightHit] = [], inside: [LauncherSpotlightHit] = []
            for i in 0..<min(mq.resultCount, 300) where named.count + inside.count < 30 {
                guard let item = mq.result(at: i) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                let hit = LauncherSpotlightHit(path: path, isDir: (item.value(forAttribute: "kMDItemContentType") as? String) == "public.folder")
                if namesToo, Fuzzy.fold((path as NSString).lastPathComponent).contains(folded) {
                    named.append(hit)
                } else if Self.isUserFile(path) {
                    // The text of mails and caches would bury the user's documents.
                    inside.append(hit)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let current = self.fileQuery, current === ref.query,
                          self.query.trimmingCharacters(in: .whitespaces) == q else { return }
                    @MainActor func commands(_ hits: [LauncherSpotlightHit], _ boost: Double) -> [AppCommand] {
                        hits.enumerated().map { i, hit in
                            self.fileKinds[hit.path] = hit.isDir
                            return self.fileCommand(hit.path, isDir: hit.isDir, boost: boost - Double(i) * 5)
                        }
                    }
                    if namesToo {
                        self.fileResults = commands(named, 300)
                        self.fileResultsQuery = q
                    }
                    self.contentResults = commands(inside, 600)
                    self.contentResultsQuery = q
                    self.fileSearchPending = false
                    self.refreshKeepingSelection()
                }
            }
        }
        fileQuery = mq
        spotlightQueue.addOperation { ref.query?.start() }
    }

    /// Re-ranks with the latest file results, without starting a new file search.
    private func refreshKeepingFiles() {
        keepFileSearch = true
        defer { keepFileSearch = false }
        refresh()
    }

    /// Stable id per path (FNV-1a), so that the files opened often come first next time.
    static func fileID(_ path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in path.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return "file_" + String(hash, radix: 16)
    }

    private func fileCommand(_ path: String, isDir: Bool, boost: Double) -> AppCommand {
        let name = (path as NSString).lastPathComponent
        // In the file window ⌘↩ picks the file (⌘R shows it in the Finder); in the launcher it shows it in the Finder.
        let hint = isDir ? "Ouvrir · ⇥ Entrer" : scope == .files ? "Ouvrir · ⌘↩ Sélectionner" : "Ouvrir · ⌘ Afficher"
        return AppCommand(id: Self.fileID(path), title: name, subtitle: FS.pretty((path as NSString).deletingLastPathComponent),
                          icon: .file(path), group: .files, hint: hint, boost: boost) { ctx in
            if ctx.alternate { Finder.reveal(path) } else { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            return .done
        }
    }
}

/// A command of the catalogue with its texts folded once: its title, then its keywords and subtitle.
struct LauncherSearchable {
    struct Texts {
        let title: Fuzzy.Prepared
        let keywords: [Fuzzy.Prepared]

        init(_ command: AppCommand) {
            title = Fuzzy.Prepared(command.title)
            keywords = (command.keywords + [command.subtitle ?? ""]).filter { !$0.isEmpty }.map(Fuzzy.Prepared.init)
        }
    }

    let command: AppCommand
    let texts: Texts

    var title: Fuzzy.Prepared { texts.title }
    var keywords: [Fuzzy.Prepared] { texts.keywords }

    /// What the folded texts depend on.
    static func key(_ c: AppCommand) -> String {
        ([c.id, c.title, c.subtitle ?? ""] + c.keywords).joined(separator: "\u{1}")
    }
}

/// A folder of the file window, read on its queue: the entries kept, best first.
struct LauncherFolderRows: Sendable {
    let dir: String
    let rows: [(name: String, isDir: Bool)]
}

/// A number shared with the file queue: each new text takes the next one, and only the latest answer is shown.
final class LauncherTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func isCurrent(_ ticket: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == ticket
    }
}

/// A file found by Spotlight, handed from its queue to the main thread.
struct LauncherSpotlightHit: Sendable {
    let path: String
    let isDir: Bool
}

/// A Spotlight query handed to its queue, where alone it is touched once started.
final class LauncherQueryRef: @unchecked Sendable {
    weak var query: NSMetadataQuery?
    private let kept: NSMetadataQuery?

    init(_ query: NSMetadataQuery, keep: Bool = false) {
        self.query = query
        kept = keep ? query : nil
    }
}
