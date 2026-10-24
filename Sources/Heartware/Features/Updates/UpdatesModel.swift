import SwiftUI
import AppKit

enum UpdatesState: Equatable {
    case idle, checking, done(Date), failed(String)

    var isChecking: Bool { self == .checking }
    var date: Date? {
        if case .done(let d) = self { return d }
        return nil
    }
}

/// A Homebrew command running (or just finished), with its live output.
struct UpdatesBrewJob: Equatable {
    enum Outcome: Equatable { case running, succeeded, failed(Int32), cancelled }

    var title: String
    var ids: Set<String>
    var lines: [String] = []
    var outcome: Outcome = .running
    var started = Date()

    var isRunning: Bool { outcome == .running }
}

struct UpdatesSettings: Codable {
    /// `brew outdated --greedy`: also list casks whose app updates itself.
    var greedy = false
}

@Observable
@MainActor
final class UpdatesModel: AppModule {
    // Homebrew
    var brewPath: String? = DemoData.isEnabled ? nil : Shell.which("brew")
    var brewPackages: [UpdatesBrewPackage] = []
    var brewState: UpdatesState = .idle
    var brewJob: UpdatesBrewJob?
    var greedy: Bool {
        didSet { settings.value.greedy = greedy }
    }

    // Sparkle and App Store
    var sparkleApps: [UpdatesApp] = []
    var storeApps: [UpdatesApp] = []
    var sparkleWithoutFeed = 0
    var inventoryLoaded = false
    var sparkleState: UpdatesState = .idle
    var storeState: UpdatesState = .idle

    // macOS
    var macOS: SecurityCheck?
    var macOSState: UpdatesState = .idle

    /// Heartware itself: the versions published on GitHub.
    let selfUpdate = UpdatesSelfModel()

    @ObservationIgnored private let settings = JSONStore<UpdatesSettings>("updates", default: UpdatesSettings())
    @ObservationIgnored private var brewCancel: CancelFlag?
    /// Homebrew packages updated (how many), told once the batch succeeded.
    @ObservationIgnored var onUpgraded: (Int) -> Void = { _ in }
    /// Casks whose upgrade stopped on a password prompt: kept "à faire dans le Terminal" after the next check.
    @ObservationIgnored private var passwordCasks = Set<String>()
    @ObservationIgnored private var inventoryTask: Task<Void, Never>?

    init() {
        greedy = settings.value.greedy
        // Real-data snapshots render before any task runs: list the apps now (local files only).
        if Snapshot.isActive && !DemoData.isEnabled {
            let scan = UpdatesInventory.scan()
            sparkleApps = scan.sparkle
            storeApps = scan.store
            sparkleWithoutFeed = scan.sparkleWithoutFeed
            inventoryLoaded = true
        }
    }

    // MARK: Counts

    var brewOutdated: [UpdatesBrewPackage] { brewPackages.filter { !$0.pinned } }
    /// What "Tout mettre à jour" upgrades (no pins, no casks that need a password).
    var brewUpgradable: [UpdatesBrewPackage] { brewPackages.filter { !$0.pinned && !$0.needsPassword } }
    var brewManual: [UpdatesBrewPackage] { brewPackages.filter { $0.needsPassword } }
    var sparkleAvailable: [UpdatesApp] { sparkleApps.filter { $0.result.release != nil } }
    var storeAvailable: [UpdatesApp] { storeApps.filter { $0.result.release != nil } }

    var macOSLabels: [String] {
        guard let c = macOS, c.status == .warn else { return [] }
        return c.detail.components(separatedBy: ", ").filter { !$0.isEmpty }
    }

    var totalAvailable: Int { brewOutdated.count + sparkleAvailable.count + storeAvailable.count + macOSLabels.count }
    var hasChecked: Bool { [brewState, sparkleState, storeState, macOSState].contains { $0.date != nil } }
    var isCheckingAnything: Bool { [brewState, sparkleState, storeState, macOSState].contains { $0.isChecking } }

    var sidebarBadge: String? {
        let n = totalAvailable + (selfUpdate.release != nil && !selfUpdate.isSkipped ? 1 : 0)
        return n > 0 ? "\(n)" : nil
    }

    // MARK: Inventory (local, no network)

    /// Lists the apps once; `force` reads them again (a check after an update must see the new versions).
    /// Concurrent calls share the same scan.
    func loadInventory(force: Bool = false) async {
        if DemoData.isEnabled || (inventoryLoaded && !force) { return }
        if let running = inventoryTask { return await running.value }
        let task = Task {
            let scan = await Task.detached(priority: .userInitiated) { UpdatesInventory.scan() }.value
            sparkleApps = Self.keepingResults(scan.sparkle, from: sparkleApps)
            storeApps = Self.keepingResults(scan.store, from: storeApps)
            sparkleWithoutFeed = scan.sparkleWithoutFeed
            inventoryLoaded = true
        }
        inventoryTask = task
        await task.value
        inventoryTask = nil
    }

    /// A new listing keeps the last answer of the apps whose version did not change (until the check replaces it);
    /// an app updated in the meantime starts again unchecked.
    private static func keepingResults(_ fresh: [UpdatesApp], from old: [UpdatesApp]) -> [UpdatesApp] {
        let previous = Dictionary(old.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return fresh.map { app in
            guard let p = previous[app.path], p.version == app.version, p.build == app.build, p.feedURL == app.feedURL else { return app }
            var a = app
            a.result = p.result
            return a
        }
    }

    // MARK: Checks (each one only after a click)

    func checkAll() async {
        async let a: Void = checkBrew()
        async let d: Void = checkMacOS()
        async let e: Void = selfUpdate.check(announce: false)
        // One fresh listing for both app sources.
        await loadInventory(force: true)
        async let b: Void = checkSparkle(reload: false)
        async let c: Void = checkStore(reload: false)
        _ = await (a, b, c, d, e)
    }

    func checkBrew() async {
        guard !DemoData.isEnabled, let brew = brewPath, !brewState.isChecking, !(brewJob?.isRunning ?? false) else { return }
        brewState = .checking
        let greedy = greedy
        ActionLog.write("HOMEBREW brew outdated\(greedy ? " --greedy" : "") (lecture seule)")
        let result = await Task.detached(priority: .userInitiated) { UpdatesBrew.outdated(brew: brew, greedy: greedy) }.value
        switch result {
        case .success(var list):
            for i in list.indices where list[i].isCask && passwordCasks.contains(list[i].name) { list[i].needsPassword = true }
            brewPackages = list
            brewState = .done(Date())
        case .failure(let f):
            brewState = .failed(f.message)
        }
    }

    /// `reload`: lists the apps again first, so that an app updated since the last check shows its new version.
    func checkSparkle(reload: Bool = true) async {
        guard !DemoData.isEnabled, !sparkleState.isChecking else { return }
        await loadInventory(force: reload)
        guard !sparkleState.isChecking, !sparkleApps.isEmpty else { return }
        sparkleState = .checking
        let os = UpdatesVersion.macOS
        let results = await Self.concurrently(sparkleApps, limit: 6) { await UpdatesSparkle.check($0, os: os) }
        apply(results, to: \.sparkleApps)
        sparkleState = Self.allFailed(results) ? .failed("Aucun flux joignable") : .done(Date())
    }

    func checkStore(reload: Bool = true) async {
        guard !DemoData.isEnabled, !storeState.isChecking else { return }
        await loadInventory(force: reload)
        guard !storeState.isChecking, !storeApps.isEmpty else { return }
        storeState = .checking
        let results = await Self.concurrently(storeApps, limit: 4) { await UpdatesAppStore.check($0) }
        apply(results, to: \.storeApps)
        storeState = Self.allFailed(results) ? .failed("L'App Store n'a pas répondu") : .done(Date())
    }

    /// Not a single answer (offline, typically): the source failed, it is not "up to date".
    static func allFailed(_ results: [String: UpdatesResult]) -> Bool {
        !results.isEmpty && results.values.allSatisfy { if case .failed = $0 { return true } else { return false } }
    }

    func checkMacOS() async {
        guard !DemoData.isEnabled, !macOSState.isChecking else { return }
        macOSState = .checking
        let check = await Task.detached(priority: .utility) { SecurityAudit.pendingUpdates() }.value
        macOS = check
        macOSState = check.status == .unknown ? .failed(check.detail) : .done(Date())
    }

    private func apply(_ results: [String: UpdatesResult], to list: ReferenceWritableKeyPath<UpdatesModel, [UpdatesApp]>) {
        for i in self[keyPath: list].indices {
            if let r = results[self[keyPath: list][i].path] { self[keyPath: list][i].result = r }
        }
    }

    /// Runs `work` on every app, `limit` at a time, off the main thread.
    nonisolated private static func concurrently(_ apps: [UpdatesApp], limit: Int,
                                                 _ work: @escaping @Sendable (UpdatesApp) async -> UpdatesResult) async -> [String: UpdatesResult] {
        await withTaskGroup(of: (String, UpdatesResult).self) { group in
            var next = 0
            var out: [String: UpdatesResult] = [:]
            func add() {
                let app = apps[next]
                next += 1
                group.addTask { (app.path, await work(app)) }
            }
            while next < min(limit, apps.count) { add() }
            for await (path, r) in group {
                out[path] = r
                if next < apps.count { add() }
            }
            return out
        }
    }

    // MARK: Homebrew jobs

    func refreshBrew() {
        runBrew([["update"]], title: "Mise à jour de la liste Homebrew (brew update)", ids: [])
    }

    func upgrade(_ p: UpdatesBrewPackage) {
        guard !p.needsPassword, !p.pinned else { return }
        let args = p.isCask ? ["upgrade", "--cask"] + (greedy ? ["--greedy"] : []) + [p.name] : ["upgrade", "--formula", p.name]
        runBrew([args], title: "Mise à jour de \(p.name)", ids: [p.id])
    }

    func upgradeAll() {
        let list = brewUpgradable
        let steps = UpdatesBrew.upgradeAllSteps(list, greedy: greedy)
        guard !steps.isEmpty else { return }
        runBrew(steps, title: "Mise à jour de \(Fmt.plural(list.count, "paquet", "paquets")) Homebrew", ids: Set(list.map(\.id)))
    }

    /// `Shell.stream` stops brew and what it launched (ruby, curl…), even during a silent download or build.
    func cancelBrew() {
        brewCancel?.cancel()
    }

    func dismissBrewJob() {
        if !(brewJob?.isRunning ?? false) { brewJob = nil }
    }

    /// Runs the steps one after the other, streaming their output. Stops at the first failure or on "Annuler".
    private func runBrew(_ steps: [[String]], title: String, ids: Set<String>) {
        guard !DemoData.isEnabled, let brew = brewPath, !(brewJob?.isRunning ?? false), !brewState.isChecking else { return }
        let cancel = CancelFlag()
        brewCancel = cancel
        brewJob = UpdatesBrewJob(title: title, ids: ids)
        let buffer = UpdatesLineBuffer { [weak self] lines in
            guard let self, self.brewJob != nil else { return }
            self.brewJob?.lines.append(contentsOf: lines)
            if let n = self.brewJob?.lines.count, n > 600 { self.brewJob?.lines.removeFirst(n - 600) }
        }
        ActionLog.write("HOMEBREW " + steps.map { "brew " + $0.joined(separator: " ") }.joined(separator: " ; "))
        Task {
            let status = await Task.detached(priority: .userInitiated) { () -> Int32 in
                var status: Int32 = 0
                for args in steps where !cancel.isCancelled {
                    buffer.append("$ brew " + args.joined(separator: " "))
                    let out = Shell.stream(brew, args, env: UpdatesBrew.environment, isCancelled: { cancel.isCancelled }) { line in
                        let l = UpdatesBrew.clean(line)
                        if !l.isEmpty { buffer.append(l) }
                    }
                    status = out.status
                    if status != 0 { break }
                }
                return status
            }.value
            buffer.flush()
            brewJob?.outcome = cancel.isCancelled ? .cancelled : (status == 0 ? .succeeded : .failed(status))
            if brewJob?.outcome == .succeeded { onUpgraded(ids.count) }
            // A cask of the batch asked for the password after all: once the list is read again, the casks still late
            // move to "À faire dans le Terminal" (the others of the batch did update).
            var askedPassword = Set<String>()
            if case .failed = brewJob?.outcome, let job = brewJob, UpdatesBrew.askedForPassword(job.lines) {
                askedPassword = Set(brewPackages.filter { $0.isCask && job.ids.contains($0.id) }.map(\.name))
                brewJob?.lines.append("→ Ce paquet demande ton mot de passe : lance la commande indiquée dans le Terminal.")
            }
            brewCancel = nil
            // Long upgrades: say when it is over if the user went elsewhere.
            if NSApp?.isActive != true, let outcome = brewJob?.outcome, outcome != .cancelled {
                Notifier.post(id: "updates-brew", title: "Homebrew",
                              body: outcome == .succeeded ? "\(title) : terminé." : "\(title) : échec. Le détail est dans Mises à jour.",
                              throttle: 0)
            }
            await checkBrew()
            if !askedPassword.isEmpty {
                let stillLate = Set(brewPackages.filter { $0.isCask && askedPassword.contains($0.name) }.map(\.name))
                passwordCasks.formUnion(stillLate)
                for i in brewPackages.indices where stillLate.contains(brewPackages[i].name) && brewPackages[i].isCask {
                    brewPackages[i].needsPassword = true
                }
            }
        }
    }

    // MARK: Apps

    func open(_ app: UpdatesApp) {
        guard !DemoData.isEnabled else { return HUD.show(DemoData.refusal) }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration())
    }

    func openLink(_ url: String?) {
        guard let url else { return }
        guard !DemoData.isEnabled else { return HUD.show(DemoData.refusal) }
        Finder.open(url)
    }

    // MARK: AppModule

    /// Heartware's own check: at launch, then every six hours (unless turned off).
    func start(app: AppModel) {
        selfUpdate.start(app: app)
    }

    func stop() {
        selfUpdate.stop()
    }

    func applySnapshotTab(_ tab: String) {
        selfUpdate.applySnapshotTab(tab)
        if tab == "attente" {
            sparkleState = .checking
            macOSState = .checking
        }
    }

    func loadDemo() {
        selfUpdate.loadDemo()
        let now = Date()
        brewPath = "/opt/homebrew/bin/brew"
        brewPackages = [
            UpdatesBrewPackage(name: "imagemagick", installed: "7.1.2-3", current: "7.1.2-5", isCask: false),
            UpdatesBrewPackage(name: "jq", installed: "1.8.0", current: "1.8.1", isCask: false),
            UpdatesBrewPackage(name: "postgresql@17", installed: "17.5", current: "17.6", isCask: false, pinned: true),
            UpdatesBrewPackage(name: "wget", installed: "1.25.0", current: "1.25.0_1", isCask: false),
            UpdatesBrewPackage(name: "boussole-vpn", installed: "2.14", current: "2.15.1", isCask: true, needsPassword: true),
            UpdatesBrewPackage(name: "nuage-drive", installed: "3.12", current: "3.13", isCask: true)
        ]
        brewState = .done(now.addingTimeInterval(-90))
        brewJob = UpdatesBrewJob(title: "Mise à jour de ripgrep", ids: [], lines: [
            "$ brew upgrade --formula ripgrep",
            "==> Upgrading 1 outdated package:",
            "ripgrep 14.1.1 -> 15.0.0",
            "==> Fetching downloads for: ripgrep",
            "✔︎ Bottle ripgrep (15.0.0)",
            "==> Pouring ripgrep--15.0.0.arm64_tahoe.bottle.tar.gz",
            "🍺  /opt/homebrew/Cellar/ripgrep/15.0.0: 15 files, 6.4MB",
            "==> Running `brew cleanup ripgrep`..."
        ], outcome: .succeeded, started: now.addingTimeInterval(-40))

        func app(_ name: String, _ id: String, _ version: String, build: String? = nil, feed: String? = nil,
                 _ result: UpdatesResult) -> UpdatesApp {
            UpdatesApp(path: "/Applications/\(name).app", name: name, bundleID: id, version: version, build: build ?? version,
                       feedURL: feed, result: result)
        }
        sparkleApps = [
            app("Cadence Studio", "net.cadence.studio", "11.0.3", feed: "https://cadence.example/appcast.xml",
                .available(UpdatesRelease(version: "11.1", notesURL: "https://cadence.example/notes/11.1",
                                          notes: "Nouvelle table de mixage, export en lot plus rapide et correction du métronome en 7/8.",
                                          date: now.addingTimeInterval(-3 * 86400)))),
            app("Lanterne", "com.lanterne.recorder", "3.1.2", feed: "https://lanterne.example/sparkle.xml",
                .available(UpdatesRelease(version: "3.2", notesURL: "https://lanterne.example/changelog",
                                          notes: "Enregistrement d'une seule fenêtre et sous-titres automatiques.",
                                          date: now.addingTimeInterval(-9 * 86400)))),
            app("Tisserand", "app.tisserand.mac", "2.9", feed: "https://tisserand.example/appcast.xml",
                .available(UpdatesRelease(version: "2.9.4", notes: "Corrections de stabilité.", date: now.addingTimeInterval(-1 * 86400)))),
            app("Fresque 3D", "com.fresque3d.Fresque", "4.8", feed: "https://fresque3d.example/feed.xml", .upToDate(latest: "4.8")),
            app("Rétro Arcade", "com.retroarcade.app", "2.3", feed: "https://retroarcade.example/appcast.xml", .upToDate(latest: "2.3")),
            app("Sonar Podcasts", "fr.sonar.podcasts", "2.6", feed: "https://sonar.example/appcast.xml", .upToDate(latest: "2.6")),
            app("Cartographe", "fr.cartographe.desktop", "7.1", feed: "http://cartographe.example/maj.xml",
                .failed("Flux en HTTP seulement (non vérifié)"))
        ]
        sparkleWithoutFeed = 3
        storeApps = [
            app("Pixelune", "com.pixelune.Pixelune", "3.8.2",
                .available(UpdatesRelease(version: "3.9", storeURL: "macappstore://apps.apple.com/app/id100000001",
                                          notes: "Retouche par calques et nouveaux filtres argentiques.", date: now.addingTimeInterval(-2 * 86400)))),
            app("Ardoise", "fr.ardoise.notes", "6.2",
                .available(UpdatesRelease(version: "6.3", storeURL: "macappstore://apps.apple.com/app/id100000002",
                                          notes: "Dossiers partagés et recherche dans les PDF.", date: now.addingTimeInterval(-6 * 86400)))),
            app("Keynote", "com.apple.iWork.Keynote", "14.4", .upToDate(latest: "14.4")),
            app("Plume", "fr.plume.editor", "4.0.1", .upToDate(latest: "4.0.1")),
            app("Zéphyr Météo", "fr.zephyr.meteo", "1.12", .upToDate(latest: "1.12")),
            app("Archiviste", "fr.archiviste.app", "4.6", .upToDate(latest: "4.6")),
            app("Carnet de bord", "fr.carnetdebord.app", "1.8", .upToDate(latest: "1.8"))
        ]
        inventoryLoaded = true
        sparkleState = .done(now.addingTimeInterval(-80))
        storeState = .done(now.addingTimeInterval(-80))
        macOS = SecurityAudit.pendingUpdates()
        macOSState = .done(now.addingTimeInterval(-75))
    }

    func commands(app: AppModel) -> [AppCommand] {
        var list: [AppCommand] = [
            AppCommand(id: "upd_check", title: "Vérifier les mises à jour",
                       subtitle: "Homebrew, apps Sparkle, App Store et macOS",
                       keywords: ["mises à jour", "mise à jour", "update", "maj", "upgrade", "versions", "vérifier"],
                       icon: .symbol("arrow.down.circle", Theme.good), group: .actions, assistantSafe: true) { ctx in
                ctx.app.page = .updates
                AppContext.showMainWindow()
                Task { await ctx.app.updates.checkAll() }
                return .message("Recherche des mises à jour…")
            },
            AppCommand(id: "upd_macos", title: "Ouvrir Mise à jour de logiciels", subtitle: "Réglages Système",
                       keywords: ["macos", "software update", "système", "mise à jour"],
                       icon: .symbol("apple.logo", Theme.text2), group: .actions, assistantSafe: true) { _ in
                Finder.open(SettingsPane.updates)
                return .done
            },
            AppCommand(id: "upd_appstore", title: "Mises à jour de l'App Store", keywords: ["app store", "mas", "mise à jour"],
                       icon: .symbol("bag", Theme.accent), group: .actions, assistantSafe: true) { _ in
                Finder.open("macappstore://showUpdatesPage")
                return .done
            }
        ]
        list += selfUpdate.commands()
        if brewPath != nil {
            let pending = brewUpgradable
            let detail = brewState.date == nil
                ? "Homebrew vérifie d'abord ce qui est en retard, puis met tout à jour."
                : (pending.isEmpty ? "Rien à mettre à jour pour le moment." : "\(Fmt.plural(pending.count, "paquet sera mis", "paquets seront mis")) à jour : \(pending.prefix(6).map(\.name).joined(separator: ", "))\(pending.count > 6 ? "…" : "").")
            list += [
                AppCommand(id: "upd_brew_upgrade_all", title: "Tout mettre à jour avec Homebrew", subtitle: "brew upgrade",
                           keywords: ["brew", "homebrew", "upgrade", "mise à jour"], icon: .symbol("mug", Theme.warn), group: .actions,
                           risk: .confirm(detail + " Les casks qui demandent un mot de passe restent à faire dans le Terminal.")) { ctx in
                    let m = ctx.app.updates
                    ctx.app.page = .updates
                    AppContext.showMainWindow()
                    guard !DemoData.isEnabled else { return .message(DemoData.refusal) }
                    if m.brewJob?.isRunning == true { return .failed("Homebrew est déjà au travail : attends la fin de la commande en cours.") }
                    if m.brewState.isChecking { return .failed("Homebrew vérifie encore ce qui est en retard : réessaie dans un instant.") }
                    if m.brewState.date == nil { await m.checkBrew() }
                    if case .failed(let why) = m.brewState { return .failed(why) }
                    guard !m.brewUpgradable.isEmpty else {
                        return .message(m.brewManual.isEmpty ? "Rien à mettre à jour avec Homebrew : tout est à jour."
                                                             : "Rien à lancer ici : le reste est à faire dans le Terminal.")
                    }
                    m.upgradeAll()
                    return m.brewJob?.isRunning == true ? .message("Homebrew se met au travail…")
                                                        : .failed("Homebrew n'a pas pu démarrer.")
                },
                AppCommand(id: "upd_brew_update", title: "Rafraîchir Homebrew", subtitle: "brew update",
                           keywords: ["brew", "homebrew", "update"], icon: .symbol("arrow.clockwise", Theme.warn), group: .actions,
                           assistantSafe: true) { ctx in
                    ctx.app.page = .updates
                    AppContext.showMainWindow()
                    ctx.app.updates.refreshBrew()
                    return .done
                }
            ]
        }
        return list
    }

    /// Known updates matching what is typed ("ripgrep", "lanterne"…). In memory only.
    func results(for query: String, app: AppModel) -> [AppCommand] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3, totalAvailable > 0 else { return [] }
        var out: [AppCommand] = []
        for (i, p) in brewUpgradable.enumerated() where Fuzzy.score(q, in: p.name, subsequence: false) != nil {
            out.append(AppCommand(id: "upd_brew_\(i)", title: "Mettre à jour \(p.name)", subtitle: "Homebrew · \(p.installed) → \(p.current)",
                                  icon: .symbol("mug", Theme.warn), group: .actions, risk: .confirm("Homebrew va lancer « \(p.command) »."),
                                  hint: "Mettre à jour", boost: 120) { ctx in
                ctx.app.updates.upgrade(p)
                return .message("Mise à jour de \(p.name)…")
            })
        }
        for (i, a) in (sparkleAvailable + storeAvailable).enumerated() where Fuzzy.score(q, in: a.name, subsequence: false) != nil {
            guard let r = a.result.release else { continue }
            let store = r.storeURL != nil
            out.append(AppCommand(id: "upd_app_\(i)", title: store ? "Mettre à jour \(a.name) dans l'App Store" : "Ouvrir \(a.name) pour la mettre à jour",
                                  subtitle: "\(a.version) → \(r.version)", icon: .file(a.path), group: .actions,
                                  hint: store ? "App Store" : "Ouvrir", boost: 120) { ctx in
                if let s = r.storeURL { ctx.app.updates.openLink(s) } else { ctx.app.updates.open(a) }
                return .done
            })
        }
        return out
    }

    func selfTest() -> [String] {
        var f = UpdatesSelfModel.selfTest()
        let order: [(String, String, ComparisonResult)] = [
            ("1.0", "1.1", .orderedAscending), ("1.10", "1.9", .orderedDescending), ("1.0", "1.0.0", .orderedSame),
            ("2.0.1", "2.0", .orderedDescending), ("1.0b1", "1.0", .orderedAscending), ("1.0a2", "1.0b1", .orderedAscending),
            ("115", "112", .orderedDescending), ("26.3.0.39832", "26.2.0.39821", .orderedDescending), ("3.8.2", "3.8.2", .orderedSame),
            ("1.25.0_1", "1.25.0", .orderedDescending), ("12345678901234567890", "12345678901234567891", .orderedAscending),
            ("2024.10", "2024.9.30", .orderedDescending), ("v2", "v10", .orderedAscending),
            // A pre-release after separators or zeros is still older than the release.
            ("1.0", "1.0.0b1", .orderedDescending), ("1.0.0b1", "1.0", .orderedAscending), ("1.0", "1.0-beta", .orderedDescending),
            ("1.0-beta", "1.0", .orderedAscending), ("2.1", "2.1.0.0.1", .orderedAscending), ("3.0.0-rc.1", "3.0", .orderedAscending),
            ("1.0.0.1", "1.0", .orderedDescending)
        ]
        for (a, b, expected) in order where UpdatesVersion.compare(a, b) != expected {
            f.append("Versions : \(a) contre \(b) donne \(UpdatesVersion.compare(a, b).rawValue), attendu \(expected.rawValue)")
        }

        // Offline: every answer failed, the source is in failure rather than "up to date".
        let late = UpdatesResult.available(UpdatesRelease(version: "2.0"))
        if !Self.allFailed(["/a": .failed("Flux injoignable"), "/b": .failed("Flux injoignable")]) { f.append("Échec de toutes les sources non repéré") }
        if Self.allFailed(["/a": .failed("Flux injoignable"), "/b": .upToDate(latest: nil)]) || Self.allFailed([:]) {
            f.append("Une source en partie joignable passe pour un échec")
        }
        // Listing the apps again keeps the answers of the unchanged apps only.
        let before = [UpdatesApp(path: "/A.app", name: "A", bundleID: "a", version: "1.0", build: "1", result: late),
                      UpdatesApp(path: "/B.app", name: "B", bundleID: "b", version: "1.0", build: "1", result: late)]
        let after = Self.keepingResults([UpdatesApp(path: "/A.app", name: "A", bundleID: "a", version: "1.0", build: "1"),
                                         UpdatesApp(path: "/B.app", name: "B", bundleID: "b", version: "2.0", build: "2")], from: before)
        if after.first?.result != late || after.last?.result != .unchecked || after.last?.version != "2.0" {
            f.append("Inventaire relu : une app mise à jour garde son ancienne réponse")
        }

        // A made-up appcast mixing Sparkle 1 (attributes) and Sparkle 2 (elements), a beta, a too recent macOS and deltas.
        let feed = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <title>Exemple</title>
            <item>
              <title>Version 3.0 bêta</title>
              <sparkle:channel>beta</sparkle:channel>
              <sparkle:version>300</sparkle:version>
              <sparkle:shortVersionString>3.0b1</sparkle:shortVersionString>
              <enclosure url="https://exemple.test/3.0b1.zip" length="1" type="application/octet-stream"/>
            </item>
            <item>
              <title>Version 2.6</title>
              <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
              <enclosure url="https://exemple.test/2.6.zip" sparkle:version="260" sparkle:shortVersionString="2.6"/>
            </item>
            <item>
              <title>Version 2.5</title>
              <pubDate>Tue, 07 Jul 2026 10:00:00 +0200</pubDate>
              <description><![CDATA[<ul><li>Plus <b>rapide</b> &amp; plus sûr</li></ul>]]></description>
              <sparkle:version>250</sparkle:version>
              <sparkle:shortVersionString>2.5</sparkle:shortVersionString>
              <sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion>
              <sparkle:releaseNotesLink xml:lang="en">https://exemple.test/en/2.5.html</sparkle:releaseNotesLink>
              <sparkle:releaseNotesLink xml:lang="fr">https://exemple.test/fr/2.5.html</sparkle:releaseNotesLink>
              <enclosure url="https://exemple.test/2.5.zip" length="1" type="application/octet-stream"/>
              <sparkle:deltas>
                <enclosure url="https://exemple.test/250-240.delta" sparkle:version="999" sparkle:deltaFrom="240"/>
              </sparkle:deltas>
            </item>
            <item>
              <title>Version 2.4</title>
              <enclosure url="https://exemple.test/2.4.zip" sparkle:version="240" sparkle:shortVersionString="2.4"/>
            </item>
          </channel>
        </rss>
        """
        if let items = UpdatesSparkle.parse(Data(feed.utf8)) {
            if items.count != 4 { f.append("Sparkle : \(items.count) entrées lues au lieu de 4") }
            if items.last?.version != "240" { f.append("Sparkle 1 : version en attribut d'enclosure non lue") }
            if items.first(where: { $0.title == "Version 2.5" })?.version != "250" { f.append("Sparkle : un delta a écrasé la version") }
            let best = UpdatesSparkle.best(items, os: "15.4.0")
            if best?.shortVersion != "2.5" { f.append("Sparkle : meilleure version \(best?.shortVersion ?? "aucune"), attendu 2.5 (bêta et macOS 99 exclus)") }
            if best?.releaseNotesLink != "https://exemple.test/fr/2.5.html" { f.append("Sparkle : notes en français non choisies") }
            if best?.pubDate == nil { f.append("Sparkle : date de publication non lue") }
            let installed = UpdatesApp(path: "/Applications/Exemple.app", name: "Exemple", bundleID: "test.exemple", version: "2.4", build: "240")
            switch UpdatesSparkle.result(for: installed, best: best) {
            case .available(let r):
                if r.version != "2.5" { f.append("Sparkle : version proposée \(r.version)") }
                if r.notes != "Plus rapide & plus sûr" { f.append("Sparkle : notes mal nettoyées « \(r.notes ?? "") »") }
            default: f.append("Sparkle : la 2.5 n'est pas proposée à une 2.4")
            }
            let current = UpdatesApp(path: "/Applications/Exemple.app", name: "Exemple", bundleID: nil, version: "2.5", build: "250")
            if UpdatesSparkle.result(for: current, best: best).release != nil { f.append("Sparkle : mise à jour proposée à une app déjà à jour") }
        } else {
            f.append("Sparkle : flux d'exemple illisible")
        }
        if UpdatesSparkle.parse(Data("<html><body>404</body></html>".utf8)) != nil { f.append("Sparkle : une page HTML passe pour un flux") }

        let outdated = """
        {"formulae":[{"name":"jq","installed_versions":["1.7.1"],"current_version":"1.8.1","pinned":false,"pinned_version":null},
        {"name":"node@22","installed_versions":["22.1.0"],"current_version":"22.2.0","pinned":true,"pinned_version":"22.1.0"}],
        "casks":[{"name":"exemple-vpn","installed_versions":["2.0"],"current_version":"2.1"}]}
        """
        let pkgs = UpdatesBrew.parseOutdated(Data(outdated.utf8)) ?? []
        if pkgs.count != 3 || pkgs.first?.current != "1.8.1" || pkgs.filter(\.pinned).count != 1 || pkgs.filter(\.isCask).count != 1 {
            f.append("Homebrew : sortie de brew outdated mal lue (\(pkgs.count) paquets)")
        }
        let info = #"{"casks":[{"token":"exemple-vpn","auto_updates":true,"artifacts":[{"uninstall":[{"pkgutil":"test.vpn"}]},{"pkg":["Exemple.pkg"]}]},{"token":"exemple-app","artifacts":[{"app":["Exemple.app"]}]}]}"#
        let flags = UpdatesBrew.parseCaskInfo(Data(info.utf8))
        if flags.password != ["exemple-vpn"] || flags.autoUpdates != ["exemple-vpn"] { f.append("Homebrew : casks à mot de passe mal repérés") }
        var withPassword = pkgs
        if let i = withPassword.firstIndex(where: \.isCask) { withPassword[i].needsPassword = true }
        if UpdatesBrew.upgradeAllSteps(withPassword, greedy: false) != [["upgrade", "--formula", "jq"]] {
            f.append("Homebrew : « Tout mettre à jour » inclut une formule épinglée ou un cask à mot de passe")
        }
        if UpdatesBrew.clean("\u{1B}[34m==>\u{1B}[0m Pouring\r######  50%\r###### 100%") != "###### 100%" { f.append("Homebrew : nettoyage de la sortie") }
        if !UpdatesBrew.askedForPassword(["==> Installing Cask exemple", "sudo: a terminal is required to read the password; either use the -S option"]) {
            f.append("Homebrew : demande de mot de passe non repérée")
        }

        let lookup = #"{"resultCount":1,"results":[{"version":"6.3","trackId":123456,"releaseNotes":"Correctifs","currentVersionReleaseDate":"2026-09-01T07:00:00Z"}]}"#
        if let i = UpdatesAppStore.parseLookup(Data(lookup.utf8)) {
            let a = UpdatesApp(path: "/Applications/A.app", name: "A", bundleID: "a", version: "6.2", build: "1")
            if UpdatesAppStore.result(for: a, info: i).release?.storeURL != "macappstore://apps.apple.com/app/id123456" {
                f.append("App Store : lien vers la page de l'app")
            }
            if i.date == nil { f.append("App Store : date de version non lue") }
        } else {
            f.append("App Store : réponse de recherche illisible")
        }
        if UpdatesAppStore.parseLookup(Data(#"{"resultCount":0,"results":[]}"#.utf8)) != nil { f.append("App Store : app absente mal gérée") }
        // A universal purchase: the listing gives the iPhone version, which says nothing about the Mac app.
        let universal = #"{"resultCount":1,"results":[{"kind":"software","version":"4.2","trackId":7}]}"#
        let ios = UpdatesAppStore.parseLookup(Data(universal.utf8))
        let mac = UpdatesApp(path: "/Applications/B.app", name: "B", bundleID: "b", version: "1.1", build: "1")
        if case .unknown = UpdatesAppStore.result(for: mac, info: ios) {} else { f.append("App Store : achat universel comparé à la version iPhone") }
        let aligned = UpdatesApp(path: "/Applications/D.app", name: "D", bundleID: "d", version: "4.1", build: "1")
        if UpdatesAppStore.result(for: aligned, info: ios).release?.version != "4.2" { f.append("App Store : achat universel à numérotation commune") }
        let sameBuild = UpdatesApp(path: "/Applications/C.app", name: "C", bundleID: nil, version: "1.6.0", build: "6413")
        let newBuild = UpdatesFeedItem(version: "6575", shortVersion: "1.6.0")
        if UpdatesSparkle.result(for: sameBuild, best: newBuild).release?.version != "1.6.0 (6575)" { f.append("Sparkle : build plus récent à version identique") }
        return f
    }

    func dump() -> [String] {
        var lines = selfUpdate.dump()
        let brew = brewPath
        lines.append("Homebrew : \(brew ?? "non installé")")
        if let brew, !DemoData.isEnabled {
            switch UpdatesBrew.outdated(brew: brew, greedy: greedy) {
            case .success(let list):
                lines.append("  \(Fmt.plural(list.count, "paquet en retard", "paquets en retard"))")
                for p in list.prefix(12) {
                    lines.append("    \(p.isCask ? "cask" : "formule") \(p.name) \(p.installed) → \(p.current)\(p.pinned ? " (épinglée)" : "")\(p.needsPassword ? " (mot de passe)" : "")")
                }
            case .failure(let e): lines.append("  \(e.message)")
            }
        } else {
            for p in brewPackages { lines.append("    \(p.name) \(p.installed) → \(p.current)") }
        }
        let inv = DemoData.isEnabled ? (sparkleApps, storeApps, sparkleWithoutFeed) : UpdatesInventory.scan()
        lines.append("Apps Sparkle avec flux : \(inv.0.count) · sans flux public : \(inv.2)")
        for a in inv.0 { lines.append("    \(a.name) \(a.version) (\(a.build ?? "?")) — \(a.feedURL ?? "")") }
        lines.append("Apps de l'App Store : \(inv.1.count)")
        for a in inv.1 { lines.append("    \(a.name) \(a.version) — \(a.bundleID ?? "")") }
        lines.append("(les flux et l'App Store ne sont interrogés que sur un clic dans l'app)")
        return lines
    }
}
