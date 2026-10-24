import SwiftUI
import AppKit

/// One domain checked by hand: on this Mac, in the chosen level's list, and among the exceptions.
struct AdBlockCheck: Equatable {
    var domain: String
    var onMac: AdBlockVerdict
    var level: AdBlockLevel
    var inList: AdBlockVerdict
    var excepted: Bool
}

/// The ad blocker: a filtering, encrypted DNS for the whole Mac (every browser and app), installed as a macOS profile
/// the user approves in System Settings. Heartware writes the profile, measures what it blocks, keeps the
/// exceptions and removes it. Nothing runs in the background: the DNS does the work, the app only looks when asked.
@Observable
@MainActor
final class AdBlockModel: AppModule {
    static let profilesPane = "x-apple.systempreferences:com.apple.Profiles-Settings.extension"

    var settings = AdBlockSettings() {
        didSet { store.value = settings }
    }
    var state: AdBlockState = .unknown
    var measuring = false
    /// Measuring a level before installing it (its resolver, over HTTPS), rather than this Mac.
    var measuringLevel: AdBlockLevel?
    var checkText = ""
    var check: AdBlockCheck?
    var checking = false
    var exceptionDraft = ""
    var exceptionError: String?
    /// The profile was opened: System Settings waits for the user's approval.
    var waitingForInstall = false
    var removing = false
    /// The DNS servers the network gives this Mac (read with the state).
    var resolvers: [String] = []
    /// Safari's ad-blocking extensions (nil until read, when the page shows).
    var browserExtensions: [AdBlockExtension]?
    /// The ads stopped, counted from macOS' log.
    var tally = AdBlockTally() {
        didSet { tallyStore.value = tally }
    }
    /// Why the log could not be followed, if it could not.
    var countError: String?

    /// YouTube and Twitch without their video ads, in a window of the app.
    let player = AdBlockPlayer()
    /// YouTube and Twitch opened in the browser go on in the player (`AdBlockHandoff`).
    let handoff = AdBlockHandoff()
    /// The player's accounts, signed in or not (`AdBlockAccount`).
    var accounts: [String: AdBlockAccountState] = AdBlockModel.storedAccounts()
    @ObservationIgnored private let store = JSONStore<AdBlockSettings>("adblock", default: AdBlockSettings())
    @ObservationIgnored private let tallyStore = JSONStore<AdBlockTally>("adblock-tally", default: AdBlockTally())
    /// The live reading of macOS' log, while the blocker is installed.
    @ObservationIgnored private var stream: AdBlockLogStream?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    @ObservationIgnored private weak var app: AppModel?

    init() {
        settings = store.value
        tally = tallyStore.value
        player.model = self
        handoff.player = player
    }

    /// An ad the player cut, added to the counter under the site it was on.
    func countVideoAd(site: String) {
        tally.addOne(app: "Lecteur sans pub · " + (AdBlockPlayerSite.named(site)?.name ?? "YouTube"))
    }

    var measure: AdBlockMeasure? { settings.lastMeasure }

    /// Safari kept playing the last video detached (it does not let the app run its pause script): the page says so.
    var safariRefusedPause: Bool {
        snapshotSafariRefused || AdBlockVideoOnly.scriptsAllowed(AdBlockVideoBrowser.all[0]) == false
    }
    /// `--tab safari`: that warning, without touching the preferences.
    @ObservationIgnored private var snapshotSafariRefused = false

    /// A profile was opened for installation by Heartware.
    var installed: Bool { settings.installedLevel != nil }

    /// The level or the exceptions changed since the profile was installed: it must be installed again.
    var needsReinstall: Bool {
        guard let level = settings.installedLevel else { return false }
        return level != settings.level || Set(settings.installedExceptions ?? []) != Set(settings.exceptions)
    }

    // MARK: Module

    var sidebarBadge: String? {
        if case .on = state { return nil }
        return installed && state == .off ? "inactif" : nil
    }

    func start(app: AppModel) {
        self.app = app
        if installed { startCounting() }
        handoff.start()
    }

    func stop() {
        handoff.stop()
        stopCounting()
        store.flush()
        tallyStore.flush()
    }

    func loadDemo() {
        settings = AdBlockSettings()
        settings.level = .maximal
        settings.exceptions = ["boutique-exemple.fr", "suivi.colis-exemple.fr"]
        settings.installedLevel = .maximal
        settings.installedExceptions = settings.exceptions
        settings.installedAt = Date().addingTimeInterval(-3 * 86_400)
        settings.lastMeasure = Self.demoMeasure(level: nil)
        state = .on(.maximal)
        resolvers = ["192.168.1.1"]
        browserExtensions = AdBlockBrowser.demo
        tally = Self.demoTally()
        tally.apps["Lecteur sans pub · YouTube"] = 37
        tally.apps["Lecteur sans pub · Twitch"] = 6
        tally.total += 43
        // The player's window as the snapshot shows it (nothing is loaded in the demo).
        player.title = "Boussole · le making-of en 12 minutes"
        player.cut = 3
        player.notice = .youtubeHeld
        accounts = ["google": .signedIn(nil), "twitch": .signedOut]
        checkText = "securepubads.g.doubleclick.net"
        check = AdBlockCheck(domain: "securepubads.g.doubleclick.net", onMac: .blocked, level: .maximal, inList: .blocked, excepted: false)
    }

    /// A fortnight of a fictional Mac: the counter, its curve and the apps that tried.
    static func demoTally() -> AdBlockTally {
        var t = AdBlockTally()
        let perDay = [612, 845, 1_204, 980, 733, 1_512, 1_388, 902, 1_120, 1_675, 1_430, 990, 1_268, 418]
        for (i, n) in perDay.enumerated() {
            t.days[AdBlockTally.dayKey(Date().addingTimeInterval(-Double(perDay.count - 1 - i) * 86_400))] = n
        }
        t.total = perDay.reduce(0, +)
        t.apps = ["Safari et pages web": 10_204, "Google Chrome": 2_870, "Mail": 1_032, "Ruche": 588, "Services de macOS": 383]
        t.since = Date().addingTimeInterval(-13 * 86_400)
        t.readUntil = Date().addingTimeInterval(-120)
        return t
    }

    /// What the demo measures: the ads all blocked but one, the useful sites all reachable.
    static func demoMeasure(level: AdBlockLevel?) -> AdBlockMeasure {
        let open: Set<String> = level == .balanced ? ["doubleclick.net", "www.googletagmanager.com", "boot.pbstck.com"] : ["boot.pbstck.com"]
        let probes = AdBlockCanary.ads.map { AdBlockProbe(domain: $0, shouldBlock: true, verdict: open.contains($0) ? .open : .blocked) }
            + AdBlockCanary.useful.map { AdBlockProbe(domain: $0, shouldBlock: false, verdict: .open) }
        return AdBlockMeasure(date: Date().addingTimeInterval(-600), level: level, probes: probes)
    }

    func applySnapshotTab(_ tab: String) {
        switch tab {
        case "intro":
            // Before anything: the blocker never installed, a preview of the Maximal level measured.
            settings.installedLevel = nil
            settings.installedExceptions = nil
            settings.exceptions = []
            settings.lastMeasure = Self.demoMeasure(level: .maximal)
            state = .off
            check = nil
            checkText = ""
        case "installation":
            state = .off
            waitingForInstall = true
        case "reinstaller":
            settings.level = .balanced
        case "sans-extension":
            browserExtensions = []
        case "compteur-vide":
            tally = AdBlockTally()
        case "lecteur-twitch":
            player.notice = .twitchSwapped
        case "video":
            // « Vidéo seule » : the small window, its buttons shown.
            player.previewVideoOnly()
        case "safari":
            // Safari kept playing the last video detached: the warning under « Vidéo seule ». With `--pip refus`, `scripts`,
            // `aucune` or `chrome`: what a page outside the player (Netflix…) answered instead.
            if let state = Entry.value(after: "--pip") {
                player.detachIssue = AdBlockVideoPiP.snapshotIssue(state)
            } else {
                snapshotSafariRefused = true
            }
        case "comptes":
            // Both accounts signed in.
            accounts = ["google": .signedIn(nil), "twitch": .signedIn("camille_des_cimes")]
        case "attente":
            // At work: a measurement on this Mac, a domain being checked, the log being read.
            measuring = true
            checking = true
        default:
            break
        }
    }

    func commands(app: AppModel) -> [AppCommand] { AdBlockCommands.list(self) }

    func results(for query: String, app: AppModel) -> [AppCommand] { AdBlockCommands.results(query, self) }

    func selfTest() -> [String] {
        AdBlockChecks.run(self) + Self.countChecks() + AdBlockVideoOnly.checks() + AdBlockVideoPiP.checks() + AdBlockAccount.checks()
            + AdBlockHandoff.checks() + AdBlockPlayerScripts.checks()
    }

    /// The live counter: a lookup read line by line gives the same events as a whole stretch of log, its memory stays
    /// small, and a stream that keeps failing waits longer each time.
    private static func countChecks() -> [String] {
        var f: [String] = []
        let lines = [
            "2026-10-20 01:03:41.542 Df mDNSResponder[688:3678] [com.apple.mdns:dnssd_server] [R100] getaddrinfo start -- flags: 0xC000D000, client pid: 988 (com.apple.WebKi), delegator uuid: 1",
            "2026-10-20 01:03:41.543 Df mDNSResponder[688:3678] [com.apple.mdns:dnssd_server] [R100->Q1] getaddrinfo result -- event: add, ifindex: 0, name: <dn:Y>, type: A, rdata: 0.0.0.0, expired: yes",
            "2026-10-20 01:03:41.544 Df mDNSResponder[688:3678] [com.apple.mdns:dnssd_server] [R100->Q2] getaddrinfo result -- event: add, ifindex: 0, name: <dn:Y>, type: A, rdata: 0.0.0.0, expired: no"
        ]
        var parser = AdBlockLogParser()
        let live = lines.compactMap { parser.feed($0) }
        if live != AdBlockLog.parse(lines.joined(separator: "\n")) || live.count != 1 || live.first?.app != "Safari et pages web" {
            f.append("Compteur : la lecture en direct ne donne pas les mêmes pubs que la lecture d'un bloc (\(live.map(\.app)))")
        }
        var flood = AdBlockLogParser()
        for i in 0..<(AdBlockLogParser.memory * 3) {
            _ = flood.feed("2026-10-20 01:03:41.542 Df mDNSResponder[688:3678] [x] [R\(i)] getaddrinfo start -- client pid: 9 (Mail), x")
        }
        if flood.remembered > 2 * AdBlockLogParser.memory {
            f.append("Compteur : la mémoire des requêtes grandit sans fin")
        }
        let delays = (1...8).map(AdBlockLogStream.retryDelay(after:))
        if delays.first != 30 || delays.last != 600 || zip(delays, delays.dropFirst()).contains(where: { $0 > $1 }) {
            f.append("Compteur : attente entre deux essais mal réglée (\(delays))")
        }
        return f
    }

    func dump() -> [String] {
        let data = AdBlockProfile.data(level: settings.level, exceptions: settings.exceptions)
        var lines = [
            "Niveau choisi : \(settings.level.title) (\(settings.level.list), \(settings.level.serverURL))",
            "Profil installé par l'app : \(settings.installedLevel.map { "\($0.title), le \(Fmt.relative(settings.installedAt ?? Date()))" } ?? "non")",
            "Exceptions : \(settings.exceptions.isEmpty ? "aucune" : settings.exceptions.joined(separator: ", "))",
            "Profil généré : \(data.map { Fmt.bytes(Int64($0.count)) } ?? "échec") · \(AdBlockProfile.neverConnect(exceptions: settings.exceptions).count) domaines hors filtre"
        ]
        if !DemoData.isEnabled {
            lines.append("État de ce Mac : \(AdBlockCLI.describe(AdBlockProbes.state())) · DNS du réseau : \(AdBlockProbes.networkResolvers().joined(separator: ", "))")
        }
        let safari = AdBlockVideoOnly.scriptsAllowed(AdBlockVideoBrowser.all[0])
        lines.append("Vidéo seule : \(player.pinned ? "au-dessus des autres fenêtres" : "passe derrière") · pause et image dans l'image de Safari : "
                     + (safari == true ? "possibles" : safari == false ? "JavaScript des évènements Apple refusé" : "pas encore essayées"))
        lines.append("Comptes du lecteur : " + AdBlockAccount.all.map { a in
            switch accounts[a.key] ?? .signedOut {
            case .signedOut: return "\(a.name) non connecté"
            case .signedIn(let name): return "\(a.name) connecté" + (name.map { " (\($0))" } ?? "")
            }
        }.joined(separator: ", "))
        lines.append("Bascule depuis le navigateur : \(handoff.enabled ? "allumée" : "éteinte")"
                     + (handoff.refused.isEmpty ? "" : " · refusée par \(handoff.refused.joined(separator: ", "))"))
        if let m = measure {
            lines.append("Dernière mesure (\(m.level.map { "niveau \($0.title)" } ?? "ce Mac"), \(Fmt.relative(m.date))) : \(m.blockedAds)/\(m.ads.count) pubs bloquées")
        }
        return lines
    }

    // MARK: State

    /// Three short lookups through this Mac's resolver: is the filter on, and at which level?
    func refreshState() {
        guard !DemoData.isEnabled, !Snapshot.isActive, state != .checking else { return }
        state = .checking
        Task {
            let found = await Task.detached(priority: .userInitiated) { AdBlockProbes.state() }.value
            resolvers = await Task.detached(priority: .utility) { AdBlockProbes.networkResolvers() }.value
            state = found
            if found.isOn { waitingForInstall = false }
        }
    }

    // MARK: Counting

    /// Stops following the log; what it counted and did not hand over yet is kept.
    private func stopCounting() {
        guard let stream else { return }
        let left = stream.stopNow()
        self.stream = nil
        if !left.isEmpty { tally.add(left, readUntil: Date()) }
    }

    /// The log is followed live while the blocker is installed: nothing to read back after a sleep or at launch.
    private func startCounting() {
        guard stream == nil, !DemoData.isEnabled, !Snapshot.isActive else { return }
        let s = AdBlockLogStream(onEvents: { [weak self] events in
            self?.tally.add(events, readUntil: Date())
        }, onError: { [weak self] why in
            if self?.countError != why { self?.countError = why }
        })
        stream = s
        s.start()
    }

    // MARK: Safari extensions

    /// The ad blockers installed in Safari (a quick read of the system's extension list).
    func refreshExtensions() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        Task {
            let found = await Task.detached(priority: .utility) { AdBlockBrowser.installed() }.value
            if found != browserExtensions { browserExtensions = found }
        }
    }

    func openSafari() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Safari.app"), configuration: NSWorkspace.OpenConfiguration())
    }

    /// The extension's own app: it has the button that opens Safari's settings on the extension.
    func openExtensionApp(_ ext: AdBlockExtension) {
        guard !DemoData.isEnabled, !Snapshot.isActive, let path = ext.appPath, FS.exists(path) else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }

    func openRecommendedStore() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        Finder.open(AdBlockBrowser.recommendedStore)
    }

    // MARK: Measuring

    /// Every canary domain, on this Mac (`level` nil) or through a level's resolver before installing it.
    func runMeasure(level: AdBlockLevel? = nil) {
        guard !measuring else { return }
        guard !DemoData.isEnabled, !Snapshot.isActive else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        measuring = true
        measuringLevel = level
        Task {
            let m = await AdBlockProbes.measure(level: level)
            settings.lastMeasure = m
            measuring = false
            measuringLevel = nil
            if level == nil {
                // The measurement tells the state as well.
                let verdict = { (d: String) in m.probes.first { $0.domain == d }?.verdict ?? .unknown }
                state = m.offline ? .offline : AdBlockState.from(both: verdict(AdBlockCanary.both), maximalOnly: verdict(AdBlockCanary.maximalOnly),
                                                                 reachable: m.useful.contains { $0.verdict == .open } ? .open : .unknown)
                if state.isOn { waitingForInstall = false }
            }
            if m.offline { HUD.show("Pas de réponse du réseau : vérifie ta connexion", symbol: "wifi.exclamationmark") }
        }
    }

    // MARK: Checking a domain

    func checkDomain() {
        guard !checking, let domain = AdBlockDomain.normalize(checkText, keepWWW: true) else {
            if !checkText.isEmpty { check = nil; HUD.show("Ce n'est pas un nom de domaine (exemple : pub.exemple.fr)", symbol: "exclamationmark.circle.fill") }
            return
        }
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        checking = true
        let level = settings.level
        Task {
            async let mac = Task.detached(priority: .userInitiated) { AdBlockProbes.systemVerdict(domain) }.value
            async let list = AdBlockProbes.resolverVerdict(domain, level: level)
            let (onMac, inList) = await (mac, list)
            check = AdBlockCheck(domain: domain, onMac: onMac, level: level, inList: inList, excepted: isExcepted(domain))
            checking = false
        }
    }

    func isExcepted(_ domain: String) -> Bool {
        settings.exceptions.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    // MARK: Exceptions

    @discardableResult
    func addException(_ raw: String) -> Bool {
        guard let d = AdBlockDomain.normalize(raw) else {
            exceptionError = "« \(raw.trimmingCharacters(in: .whitespaces)) » n'est pas un nom de domaine (exemple : boutique.fr)."
            return false
        }
        guard !settings.exceptions.contains(d) else {
            exceptionError = "\(d) est déjà dans les exceptions."
            return false
        }
        settings.exceptions.append(d)
        settings.exceptions.sort()
        exceptionError = nil
        exceptionDraft = ""
        if check?.domain == d || check.map({ $0.domain.hasSuffix("." + d) }) == true { check?.excepted = true }
        return true
    }

    func removeException(_ d: String) {
        settings.exceptions.removeAll { $0 == d }
        if let c = check { check?.excepted = isExcepted(c.domain) }
    }

    // MARK: Installing and removing

    /// Writes the profile, hands it to macOS and opens System Settings on the profiles, where the user approves it.
    func install() {
        guard !DemoData.isEnabled, !Snapshot.isActive else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        guard let data = AdBlockProfile.data(level: settings.level, exceptions: settings.exceptions),
              let folder = DataStore.ensureFolder("AdBlock") else {
            HUD.show("Impossible de préparer le profil", symbol: "xmark.octagon.fill")
            return
        }
        let url = folder.appendingPathComponent(AdBlockProfile.fileName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            HUD.show("Impossible d'écrire le profil : \(error.localizedDescription)", symbol: "xmark.octagon.fill")
            return
        }
        DataStore.protect(url)
        ActionLog.write("BLOQUEUR DE PUB profil \(settings.level.title) préparé · \(url.path)")
        NSWorkspace.shared.open(url)
        // macOS keeps the profile aside until the user approves it in System Settings: open it there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { Finder.open(Self.profilesPane) }
        settings.installedLevel = settings.level
        settings.installedExceptions = settings.exceptions
        settings.installedAt = Date()
        waitingForInstall = true
        watchReturn()
        startCounting()
    }

    /// Back from System Settings: is the filter on now?
    private func watchReturn() {
        guard activeObserver == nil else { return }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.waitingForInstall else { return }
                // System Settings has just let go of the DNS: a moment for it to apply.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshState() }
            }
        }
    }

    /// Removes the profile (administrator password). If macOS refuses, System Settings opens on the profiles.
    func remove() {
        guard !removing else { return }
        guard !DemoData.isEnabled, !Snapshot.isActive else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        removing = true
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                Shell.runAsAdmin("/usr/bin/profiles remove -identifier fr.cleanmyclaude.adblock")
            }.value
            removing = false
            if r.ok {
                ActionLog.write("BLOQUEUR DE PUB profil retiré")
                settings.installedLevel = nil
                // No blocker of ours any more: a 0.0.0.0 answer would come from another one (a Pi-hole, a hosts file).
                stopCounting()
                settings.installedExceptions = nil
                settings.installedAt = nil
                waitingForInstall = false
                HUD.show("Bloqueur de pub retiré : tout est comme avant", symbol: "hand.raised.slash.fill")
                refreshState()
            } else if r.all.contains("-128") {
                return // the password window was cancelled
            } else {
                Finder.open(Self.profilesPane)
                HUD.show("Retire « \(AdBlockProfile.displayName) » dans Réglages Système › Profils", symbol: "info.circle.fill")
            }
        }
    }

    func openProfiles() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        Finder.open(Self.profilesPane)
    }

    /// The Multimédia page on one of the blocker's tabs (`.blocker` or `.player`).
    func openPage(_ tab: MediaTab = .blocker) {
        guard let app = app ?? AppContext.model else { return }
        app.media.show(tab, app: app)
    }
}
