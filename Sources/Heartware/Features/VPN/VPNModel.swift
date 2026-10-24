import AppKit
import Observation

/// The free VPN of Windscribe, driven from Heartware through `windscribe-cli`: the country chosen here, a click to connect,
/// another to disconnect. Nothing runs at rest: the state is read when the page or the menu bar panel shows, when
/// Windscribe starts or quits (a notification of macOS), and every second only while a connection is being made.
@Observable
@MainActor
final class VPNModel: AppModule {
    var phase: VPNPhase = .unknown
    var usage: VPNUsage?
    var install: VPNInstallStep?
    /// The country of the last connection asked.
    var target: VPNCountry?
    /// The address outside the tunnel, as Windscribe last saw it.
    var publicIP: String?
    /// « Garder Windscribe invisible »: the user's yes, given on the page. Windscribe's two settings are then written
    /// whenever it is closed (before Heartware starts it, when it quits).
    var keepHidden = UserDefaults.standard.bool(forKey: VPNModel.keepHiddenKey)
    /// Windscribe's « Hide from Dock » and « Start minimized » as last read; nil when unreadable.
    var windscribeVisibility: VPNWindscribeFlags?

    @ObservationIgnored private(set) var lastRead: Date?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var installCancel: CancelFlag?
    @ObservationIgnored private var mountedVolume: String?
    @ObservationIgnored private var downloadFolder: URL?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var menuRefreshQueued = false
    /// Asked from the launcher or the menu bar: the end is told by a message (the page shows it by itself).
    @ObservationIgnored private var announce = false
    /// Heartware just started Windscribe: until then, whatever it brings forward goes back out of sight.
    @ObservationIgnored private var hideGuardUntil: Date?
    /// When the last disconnection ended: a click right after it lands where « Déconnecter » was, not a new order.
    @ObservationIgnored private var disconnectedAt: Date?
    nonisolated static let doubleClickPause: TimeInterval = 1.5

    /// Remembered: Windscribe was not signed in to an account the last time it was read.
    private static let signedOutKey = "vpn.signedOut"
    nonisolated static let keepHiddenKey = "vpn.keepHidden"
    /// How long after its start Windscribe is kept out of sight (its window, its activation): short, so that a click of
    /// the user on its menu bar icon soon after is not undone.
    nonisolated static let hideGuardSeconds: TimeInterval = 15
    nonisolated static let installerBundleID = "com.windscribe.installer.macos"
    static let plansPage = "https://windscribe.com/upgrade"

    var isOn: Bool { phase.isOn }

    // MARK: Reading the state

    /// Reads Windscribe's state: only the files when it is closed (`windscribe-cli` would start it), `status` when it runs.
    func refresh() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        lastRead = Date()
        guard operation == nil else { return }
        guard let cli = VPNWindscribe.cliPath() else {
            phase = .notInstalled
            usage = nil
            return
        }
        cleanUpInstaller()
        windscribeVisibility = VPNWindscribe.visibility()
        guard VPNWindscribe.isRunning else {
            phase = UserDefaults.standard.bool(forKey: Self.signedOutKey) ? .loggedOut : .closed
            return
        }
        operation = Task { [weak self] in
            let (status, out) = await VPNWindscribe.status(cli)
            guard let self, !Task.isCancelled else { return }
            self.operation = nil
            if let status {
                self.apply(status, ownAttempt: false)
            } else {
                self.phase = .failed(VPNStatusParser.failure(out.all).message)
            }
        }
    }

    private func apply(_ s: VPNStatus, ownAttempt: Bool) {
        if let u = s.usage { usage = u }
        if let ip = s.ip, !s.ipIsVPN, !phase.isOn { publicIP = ip }
        let p = VPNPhase.from(s, target: target, ownAttempt: ownAttempt)
        phase = p
        switch s.login {
        case .loggedIn: UserDefaults.standard.set(false, forKey: Self.signedOutKey)
        case .loggedOut, .failed: UserDefaults.standard.set(true, forKey: Self.signedOutKey)
        case .loggingIn: break
        }
    }

    /// The menu bar panel shows: a read at most every 20 seconds, after its drawing (never during it).
    /// The menu bar panel opened: its switch shows the real state (read at most every 20 s).
    func menuAppeared() {
        queueMenuRefresh()
    }

    private func queueMenuRefresh() {
        guard !DemoData.isEnabled, !Snapshot.isActive, !menuRefreshQueued else { return }
        if let last = lastRead, Date().timeIntervalSince(last) < 20 { return }
        menuRefreshQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.menuRefreshQueued = false
                self?.refresh()
            }
        }
    }

    // MARK: Connecting

    /// Connects to a free city of `country`. `announce`: asked from outside the page, the end is told by a message.
    func connect(_ country: VPNCountry, announce: Bool = false) {
        guard !DemoData.isEnabled else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        guard let cli = VPNWindscribe.cliPath() else {
            phase = .notInstalled
            return
        }
        if let at = disconnectedAt, Date().timeIntervalSince(at) < Self.doubleClickPause { return }
        operation?.cancel()
        self.announce = announce
        target = country
        phase = .connecting(country)
        lastRead = Date()
        operation = Task { [weak self] in
            await self?.runConnect(country, cli: cli)
            if !Task.isCancelled { self?.operation = nil }
        }
    }

    private func runConnect(_ country: VPNCountry, cli: String) async {
        // A closed Windscribe is started here, out of sight (the CLI would start it in front of everything).
        if !VPNWindscribe.isRunning {
            applyVisibility()
            hideGuardUntil = Date().addingTimeInterval(Self.hideGuardSeconds)
            guard let running = await VPNWindscribe.launchHidden() else {
                return finish(.failed("Windscribe ne démarre pas : ouvre-le une fois toi-même, puis réessaie."))
            }
            if Task.isCancelled { return }
            keepOutOfSight(running)
        }
        // Windscribe must be signed in: the CLI refuses to connect while it is still signing in.
        var status: VPNStatus?
        var out = Shell.Output(status: -1, out: "", err: "")
        for _ in 0..<20 {
            (status, out) = await VPNWindscribe.status(cli)
            if Task.isCancelled { return }
            guard let s = status else { break }
            if s.login != .loggingIn { break }
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
        }
        guard let before = status else { return finish(.failed(VPNStatusParser.failure(out.all).message)) }
        guard before.login == .loggedIn else {
            apply(before, ownAttempt: false)
            return finish(phase)
        }
        if case .connected(let city) = before.link, city.flatMap({ VPNCountry.forCity(VPNStatusParser.cityName($0)) }) == country {
            apply(before, ownAttempt: true)
            return finish(phase)
        }
        phase = .connecting(country)
        let names = country.cliNames
        for (i, name) in names.enumerated() {
            guard let out = await VPNWindscribe.connect(cli, to: name, in: country) else { continue }
            if Task.isCancelled { return }
            guard out.ok else {
                let failure = VPNStatusParser.failure(out.all)
                if failure == .notSignedIn {
                    UserDefaults.standard.set(true, forKey: Self.signedOutKey)
                    return finish(.loggedOut)
                }
                return finish(.failed(failure.message))
            }
            let end = await follow(country, cli: cli, before: before.link)
            if Task.isCancelled { return }
            if end == .unavailable {
                // Refused under this name: the next one (the region's English name), or the end.
                if i < names.count - 1 { continue }
                return finish(.failed(VPNText.unavailable(country)))
            }
            return finish(phase)
        }
        finish(.failed(VPNText.unavailable(country)))
    }

    private enum FollowEnd { case settled, unavailable }

    /// Reads `status` about once a second until the tunnel is up, refused or given up (75 seconds at most).
    private func follow(_ country: VPNCountry, cli: String, before: VPNStatus.Link) async -> FollowEnd {
        let start = Date()
        var moved = false
        // Switching countries, Windscribe may pass by « disconnected » for a moment: only a lasting one is an end.
        var idleSince: Date?
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(900))
            if Task.isCancelled { return .settled }
            let elapsed = Date().timeIntervalSince(start)
            let (status, out) = await VPNWindscribe.status(cli)
            if Task.isCancelled { return .settled }
            guard let s = status else {
                if elapsed > 60 {
                    phase = .failed(VPNStatusParser.failure(out.all).message)
                    return .settled
                }
                continue
            }
            if let u = s.usage { usage = u }
            if s.link != .disconnected { idleSince = nil }
            if s.login != .loggedIn {
                apply(s, ownAttempt: true)
                return .settled
            }
            switch s.link {
            case .connected(let city):
                // Still the previous tunnel, before Windscribe switches to the new country.
                let there = city.flatMap { VPNCountry.forCity(VPNStatusParser.cityName($0)) }
                if !moved, s.link == before || (there != nil && there != country), elapsed < 10 { continue }
                moved = true
                apply(s, ownAttempt: true)
                // The tunnel test goes on a few seconds ("*"): the connection is there already.
                if !s.testing || elapsed > 20 { return .settled }
            case .connecting, .disconnecting:
                moved = true
                phase = .connecting(country)
            case .failed(let error):
                // The last attempt's error stays shown until Windscribe takes the new order.
                if !moved, s.link == before, elapsed < 4 { continue }
                if error == .locationUnavailable { return .unavailable }
                apply(s, ownAttempt: true)
                return .settled
            case .disconnected:
                let idle = idleSince ?? Date()
                idleSince = idle
                if Date().timeIntervalSince(idle) > 5, moved || elapsed > 12 {
                    phase = .failed("Windscribe n'a pas pu se connecter \(country.inName) : réessaie, ou choisis un autre pays.")
                    return .settled
                }
            }
            if elapsed > 75 {
                phase = .failed("La connexion prend trop de temps : regarde ce qu'en dit Windscribe.")
                return .settled
            }
        }
        return .settled
    }

    private func finish(_ final: VPNPhase) {
        phase = final
        lastRead = Date()
        guard announce else { return }
        announce = false
        switch final {
        case .connected(let c): HUD.show("VPN : connecté \(c.place)", symbol: "lock.shield.fill")
        case .loggedOut: HUD.show("Connecte-toi d'abord à ton compte dans Windscribe", symbol: "person.crop.circle.badge.exclamationmark")
        case .outOfData: HUD.show("Tes données Windscribe du mois sont épuisées", symbol: "exclamationmark.triangle.fill")
        case .failed(let message): HUD.show(message, symbol: "exclamationmark.triangle.fill")
        default: break
        }
    }

    // MARK: Disconnecting

    func disconnect(announce: Bool = false) {
        guard !DemoData.isEnabled else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        guard let cli = VPNWindscribe.cliPath() else {
            phase = .notInstalled
            return
        }
        operation?.cancel()
        operation = nil
        // Closed, Windscribe has no tunnel (and the CLI would start it just to answer).
        guard VPNWindscribe.isRunning else {
            phase = .closed
            return
        }
        phase = .disconnecting
        operation = Task { [weak self] in
            let out = await VPNWindscribe.disconnect(cli)
            if Task.isCancelled { return }
            // « Déconnexion… » with its mascot until Windscribe really is disconnected (never a « connecting » on the way).
            var status: VPNStatus?
            for _ in 0..<20 {
                let (read, _) = await VPNWindscribe.status(cli)
                if Task.isCancelled { return }
                status = read
                guard let s = read, s.login == .loggedIn, VPNPhase.stillDisconnecting(s.link) else { break }
                try? await Task.sleep(for: .milliseconds(700))
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.operation = nil
            self.lastRead = Date()
            self.disconnectedAt = Date()
            if let status {
                self.apply(status, ownAttempt: false)
                // Whatever Windscribe still says on the way, the user asked to stop: no « Connexion… » here.
                if case .connecting = self.phase { self.phase = .ready }
            } else {
                self.phase = out.ok ? .ready : .failed(VPNStatusParser.failure(out.all).message)
            }
            if announce, !self.phase.isOn { HUD.show("VPN coupé", symbol: "lock.open.fill") }
        }
    }

    /// From the launcher or the menu bar: straight to the connection when Windscribe can take it, to the page otherwise.
    func connectFromOutside(_ country: VPNCountry, app: AppModel) -> CommandOutcome {
        guard !DemoData.isEnabled else { return .message(DemoData.refusal) }
        guard VPNWindscribe.cliPath() != nil, phase != .loggedOut else {
            app.media.show(.vpn, app: app)
            return .done
        }
        if case .connected(let c) = phase, c.country == country { return .message("Déjà connecté \(country.inName)") }
        connect(country, announce: true)
        return .message("Connexion \(country.inName)…")
    }

    func toggleFromMenu() {
        guard let app = AppContext.model else { return }
        switch phase.menuAction {
        case .disconnect:
            disconnect(announce: true)
        case .connect:
            if case .message(let text) = connectFromOutside(.fr, app: app) { HUD.show(text, symbol: "lock.shield") }
        case .wait:
            break
        }
    }

    /// Windscribe's window in front, on a click (to sign in, or for its own settings).
    func openWindscribe() {
        guard !DemoData.isEnabled else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        hideGuardUntil = nil
        let wasRunning = VPNWindscribe.isRunning
        let cli = VPNWindscribe.cliPath()
        Task {
            await VPNWindscribe.open()
            // Started minimized, it shows no window: once it answers, a « reopen » brings it up.
            guard !wasRunning, let cli else { return }
            _ = await VPNWindscribe.status(cli)
            await VPNWindscribe.open()
        }
    }

    // MARK: Out of sight

    /// Windscribe's settings wait for its next start (or it could not be read).
    var visibilityPending: Bool {
        guard keepHidden, let v = windscribeVisibility else { return false }
        return v != .invisible
    }

    func setKeepHidden(_ on: Bool) {
        guard !DemoData.isEnabled else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        keepHidden = on
        UserDefaults.standard.set(on, forKey: Self.keepHiddenKey)
        applyVisibility()
    }

    /// Writes Windscribe's two settings when it is closed: invisible when the user said yes, as they were before
    /// Heartware changed them otherwise (nothing when it never did).
    private func applyVisibility() {
        guard !DemoData.isEnabled, VPNWindscribe.cliPath() != nil else { return }
        let original = VPNWindscribe.originalVisibility()
        if keepHidden || original != nil {
            let wanted = keepHidden ? VPNWindscribeFlags.invisible : (original ?? .visible)
            if VPNWindscribe.setVisibility(wanted) == .failed {
                HUD.show("Heartware n'a pas pu changer ce réglage de Windscribe", symbol: "exclamationmark.triangle.fill")
            }
        }
        windscribeVisibility = VPNWindscribe.visibility()
    }

    /// Heartware has just started Windscribe: hidden now, and again if it comes forward in the next seconds (its window
    /// at launch, or its own activation), until `hideGuardUntil`.
    private func keepOutOfSight(_ running: NSRunningApplication) {
        if !running.isHidden { running.hide() }
        Task { [weak self] in
            for delay in [0.5, 1.0, 1.5, 3.0, 4.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.guarding, !running.isTerminated else { return }
                if !running.isHidden { running.hide() }
            }
        }
    }

    private var guarding: Bool {
        guard let until = hideGuardUntil else { return false }
        return Date() < until
    }

    /// Windscribe came forward (activated, or shown again).
    private func windscribeSurfaced(_ running: NSRunningApplication) {
        guard guarding else { return }
        running.hide()
    }

    func openPlans() {
        guard !DemoData.isEnabled else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        Finder.open(Self.plansPage)
    }

    // MARK: Installing

    func installWindscribe() {
        guard !DemoData.isEnabled else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        guard installTask == nil else { return }
        let flag = CancelFlag()
        installCancel = flag
        installTask = Task { [weak self] in
            await self?.runInstall(flag)
            self?.installTask = nil
            self?.installCancel = nil
        }
    }

    func cancelInstall() {
        installCancel?.cancel()
        installTask?.cancel()
        install = nil
    }

    /// The download page in the browser, when the installation from Heartware failed.
    func openDownloadPage() {
        guard !DemoData.isEnabled else { return }
        Finder.open(VPNInstaller.downloadPage)
    }

    private func runInstall(_ flag: CancelFlag) async {
        var installer: URL?
        if let brew = VPNInstaller.brewPath() {
            install = .brew("Homebrew télécharge Windscribe…")
            ActionLog.write("HOMEBREW brew install --cask windscribe")
            let gate = VPNLineGate()
            let result = await Task.detached(priority: .userInitiated) { [weak self] in
                Shell.stream(brew, ["install", "--cask", "windscribe"],
                             env: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1"],
                             isCancelled: { flag.isCancelled }) { line in
                    let clean = line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    guard !clean.isEmpty, gate.due() else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if case .brew = self?.install { self?.install = .brew(clean) }
                        }
                    }
                }
            }.value
            if flag.isCancelled { return }
            installer = VPNInstaller.stagedInstaller(brew: brew)
            if installer == nil { ActionLog.write("HOMEBREW échec (code \(result.status)) : téléchargement depuis windscribe.com") }
        }
        if installer == nil {
            let stamp = String(Int(Date().timeIntervalSince1970))
            guard let base = DataStore.ensureFolder(VPNInstaller.folderName),
                  let folder = try? FileOps.makeDirectory(base.appendingPathComponent(stamp)) else {
                install = .failed("Impossible de préparer le dossier du téléchargement.")
                return
            }
            downloadFolder = folder
            install = .downloading(received: 0, expected: 0)
            do {
                let dmg = try await HTTP.download(VPNInstaller.downloadURL, into: folder, name: "Windscribe.dmg") { [weak self] received, expected in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, case .downloading = self.install else { return }
                            self.install = .downloading(received: received, expected: expected)
                        }
                    }
                }
                if flag.isCancelled { return }
                install = .checking
                let mounted = await Task.detached(priority: .userInitiated) { VPNInstaller.mount(dmg) }.value
                guard let mounted else {
                    install = .failed("L'image disque de Windscribe ne s'ouvre pas : réessaie, ou passe par windscribe.com.")
                    return
                }
                mountedVolume = mounted.volume
                installer = mounted.installer
            } catch {
                if flag.isCancelled || Task.isCancelled { return }
                install = .failed("Téléchargement impossible : \(error.localizedDescription)")
                return
            }
        }
        guard let installer, !flag.isCancelled else { return }
        install = .checking
        let problem = await Task.detached(priority: .userInitiated) { VPNInstaller.verify(installer) }.value
        if flag.isCancelled { return }
        if let problem {
            install = .failed(problem)
            return
        }
        VPNInstaller.openInstaller(installer)
        install = .opened
    }

    /// Once Windscribe is installed and its installer closed: the disk image is detached and its download removed.
    private func cleanUpInstaller() {
        guard install?.running != true else { return }
        let installerOpen = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.installerBundleID }
        guard !installerOpen else { return }
        install = nil
        if let volume = mountedVolume {
            mountedVolume = nil
            DispatchQueue.global(qos: .utility).async { VPNInstaller.detach(volume) }
        }
        if let folder = downloadFolder {
            downloadFolder = nil
            _ = Remover.removeInternal(folder.path)
        }
    }

    private func windscribeChanged(launched: Bool, installer: Bool) {
        if installer {
            if !launched { refresh() }
            return
        }
        if launched {
            guard operation == nil else { return }
            if install != nil { install = .opened }
            phase = .starting
            // A moment for Windscribe to sign in with its saved session.
            operation = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.operation = nil
                self?.refresh()
            }
        } else {
            operation?.cancel()
            operation = nil
            hideGuardUntil = nil
            phase = UserDefaults.standard.bool(forKey: Self.signedOutKey) ? .loggedOut : .closed
            // Closed: the moment to write its settings, once it has finished with them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !VPNWindscribe.isRunning else { return }
                    self.applyVisibility()
                }
            }
        }
    }

    // MARK: Module

    func start(app: AppModel) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let launched = name == NSWorkspace.didLaunchApplicationNotification
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let isInstaller = running.bundleIdentifier == VPNModel.installerBundleID
                guard isInstaller || VPNWindscribe.isWindscribe(running) else { return }
                MainActor.assumeIsolated { self?.windscribeChanged(launched: launched, installer: isInstaller) }
            })
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      VPNWindscribe.isWindscribe(running) else { return }
                MainActor.assumeIsolated { self?.windscribeSurfaced(running) }
            })
        }
        // A disk image downloaded during an earlier session.
        _ = Remover.removeInternal(DataStore.url(VPNInstaller.folderName).path)
    }

    func stop() {
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
        operation?.cancel()
        cancelInstall()
    }

    func loadDemo() {
        target = .fr
        phase = .connected(VPNConnection(country: .fr, city: "Paris", proto: "WireGuard:443", ip: "203.0.113.24"))
        usage = VPNUsage(used: 3_435_973_837, limit: 10_737_418_240)
        publicIP = "198.51.100.7"
        install = nil
        keepHidden = true
        windscribeVisibility = .invisible
    }

    /// `--snapshot --page media --tab vpn` (connected), and its other states: `vpn-absent`, `vpn-installation`,
    /// `vpn-installateur`, `vpn-ferme`, `vpn-compte`, `vpn-pret`, `vpn-connexion`, `vpn-limite`, `vpn-erreur`.
    func applySnapshotTab(_ tab: String) {
        guard tab.hasPrefix("vpn") else { return }
        loadDemo()
        switch tab {
        case "vpn-absent":
            phase = .notInstalled
            usage = nil
        case "vpn-installation":
            phase = .notInstalled
            usage = nil
            install = .downloading(received: 41_200_000, expected: 96_500_000)
        case "vpn-installateur":
            phase = .notInstalled
            usage = nil
            install = .opened
        case "vpn-ferme":
            phase = .closed
            usage = nil
        case "vpn-compte":
            phase = .loggedOut
            usage = nil
        case "vpn-pret":
            phase = .ready
            usage = VPNUsage(used: 1_181_116_006, limit: 10_737_418_240)
        case "vpn-connexion":
            phase = .connecting(.fr)
        case "vpn-limite":
            phase = .outOfData
            usage = VPNUsage(used: 10_737_418_240, limit: 10_737_418_240)
        case "vpn-erreur":
            phase = .failed(VPNText.unavailable(.fr))
        default:
            break
        }
    }

    var quickToggles: [QuickToggle] {
        [QuickToggle(id: "vpn", title: VPNText.menuTitle(phase), symbol: phase.isBusy ? "hourglass" : "lock.shield",
                     isOn: phase.isOn) { [weak self] in
            self?.toggleFromMenu()
        }]
    }

    func commands(app: AppModel) -> [AppCommand] { VPNLauncher.commands() }

    func results(for query: String, app: AppModel) -> [AppCommand] { VPNLauncher.results(query) }

    func selfTest() -> [String] { VPNChecks.run() }

    func dump() -> [String] {
        var lines: [String] = []
        if DemoData.isEnabled {
            lines.append("État (démo) : " + VPNText.headline(phase, usage: usage))
            if let usage { lines.append("Données : " + VPNText.usageLine(usage)) }
            return lines
        }
        let app = VPNWindscribe.appURL()
        let cli = VPNWindscribe.cliPath()
        let running = VPNWindscribe.isRunning
        lines.append("Windscribe : " + (app?.path ?? "pas installé") + (app != nil ? (running ? " · ouvert" : " · fermé") : ""))
        lines.append("windscribe-cli : " + (cli ?? "introuvable"))
        lines.append("Homebrew : " + (VPNInstaller.brewPath() ?? "absent"))
        if app != nil {
            let v = VPNWindscribe.visibility()
            lines.append("Réglages de Windscribe : " + (v.map { "masqué du Dock \($0.hideFromDock ? "oui" : "non") · démarrage réduit \($0.startMinimized ? "oui" : "non")" }
                ?? "illisibles (Heartware n'y touche pas)") + " · invisible demandé : " + (keepHidden ? "oui" : "non"))
            if let o = VPNWindscribe.originalVisibility() {
                lines.append("Avant Heartware : masqué du Dock \(o.hideFromDock ? "oui" : "non") · démarrage réduit \(o.startMinimized ? "oui" : "non")")
            }
        }
        if let cli, running {
            let out = Shell.run(cli, ["status"], timeout: 25)
            lines.append("status (code \(out.status)) :")
            lines += out.all.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { "  │ " + $0 }
            if let s = VPNStatusParser.parse(out.out) {
                let p = VPNPhase.from(s, target: nil, ownAttempt: false)
                lines.append("Lu : " + VPNText.headline(p, usage: s.usage) + (s.usage.map { " · " + VPNText.usageLine($0) } ?? ""))
            } else {
                lines.append("Lu : " + VPNStatusParser.failure(out.all).message)
            }
        } else if app != nil {
            lines.append("Statut non lu : Windscribe est fermé (windscribe-cli l'ouvrirait).")
        }
        lines.append("Pays gratuits : " + VPNCountry.allCases.map { "\($0.name) (\($0.cliNames.joined(separator: ", ")))" }
            .joined(separator: " · "))
        return lines
    }
}

/// Lets through at most four lines of Homebrew a second.
final class VPNLineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func due() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.25 else { return false }
        last = now
        return true
    }
}
