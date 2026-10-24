import Foundation
import SwiftUI
import AppKit

@main
enum Entry {
    /// False when LaunchServices started the app bundle (Finder, Dock, login, `open -a "Heartware" --args …`):
    /// its parent is then launchd. Started that way the app answers to macOS with its own permissions (Full Disk Access…),
    /// so any program could make it read a protected folder and write the result where it likes (`--dump --storage
    /// ~/Library/Messages`, `--snapshot <folder>`): every command line mode, `--demo` included, is ignored and the app
    /// opens normally. The same when a program started the bundle "disclaimed" (posix_spawn with
    /// responsibility_spawnattrs_setdisclaim): the app is then responsible for itself, with its own permissions too.
    /// The binary started from a terminal (.build/debug/Heartware, or the bundle's own executable run from a shell)
    /// keeps them: macOS then holds the terminal responsible, with the terminal's permissions.
    static let commandLineAllowed: Bool = {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return true }
        if getppid() == 1 { return false }
        return Shell.responsiblePID(getpid()) != getpid()
    }()

    /// The command line as the app may read it: only the executable when `commandLineAllowed` is false.
    static let arguments: [String] = commandLineAllowed ? CommandLine.arguments : Array(CommandLine.arguments.prefix(1))

    static func main() {
        // A tool that quits before reading its input (claude, a killed process) must not take the app down with it.
        signal(SIGPIPE, SIG_IGN)
        if !commandLineAllowed {
            // "-key value" arguments also land in UserDefaults (`-launcher.indexConsent YES`…): none from a launch by another program.
            UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            // A copy updated from a version under an older name: its folders and settings first, then its own file name.
            HeartwareLegacy.migrate()
            if HeartwareLegacy.renameBundleIfNeeded() { exit(0) }
            HeartwareApp.main()
            return
        }
        let args = arguments
        if args.contains(UpdatesSelfKeychain.flag) {
            // Launched by the previous version during an update: takes over its keychain items, nothing else.
            exit(UpdatesSelfKeychain.adopt())
        }
        if args.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }
        if let question = value(after: "--ask") {
            // Asks Claude through Claude Code (the user's subscription), exactly like the Assistant page.
            MainActor.assumeIsolated {
                let app = AppModel(liveMonitor: false)
                let ids = AssistantModel.catalog(app: app).map(\.id)
                let model = AssistantModelChoice(rawValue: value(after: "--model") ?? "") ?? .haiku
                let status = AssistantClaudeCode.status()
                print("Claude Code : \(status.binary ?? "introuvable") · connecté : \(status.loggedIn ? "oui (\(status.method ?? "?"))" : "non")")
                do {
                    let t = Date()
                    let a = try AssistantClaudeCode.ask(system: AssistantModel.systemPrompt(app: app, lookups: false, structured: true),
                                                        prompt: "QUESTION :\n" + question,
                                                        schema: AssistantClaudeCode.schema(commandIDs: ids), model: model)
                    print(String(format: "Réponse de %@ en %.1f s, %d jetons :", a.model ?? "?", Date().timeIntervalSince(t), a.tokens))
                    print(a.text)
                    for act in a.actions { print("→ action proposée : \(act.id) — \(act.reason)") }
                } catch {
                    print("✗ \(error.localizedDescription)")
                }
            }
            return
        }
        if args.contains("--watchdog-check") {
            // The main thread frozen on purpose: what the watchdog notes, and what it would do.
            let failures = MainActor.assumeIsolated { MainWatchdog.rehearse() }
            for f in failures { print("✗ \(f)") }
            print(failures.isEmpty ? "✓ vigie du fil principal OK" : "✗ \(failures.count) échec(s)")
            exit(failures.isEmpty ? 0 : 1)
        }
        if args.contains("--devices-check") {
            // The shared watch of the microphone, the sound and the cameras, for a while: what reaches the main thread.
            let seconds = Double(value(after: "--devices-check") ?? "") ?? 20
            let watch = DeviceActivity.shared
            var changes = 0
            let cpu0 = ProcessInfo.processInfo.systemUptime
            let usage0 = Entry.processCPU()
            let id = MainActor.assumeIsolated {
                watch.watch { s in
                    changes += 1
                    print("état \(changes) : \(s.sounding.count) processus font du son, micro \(s.microphoneOn ? "allumé" : "éteint"), caméra \(s.cameraOn ? "allumée" : "éteinte")")
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            watch.unwatch(id)
            let used = Entry.processCPU() - usage0
            let span = ProcessInfo.processInfo.systemUptime - cpu0
            print("\(watch.readingCount) lectures, \(changes) états transmis au fil principal, processeur \(String(format: "%.2f", used)) s en \(Int(span)) s")
            return
        }
        if let path = value(after: "--doc-check") {
            for line in ConverterDocCheck.run(path, format: value(after: "--to"), folder: value(after: "--out")) { print(line) }
            return
        }
        if let path = value(after: "--fillsign-check") {
            // What the signing window opens for this file (a Word document is laid out as a PDF first), written nowhere.
            for line in FillSignDocument.check(path) { print(line) }
            return
        }
        if args.contains("--wheel-check") {
            // The wheel alone, for a while: the gestures it sees, what is under the pointer, the drop and its copy.
            let seconds = Double(value(after: "--wheel-check") ?? "") ?? 30
            MainActor.assumeIsolated { WheelCheck.run(seconds: seconds) }
            return
        }
        if let i = args.firstIndex(of: "--wheel-engines"), args.count > i + 1 {
            // Every action of the wheel on made-up files in that folder, and what each one wrote.
            final class Done: @unchecked Sendable { var value = false }
            let done = Done()
            let folder = args[i + 1]
            Task.detached {
                for line in await WheelEngineCheck.run(folder: folder) { print(line) }
                done.value = true
            }
            while !done.value { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return
        }
        if args.contains("--preview-check") {
            final class Done: @unchecked Sendable { var value = false }
            let done = Done()
            Task.detached {
                for line in await ConverterPreviewCheck.run() { print(line) }
                done.value = true
            }
            while !done.value { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return
        }
        if args.contains("--languages") {
            // What Apple's on-device translation has on this Mac, from French (the same check as the app).
            final class Done: @unchecked Sendable { var value = false }
            let done = Done()
            Task.detached {
                for l in TranslatorLanguage.all where l.code != "fr" {
                    let s = await TranslatorAvailability.status(from: "fr", to: l.code)
                    print("fr → \(l.code) (\(l.name)) : \(s.label)")
                }
                done.value = true
            }
            // The framework answers on the main run loop: keep it turning while waiting.
            while !done.value { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return
        }
        if let text = value(after: "--translate") {
            // The translator's Claude engine, from the command line (the on-device engine needs a window).
            let detected = TranslatorLanguage.detect(text)
            let target = TranslatorLanguage.effectiveTarget(value(after: "--to") ?? "en", detected: detected)
            let tone = TranslatorTone(rawValue: value(after: "--tone") ?? "") ?? .neutral
            let model = AssistantModelChoice(rawValue: value(after: "--model") ?? "") ?? .haiku
            let schema: [String: Any] = ["type": "object", "properties": ["reponse": ["type": "string"]],
                                         "required": ["reponse"], "additionalProperties": false]
            print("\(TranslatorLanguage.named(detected)) → \(TranslatorLanguage.named(target)), \(model.familyTitle), ton \(tone.title.lowercased())")
            do {
                let t = Date()
                let a = try AssistantClaudeCode.ask(system: TranslatorModel.claudeSystem(target: target, source: detected, tone: tone),
                                                    prompt: text, schema: schema, model: model, effort: "low", timeout: 180)
                print(String(format: "%.1f s : %@", Date().timeIntervalSince(t), a.text))
            } catch {
                print("✗ \(error.localizedDescription)")
            }
            return
        }
        if args.contains("--update-check") || args.contains("--update-install") {
            // Heartware's own update, from the command line (see UpdatesSelfCLI).
            final class Done: @unchecked Sendable { var value = false }
            let done = Done()
            Task.detached {
                await UpdatesSelfCLI.run()
                done.value = true
            }
            while !done.value { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return
        }
        if args.contains("--cinema-check") {
            // Films et séries against the real TMDB and Wikidata (see CinemaCLI).
            final class Done: @unchecked Sendable { var value = false }
            let done = Done()
            Task.detached {
                await CinemaCLI.run()
                done.value = true
            }
            while !done.value { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return
        }
        if let i = args.firstIndex(of: "--adblock") {
            // The ad blocker from the command line: measure it, check a domain, write its profile (see AdBlockCLI).
            final class Done: @unchecked Sendable { var value = false }
            let done = Done()
            let rest = Array(args[(i + 1)...])
            Task.detached {
                await AdBlockCLI.run(rest)
                done.value = true
            }
            while !done.value { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return
        }
        if let i = args.firstIndex(of: "--xprotect") {
            ProtectionCLI.run(Array(args[(i + 1)...]))
            return
        }
        if args.contains("--menubar-check") {
            // The menu bar panel in its real popover for a few seconds: the popover's height against the panel's.
            let out = value(after: "--menubar-check").flatMap { $0.hasPrefix("--") ? nil : $0 }
            let ok = MainActor.assumeIsolated { StatusItemController.check(out: out) }
            exit(ok ? 0 : 1)
        }
        if args.contains("--dump") {
            MainActor.assumeIsolated { Diagnostics.run() }
            return
        }
        if let i = args.firstIndex(of: "--snapshot") {
            let dir = args.count > i + 1 ? args[i + 1] : "snapshots"
            MainActor.assumeIsolated { Snapshot.run(dir: dir) }
            return
        }
        HeartwareLegacy.migrate()
        HeartwareApp.main()
    }

    /// The processor time this process has used so far, in seconds.
    static func processCPU() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    static func value(after flag: String) -> String? {
        let args = arguments
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
        return args[i + 1]
    }
}

/// `Heartware --dump` prints what every scanner finds, without deleting anything.
@MainActor
enum Diagnostics {
    static func timed<T>(_ label: String, _ f: () -> T) -> T {
        let t = Date()
        let r = f()
        print(String(format: "  ⏱ %@ : %.2f s", label, Date().timeIntervalSince(t)))
        return r
    }

    static func run() {
        print("Heartware — diagnostic (lecture seule)" + (DemoData.isEnabled ? " · données de démonstration (fictives)" : ""))
        print("Accès complet au disque : \(Permissions.hasFullDiskAccess ? "oui" : "non")")
        let monitor = SystemMonitor(start: false)
        usleep(500_000)
        monitor.sample()
        print("\n== Système")
        print("  CPU \(Fmt.pct(monitor.cpu)) · RAM \(Fmt.bytes(monitor.memUsed))/\(Fmt.bytes(monitor.memTotal)) (\(monitor.pressure.label)) · swap \(Fmt.bytes(monitor.swapUsed))")
        print("  Disque \(Fmt.bytes(monitor.diskFree)) libres (\(Fmt.bytes(monitor.diskFreeStrict)) strict) sur \(Fmt.bytes(monitor.diskTotal))")
        print("  Réseau ↓\(Fmt.speed(monitor.netIn)) ↑\(Fmt.speed(monitor.netOut)) · uptime \(Fmt.duration(monitor.uptime)) · thermique \(monitor.thermalLabel)")
        if let b = monitor.battery {
            print("  Batterie \(Fmt.pct(b.level)) charge=\(b.isCharging) santé=\(b.health.map(Fmt.pct) ?? "?") cycles=\(b.cycleCount ?? -1)")
        }
        print("  \(SystemMonitor.chipName) · \(SystemMonitor.modelName)")

        let running = RunningApps.snapshot()
        let only = Entry.value(after: "--only")

        if only == nil || only == "cleanup" {
            print("\n== Nettoyage")
            let targets = timed("analyse") { CleanupScanner.scan(running: running) }
            for t in targets where !t.items.isEmpty || t.needsFullDiskAccess {
                let on = t.cleanable.filter(\.defaultOn).reduce(Int64(0)) { $0 + $1.size }
                let blocked = t.items.filter { $0.blockedReason != nil }.count
                print("  [\(t.group.title)] \(t.title) : \(Fmt.bytes(t.size)) en \(Fmt.plural(t.items.count, "élément", "éléments"))" +
                      (t.needsFullDiskAccess ? " — ACCÈS COMPLET REQUIS" : "") +
                      " · coché \(Fmt.bytes(on))" + (blocked > 0 ? " · \(blocked) bloqués (app ouverte)" : ""))
                for i in t.items.prefix(3) { print("      \(Fmt.bytes(i.size))\t\(i.name)\(i.detail.map { " — \($0)" } ?? "")") }
            }
            let fp = CleanupScanner.claudeFootprint()
            print("  Claude gardé : transcripts \(Fmt.bytes(fp.transcripts)), VM \(Fmt.bytes(fp.vm)), versions \(Fmt.bytes(fp.codeVersions))")
        }

        if only == nil || only == "security" {
            print("\n== Sécurité")
            for c in timed("bilan", { SecurityAudit.run() }) {
                print("  \(c.status.label.padding(toLength: 11, withPad: " ", startingAt: 0)) \(c.title) — \(c.detail)")
            }
            print("\n== Éléments persistants")
            let items = timed("signatures") { LaunchItemScanner.scan() }
            for i in items {
                print("  [\(i.domain.rawValue)] \(i.label) · \(i.signature.label)\(i.disabled ? " · désactivé" : "")\(i.running ? " · en cours" : "")" +
                      (i.flags.isEmpty ? "" : " ⚠︎ " + i.flags.map(\.rawValue).joined(separator: ", ")))
            }
            print("\n== Autorisations")
            if let grants = TCCReader.read() {
                print("  \(grants.count) autorisations lues")
            } else {
                print("  Illisibles (accès complet au disque requis)")
            }
            print("\n== Traces")
            for t in PrivacyScanner.scan(running: running) {
                print("  [\(t.group)] \(t.title) · \(t.count.map { "\($0) entrées" } ?? "") \(Fmt.bytes(t.size))\(t.needsFullDiskAccess ? " — ACCÈS REQUIS" : "")\(t.blockedReason.map { " — \($0)" } ?? "")")
            }
        }

        if only == nil || only == "apps" {
            print("\n== Applications")
            let apps = timed("inventaire") { AppInventory.scan(running: running) }
            print("  \(apps.count) apps, \(Fmt.bytes(apps.reduce(0) { $0 + $1.size }))")
            for a in apps.prefix(8) {
                print("  \(Fmt.bytes(a.size))\t\(a.name) \(a.version ?? "") · \(a.architecture.label)\(a.fromAppStore ? " · App Store" : "") · \(a.lastUsed.map(Fmt.relative) ?? "jamais")")
            }
            print("  Inutilisées : \(apps.filter { $0.isUnused && !$0.isApple }.map(\.name).joined(separator: ", "))")
            print("  Intel : \(apps.filter { $0.architecture == .intel }.map(\.name).joined(separator: ", "))")
            if let slack = apps.first(where: { !$0.isApple && $0.bundleID != nil }) {
                let left = Leftovers.find(for: slack)
                print("  Restes de \(slack.name) : \(left.map { "\($0.detail ?? "") \(Fmt.bytes($0.size))" }.joined(separator: ", "))")
            }
            let orphans = timed("restes orphelins") { OrphanFinder.scan(installed: apps, includeContainers: Permissions.hasFullDiskAccess) }
            print("  \(orphans.count) restes orphelins, \(Fmt.bytes(orphans.reduce(0) { $0 + $1.size }))")
            for o in orphans.prefix(8) { print("      \(Fmt.bytes(o.size))\t\(o.name) — \(o.detail ?? "")") }
        }

        if only == nil || only == "processes" {
            print("\n== Processus (groupés par app)")
            for g in ProcessList.sample().sorted(by: { $0.memory > $1.memory }).prefix(8) {
                print("  \(Fmt.bytes(g.memory))\t\(Fmt.dec(g.cpu)) %\t\(g.name) (\(g.processCount))")
            }
        }

        // Modules: `--only <module>` (launcher, converter, toolbox…).
        let app = AppModel(liveMonitor: false)
        AppContext.model = app
        for e in ModuleRegistry.modules(app) where only == e.id {
            print("\n== \(e.title)")
            for line in e.module.dump() { print("  \(line)") }
        }

        if let path = Entry.value(after: "--storage") {
            print("\n== Stockage : \(path)")
            let r = timed("carte") { StorageScanner.scan(FS.expand(path), isCancelled: { false }) { _, _ in } }
            print("  \(Fmt.bytes(r.root.size)) · \(r.scannedFiles) fichiers · \(r.unreadable) illisibles")
            for c in r.root.children.prefix(10) { print("      \(Fmt.bytes(c.size))\t\(c.name)\(c.complete ? "" : " (+)")") }
            print("  Gros fichiers : \(r.bigFiles.prefix(5).map { "\($0.name) \(Fmt.bytes($0.size))" }.joined(separator: ", "))")
        }
        if let path = Entry.value(after: "--duplicates") {
            print("\n== Doublons : \(path)")
            let groups = timed("doublons") { DuplicateFinder.find(in: [FS.expand(path)], isCancelled: { false }) { _ in } }
            print("  \(groups.count) groupes, \(Fmt.bytes(groups.reduce(0) { $0 + $1.wasted })) en trop")
        }
    }
}

/// `Heartware --snapshot <dir> [--page cleanup] [--light] [--theme graphite] [--scale 2] [--demo]` renders pages to PNG,
/// with real scan data or, with `--demo`, the fictional Mac of `DemoData`.
/// `--page appearance` renders the theme settings (`--tab edit` shows the editor, on a copy of the theme),
/// `--page mascotte` every scene of the busy mascot, `--page reglages` the Réseau tab of the settings, `--page fenetre`
/// the whole window (sidebar, stage and toolbar; `--tab cleanup` opens that page in it), and `--tab attente`
/// a page while its work is in progress.
@MainActor
enum Snapshot {
    /// True while rendering: AppKit controls (menus, fields, switches) come out as yellow boxes in `ImageRenderer`
    /// and scroll views come out empty, so views swap them for drawn equivalents.
    nonisolated static let isActive = Entry.arguments.contains("--snapshot")

    static func run(dir: String) {
        _ = NSApplication.shared
        let themes = ThemeStore.shared
        if let id = Entry.value(after: "--theme") {
            guard themes.all.contains(where: { $0.id == id }) else {
                print("thème inconnu : \(id) (\(themes.all.map(\.id).joined(separator: ", ")))")
                return
            }
            themes.select(id)
        }
        // A theme that is always light or always dark decides on its own.
        let light = themes.active.appearance == .system ? Entry.arguments.contains("--light") : themes.active.appearance == .light
        let appearance = NSAppearance(named: light ? .aqua : .darkAqua)!
        NSApp.appearance = appearance
        let scale = Entry.value(after: "--scale").flatMap(Double.init) ?? 1
        let pageName = Entry.value(after: "--page")
        let only = pageName.flatMap(Page.init(rawValue:))

        // In demo mode the model fills itself with the fictional Mac.
        let model = AppModel(liveMonitor: false)
        model.showOnboarding = false
        if !DemoData.isEnabled { scan(model) }
        // `--profile etudes,loisirs` (or `aucun`): the sidebar and the dashboard of that profile, nothing saved.
        if let slugs = Entry.value(after: "--profile") { model.profile.preview(slugs) }

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var shots: [(String, AnyView)] = []
        let everything = only == nil && !["appearance", "mascotte", "reglages", "fenetre"].contains(pageName ?? "")
        if pageName == "fenetre" {
            model.page = Entry.value(after: "--tab").flatMap(Page.init(rawValue:)) ?? .dashboard
            shots.append(("fenetre-panel", AnyView(WindowShell().frame(height: 900))))
        }
        if pageName == "mascotte" {
            // Every scene of the busy mascot, frame by frame.
            shots.append(("mascotte-panel", AnyView(MascotGallery())))
        }
        if pageName == "appearance" {
            if Entry.value(after: "--tab") == "edit" { themes.duplicate(themes.active) }
            shots.append(("appearance-panel", AnyView(AppearanceSettings())))
        }
        if pageName == "reglages" {
            // Réglages › Réseau, one picture per part (`--tab attente`: a speed test under way).
            for section in NetworkTab.allCases {
                shots.append(("reglages-reseau-\(section.rawValue)-panel",
                              AnyView(NetworkSettings(section: section).frame(height: NetworkSettings.height))))
            }
        }
        for page in Page.allCases where everything || only == page {
            shots.append((page.rawValue, AnyView(PageView(page: page))))
        }
        if everything || only == .menubar {
            shots.append(("menubar-panel", AnyView(MenuBarPanel())))
            // The menu bar item while a video downloads, over a light and a dark bar.
            shots.append(("statusitem-panel", AnyView(StatusItemPreview())))
        }
        if everything || only == .dashboard {
            // The sidebar (it follows the profile, `--tab autres` unfolds « Autres outils ») and the profile panel.
            shots.append(("sidebar-panel", AnyView(Sidebar(unfoldOthers: Entry.value(after: "--tab") == "autres").fixedSize(horizontal: false, vertical: true))))
            shots.append(("profile-panel", AnyView(ProfilePanel())))
            // The first-launch cards, one picture each (`--tab barre` keeps only that one), then as the user sees
            // them: in the middle of the window, the dashboard dimmed behind them.
            let tab = Entry.value(after: "--tab")
            for slide in OnboardingSlide.allCases where tab == nil || tab == slide.snapshotName {
                shots.append(("onboarding-\(slide.snapshotName)-panel", AnyView(OnboardingPanel(start: slide))))
            }
            shots.append(("onboarding-window-panel", AnyView(
                PageView(page: .dashboard)
                    .padding(32)
                    .frame(width: 1180, height: 760, alignment: .top)
                    .clipped()
                    .background(Theme.bg)
                    .overlay { OnboardingModal() }
            )))
        }
        if everything || only == .updates {
            // Heartware's own update panel (`--tab maj-telechargement`, `maj-prete`… for its other steps).
            shots.append(("selfupdate-panel", AnyView(UpdatesSelfPanel())))
            // And as the user sees it: in the middle of the window, the page dimmed behind it.
            shots.append(("selfupdate-window-panel", AnyView(
                PageView(page: .updates)
                    .padding(32)
                    .frame(width: 1180, height: 760, alignment: .top)
                    .clipped()
                    .background(Theme.bg)
                    .overlay { UpdatesSelfModal() }
            )))
        }
        if everything || only == .hotkeys {
            // The floating panel, as if the user had typed `--query` (default: a calculation).
            // `--tab files` shows the file window instead (`--query ""` for its first screen); `--tab youtube` a pasted
            // YouTube link and its pane (`youtube:outils`, `youtube:audio`…), `--tab telechargements` the download list,
            // `--tab traducteur` the translator (`traducteur:reglages` its settings). The launcher's settings are on the
            // page itself: `--tab lanceur` (Raccourcis › Heartware), `lanceur:indexation`, `lanceur:sans-index`.
            model.launcher.preview(Entry.value(after: "--query") ?? "1250*1,2", app: model)
            shots.append(("launcher-panel", AnyView(LauncherView())))
        }
        if everything || only == .media {
            // The page's tabs: `--tab films`, `lecteur`, `bloqueur`, `vpn` (and their states: `cle`, `comptes`, `safari`, `intro`…,
            // `vpn-absent`, `vpn-installation`, `vpn-compte`, `vpn-pret`, `vpn-connexion`, `vpn-limite`, `vpn-erreur`…).
            // The ad-free player's window: its bar and what it says over a video (the page itself cannot be drawn here).
            // `--tab video` : the « Vidéo seule » window instead, 16:9.
            shots.append(("adblock-player-panel", AnyView(AdBlockPlayerSnapshot(player: model.adblock.player))))
            // `--tab bulles` : every « ? » of the page, opened.
            if Entry.value(after: "--tab") == "bulles" {
                shots.append(("media-tips-panel", AnyView(MediaTipsGallery())))
            }
        }
        if everything || only == .refuge {
            // The chamois' birth (`--tab naissance`, `naissance-nom`, `refus`…), a mue (`mue`, `echarpe`) or its path (`voie`),
            // as it shows in the middle of the window.
            shots.append(("refuge-ceremony-panel", AnyView(RefugeCeremonyPanel())))
        }
        var widths: [String: CGFloat] = [:]
        if everything || only == .wheel {
            // The wheel over a desktop (`--tab pdf`, `video`… for another kind of file), the Convertisseur's window (the same
            // tab picks its scene: `renommer`, `texte`, `qr`, `vide`…, and a few more scenes besides), the small windows and the toast.
            for p in WheelDemo.panels(model) {
                shots.append((p.name, p.view))
                widths[p.name] = p.width
            }
        }
        if everything || only == .hotkeys {
            // The history's own window, read here since the module has no page: `--tab presse-papiers` as it opens,
            // `presse-papiers:reglages` its settings (`:effacer` the clearing asked, `:apps` the ignored apps unfolded),
            // `presse-papiers:activer` before the first activation, `:images` (any filter) filtered, `:cherche:lumiere` a search typed.
            shots.append(("clipboard-window-panel", AnyView(ClipboardWindowView())))
            if only == .hotkeys, let tab = Entry.value(after: "--tab") { model.clipboard.applySnapshotTab(tab) }
        }
        if let tab = Entry.value(after: "--tab") {
            model.protection.tab = ProtectionTab(rawValue: tab) ?? model.protection.tab
            model.performance.tab = PerformanceTab(rawValue: tab) ?? model.performance.tab
            model.storage.tab = StorageTab(rawValue: tab) ?? model.storage.tab
            model.apps.filter = AppFilter(rawValue: tab) ?? model.apps.filter
            if tab == "attente" { showWork(model, page: only) }
            ModuleRegistry.applySnapshotTab(tab, only: only, app: model)
        }
        if everything || only == .wheel {
            // Remplir et signer's window, opened by the Convertisseur's « Signer »: the demo contract and the signatures,
            // at its size on screen (`--tab signer-pad`, `signer-signe`… for its other scenes).
            shots.append(("fillsign-window-panel", AnyView(FillSignWindowView().frame(height: FillSignWindow.size.height))))
            widths["fillsign-window-panel"] = FillSignWindow.size.width
            if only == .wheel, let tab = Entry.value(after: "--tab") { model.fillSign.applySnapshotTab(tab) }
        }
        for (name, view) in shots {
            if let p = Page(rawValue: name) { model.page = p }
            let content = view
                .environment(model)
                .frame(width: ["menubar-panel": 340, "launcher-panel": LauncherView.width, "clipboard-window-panel": ClipboardWindow.width,
                               "adblock-player-panel": 960,
                               "appearance-panel": AppearanceSettings.width, "mascotte-panel": MascotGallery.width,
                               "selfupdate-panel": UpdatesSelfPanel.width, "refuge-ceremony-panel": RefugeCeremonyPanel.width, "selfupdate-window-panel": 1180, "onboarding-window-panel": 1180,
                               "sidebar-panel": WindowShell.sidebarWidth, "profile-panel": ProfilePanel.width, "statusitem-panel": 340,
                               "fenetre-panel": 1380][name]
                       ?? widths[name] ?? (name.hasPrefix("onboarding-") ? OnboardingPanel.width : name.hasPrefix("reglages-") ? NetworkSettings.width : 1180))
                .padding(name.hasSuffix("-panel") ? 0 : 32)
                .background(Theme.bg)
                .environment(\.colorScheme, light ? .light : .dark)
            appearance.performAsCurrentDrawingAppearance {
                let renderer = ImageRenderer(content: content)
                renderer.scale = scale
                guard let cg = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                    print("échec \(name)")
                    return
                }
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
                try? png.write(to: url)
                print("écrit \(url.path) \(cg.width)x\(cg.height)")
            }
        }
    }

    /// `--tab attente`: the pages that are not modules, in the middle of their work (the modules do it in `applySnapshotTab`).
    private static func showWork(_ model: AppModel, page: Page?) {
        let home = DemoData.isEnabled ? DemoData.home : FS.home
        switch page {
        case .cleanup:
            model.cleanup.isScanning = true
            model.cleanup.progress = 0.42
            model.cleanup.progressLabel = home + "/Library/Caches/com.exemple.atelier"
        case .storage:
            model.storage.tab = .explorer
            model.storage.root = nil
            model.storage.current = nil
            model.storage.isScanning = true
            model.storage.scannedCount = 48_210
            model.storage.scanningPath = home + "/Developer/atelier/node_modules"
        case .apps:
            model.apps.apps = []
            model.apps.isScanning = true
            model.apps.progress = 0.6
        case .dashboard:
            model.smartScanRunning = true
            model.cleanup.isScanning = true
            model.protection.isScanning = true
            model.apps.isScanning = true
            model.startup.isScanning = true
        default:
            break
        }
    }

    /// Runs every scanner on this Mac (`--storage` picks the folder to map, ~/Developer by default).
    private static func scan(_ model: AppModel) {
        for _ in 0..<12 {
            usleep(150_000)
            model.monitor.sample()
        }
        let running = RunningApps.snapshot()
        model.cleanup.apply(CleanupScanner.scan(running: running))
        model.cleanup.claude = CleanupScanner.claudeFootprint()
        model.cleanup.lastScan = Date()
        model.protection.checks = SecurityAudit.run()
        model.protection.grants = TCCReader.read()
        model.protection.traces = PrivacyScanner.scan(running: running)
        model.protection.lastAudit = Date()
        model.startup.items = LaunchItemScanner.scan()
        model.startup.lastScan = Date()
        model.apps.apps = AppInventory.scan(running: running)
        model.apps.lastScan = Date()
        model.performance.processes = ProcessList.sample()
        model.smartScanDate = Date()
        let storagePath = FS.expand(Entry.value(after: "--storage") ?? "~/Developer")
        let r = StorageScanner.scan(storagePath, isCancelled: { false }) { _, _ in }
        model.storage.root = r.root
        model.storage.current = r.root
        model.storage.bigFiles = r.bigFiles
        model.storage.rootPath = storagePath
    }
}

/// `Heartware --selftest` checks the deletion guard rails without touching any file.
/// With `--demo`, it also checks that the demo mode deletes and runs nothing, on a throwaway file of its own.
enum SelfTest {
    static func run() -> Bool {
        let h = FS.home
        let refused = [
            "/", "/System", "/Library/Caches/x", "/usr/bin/zsh", "/Applications", "/Applications/Utilities",
            h, h + "/Documents", h + "/Desktop", h + "/Library", h + "/Library/Caches", h + "/Library/Application Support",
            h + "/Library/Keychains/login.keychain-db", h + "/Library/Mail/V10", h + "/Library/Mobile Documents/x",
            h + "/Library/Messages/chat.db", h + "/.ssh", h + "/.zshrc", h + "/Library/Caches/../Keychains/x",
            h + "/Library/Logs/Heartware/actions.log", "/Users/someoneelse/Library/Caches/x"
        ]
        let allowed = [
            h + "/Library/Caches/com.spotify.client", h + "/Library/Logs/DiagnosticReports",
            h + "/Library/Developer/Xcode/DerivedData/App-abc", h + "/.npm/_cacache", h + "/.Trash/old.zip",
            h + "/Downloads/setup.dmg", h + "/.zsh_history", "/Applications/Install macOS Tahoe.app",
            h + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/x", h + "/Developer/app/node_modules"
        ]
        var ok = true
        for p in refused where Remover.isSafe(p) {
            print("✗ accepté à tort : \(p)")
            ok = false
        }
        for p in allowed where !Remover.isSafe(p) {
            print("✗ refusé à tort : \(p)")
            ok = false
        }
        // The scan must never offer anything outside the safe zone.
        for t in CleanupScanner.scan(running: RunningApps()) {
            for i in t.items where !Remover.isSafe(i.path) {
                print("✗ proposé mais protégé : \(i.path)")
                ok = false
            }
        }
        // Sizes switch unit instead of showing "1 000 Ko".
        for (bytes, text) in [(Int64(999), "999 o"), (999_600, "1 Mo"), (999_400, "999 Ko"), (1_500_000_000, "1,5 Go")]
        where Fmt.bytes(bytes) != text {
            print("✗ Fmt.bytes(\(bytes)) = \(Fmt.bytes(bytes)), attendu \(text)")
            ok = false
        }
        // Module checks (calculator, conversions, command ids…).
        let moduleFailures = MainActor.assumeIsolated { ModuleRegistry.selfTest(AppModel(liveMonitor: false)) + SystemMonitor.selfTest() + StatusItemController.selfTest() }
        for f in moduleFailures + ThemeChecks.run() + ToolProfileRules.selfTest().map({ "[Profils] \($0)" }) + MascotActivity.selfTest() + MascotFigure.selfTest() + Shell.selfTest() + LoginItem.selfTest() + RetiredDarkMode.selfTest() + MainWatchdog.selfTest() + DeviceActivity.selfTest() + thirdPartyTools() {
            print("✗ \(f)")
            ok = false
        }
        if !DemoData.isEnabled {
            // A silent tool must stop soon after a cancel (networkQuality, a brew download).
            let flag = CancelFlag()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { flag.cancel() }
            let start = Date()
            _ = Shell.stream("/bin/sleep", ["20"], isCancelled: { flag.isCancelled }) { _ in }
            if Date().timeIntervalSince(start) > 3 {
                print("✗ l'annulation d'un outil silencieux n'a pas abouti")
                ok = false
            }
        }
        if DemoData.isEnabled {
            let probe = NSTemporaryDirectory() + "heartware-demo-probe-\(getpid())"
            FileManager.default.createFile(atPath: probe, contents: Data("démo".utf8))
            let report = Remover.remove([RemovalEntry(path: probe, size: 5)], mode: .delete)
            if report.removed > 0 || !FS.exists(probe) {
                print("✗ le mode démo a supprimé un fichier")
                ok = false
            }
            if Shell.run("/usr/bin/true").ok {
                print("✗ le mode démo a lancé une commande")
                ok = false
            }
            try? FileManager.default.removeItem(atPath: probe)
        }
        print(ok ? "✓ garde-fous OK (\(refused.count) refus, \(allowed.count) autorisations, catalogue vérifié\(DemoData.isEnabled ? ", mode démo inerte" : ""))" : "✗ échec")
        return ok
    }

    /// Claude Code and ffmpeg, when this Mac has them, still answer once started without the app's permissions.
    private static func thirdPartyTools() -> [String] {
        guard !DemoData.isEnabled else { return [] }
        var f: [String] = []
        if let claude = AssistantClaudeCode.findBinary() {
            let r = Shell.run(claude, ["--version"], replaceEnvironment: AssistantClaudeCode.cleanEnvironment(), timeout: 30)
            if r.ok, let line = r.out.split(separator: "\n").first {
                print("  claude --version : \(line) · \(FS.pretty(claude))\(AssistantClaudeCode.isSignedByAnthropic(claude) ? " · signé par Anthropic" : "")")
            } else {
                f.append("claude --version a échoué hors des droits de l'app (\(r.status)) : \(r.err.prefix(200))")
            }
        }
        if let ffmpeg = Shell.which("ffmpeg") {
            let r = Shell.run(ffmpeg, ["-version"], timeout: 30)
            if r.ok, r.out.hasPrefix("ffmpeg version") {
                print("  ffmpeg -version : \(r.out.split(separator: "\n").first ?? "") · \(ffmpeg)")
            } else {
                f.append("ffmpeg -version a échoué hors des droits de l'app (\(r.status)) : \(r.err.prefix(200))")
            }
        }
        return f
    }
}
