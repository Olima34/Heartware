import SwiftUI
import AppKit
import CryptoKit

enum AutomationKind: String, Codable, CaseIterable, Identifiable {
    case cleanup, trash, downloads, health

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleanup: return "Nettoyage planifié"
        case .trash: return "Corbeille"
        case .downloads: return "Rangement des Téléchargements"
        case .health: return "Historique de santé"
        }
    }

    var symbol: String {
        switch self {
        case .cleanup: return "sparkles"
        case .trash: return "trash"
        case .downloads: return "tray.and.arrow.down"
        case .health: return "waveform.path.ecg"
        }
    }

    /// Journal line when the user turns it on or off.
    func switched(on: Bool) -> String {
        switch self {
        case .cleanup: return on ? "Nettoyage planifié activé" : "Nettoyage planifié désactivé"
        case .trash: return on ? "Règle de la Corbeille activée" : "Règle de la Corbeille désactivée"
        case .downloads: return on ? "Rangement des Téléchargements activé" : "Rangement des Téléchargements désactivé"
        case .health: return on ? "Historique de santé activé" : "Historique de santé désactivé"
        }
    }

    var tint: Color {
        switch self {
        case .cleanup: return Theme.accent
        case .trash: return Theme.palette[5]
        case .downloads: return Theme.warn
        case .health: return Theme.good
        }
    }
}

enum AutomationTab: String, CaseIterable, Identifiable {
    case rules, downloads, health, journal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rules: return "Règles"
        case .downloads: return "Téléchargements"
        case .health: return "Santé"
        case .journal: return "Journal"
        }
    }
}

/// Everything is off until the user turns it on, after a dry run.
struct AutomationSettings: Codable, Equatable {
    var cleanupEnabled = false
    var cleanupFrequency: AutomationFrequency = .weekly
    var cleanupLastRun: Date?
    var trashEnabled = false
    var trashDays = 30
    var trashLastRun: Date?
    var downloadsEnabled = false
    var downloadsFrequency: AutomationFrequency = .hourly
    /// Empty: ~/Downloads.
    var downloadsFolder = ""
    var downloadsLastRun: Date?
    var rules: [AutomationRule] = AutomationRule.defaults
    var healthEnabled = false
    var notify = true

    init() {}

    /// Tolerant reading: a field added later never resets the others.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AutomationSettings()
        cleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? d.cleanupEnabled
        cleanupFrequency = (try? c.decodeIfPresent(AutomationFrequency.self, forKey: .cleanupFrequency)) ?? d.cleanupFrequency
        cleanupLastRun = try c.decodeIfPresent(Date.self, forKey: .cleanupLastRun)
        trashEnabled = try c.decodeIfPresent(Bool.self, forKey: .trashEnabled) ?? d.trashEnabled
        trashDays = try c.decodeIfPresent(Int.self, forKey: .trashDays) ?? d.trashDays
        trashLastRun = try c.decodeIfPresent(Date.self, forKey: .trashLastRun)
        downloadsEnabled = try c.decodeIfPresent(Bool.self, forKey: .downloadsEnabled) ?? d.downloadsEnabled
        downloadsFrequency = (try? c.decodeIfPresent(AutomationFrequency.self, forKey: .downloadsFrequency)) ?? d.downloadsFrequency
        downloadsFolder = try c.decodeIfPresent(String.self, forKey: .downloadsFolder) ?? d.downloadsFolder
        downloadsLastRun = try c.decodeIfPresent(Date.self, forKey: .downloadsLastRun)
        rules = try c.decodeIfPresent([AutomationRule].self, forKey: .rules) ?? d.rules
        healthEnabled = try c.decodeIfPresent(Bool.self, forKey: .healthEnabled) ?? d.healthEnabled
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? d.notify
    }
}

/// One line of the automations' journal.
struct AutomationLogEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var kind: AutomationKind
    var automatic: Bool
    var title: String
    var detail: String
    var bytes: Int64 = 0
    var failures = 0
    /// A switch turned on or off rather than a run (optional: older journals lack it).
    var setting: Bool?
}

struct AutomationTrashPreview {
    /// Items old enough, or nil when the Trash cannot be read (no Full Disk Access).
    var expired: [AutomationTrash.Item]?
    var total: Int
}

struct AutomationDownloadsPreview {
    var moves: [AutomationMove]
    /// The folder could not be read (macOS asks for access to Downloads).
    var unreadable = false
    var files = 0
}

@Observable
@MainActor
final class AutomationModel: AppModule {
    static let jobID = "automation"
    static let trashInterval: TimeInterval = 86400

    var tab: AutomationTab = .rules
    var settings: AutomationSettings {
        didSet { settingsChanged(from: oldValue) }
    }
    var journal: [AutomationLogEntry] {
        didSet { journalStore.value = journal }
    }
    var samples: [AutomationHealthSample] {
        didSet { healthStore.value = samples }
    }
    var range: AutomationHealthRange = .month

    /// The dry run shown before turning an automation on.
    var pending: AutomationKind?
    /// Dry runs opened on automations that are already on.
    var shownPreviews: Set<AutomationKind> = []
    /// A dry run or a run in progress.
    var busy: Set<AutomationKind> = []
    var cleanupPreview: [AutomationCleanupPlan.Line]?
    var trashPreview: AutomationTrashPreview?
    var downloadsPreview: AutomationDownloadsPreview?
    var editingRule: UUID?
    /// The settings did not match their seal at launch: the automations were turned off (shown on the page).
    var integrityNotice: String?

    static let settingsName = "automation"
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let settingsStore = JSONStore<AutomationSettings>(settingsName, default: AutomationSettings())
    @ObservationIgnored private let sealStore = JSONStore<AutomationSealRecord>("automation-seal", default: AutomationSealRecord())
    @ObservationIgnored private let journalStore = JSONStore<[AutomationLogEntry]>("automation-journal", default: [])
    @ObservationIgnored private let healthStore = JSONStore<[AutomationHealthSample]>("automation-health", default: [])
    @ObservationIgnored private var previewWork: DispatchWorkItem?
    /// Set once the settings were checked at launch: from then on every change is sealed.
    @ObservationIgnored private var sealing = false
    @ObservationIgnored private var sealKey: SymmetricKey?
    /// The launch check of the seal is reading the keychain; a seal asked for meanwhile waits for it.
    @ObservationIgnored private var verifying = false
    @ObservationIgnored private var resealAfterCheck = false

    init() {
        // Whatever the file says, only values the page could have set.
        settings = settingsStore.value.sanitized()
        journal = journalStore.value
        samples = healthStore.value
    }

    private func settingsChanged(from old: AutomationSettings) {
        settingsStore.value = settings
        reseal()
        if Self.anyActive(settings) != Self.anyActive(old) { updateSchedule() }
        if (settings.rules != old.rules || settings.downloadsFolder != old.downloadsFolder) && downloadsPreview != nil {
            // Keep the dry run in step with the rules being edited.
            previewWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.preview(.downloads) }
                }
            }
            previewWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    // MARK: State

    func isEnabled(_ k: AutomationKind) -> Bool {
        switch k {
        case .cleanup: return settings.cleanupEnabled
        case .trash: return settings.trashEnabled
        case .downloads: return settings.downloadsEnabled
        case .health: return settings.healthEnabled
        }
    }

    func lastRun(_ k: AutomationKind) -> Date? {
        switch k {
        case .cleanup: return settings.cleanupLastRun
        case .trash: return settings.trashLastRun
        case .downloads: return settings.downloadsLastRun
        case .health: return samples.last?.day
        }
    }

    func interval(_ k: AutomationKind) -> TimeInterval {
        switch k {
        case .cleanup: return settings.cleanupFrequency.interval
        case .trash, .health: return Self.trashInterval
        case .downloads: return settings.downloadsFrequency.interval
        }
    }

    func nextRun(_ k: AutomationKind, now: Date = Date()) -> Date? {
        guard isEnabled(k) else { return nil }
        return AutomationSchedule.next(last: lastRun(k), every: interval(k), now: now)
    }

    var activeCount: Int { AutomationKind.allCases.filter(isEnabled).count }

    var downloadsFolder: String {
        settings.downloadsFolder.isEmpty ? AutomationDownloads.defaultFolder : FS.expand(settings.downloadsFolder)
    }

    var sidebarBadge: String? {
        activeCount > 0 ? Fmt.plural(activeCount, "active", "actives") : nil
    }

    // MARK: Module

    func start(app: AppModel) {
        self.app = app
        checkIntegrity()
        // While the seal is being checked nothing is scheduled: `verify` does it once the settings are known to be ours.
        if !verifying { updateSchedule() }
    }

    /// A light check every quarter of an hour, only while an automation is on (each one decides whether it is due);
    /// nothing at all otherwise. Called again whenever one is turned on or off.
    private func updateSchedule() {
        guard app != nil else { return }
        if Self.anyActive(settings) {
            Scheduler.shared.register(Self.jobID, every: 900) { [weak self] in
                await self?.tick()
            }
        } else {
            Scheduler.shared.unregister(Self.jobID)
        }
    }

    /// Seconds since the last keyboard, mouse or trackpad event, from any app.
    static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    static func anyActive(_ s: AutomationSettings) -> Bool {
        s.cleanupEnabled || s.trashEnabled || s.downloadsEnabled || s.healthEnabled
    }

    func stop() {
        Scheduler.shared.unregister(Self.jobID)
        // The settings and their seal go together: a seal behind its file turns the automations off at the next launch.
        settingsStore.flush()
        sealStore.flush()
    }

    // MARK: Seal

    /// At launch (real app only): automation.json must be the one the app wrote last (`AutomationSeal`).
    /// Never changed (no file): the defaults, all off, nothing to check.
    private func checkIntegrity() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        sealing = true
        guard let raw = try? Data(contentsOf: DataStore.url(Self.settingsName + ".json")) else { return }
        // Nothing runs on its own: nothing to protect, and the keychain is left alone (with an ad hoc signature, macOS
        // would ask for it again after every update). A file switched on behind the app's back is checked next launch.
        guard settings.cleanupEnabled || settings.trashEnabled || settings.downloadsEnabled else { return }
        // First launch of a version with seals (no seal, no key yet): the settings, already brought back within what
        // the page offers, are sealed as they are, so an update does not switch off what the user set up.
        // The keychain is read away from the main thread: right after a login it can take seconds, and macOS may ask
        // the user first. Nothing is scheduled meanwhile (however long the question waits for an answer); a seal asked
        // for meanwhile is written once the check is done.
        verifying = true
        let unsealed = sealStore.value.mac.isEmpty
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> (exists: Bool, key: SymmetricKey?) in
                (Keychain.exists(AutomationSeal.keyAccount), AutomationSeal.key(create: false))
            }.value
            verify(raw: raw, unsealed: unsealed, keyExists: found.exists, key: found.key)
        }
    }

    private func verify(raw: Data, unsealed: Bool, keyExists: Bool, key: SymmetricKey?) {
        verifying = false
        defer {
            if resealAfterCheck {
                resealAfterCheck = false
                reseal()
            }
            updateSchedule()
        }
        if unsealed, !keyExists {
            settingsStore.value = settings
            reseal()
            return
        }
        if let key, AutomationSeal.isValid(sealStore.value.mac, for: raw, key: key) {
            sealKey = key
            // A folder that became a symbolic link since, for instance.
            if settings != settingsStore.value {
                settingsStore.value = settings
                reseal()
            }
            return
        }
        resealAfterCheck = false
        lockdown()
    }

    /// The settings were changed outside the app (or the keychain refused the key): nothing runs on its own any more.
    private func lockdown() {
        let wereOn = [AutomationKind.cleanup, .trash, .downloads].filter(isEnabled)
        settings.cleanupEnabled = false
        settings.trashEnabled = false
        settings.downloadsEnabled = false
        settings.downloadsFolder = ""
        for k in wereOn {
            log(k, automatic: true, title: k.switched(on: false),
                detail: "Réglages modifiés hors de Heartware : réactive-la après un aperçu à blanc.", setting: true)
        }
        integrityNotice = "Heartware n'a pas pu vérifier que les réglages des automatisations viennent de lui : ils ont été modifiés en dehors de l'app. Par prudence, le nettoyage planifié, la Corbeille et le rangement sont coupés, et le dossier surveillé est revenu à Téléchargements. Relis tes règles, puis réactive ce que tu veux après un aperçu à blanc."
    }

    /// Seals what is about to be written (the key is made the first time).
    private func reseal() {
        guard sealing, !DemoData.isEnabled else { return }
        guard !verifying else {
            resealAfterCheck = true
            return
        }
        if sealKey == nil { sealKey = AutomationSeal.key(create: true) }
        guard let key = sealKey, let data = AutomationSeal.bytes(settings) else { return }
        sealStore.value = AutomationSealRecord(mac: AutomationSeal.mac(data, key: key))
    }

    func loadDemo() {
        let now = Date()
        settings = AutomationDemo.settings(now: now)
        journal = AutomationDemo.journal(now: now)
        samples = AutomationDemo.samples(now: now)
        range = .quarter
        cleanupPreview = AutomationCleanupPlan.lines(DemoData.cleanupTargets())
        trashPreview = AutomationTrashPreview(expired: AutomationTrash.expired(AutomationDemo.trashItems(now: now), days: settings.trashDays, now: now),
                                              total: AutomationDemo.trashItems(now: now).count)
        pending = .trash
        let files = AutomationDemo.downloadFiles(now: now)
        downloadsPreview = AutomationDownloadsPreview(
            moves: AutomationDownloads.plan(files, rules: settings.rules, source: downloadsFolder, now: now), files: files.count)
    }

    func applySnapshotTab(_ tab: String) {
        if let t = AutomationTab(rawValue: tab) { self.tab = t }
        // `--tab alerte`: the rules as they look after settings changed outside the app.
        if tab == "alerte", DemoData.isEnabled {
            lockdown()
            self.tab = .rules
        }
    }

    /// Runs whatever is due. Called by the `Scheduler`.
    func tick() async {
        guard let app, !DemoData.isEnabled else { return }
        let now = Date()
        // The day's health reading measures the junk too (a whole scan): only once the user has left the Mac alone for
        // two minutes, never while they work or just after it wakes up. Else at a later check of the day.
        if settings.healthEnabled, AutomationHealth.needsSample(samples, now: now), Self.idleSeconds() > 120 {
            await recordHealth(app: app)
        }
        if settings.cleanupEnabled, AutomationSchedule.isDue(last: settings.cleanupLastRun, every: interval(.cleanup), now: now) {
            _ = await runCleanup(app: app, automatic: true)
        }
        if settings.trashEnabled, AutomationSchedule.isDue(last: settings.trashLastRun, every: interval(.trash), now: now) {
            _ = await runTrash(automatic: true)
        }
        if settings.downloadsEnabled, AutomationSchedule.isDue(last: settings.downloadsLastRun, every: interval(.downloads), now: now) {
            _ = await runDownloads(automatic: true)
        }
    }

    // MARK: Turning on and off

    /// Shows the dry run; the automation starts only after `confirm`.
    func beginActivation(_ k: AutomationKind) {
        pending = k
        Task { await preview(k) }
    }

    func confirmActivation(_ k: AutomationKind) {
        pending = nil
        let now = Date()
        switch k {
        case .cleanup:
            settings.cleanupEnabled = true
            settings.cleanupLastRun = settings.cleanupLastRun ?? now
        case .trash:
            settings.trashEnabled = true
            settings.trashLastRun = settings.trashLastRun ?? now
        case .downloads:
            settings.downloadsEnabled = true
            settings.downloadsLastRun = settings.downloadsLastRun ?? now
        case .health:
            settings.healthEnabled = true
        }
        if settings.notify { Notifier.requestPermission() }
        let next = nextRun(k).map { " Prochain passage le \(Fmt.day($0)) vers \(Fmt.clock($0))." } ?? ""
        log(k, automatic: false, title: k.switched(on: true), detail: k == .health ? "Un instantané par jour." : "Après un aperçu à blanc.\(next)",
            setting: true)
    }

    func deactivate(_ k: AutomationKind) {
        if pending == k { pending = nil }
        shownPreviews.remove(k)
        switch k {
        case .cleanup: settings.cleanupEnabled = false
        case .trash: settings.trashEnabled = false
        case .downloads: settings.downloadsEnabled = false
        case .health: settings.healthEnabled = false
        }
        log(k, automatic: false, title: k.switched(on: false), detail: "Plus rien ne se fera tout seul.", setting: true)
    }

    func setHealthEnabled(_ on: Bool, app: AppModel) {
        if on {
            confirmActivation(.health)
            if AutomationHealth.needsSample(samples, now: Date()) { Task { await recordHealth(app: app) } }
        } else {
            deactivate(.health)
        }
    }

    func togglePreview(_ k: AutomationKind) {
        if shownPreviews.contains(k) {
            shownPreviews.remove(k)
        } else {
            shownPreviews.insert(k)
            Task { await preview(k) }
        }
    }

    // MARK: Dry runs

    /// Computes what `k` would do now, without touching anything.
    func preview(_ k: AutomationKind) async {
        guard !busy.contains(k) else { return }
        busy.insert(k)
        defer { busy.remove(k) }
        let now = Date()
        switch k {
        case .cleanup:
            let running = RunningApps.snapshot()
            let targets = await Task.detached(priority: .userInitiated) { CleanupScanner.scan(running: running) }.value
            cleanupPreview = AutomationCleanupPlan.lines(targets)
        case .trash:
            let days = settings.trashDays
            if DemoData.isEnabled {
                let items = AutomationDemo.trashItems(now: now)
                trashPreview = AutomationTrashPreview(expired: AutomationTrash.expired(items, days: days, now: now), total: items.count)
                return
            }
            let items = await Task.detached(priority: .userInitiated) { AutomationTrash.list() }.value
            trashPreview = AutomationTrashPreview(expired: items.map { AutomationTrash.expired($0, days: days, now: now) }, total: items?.count ?? 0)
        case .downloads:
            let rules = settings.rules, folder = downloadsFolder
            guard AutomationDownloads.isAllowedSource(folder) else {
                downloadsPreview = AutomationDownloadsPreview(moves: [], unreadable: true)
                return
            }
            let files: [AutomationFile]?
            if DemoData.isEnabled {
                files = AutomationDemo.downloadFiles(now: now)
            } else {
                files = await Task.detached(priority: .userInitiated) { AutomationDownloads.list(folder) }.value
            }
            guard let files else {
                downloadsPreview = AutomationDownloadsPreview(moves: [], unreadable: true)
                return
            }
            downloadsPreview = AutomationDownloadsPreview(moves: AutomationDownloads.plan(files, rules: rules, source: folder, now: now),
                                                          files: files.count)
        case .health:
            break
        }
    }

    /// After a run: recomputes the dry run on screen, or forgets the stale one.
    private func refreshPreview(_ k: AutomationKind) async {
        if pending == k || shownPreviews.contains(k) || (k == .downloads && downloadsPreview != nil) {
            await preview(k)
        } else {
            switch k {
            case .cleanup: cleanupPreview = nil
            case .trash: trashPreview = nil
            case .downloads: downloadsPreview = nil
            case .health: break
            }
        }
    }

    // MARK: Runs

    /// The Cleanup page's default selection, minus the Trash and personal files.
    func runCleanup(app: AppModel, automatic: Bool) async -> CommandOutcome {
        guard !DemoData.isEnabled else { return .message(DemoData.refusal) }
        let c = app.cleanup
        guard !c.isScanning, !c.isCleaning, !busy.contains(.cleanup) else { return .failed("Un nettoyage est déjà en cours.") }
        // Never under the user's nose: if they are reviewing the Cleanup page, try again later.
        if automatic && NSApp.isActive && app.page == .cleanup { return .done }
        busy.insert(.cleanup)
        await c.scan()
        let plan = AutomationCleanupPlan.selection(c.targets)
        settings.cleanupLastRun = Date()
        guard !plan.isEmpty else {
            busy.remove(.cleanup)
            log(.cleanup, automatic: automatic, title: "Nettoyage : rien à faire", detail: "Ton Mac était déjà propre.")
            return .message("Rien à nettoyer : ton Mac est déjà propre.")
        }
        c.selection = plan
        let report = await c.clean()
        busy.remove(.cleanup)
        await refreshPreview(.cleanup)
        log(.cleanup, automatic: automatic, title: "Nettoyage sans risque", detail: report.summary, bytes: report.freed, failures: report.failures.count)
        if automatic { notify(.cleanup, title: "Nettoyage automatique terminé", body: report.summary) }
        return .message(report.summary)
    }

    /// Deletes for good what has been in the Trash for more than `trashDays` days.
    func runTrash(automatic: Bool) async -> CommandOutcome {
        guard !DemoData.isEnabled else { return .message(DemoData.refusal) }
        guard !busy.contains(.trash) else { return .failed("La Corbeille est déjà en cours de tri.") }
        guard !Preferences.alwaysTrash else {
            return .failed("Ton réglage « Toujours passer par la Corbeille » interdit les suppressions définitives : cette règle est en pause.")
        }
        busy.insert(.trash)
        let days = settings.trashDays
        let (report, readable) = await Task.detached(priority: .utility) { () -> (RemovalReport, Bool) in
            guard let items = AutomationTrash.list() else { return (RemovalReport(), false) }
            let old = AutomationTrash.expired(items, days: days, now: Date())
            return (old.isEmpty ? RemovalReport() : AutomationTrash.empty(old), true)
        }.value
        busy.remove(.trash)
        settings.trashLastRun = Date()
        guard readable else {
            logFailure(.trash, automatic: automatic, title: "Corbeille illisible", detail: "Accorde l'accès complet au disque pour que cette règle fonctionne.")
            return .failed("La Corbeille est illisible sans l'accès complet au disque.")
        }
        await refreshPreview(.trash)
        app?.monitor.sampleDisk()
        if report.removed == 0 && report.failures.isEmpty {
            if !automatic { log(.trash, automatic: false, title: "Corbeille : rien d'ancien", detail: "Aucun élément n'y dort depuis plus de \(days) jours.") }
            return .message("Rien n'est dans la Corbeille depuis plus de \(days) jours.")
        }
        let detail = "\(Fmt.plural(report.removed, "élément supprimé", "éléments supprimés")) (plus de \(days) j), \(Fmt.bytes(report.freed)) libérés."
            + (report.failures.isEmpty ? "" : " \(report.failures.count) en échec.")
        log(.trash, automatic: automatic, title: "Corbeille allégée", detail: detail, bytes: report.freed, failures: report.failures.count)
        app?.history.record(report.freed)
        if automatic { notify(.trash, title: "Corbeille allégée", body: detail) }
        return .message(detail)
    }

    /// Applies the active rules to the watched folder.
    func runDownloads(automatic: Bool) async -> CommandOutcome {
        guard !DemoData.isEnabled else { return .message(DemoData.refusal) }
        let rules = settings.rules.filter { $0.enabled && !$0.isIncomplete }
        guard !rules.isEmpty else { return .failed("Aucune règle active : règle-les dans Automatisations › Téléchargements.") }
        guard !busy.contains(.downloads) else { return .failed("Le rangement est déjà en cours.") }
        let folder = downloadsFolder
        guard AutomationDownloads.isAllowedSource(folder) else {
            return .failed("Le dossier surveillé doit se trouver dans ton dossier personnel, hors Bibliothèque.")
        }
        busy.insert(.downloads)
        let result = await Task.detached(priority: .utility) { () -> AutomationRunResult? in
            guard let files = AutomationDownloads.list(folder) else { return nil }
            return AutomationDownloads.execute(AutomationDownloads.plan(files, rules: rules, source: folder, now: Date()))
        }.value
        busy.remove(.downloads)
        settings.downloadsLastRun = Date()
        guard let result else {
            logFailure(.downloads, automatic: automatic, title: "Dossier illisible", detail: "macOS refuse l'accès à \(FS.pretty(folder)).")
            return .failed("Impossible de lire \(FS.pretty(folder)).")
        }
        await refreshPreview(.downloads)
        let done = result.moved + result.trashed
        // Quiet hours stay out of the journal: only runs that did something are kept.
        if done > 0 || !result.failures.isEmpty || !automatic {
            log(.downloads, automatic: automatic, title: "Téléchargements rangés", detail: result.summary,
                bytes: result.bytes, failures: result.failures.count)
        }
        if automatic && done > 0 { notify(.downloads, title: "Téléchargements rangés", body: result.summary) }
        return result.failures.isEmpty ? .message(result.summary) : .failed(result.summary)
    }

    /// Today's snapshot (replaces an earlier one of the same day).
    func recordHealth(app: AppModel) async {
        guard !busy.contains(.health) else { return }
        busy.insert(.health)
        defer { busy.remove(.health) }
        let m = app.monitor
        m.refresh()
        var junk: Int64?
        if let scanned = app.cleanup.lastScan, Date().timeIntervalSince(scanned) < 86400 {
            junk = app.cleanup.recommendedSize
        } else if !DemoData.isEnabled {
            // At background priority (slow processor cores, disk reads after everyone else's): the user is away anyway.
            let running = RunningApps.snapshot()
            junk = await Task.detached(priority: .background) { () -> Int64 in
                CleanupScanner.scan(running: running).flatMap { $0.cleanable.filter(\.defaultOn) }.reduce(0) { $0 + $1.size }
            }.value
        }
        let sample = AutomationHealthSample(day: Calendar.current.startOfDay(for: Date()), diskFree: m.diskFree, diskTotal: m.diskTotal,
                                            memoryUsed: m.memFraction, batteryHealth: m.battery?.health,
                                            batteryCycles: m.battery?.cycleCount, score: app.healthScore, junk: junk)
        samples = AutomationHealth.recording(sample, into: samples)
    }

    // MARK: Rules

    func addRule() {
        var rule = AutomationRule(name: "Nouvelle règle", kinds: [.videos], minAgeDays: 7, action: .move, destination: "~/Movies/Téléchargements")
        rule.enabled = true
        settings.rules.append(rule)
        editingRule = rule.id
    }

    func deleteRule(_ id: UUID) {
        settings.rules.removeAll { $0.id == id }
        if editingRule == id { editingRule = nil }
    }

    func moveRule(_ id: UUID, by delta: Int) {
        guard let i = settings.rules.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard settings.rules.indices.contains(j) else { return }
        settings.rules.swapAt(i, j)
    }

    func binding(for id: UUID) -> Binding<AutomationRule>? {
        guard let rule = settings.rules.first(where: { $0.id == id }) else { return nil }
        return Binding(get: { [weak self] in self?.settings.rules.first { $0.id == id } ?? rule },
                       set: { [weak self] new in
                           guard let self, let i = self.settings.rules.firstIndex(where: { $0.id == id }) else { return }
                           self.settings.rules[i] = new
                       })
    }

    // MARK: Journal

    func log(_ k: AutomationKind, automatic: Bool, title: String, detail: String, bytes: Int64 = 0, failures: Int = 0, setting: Bool? = nil) {
        journal.insert(AutomationLogEntry(date: Date(), kind: k, automatic: automatic, title: title, detail: detail,
                                          bytes: bytes, failures: failures, setting: setting), at: 0)
        if journal.count > 80 { journal.removeLast(journal.count - 80) }
    }

    /// A failure: the scheduler does not write it again while it is still the latest line of the journal.
    private func logFailure(_ k: AutomationKind, automatic: Bool, title: String, detail: String) {
        if automatic, let last = journal.first, last.kind == k, last.title == title, last.detail == detail { return }
        log(k, automatic: automatic, title: title, detail: detail, failures: 1)
    }

    func clearJournal() { journal = [] }

    private func notify(_ k: AutomationKind, title: String, body: String) {
        guard settings.notify else { return }
        Notifier.post(id: "auto_" + k.rawValue, title: title, body: body, throttle: 60)
    }

    /// Bytes moved, trashed or freed by the automations over the last `days` days.
    func handled(days: Int, now: Date = Date()) -> Int64 {
        let since = now.addingTimeInterval(-Double(days) * 86400)
        return journal.filter { $0.date >= since }.reduce(0) { $0 + $1.bytes }
    }

    // MARK: Launcher

    func commands(app: AppModel) -> [AppCommand] {
        let days = settings.trashDays
        return [
            AppCommand(id: "auto_tidy_downloads", title: "Ranger mes téléchargements maintenant",
                       subtitle: "Avec les règles actives de la page Automatisations",
                       keywords: ["ranger", "trier", "téléchargements", "downloads", "automatisation"],
                       icon: .symbol("tray.and.arrow.down", Theme.warn), group: .actions,
                       risk: .confirm("Les fichiers de ton dossier Téléchargements qui correspondent à tes règles actives seront déplacés ou mis à la Corbeille. Rien n'est supprimé définitivement.")) { ctx in
                await ctx.app.automation.runDownloads(automatic: false)
            },
            AppCommand(id: "auto_preview_downloads", title: "Aperçu du rangement des téléchargements",
                       subtitle: "Ce que tes règles feraient, sans rien toucher",
                       keywords: ["aperçu", "ranger", "téléchargements", "règles"],
                       icon: .symbol("eye", Theme.warn), group: .actions, assistantSafe: true, urlSafe: true) { ctx in
                ctx.app.automation.open(.downloads, app: ctx.app)
                await ctx.app.automation.preview(.downloads)
                return .done
            },
            AppCommand(id: "auto_open_health", title: "Ouvrir l'historique de santé",
                       subtitle: "Espace libre, mémoire, batterie et score au fil des jours",
                       keywords: ["santé", "historique", "graphique", "batterie", "évolution"],
                       icon: .symbol("waveform.path.ecg", Theme.good), group: .actions, assistantSafe: true, urlSafe: true) { ctx in
                ctx.app.automation.open(.health, app: ctx.app)
                return .done
            },
            AppCommand(id: "auto_health_snapshot", title: "Noter l'état de santé du jour",
                       subtitle: "Ajoute un point à l'historique de santé",
                       keywords: ["santé", "instantané", "historique", "mesurer"],
                       icon: .symbol("camera.metering.center.weighted", Theme.good), group: .actions, assistantSafe: true) { ctx in
                await ctx.app.automation.recordHealth(app: ctx.app)
                return .message("État de santé noté : \(ctx.app.healthScore)/100.")
            },
            AppCommand(id: "auto_trash_old", title: "Supprimer les éléments anciens de la Corbeille",
                       subtitle: "Mis à la Corbeille il y a plus de \(days) jours",
                       keywords: ["corbeille", "trash", "anciens", "vider"],
                       icon: .symbol("trash", Theme.palette[5]), group: .actions,
                       risk: .confirm("Les éléments mis à la Corbeille il y a plus de \(days) jours seront supprimés définitivement. Les plus récents restent récupérables.")) { ctx in
                await ctx.app.automation.runTrash(automatic: false)
            },
            AppCommand(id: "auto_cleanup_now", title: "Lancer le nettoyage sans risque",
                       subtitle: "Caches et journaux cochés par défaut, sans toucher à la Corbeille",
                       keywords: ["nettoyage", "caches", "planifié", "automatique"],
                       icon: .symbol("sparkles", Theme.accent), group: .actions,
                       risk: .confirm("Heartware va analyser puis supprimer les caches et journaux que la page Nettoyage coche par défaut. La Corbeille et tes fichiers personnels ne sont pas touchés.")) { ctx in
                await ctx.app.automation.runCleanup(app: ctx.app, automatic: false)
            }
        ]
    }

    func open(_ tab: AutomationTab, app: AppModel) {
        self.tab = tab
        app.page = .automation
        AppContext.showMainWindow()
    }

    // MARK: Checks

    func selfTest() -> [String] {
        var f: [String] = []
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func file(_ name: String, addedDaysAgo: Double, modifiedMinutesAgo: Double = 600_000, dir: Bool = false, package: Bool = false) -> AutomationFile {
            AutomationFile(path: "/tmp/test/" + name, name: name, size: 1000, added: now.addingTimeInterval(-addedDaysAgo * 86400),
                           modified: now.addingTimeInterval(-modifiedMinutesAgo * 60), isDirectory: dir, isPackage: package)
        }
        let installers = AutomationRule(name: "Installeurs", kinds: [.installers], minAgeDays: 7, action: .trash)
        let images = AutomationRule(name: "Images", kinds: [.images], extensions: ["torrent"], minAgeDays: 0, action: .move, destination: "/tmp/test/Images")
        let all = AutomationRule(name: "Tout PDF", kinds: [.documents], minAgeDays: 0, action: .trash)
        let rules = [installers, images, all]
        let cases: [(AutomationFile, String?)] = [
            (file("Setup-2.1.dmg", addedDaysAgo: 3), nil),                       // too recent for its rule
            (file("Setup-2.0.DMG", addedDaysAgo: 10), "Installeurs"),            // case-insensitive extension
            (file("photo.HEIC", addedDaysAgo: 0.5), "Images"),
            (file("film.mp4.crdownload", addedDaysAgo: 2), nil),                 // download in progress
            (file("archive.zip.part", addedDaysAgo: 2), nil),
            (file("scan.pdf", addedDaysAgo: 3, modifiedMinutesAgo: 4), nil),     // modified 4 minutes ago
            (file("tout-juste.png", addedDaysAgo: 5.0 / 1440), nil),             // arrived 5 minutes ago
            (file("linux.torrent", addedDaysAgo: 1), "Images"),                  // custom extension
            (file(".DS_Store", addedDaysAgo: 30), nil),
            (file("Projet", addedDaysAgo: 30, dir: true), nil),                  // plain folder
            (file("sans-extension", addedDaysAgo: 30), nil),
            (file("rapport.pdf", addedDaysAgo: 1), "Tout PDF")
        ]
        let plan = AutomationDownloads.plan(cases.map(\.0), rules: rules, source: "/tmp/test", now: now, home: "/tmp")
        for (fileCase, expected) in cases {
            let got = plan.first { $0.file.path == fileCase.path }?.ruleName
            if got != expected { f.append("règle pour « \(fileCase.name) » : \(got ?? "aucune"), attendu \(expected ?? "aucune")") }
        }
        if plan.first(where: { $0.file.name == "photo.HEIC" })?.destination != "/tmp/test/Images" { f.append("dossier de destination") }
        // Disabled rules, incomplete rules and moves into the watched folder itself are skipped.
        var off = images
        off.enabled = false
        if !AutomationDownloads.plan([file("a.png", addedDaysAgo: 2)], rules: [off], source: "/tmp/test", now: now, home: "/tmp").isEmpty { f.append("règle désactivée appliquée") }
        let noFolder = AutomationRule(name: "x", kinds: [.images], minAgeDays: 0, action: .move, destination: " ")
        if !AutomationDownloads.plan([file("a.png", addedDaysAgo: 2)], rules: [noFolder], source: "/tmp/test", now: now, home: "/tmp").isEmpty { f.append("règle sans dossier appliquée") }
        let same = AutomationRule(name: "x", kinds: [.images], minAgeDays: 0, action: .move, destination: "/tmp/test/")
        if !AutomationDownloads.plan([file("a.png", addedDaysAgo: 2)], rules: [same], source: "/tmp/test", now: now, home: "/tmp").isEmpty { f.append("déplacement vers le même dossier") }
        // First match wins.
        let order = AutomationDownloads.plan([file("doc.pdf", addedDaysAgo: 40)],
                                             rules: [AutomationRule(name: "A", kinds: [.documents], minAgeDays: 30, action: .trash), all],
                                             source: "/tmp/test", now: now, home: "/tmp")
        if order.first?.ruleName != "A" { f.append("la première règle doit l'emporter") }
        if AutomationRule.parseExtensions(".Torrent, epub;epub  mobi") != ["torrent", "epub", "mobi"] { f.append("lecture des extensions") }
        let home = "/Users/test"
        let sources: [(String, Bool)] = [(home + "/Downloads", true), (home + "/Desktop/Tri", true), (home, false), (home + "/", false),
                                         (home + "/Library/Caches", false), (home + "/.Trash", false), ("/Applications", false),
                                         (home + "/Downloads/../Library", false), ("/Users/other/Downloads", false)]
        for (path, ok) in sources where AutomationDownloads.isAllowedSource(path, home: home) != ok {
            f.append("dossier surveillé « \(path) » \(ok ? "refusé" : "accepté") à tort")
        }
        // A rule never moves files out of the home folder, into a hidden folder, ~/Library or a package.
        let destinations: [(String, Bool)] = [("~/Pictures/Téléchargements", true), (home + "/Documents/Tri", true), ("/tmp/vol", false),
                                              ("~/Library/Mail", false), ("~/.ssh", false), ("~/Documents/.cache/x", false),
                                              ("~/Pictures/Photos Library.photoslibrary/originals", false), ("~/Applications/Outil.app", false),
                                              ("~", false), ("~/../other/Downloads", false), ("/Users/other/Documents", false)]
        for (path, ok) in destinations where AutomationDownloads.isAllowedDestination(path, home: home) != ok {
            f.append("dossier de destination « \(path) » \(ok ? "refusé" : "accepté") à tort")
        }
        if !AutomationDownloads.plan([file("a.png", addedDaysAgo: 2)],
                                     rules: [AutomationRule(name: "x", kinds: [.images], minAgeDays: 0, action: .move, destination: "/var/tmp/x")],
                                     source: "/tmp/test", now: now, home: "/tmp").isEmpty {
            f.append("déplacement hors du dossier personnel appliqué")
        }
        // automation.json rewritten by another program: back within what the page offers.
        var forged = AutomationSettings()
        forged.trashDays = 0
        forged.downloadsFolder = "/tmp"
        forged.rules = [AutomationRule(name: "Vol", kinds: [.images], minAgeDays: -5, action: .move, destination: "/tmp/vol"),
                        AutomationRule(name: "Bon", kinds: [.images], minAgeDays: 1, action: .move, destination: "~/Pictures/Tri")]
        let clean = forged.sanitized(home: home)
        if clean.trashDays != 7 || clean.downloadsFolder != "" { f.append("réglages falsifiés : Corbeille \(clean.trashDays) j, dossier « \(clean.downloadsFolder) »") }
        if clean.rules.first?.enabled != false || clean.rules.first?.destination != "" || clean.rules.first?.minAgeDays != 0 {
            f.append("règle falsifiée gardée")
        }
        if clean.rules.last != forged.rules.last { f.append("règle valide modifiée par la vérification") }
        forged.trashDays = 9000
        if forged.sanitized(home: home).trashDays != 365 { f.append("durée de la Corbeille non bornée") }
        f += AutomationSeal.selfTest()

        // Trash age
        let trash = [AutomationTrash.Item(path: "/t/a", name: "a", size: 1, added: now.addingTimeInterval(-40 * 86400)),
                     AutomationTrash.Item(path: "/t/b", name: "b", size: 1, added: now.addingTimeInterval(-10 * 86400)),
                     AutomationTrash.Item(path: "/t/c", name: "c", size: 1, added: nil)]
        if AutomationTrash.expired(trash, days: 30, now: now).map(\.name) != ["a"] { f.append("éléments anciens de la Corbeille") }
        if AutomationTrash.expired(trash, days: 7, now: now).map(\.name) != ["a", "b"] { f.append("Corbeille à 7 jours") }

        // Schedules
        let week = AutomationFrequency.weekly.interval
        if AutomationSchedule.isDue(last: now.addingTimeInterval(-6 * 86400), every: week, now: now) { f.append("hebdomadaire lancé trop tôt") }
        if !AutomationSchedule.isDue(last: now.addingTimeInterval(-7 * 86400 + 60), every: week, now: now) { f.append("hebdomadaire en retard") }
        if !AutomationSchedule.isDue(last: nil, every: week, now: now) { f.append("jamais lancé : doit être dû") }
        if AutomationSchedule.next(last: now, every: 3600, now: now) != now.addingTimeInterval(3600) { f.append("prochain passage") }

        // The scheduled cleanup never takes the Trash nor what is unchecked by default
        let item = { (p: String, on: Bool) in CleanupItem(path: p, name: p, size: 100, defaultOn: on) }
        var caches = CleanupTarget(id: "c", group: .apps, title: "Caches", explanation: "", symbol: "x", mode: .delete, defaultOn: true)
        caches.items = [item("/c/1", true), item("/c/2", false), CleanupItem(path: "/c/3", name: "3", size: 5, blockedReason: "ouverte")]
        var bin = CleanupTarget(id: "t", group: .trash, title: "Corbeille", explanation: "", symbol: "x", mode: .delete, defaultOn: true)
        bin.items = [item("/t/1", true)]
        if AutomationCleanupPlan.selection([caches, bin]) != ["/c/1"] { f.append("sélection du nettoyage planifié : \(AutomationCleanupPlan.selection([caches, bin]))") }

        // Health history
        let cal = Calendar(identifier: .gregorian)
        let day = cal.startOfDay(for: now)
        let s1 = AutomationHealthSample(day: day.addingTimeInterval(-86400), diskFree: 100, diskTotal: 1000, memoryUsed: 0.5, score: 80)
        var s2 = s1
        s2.day = day
        s2.score = 90
        var history = AutomationHealth.recording(s2, into: AutomationHealth.recording(s1, into: [], calendar: cal), calendar: cal)
        if !AutomationHealth.needsSample([s1], now: now, calendar: cal) || AutomationHealth.needsSample(history, now: now, calendar: cal) { f.append("un instantané par jour") }
        var again = s2
        again.score = 70
        history = AutomationHealth.recording(again, into: history, calendar: cal)
        if history.count != 2 || history.last?.score != 70 { f.append("instantané du jour remplacé") }
        if AutomationHealth.change(history, { Double($0.score) }) != -10 { f.append("évolution sur la période") }
        let year = AutomationDemo.samples(now: now)
        if AutomationHealth.window(year, range: .month, now: now).count > 30 || year.count < 300 { f.append("fenêtre de 30 jours") }

        // Settings written by an older version keep their values.
        if let s = try? JSONDecoder.store.decode(AutomationSettings.self, from: Data("{\"trashDays\": 7, \"rules\": [{\"name\": \"x\", \"kinds\": [\"images\", \"inconnu\"]}]}".utf8)) {
            if s.trashDays != 7 || s.cleanupEnabled || s.rules.first?.kinds != [.images] { f.append("réglages partiels mal relus") }
        } else {
            f.append("réglages partiels illisibles")
        }
        if AutomationSettings().cleanupEnabled || AutomationSettings().trashEnabled || AutomationSettings().downloadsEnabled || AutomationSettings().healthEnabled {
            f.append("une automatisation est active par défaut")
        }
        // The quarter-hour check is registered only while one of them is on.
        var one = AutomationSettings()
        one.healthEnabled = true
        if Self.anyActive(AutomationSettings()) || !Self.anyActive(one) { f.append("vérification planifiée sans automatisation active") }
        return f
    }

    func dump() -> [String] {
        var lines: [String] = []
        for k in AutomationKind.allCases {
            let state = isEnabled(k) ? "active" : "désactivée"
            let last = lastRun(k).map { k == .health ? " · dernier instantané le \(Fmt.day($0))" : " · dernier passage \(Fmt.relative($0))" }
            lines.append("\(k.title) : \(state)" + (last ?? ""))
        }
        let folder = downloadsFolder
        let now = Date()
        if let files = DemoData.isEnabled ? AutomationDemo.downloadFiles(now: now) : AutomationDownloads.list(folder) {
            let plan = AutomationDownloads.plan(files, rules: settings.rules, source: folder, now: Date())
            lines.append("\(FS.pretty(folder)) : \(files.count) éléments, \(plan.count) concernés par les règles actives (aperçu, rien n'est déplacé)")
            for m in plan.prefix(10) {
                lines.append("  \(m.file.name) → \(m.ruleName) : \(m.destination.map(FS.pretty) ?? "Corbeille")")
            }
        } else {
            lines.append("\(FS.pretty(folder)) : illisible")
        }
        if let trash = DemoData.isEnabled ? AutomationDemo.trashItems(now: now) : AutomationTrash.list() {
            let old = AutomationTrash.expired(trash, days: settings.trashDays, now: Date())
            lines.append("Corbeille : \(trash.count) éléments, \(old.count) depuis plus de \(settings.trashDays) jours (\(Fmt.bytes(old.reduce(0) { $0 + $1.size })))")
        } else {
            lines.append("Corbeille : illisible sans l'accès complet au disque")
        }
        lines.append("Historique de santé : \(samples.count) instantanés · journal : \(journal.count) lignes")
        return lines
    }
}
