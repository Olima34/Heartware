import SwiftUI
import AppKit

/// What is kept between launches.
struct UpdatesSelfSaved: Codable {
    var lastCheck: Date?
    /// The latest version GitHub had at the last check (even when this copy has it).
    var latest: String?
    /// A newer version than this copy, with what changed.
    var release: UpdatesSelfRelease?
    var skipped: String?
    /// The version this copy replaced, written just before the relaunch: the new copy says it is up to date.
    var updatedFrom: String?
    /// Written when the new version went to Applications instead of the copy the user opened: whether that copy opened
    /// at login, so that the new one takes over its login item.
    var loginItemAfterMove: Bool?
}

/// Heartware's own updates: a check at launch and every six hours (unless turned off), the panel that shows
/// what changed, and the download and replacement of the app when the user asks for it.
@Observable
@MainActor
final class UpdatesSelfModel {
    enum Step: Equatable {
        case idle
        case downloading(received: Int64, expected: Int64)
        case verifying
        /// Verified; the password of the signing keychain is asked to re-sign it with the local certificate
        /// (the text: why the last one did not work).
        case password(String?)
        case ready
        case installing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying, .installing: return true
            default: return false
            }
        }

        /// Downloaded and verified, waiting for the user: a password, or "Installer et relancer".
        var awaitsUser: Bool {
            switch self {
            case .password, .ready: return true
            default: return false
            }
        }
    }

    static let autoKey = "selfupdate.auto"
    static let jobID = "selfupdate"
    static let interval: TimeInterval = 6 * 3600
    /// On unless the user turned it off (Réglages › Général, or the Mises à jour page).
    static var autoEnabled: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }

    let build = UpdatesSelfBuild.current
    /// The check itself.
    var state: UpdatesState = .idle
    /// A newer version than this copy, or nil.
    var release: UpdatesSelfRelease?
    var latestSeen: String?
    var lastCheck: Date?
    var skipped: String?
    /// The download and installation of `release`.
    var step: Step = .idle
    /// Where the new version goes: in place of this copy, or in Applications when it was opened straight from its archive.
    var place: UpdatesSelfPlace = .inPlace("")
    /// Why this copy cannot update itself (source build, folder that needs a password…), or nil.
    var blocker: String? {
        if case .blocked(let why) = place { return why }
        return nil
    }
    /// How the version ready to install is signed: whether macOS keeps the permissions.
    var continuity: UpdatesSelfSigning.Continuity = .adhoc
    /// The new version is being re-signed with the local certificate (`UpdatesSelfSigning`).
    var signing = false
    /// The last attempt failed while re-signing: "Installer sans re-signer" is offered.
    var signingRefused = false
    var panelVisible = false

    @ObservationIgnored private let store = JSONStore<UpdatesSelfSaved>("selfupdate", default: UpdatesSelfSaved())
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var cancel: CancelFlag?
    @ObservationIgnored private var stagedFolder: URL?
    @ObservationIgnored private var stagedApp: URL?
    /// The local certificate `stagedApp` is re-signed with once the password is typed (`.password`).
    @ObservationIgnored private var pendingIdentity: UpdatesSelfSigning.Identity?
    /// `stagedApp` with its published signature ("Installer sans re-signer").
    @ObservationIgnored private var publishedContinuity: UpdatesSelfSigning.Continuity = .adhoc
    /// "Plus tard": the background checks of this session stay quiet for a day; the next launch shows it again.
    @ObservationIgnored private var snoozedUntil: Date?
    @ObservationIgnored private var demoPlace: UpdatesSelfPlace?
    /// An automatic check that failed (no network yet at login, typically) tries once more a little later.
    @ObservationIgnored private var retry: DispatchWorkItem?
    @ObservationIgnored private var retrying = false

    init() {
        let saved = store.value
        lastCheck = saved.lastCheck
        latestSeen = saved.latest
        skipped = saved.skipped
        if let d = saved.lastCheck { state = .done(d) }
        // Only a version still newer than this copy (it may have been updated another way since).
        if var r = saved.release, let v = build.version, UpdatesSelfGitHub.isNewer(r.version, than: v) {
            // selfupdate.json can be rewritten by any program: its addresses are checked again (and once more before use).
            if let link = r.downloadURL, !UpdatesSelfGitHub.isTrustedDownload(link) { r.downloadURL = nil }
            if let link = r.signatureURL, !UpdatesSelfGitHub.isTrustedDownload(link) { r.signatureURL = nil }
            release = r
        }
        refreshPlace()
    }

    /// The Labo copy is rebuilt from the local branch for every test: it never compares itself with the published versions.
    var canCheck: Bool { build.version != nil && !AppEdition.isLab }
    var isSkipped: Bool { release != nil && release?.version == skipped }

    // MARK: Lifecycle

    func start(app: AppModel) {
        welcomeAfterUpdate()
        // What an earlier download left (an update abandoned or installed).
        Remover.removeInternal(DataStore.url(UpdatesSelfInstaller.folderName).path)
        guard canCheck else { return }
        Scheduler.shared.register(Self.jobID, every: Self.interval) { [weak self] in await self?.check(auto: true) }
        // At every launch, once the Mac has settled (the scheduler's quiet minutes); then every six hours through the
        // scheduler (it catches up after a sleep, a few minutes after the wake).
        DispatchQueue.main.asyncAfter(deadline: .now() + Scheduler.settle) {
            Task { await Scheduler.shared.runNow(Self.jobID) }
        }
    }

    func stop() {
        cancelUpdate()
        store.flush()
    }

    private func save() {
        store.value.lastCheck = lastCheck
        store.value.latest = latestSeen
        store.value.release = release
        store.value.skipped = skipped
    }

    // MARK: Check

    /// `auto`: the launch and six-hourly check, quiet unless a new version shows up (and only when allowed).
    /// Otherwise the user asked: with `announce`, the panel opens on a new version and a short message says when all
    /// is up to date (the Mises à jour page shows the answer itself).
    func check(auto: Bool = false, announce: Bool = true) async {
        if auto && !Self.autoEnabled { return }
        let tell = !auto && announce
        guard !state.isChecking, !step.isBusy, !step.awaitsUser else {
            if tell, release != nil { showPanel() }
            return
        }
        guard !DemoData.isEnabled else {
            if tell { release == nil ? HUD.show(DemoData.refusal) : showPanel() }
            return
        }
        guard canCheck else {
            state = .failed(AppEdition.isLab
                            ? "Version Labo : elle est reconstruite à chaque essai et ne se compare pas aux versions publiées."
                            : "Version de développement : assemble l'app avec ./scripts/build_app.sh pour la comparer aux versions publiées.")
            if tell { HUD.show(AppEdition.isLab ? "Version Labo : rien à comparer" : "Version de développement : rien à comparer",
                               symbol: "exclamationmark.triangle.fill") }
            return
        }
        state = .checking
        retry?.cancel()
        retry = nil
        do {
            let result = try await UpdatesSelfGitHub.check(build)
            let now = Date()
            lastCheck = now
            latestSeen = result.latest.version
            release = result.isUpdate ? result.latest : nil
            if case .failed = step { step = .idle }
            state = .done(now)
            save()
            if let r = release {
                if tell || (auto && remind(r)) { showPanel() }
            } else if tell {
                HUD.show("\(AppEdition.name) est à jour (\(build.version ?? "?"))")
            }
        } catch {
            state = .failed(UpdatesSelfGitHub.message(for: error))
            if tell { HUD.show("Vérification impossible : voir Mises à jour", symbol: "exclamationmark.triangle.fill") }
            if auto && !retrying { retryLater() }
        }
    }

    /// One more try in a quarter of an hour, not a loop: the next one is the six-hourly check.
    private func retryLater() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.retry != nil else { return }
                self.retry = nil
                self.retrying = true
                Task {
                    await self.check(auto: true)
                    self.retrying = false
                }
            }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60, execute: work)
    }

    private func remind(_ r: UpdatesSelfRelease) -> Bool {
        if r.version == skipped { return false }
        if let until = snoozedUntil, Date() < until { return false }
        return !panelVisible
    }

    // MARK: Panel

    /// Shows the panel in the middle of the main window, the app dimmed behind it (`UpdatesSelfModal`):
    /// the window comes to the front, opened if it was closed (the app may only live in the menu bar).
    func showPanel() {
        guard !Snapshot.isActive else { return }
        refreshPlace()
        panelVisible = true
        AppContext.showMainWindow()
    }

    /// Closed without answering ("Plus tard", ✕ or Esc). A download goes on: the panel comes back when it is ready.
    func closePanel() {
        guard panelVisible else { return }
        panelVisible = false
        if !step.isBusy && !step.awaitsUser { snoozedUntil = Date().addingTimeInterval(24 * 3600) }
    }

    func later() {
        closePanel()
        snoozedUntil = Date().addingTimeInterval(24 * 3600)
    }

    /// "Ignorer cette version": no panel by itself until a newer one comes out (the Mises à jour page still shows it).
    func skip() {
        guard let r = release else { return }
        skipped = r.version
        save()
        closePanel()
    }

    func unskip() {
        skipped = nil
        save()
    }

    func refreshPlace() {
        place = DemoData.isEnabled ? demoPlace ?? .inPlace("/Applications/Heartware.app") : UpdatesSelfInstaller.currentPlace()
    }

    /// When the new version goes to Applications rather than in place of this copy: said before downloading.
    var placeNote: String? {
        guard case .applications(let target, let leftover) = place else { return nil }
        let folder = UpdatesSelfInstaller.folderLabel((target as NSString).deletingLastPathComponent)
        var note = "Tu as ouvert \(AppEdition.name) sans l'installer : la nouvelle version va dans « \(folder) », d'où tu l'ouvriras désormais et d'où elle se mettra à jour toute seule."
        if let leftover {
            note += " La copie de « \(UpdatesSelfInstaller.folderLabel((leftover as NSString).deletingLastPathComponent)) » part à la Corbeille."
        }
        return note
    }

    /// What "Installer et relancer" does, said once the version is ready.
    func readyNote(_ version: String) -> String {
        guard case .applications(let target, let leftover) = place else {
            return "\(AppEdition.name) se ferme quelques secondes puis se rouvre en version \(version) ; l'ancienne part à la Corbeille. Une tâche en cours (conversion, mise à jour Homebrew) serait interrompue."
        }
        let folder = UpdatesSelfInstaller.folderLabel((target as NSString).deletingLastPathComponent)
        let old = leftover.map { " ; la copie de « \(UpdatesSelfInstaller.folderLabel(($0 as NSString).deletingLastPathComponent)) » part à la Corbeille" } ?? ""
        return "\(AppEdition.name) se ferme quelques secondes puis se rouvre en version \(version), installé dans « \(folder) »\(old). Une tâche en cours (conversion, mise à jour Homebrew) serait interrompue."
    }

    func openReleasePage() {
        guard !DemoData.isEnabled else { return HUD.show(DemoData.refusal) }
        Finder.open(release?.pageURL ?? UpdatesSelfGitHub.releasesPage)
    }

    func copyInstallCommand() {
        if case .copied = CommandRunner.copy(UpdatesSelfGitHub.installCommand) {
            HUD.show("Commande copiée : colle-la dans le Terminal")
        } else {
            HUD.show(DemoData.refusal)
        }
    }

    // MARK: Download and install

    /// "Mettre à jour": downloads the archive and checks it. Nothing is replaced before "Installer et relancer".
    /// `resign` false ("Installer sans re-signer") keeps the published signature instead of the local certificate.
    func startUpdate(resign: Bool = true) {
        guard let r = release, !step.isBusy else { return }
        guard !DemoData.isEnabled else { return HUD.show(DemoData.refusal) }
        refreshPlace()
        guard blocker == nil else { return }
        guard let link = r.downloadURL else {
            step = .failed("Cette version n'a pas encore d'archive prête à installer : réessaie dans quelques minutes, ou passe par la page de la version.")
            return
        }
        guard UpdatesSelfGitHub.isTrustedDownload(link), let url = URL(string: link) else {
            step = .failed(UpdatesSelfInstaller.Failure.untrusted.localizedDescription)
            return
        }
        guard r.digest != nil else {
            step = .failed(UpdatesSelfInstaller.Failure.noDigest.localizedDescription)
            return
        }
        discardStaged()
        let flag = CancelFlag()
        cancel = flag
        signingRefused = false
        step = .downloading(received: 0, expected: r.size)
        work = Task { await download(r, from: url, resign: resign, cancel: flag) }
    }

    private func download(_ r: UpdatesSelfRelease, from url: URL, resign: Bool, cancel flag: CancelFlag) async {
        guard let base = DataStore.ensureFolder(UpdatesSelfInstaller.folderName),
              let folder = try? FileOps.makeDirectory(base.appendingPathComponent(r.version)) else {
            step = .failed("Impossible de préparer le dossier de téléchargement de l'app.")
            return
        }
        stagedFolder = folder
        let bundle = build.bundlePath
        do {
            let zip = try await HTTP.download(url, into: folder, name: UpdatesSelfGitHub.assetName) { [weak self] received, expected in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, !flag.isCancelled, case .downloading = self.step else { return }
                        self.step = .downloading(received: received, expected: expected > 0 ? expected : r.size)
                    }
                }
            }
            guard !flag.isCancelled else { throw CancellationError() }
            step = .verifying
            let signature = try await UpdatesSelfSignature.fetch(for: r)
            let (app, identity, published) = try await Task.detached(priority: .userInitiated) {
                let app = try UpdatesSelfInstaller.prepare(zip: zip, folder: folder, release: r, signature: signature,
                                                           isCancelled: { flag.isCancelled })
                let current = UpdatesSelfSigning.signer(of: bundle), signed = UpdatesSelfSigning.signer(of: app.path)
                return (app, resign ? UpdatesSelfSigning.identity(current: current, published: signed) : nil,
                        UpdatesSelfSigning.continuity(current: current, published: signed))
            }.value
            guard !flag.isCancelled else { throw CancellationError() }
            stagedApp = app
            publishedContinuity = published
            continuity = published
            ActionLog.write("MISE À JOUR \(r.version) téléchargée et vérifiée : \(app.path)")
            if let identity, identity.keychain != nil {
                // The signing keychain opens only with its password: the panel asks for it.
                pendingIdentity = identity
                step = .password(nil)
            } else {
                // A certificate of the session keychain (set up before the signing keychain) needs nothing.
                if let identity {
                    signing = true
                    let outcome = await Task.detached(priority: .userInitiated) { UpdatesSelfSigning.sign(app, with: identity) }.value
                    signing = false
                    guard outcome == .signed else { throw UpdatesSelfInstaller.Failure.localSign(Self.detail(outcome)) }
                    continuity = .local
                }
                step = .ready
            }
            if !panelVisible { showPanel() }
        } catch {
            signing = false
            if flag.isCancelled || error is CancellationError {
                step = .idle
            } else {
                // The local certificate could not be used: the published signature remains possible, at the user's choice.
                if case .localSign? = error as? UpdatesSelfInstaller.Failure { signingRefused = true }
                step = .failed(UpdatesSelfGitHub.message(for: error))
                ActionLog.write("MISE À JOUR \(r.version) abandonnée : \(UpdatesSelfGitHub.message(for: error))")
            }
            discardStaged()
        }
        cancel = nil
    }

    /// "Signer": unlocks the signing keychain with `password` just long enough to re-sign the verified version,
    /// which then keeps the designated requirement macOS ties the permissions to. A wrong password asks again.
    func signStaged(password: String) {
        guard case .password = step, let app = stagedApp, let identity = pendingIdentity, !password.isEmpty else { return }
        guard !DemoData.isEnabled else { return HUD.show(DemoData.refusal) }
        step = .verifying
        signing = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { UpdatesSelfSigning.sign(app, with: identity, password: password) }.value
            signing = false
            switch outcome {
            case .signed:
                pendingIdentity = nil
                continuity = .local
                step = .ready
            case .wrongPassword:
                step = .password("Mot de passe refusé : c'est celui choisi avec setup_signing.sh, pas celui de ta session.")
            case .failed:
                // A half-signed app is never installed.
                pendingIdentity = nil
                signingRefused = true
                step = .failed(UpdatesSelfInstaller.Failure.localSign(Self.detail(outcome)).localizedDescription)
                ActionLog.write("MISE À JOUR re-signature impossible : \(Self.detail(outcome))")
                discardStaged()
            }
        }
    }

    /// "Installer sans re-signer": the verified version keeps its published signature; macOS will ask for the permissions again.
    func skipSigning() {
        guard case .password = step else { return }
        pendingIdentity = nil
        continuity = publishedContinuity
        step = .ready
    }

    nonisolated static func detail(_ outcome: UpdatesSelfSigning.Outcome) -> String {
        switch outcome {
        case .signed: return ""
        case .wrongPassword: return "trousseau de signature verrouillé"
        case .failed(let why): return why
        }
    }

    func cancelUpdate() {
        cancel?.cancel()
        work?.cancel()
        if step.awaitsUser {
            pendingIdentity = nil
            discardStaged()
            step = .idle
        }
    }

    /// The old app goes to the Trash, the new one takes its place and opens once this one has quit.
    func installAndRelaunch() {
        guard step == .ready, let staged = stagedApp else { return }
        guard !DemoData.isEnabled else { return HUD.show(DemoData.refusal) }
        refreshPlace()
        let current = URL(fileURLWithPath: build.bundlePath)
        let place = self.place
        let from = build.version
        step = .installing
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> (URL, Int) in
                    // The keychain items go to the new version first: it then reads them without macOS asking.
                    let adopted = UpdatesSelfKeychain.handOver(to: staged)
                    if case .applications(let target, let leftover) = place {
                        return (try UpdatesSelfInstaller.install(staged, at: URL(fileURLWithPath: target),
                                                                 leftover: leftover.map { URL(fileURLWithPath: $0) }), adopted)
                    }
                    return (try UpdatesSelfInstaller.replace(current, with: staged), adopted)
                }
            }.value
            switch result {
            case .success(let (installed, adopted)):
                if adopted > 0 { ActionLog.write("MISE À JOUR trousseau : \(Fmt.plural(adopted, "clé reprise", "clés reprises")) par la nouvelle version") }
                store.value.updatedFrom = from
                store.value.release = nil
                if case .applications = place { store.value.loginItemAfterMove = LoginItem.isEnabled }
                store.flush()
                ActionLog.write("MISE À JOUR installée : \(installed.path)")
                if UpdatesSelfInstaller.relaunch(installed) {
                    NSApp.terminate(nil)
                } else {
                    step = .failed("La nouvelle version est installée, mais je n'ai pas pu la relancer : quitte \(AppEdition.name) (menu d'état › Quitter) puis rouvre-le.")
                }
            case .failure(let error):
                step = .failed(error.localizedDescription)
            }
        }
    }

    private func discardStaged() {
        if let folder = stagedFolder { Remover.removeInternal(folder.path) }
        stagedFolder = nil
        stagedApp = nil
    }

    /// The first launch after an update says so.
    private func welcomeAfterUpdate() {
        if let login = store.value.loginItemAfterMove {
            store.value.loginItemAfterMove = nil
            // The login item still opened the copy the user had opened (now in the Trash): it opens this one instead.
            if login {
                LoginItem.set(false)
                LoginItem.set(true)
            }
        }
        guard let from = store.value.updatedFrom else { return }
        store.value.updatedFrom = nil
        guard let v = build.version, v != from else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            HUD.show("\(AppEdition.name) est passé en version \(v)", symbol: "sparkles")
        }
    }
}

// MARK: - Demo, snapshots, launcher, self-tests

extension UpdatesSelfModel {
    func loadDemo() {
        let now = Date()
        func change(_ id: String, _ title: String, _ details: [String], hoursAgo: Double) -> UpdatesSelfChange {
            UpdatesSelfChange(id: id, title: UpdatesSelfGitHub.line(title), details: details.map { UpdatesSelfGitHub.line($0, title: false) },
                              date: now.addingTimeInterval(-hoursAgo * 3600))
        }
        release = UpdatesSelfRelease(
            version: "0.4.0", tag: "v0.4.0", title: "Heartware 0.4.0",
            pageURL: "https://github.com/\(UpdatesSelfGitHub.repo)/releases/tag/v0.4.0", published: now.addingTimeInterval(-5 * 3600),
            downloadURL: "https://github.com/\(UpdatesSelfGitHub.repo)/releases/download/v0.4.0/\(UpdatesSelfGitHub.assetName)",
            size: 11_480_000, digest: "sha256:" + String(repeating: "5e", count: 32),
            changes: [
                change("d1", "Mises à jour : Heartware se met à jour tout seul", [
                    "Vérification au lancement puis toutes les 6 h, désactivable dans les réglages",
                    "Nouveautés listées avant d'installer, ancienne version mise à la Corbeille"
                ], hoursAgo: 6),
                change("d2", "Lanceur : glisser un résultat vers le Bureau, le Finder ou une autre app", [
                    "Fichiers, dossiers et apps se glissent directement depuis la liste",
                    "L'aperçu suit la sélection sans clignoter"
                ], hoursAgo: 20),
                change("d3", "Convertisseur : les PDF défilent page par page dans l'aperçu", [
                    "Aperçu du résultat réel avant d'enregistrer"
                ], hoursAgo: 31),
                change("d4", "Moniteur système : en pause quand rien ne l'affiche", [], hoursAgo: 40),
                change("d5", "Corrections de bugs dans toute l'app", [
                    "Presse-papiers : le réglage « Garder les fichiers » est respecté",
                    "Traducteur : inversion des langues et articles corrects (« l'anglais »)"
                ], hoursAgo: 52)
            ],
            moreChanges: 3)
        latestSeen = "0.4.0"
        lastCheck = now.addingTimeInterval(-12 * 60)
        state = .done(now.addingTimeInterval(-12 * 60))
        refreshPlace()
    }

    /// `--snapshot --demo --page updates --tab maj-…`: the panel at each step.
    func applySnapshotTab(_ tab: String) {
        switch tab {
        case "maj-telechargement": step = .downloading(received: 4_820_000, expected: release?.size ?? 11_480_000)
        case "maj-verification": step = .verifying
        case "maj-installation": step = .installing
        case "maj-motdepasse": step = .password(nil)
        case "maj-motdepasse-refuse": step = .password("Mot de passe refusé : c'est celui choisi avec setup_signing.sh, pas celui de ta session.")
        case "maj-signature":
            step = .verifying
            signing = true
        case "maj-resignature":
            step = .failed(UpdatesSelfInstaller.Failure.localSign("errSecInternalComponent").localizedDescription)
            signingRefused = true
        case "maj-prete":
            step = .ready
            continuity = .kept
        case "maj-prete-certificat":
            step = .ready
            continuity = .firstRelease
        case "maj-erreur": step = .failed(UpdatesSelfGitHub.message(for: URLError(.notConnectedToInternet)))
        case "maj-impossible":
            demoPlace = UpdatesSelfInstaller.place(bundlePath: "/Applications/Heartware.app", readOnly: false, writable: false)
            refreshPlace()
        case "maj-applications", "maj-applications-prete":
            // Opened from the folder its archive was unpacked in, on the Desktop of the fictional Mac.
            demoPlace = .applications(target: "/Applications/Heartware.app", leftover: "/Users/camille/Desktop/Heartware.app")
            refreshPlace()
            if tab == "maj-applications-prete" {
                step = .ready
                continuity = .kept
            }
        case "maj-ajour":
            release = nil
        default: break
        }
    }

    func commands() -> [AppCommand] {
        var list = [
            AppCommand(id: "upd_self_check", title: "Rechercher une mise à jour de \(AppEdition.name)",
                       subtitle: "Dernière version publiée sur GitHub · tu as la \(build.label)",
                       keywords: ["heartware", "mise à jour", "version", "nouveautés", "update", "github", "maj"],
                       icon: .spark, group: .actions, assistantSafe: true) { ctx in
                await ctx.app.updates.selfUpdate.check()
                return .done
            }
        ]
        if let r = release {
            list.append(AppCommand(id: "upd_self_show", title: "Voir les nouveautés de \(AppEdition.name) \(r.version)",
                                   subtitle: Fmt.plural(r.changeCount, "changement", "changements") + " depuis ta version",
                                   keywords: ["heartware", "nouveautés", "mise à jour", "changements", "version"],
                                   icon: .spark, group: .actions, assistantSafe: true, urlSafe: true) { ctx in
                ctx.app.updates.selfUpdate.showPanel()
                return .done
            })
        }
        return list
    }

    func dump() -> [String] {
        var lines = ["\(AppEdition.name) : \(build.label)" + (build.isBundle ? " · \(FS.pretty(build.bundlePath))" : " · non assemblée")]
        lines.append("  Vérification automatique : \(Self.autoEnabled ? "oui, au lancement puis toutes les 6 h" : "désactivée") · dépôt \(UpdatesSelfGitHub.repo)")
        let last = lastCheck.map { "dernière vérification \(Fmt.relative($0))" } ?? "jamais vérifiée"
        let latest = latestSeen.map { "dernière version publiée connue : \($0)" } ?? "aucune version connue"
        lines.append("  \(Fmt.cap(last)) · \(latest)")
        if let r = release {
            lines.append("  Nouvelle version \(r.version)\(isSkipped ? " (ignorée)" : "") · \(Fmt.plural(r.changeCount, "changement", "changements")) · \(r.downloadURL ?? "pas d'archive")")
            for c in r.changes.prefix(5) { lines.append("    • \(c.title.topic.map { "\($0) : " } ?? "")\(c.title.text)") }
        }
        if let b = blocker { lines.append("  Mise à jour sur place impossible : \(b)") }
        if let n = placeNote { lines.append("  Installation : \(n)") }
        if !DemoData.isEnabled { lines += UpdatesSelfSigning.describe(bundle: build.isBundle ? build.bundlePath : nil).map { "  " + $0 } }
        lines.append("  (GitHub n'est interrogé que par l'app en marche, jamais par --dump)")
        return lines
    }

    /// Version comparison, GitHub's answers, the changes read from commit messages and the installation rules.
    static func selfTest() -> [String] {
        var f: [String] = []
        for (a, b, newer) in [("v0.3.1", "0.3.0", true), ("0.3.0", "0.3.0", false), ("v0.3.0", "0.3.1", false), ("0.4.0", "0.3.12", true),
                              ("0.10.0", "0.9.9", true), ("1.0.0", "1.0.0-rc.1", true), ("1.0.0-rc.1", "0.9", true), ("V2.0", "1.9", true),
                              ("0.3.0", "0.3.0.1", false), ("0.3.10", "0.3.9", true), ("v0.3.9", "0.3.12", false), ("0.4.1", "0.3.48", true)]
        where UpdatesSelfGitHub.isNewer(a, than: b) != newer {
            f.append("Mise à jour de l'app : \(a) contre \(b) donne \(!newer), attendu \(newer)")
        }
        if UpdatesSelfGitHub.version(fromTag: "v0.3.1") != "0.3.1" || UpdatesSelfGitHub.version(fromTag: "version-2") != "version-2" {
            f.append("Mise à jour de l'app : étiquette mal lue")
        }

        let digest = "sha256:" + String(repeating: "ab", count: 32)
        let release = """
        {"tag_name":"v0.4.0","name":"Heartware 0.4.0","html_url":"https://github.com/Olima34/Heartware/releases/tag/v0.4.0",
         "draft":false,"prerelease":false,"published_at":"2026-10-19T00:36:44Z","body":"**Installer en une ligne**",
         "assets":[{"name":"notes.txt","size":10,"browser_download_url":"https://github.com/Olima34/Heartware/releases/download/v0.4.0/notes.txt","state":"uploaded"},
                   {"name":"Heartware.zip","size":11118628,"state":"uploaded","digest":"\(digest.uppercased().replacingOccurrences(of: "SHA256", with: "sha256"))",
                    "browser_download_url":"https://github.com/Olima34/Heartware/releases/download/v0.4.0/Heartware.zip"},
                   {"name":"Heartware.zip.sig","size":88,"state":"uploaded",
                    "browser_download_url":"https://github.com/Olima34/Heartware/releases/download/v0.4.0/Heartware.zip.sig"}]}
        """
        if let r = UpdatesSelfGitHub.parseRelease(Data(release.utf8)) {
            if r.version != "0.4.0" || r.tag != "v0.4.0" { f.append("Mise à jour de l'app : version publiée mal lue (\(r.version))") }
            if r.downloadURL?.hasSuffix("/Heartware.zip") != true || r.size != 11_118_628 { f.append("Mise à jour de l'app : archive non trouvée") }
            if r.digest != digest { f.append("Mise à jour de l'app : empreinte de l'archive mal lue (\(r.digest ?? "aucune"))") }
            if r.signatureURL?.hasSuffix("/Heartware.zip.sig") != true { f.append("Mise à jour de l'app : signature de l'archive non trouvée") }
            if r.published == nil { f.append("Mise à jour de l'app : date de publication non lue") }
        } else {
            f.append("Mise à jour de l'app : réponse de version illisible")
        }
        // The archive's address, read again from selfupdate.json before use: the owner's releases on GitHub only, under
        // whatever name the repository has (a renamed repository keeps updating the copies already installed).
        for (link, ok) in [("https://github.com/Olima34/Heartware/releases/download/v0.4.0/Heartware.zip", true),
                           ("https://github.com/Olima34/UnNouveauNom/releases/download/v0.5.0/UnNouveauNom.zip", true),
                           ("https://api.github.com/repos/Olima34/Heartware/releases/assets/123", true),
                           ("https://api.github.com/repositories/\(UpdatesSelfGitHub.repositoryID)/releases/assets/123", true),
                           ("https://api.github.com/repositories/1/releases/assets/123", false),
                           ("https://github.com/Olima34/Heartware/archive/refs/tags/v0.4.0.zip", false),
                           ("http://github.com/Olima34/Heartware/releases/download/v0.4.0/Heartware.zip", false),
                           ("https://github.com.exemple.test/Olima34/Heartware/releases/download/v1/x.zip", false),
                           ("https://exemple.test/Heartware.zip", false), ("https://evilgithub.com/Olima34/Heartware/releases/download/v1/x.zip", false),
                           ("https://github.com/autre/Heartware/releases/download/v9.0/Heartware.zip", false),
                           ("https://user@github.com/Olima34/Heartware/releases/download/v1/x.zip", false),
                           ("https://github.com/Olima34/Heartware/releases/download/../../../autre/x.zip", false),
                           ("file:///tmp/Heartware.zip", false), ("pas une adresse", false)]
        where UpdatesSelfGitHub.isTrustedDownload(link) != ok {
            f.append("Mise à jour de l'app : adresse d'archive « \(link) » \(ok ? "refusée" : "acceptée") à tort")
        }
        f += UpdatesSelfSignature.selfTest()
        f += UpdatesSelfSigning.selfTest()
        f += UpdatesSelfKeychain.selfTest()
        // A pre-release, a tag that is no version, an archive outside GitHub or still uploading: not offered.
        let prerelease = #"{"tag_name":"v0.5.0-beta","html_url":"https://github.com/x/y","prerelease":true,"assets":[]}"#
        let notVersion = #"{"tag_name":"nightly","html_url":"https://github.com/x/y","assets":[]}"#
        if UpdatesSelfGitHub.parseRelease(Data(prerelease.utf8)) != nil || UpdatesSelfGitHub.parseRelease(Data(notVersion.utf8)) != nil
            || UpdatesSelfGitHub.parseRelease(Data("<html>rate limited</html>".utf8)) != nil {
            f.append("Mise à jour de l'app : pré-version, étiquette quelconque ou page HTML acceptée")
        }
        let elsewhere = #"{"tag_name":"v9.0","html_url":"https://github.com/x/y","assets":[{"name":"Heartware.zip","size":5,"browser_download_url":"https://exemple.test/Heartware.zip","digest":"sha256:00"},{"name":"Heartware.zip","size":5,"state":"starter","browser_download_url":"https://github.com/x/y/z.zip"}]}"#
        if let r = UpdatesSelfGitHub.parseRelease(Data(elsewhere.utf8)) {
            if r.downloadURL != nil || r.digest != nil { f.append("Mise à jour de l'app : archive hors de GitHub ou incomplète acceptée") }
        } else {
            f.append("Mise à jour de l'app : version sans archive refusée")
        }

        let compare = """
        {"status":"ahead","ahead_by":4,"total_commits":4,"commits":[
         {"sha":"aaa1","parents":[{"sha":"p"}],"commit":{"message":"Lanceur : glisser un fichier où on veut\\n\\nUn paragraphe d'explication.\\n- Fichiers : depuis la liste\\n- aperçu plus fluide\\n\\nCo-Authored-By: Claude <noreply@anthropic.com>","committer":{"date":"2026-10-18T10:00:00Z"}}},
         {"sha":"aaa2","parents":[{"sha":"p"},{"sha":"q"}],"commit":{"message":"Merge pull request #1 from Olima34/themes"}},
         {"sha":"aaa3","parents":[{"sha":"p"}],"commit":{"message":"Fusion de main dans themes"}},
         {"sha":"aaa4","parents":[{"sha":"p"}],"commit":{"message":"Corrections de bugs dans toute l'app, après une revue","author":{"date":"2026-10-19T07:37:16Z"}}}]}
        """
        if let c = UpdatesSelfGitHub.parseCompare(Data(compare.utf8)) {
            if c.changes.map(\.id) != ["aaa4", "aaa1"] || c.total != 2 { f.append("Mise à jour de l'app : changements mal triés ou fusions gardées (\(c.changes.map(\.id)))") }
            if let l = c.changes.last {
                if l.title != UpdatesSelfLine(topic: "Lanceur", text: "Glisser un fichier où on veut") { f.append("Mise à jour de l'app : titre mal découpé (\(l.title))") }
                if l.details != [UpdatesSelfLine(topic: "Fichiers", text: "depuis la liste"), UpdatesSelfLine(topic: nil, text: "Aperçu plus fluide")] {
                    f.append("Mise à jour de l'app : détails mal lus (\(l.details))")
                }
                if l.date == nil { f.append("Mise à jour de l'app : date du changement non lue") }
            }
            if c.changes.first?.title.topic != nil { f.append("Mise à jour de l'app : thème inventé pour une phrase sans deux-points") }
        } else {
            f.append("Mise à jour de l'app : comparaison illisible")
        }
        for (text, topic) in [("Applications, Protection, Optimisation : app ouverte", "Applications, Protection, Optimisation"),
                              ("Voir https://github.com/x", nil), ("SIGPIPE ignoré (un outil : fermé tôt)", nil),
                              ("docs/GUIDE.md : tout le détail", "docs/GUIDE.md"), ("Fin de phrase. Puis : non", nil),
                              ("Une phrase vraiment beaucoup trop longue pour être un thème : non", nil)]
        where UpdatesSelfGitHub.line(text).topic != topic {
            f.append("Mise à jour de l'app : thème de « \(text) » mal repéré")
        }
        if UpdatesSelfGitHub.line("build_app.sh accepte --zip").text != "build_app.sh accepte --zip"
            || UpdatesSelfGitHub.line("glisser un fichier").text != "Glisser un fichier" {
            f.append("Mise à jour de l'app : majuscule mise à un nom de fichier, ou oubliée")
        }

        // A local build made after the release, whose number was not raised, has nothing to install.
        let latest = UpdatesSelfRelease(version: "0.4.0", tag: "v0.4.0", title: "", pageURL: "")
        let local = UpdatesSelfBuild(version: "0.3.0", commit: "1541d89a0427e1e3ded26827beca1aaab7588903", bundlePath: "/Applications/Heartware.app")
        let behind = UpdatesSelfCompare(status: "behind", aheadBy: 0, changes: [], total: 0)
        let ahead = UpdatesSelfCompare(status: "ahead", aheadBy: 3, changes: [], total: 3)
        if UpdatesSelfGitHub.isUpdate(latest, for: local, compare: behind, fromCommit: true)
            || !UpdatesSelfGitHub.isUpdate(latest, for: local, compare: ahead, fromCommit: true)
            || !UpdatesSelfGitHub.isUpdate(latest, for: local, compare: behind, fromCommit: false)
            || !UpdatesSelfGitHub.isUpdate(latest, for: local, compare: nil, fromCommit: false) {
            f.append("Mise à jour de l'app : décision faussée par la comparaison des commits")
        }
        var dev = local
        dev.version = nil
        if UpdatesSelfGitHub.isUpdate(latest, for: dev, compare: ahead, fromCommit: true) { f.append("Mise à jour de l'app : proposée à une version de développement") }

        // One version per push on main (scripts/version.sh): a local build carries the number the CI gives its commit.
        let pushed = UpdatesSelfRelease(version: "0.3.6", tag: "v0.3.6", title: "Heartware 0.3.6", pageURL: "")
        let identical = UpdatesSelfCompare(status: "identical", aheadBy: 0, changes: [], total: 0)
        let sameCommit = UpdatesSelfBuild(version: "0.3.6", commit: local.commit, bundlePath: local.bundlePath)
        let nextCommit = UpdatesSelfBuild(version: "0.3.7", commit: local.commit, bundlePath: local.bundlePath)
        let published = UpdatesSelfBuild(version: "0.3.5", commit: local.commit, bundlePath: local.bundlePath)
        if UpdatesSelfGitHub.isUpdate(pushed, for: sameCommit, compare: identical, fromCommit: true)
            || UpdatesSelfGitHub.isUpdate(pushed, for: nextCommit, compare: nil, fromCommit: false)
            || !UpdatesSelfGitHub.isUpdate(pushed, for: published, compare: UpdatesSelfCompare(status: "ahead", aheadBy: 1, changes: [], total: 1), fromCommit: true) {
            f.append("Mise à jour de l'app : version d'un push mal départagée d'une copie compilée en local")
        }
        // Built before the CI published its own commit, with no tag to count from: the commits decide.
        let untagged = UpdatesSelfBuild(version: "0.3.0", commit: local.commit, bundlePath: local.bundlePath)
        if UpdatesSelfGitHub.isUpdate(pushed, for: untagged, compare: identical, fromCommit: true) {
            f.append("Mise à jour de l'app : sa propre version proposée à une copie compilée sans étiquette")
        }

        // Where the new version goes.
        let home = "/Users/x", app = "Heartware.app"
        let opened = "/private/var/folders/x/AppTranslocation/y/d/" + app, desktop = home + "/Desktop/" + app
        func place(_ path: String, readOnly: Bool = false, writable: Bool = true, original: String? = nil,
                   userCopy: Bool = false, systemWritable: Bool = true) -> UpdatesSelfPlace {
            UpdatesSelfInstaller.place(bundlePath: path, readOnly: readOnly, writable: writable, original: original, home: home,
                                       userCopy: userCopy, systemWritable: systemWritable)
        }
        if place(home + "/Applications/" + app) != .inPlace(home + "/Applications/" + app)
            || place("/Applications/" + app, writable: false) == .inPlace("/Applications/" + app)
            || place("/Users/x/Dev/.build/debug/Heartware") == .inPlace("/Users/x/Dev/.build/debug/Heartware") {
            f.append("Mise à jour de l'app : emplacements remplaçables mal repérés")
        }
        // Opened from the folder of its archive: to Applications, and the copy the user opened to the Trash.
        if place(opened, readOnly: true, writable: false, original: desktop) != .applications(target: "/Applications/" + app, leftover: desktop)
            || place(opened, readOnly: true, original: desktop, userCopy: true) != .applications(target: home + "/Applications/" + app, leftover: desktop)
            || place(opened, readOnly: true, original: desktop, systemWritable: false) != .applications(target: home + "/Applications/" + app, leftover: desktop)
            || place(opened, readOnly: true, original: "/Applications/" + app) != .applications(target: "/Applications/" + app, leftover: nil)
            || place("/Volumes/Heartware/" + app, readOnly: true, writable: false) != .applications(target: "/Applications/" + app, leftover: nil) {
            f.append("Mise à jour de l'app : copie ouverte depuis son archive ou une image disque mal installée")
        }
        if UpdatesSelfInstaller.folderLabel(home + "/Desktop", home: home) != "Bureau"
            || UpdatesSelfInstaller.folderLabel(home + "/Applications", home: home) != "~/Applications"
            || UpdatesSelfInstaller.folderLabel("/Users/y/Downloads", home: home) != "Téléchargements"
            || UpdatesSelfInstaller.folderLabel(home + "/Projets/Desktop", home: home) == "Bureau" {
            f.append("Mise à jour de l'app : dossier de la copie ouverte mal nommé")
        }
        if UpdatesSelfInstaller.originalPath(ofTranslocated: home + "/Applications/" + app) != nil {
            f.append("Mise à jour de l'app : copie ordinaire prise pour une copie provisoire")
        }
        let good: [String: Any] = ["CFBundleIdentifier": UpdatesSelfInstaller.bundleID, "CFBundleShortVersionString": "0.4.0", "LSMinimumSystemVersion": "14.0"]
        if UpdatesSelfInstaller.validate(info: good, expectedVersion: "v0.4.0", macOS: "15.4.0") != nil { f.append("Mise à jour de l'app : archive valide refusée") }
        var other = good
        other["CFBundleIdentifier"] = "com.exemple.autre"
        var older = good
        older["CFBundleShortVersionString"] = "0.3.9"
        if UpdatesSelfInstaller.validate(info: other, expectedVersion: "0.4.0", macOS: "15.4.0") == nil
            || UpdatesSelfInstaller.validate(info: older, expectedVersion: "0.4.0", macOS: "15.4.0") == nil
            || UpdatesSelfInstaller.validate(info: good, expectedVersion: "0.4.0", macOS: "13.6") == nil {
            f.append("Mise à jour de l'app : autre app, autre version ou macOS trop ancien acceptés")
        }
        let requirement = #"designated => identifier "io.github.olima34.cleanmyclaude" and certificate leaf = H"fd519d2fb27988160f2d2bb57daab256af171bda""#
        if UpdatesSelfInstaller.leafHash(fromRequirement: requirement) != "FD519D2FB27988160F2D2BB57DAAB256AF171BDA"
            || UpdatesSelfInstaller.leafHash(fromRequirement: #"designated => cdhash H"0123456789abcdef0123456789abcdef01234567""#) != nil {
            f.append("Mise à jour de l'app : certificat de signature locale mal lu")
        }
        return f
    }
}
