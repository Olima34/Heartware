import SwiftUI
import AppKit

/// The Optimisation page as a module: launcher commands, menu bar switches, demo, self-tests and `--dump`.
extension PerformanceModel: AppModule {
    var sidebarBadge: String? {
        if bench.isRunning { return "test…" }
        if boost.coolingDown { return "Frais" }
        switch boost.effectiveMode {
        case .performance: return "Boost"
        case .cool: return "Frais"
        default: return nil
        }
    }

    func start(app: AppModel) {
        boost.start()
    }

    func stop() {
        boost.stop()
    }

    func loadDemo() {
        boost.loadDemo()
        bench.loadDemo()
        sensors.loadDemo()
        tweaks.refresh()
        rosetta = []
    }

    func applySnapshotTab(_ tab: String) {
        if let t = PerformanceTab(rawValue: tab) { self.tab = t }
        if tab == "attente" {
            self.tab = .bench
            bench.job = .full
            bench.progress = 0.4
            bench.currentTest = PerformanceBenchTest.allCases.dropFirst().first
        }
    }

    var quickToggles: [QuickToggle] {
        [
            QuickToggle(id: "perf_boost", title: "Boost", symbol: "bolt.fill", isOn: boost.mode == .performance) { [weak self] in
                self?.boost.toggleBoost()
            },
            QuickToggle(id: "perf_cool", title: "Fraîcheur", symbol: "snowflake", isOn: boost.mode == .cool) { [weak self] in
                self?.boost.toggleCool()
            }
        ]
    }

    // MARK: Launcher

    func commands(app: AppModel) -> [AppCommand] {
        var list: [AppCommand] = []
        let keywords: [PerformanceMode: [String]] = [
            .off: ["boost", "désactiver", "arrêter", "normal"],
            .smart: ["boost", "intelligent", "automatique", "optimiser", "accélérer"],
            .performance: ["boost", "performance", "jeu", "gaming", "fps", "turbo", "accélérer", "game"],
            .cool: ["boost", "fraîcheur", "refroidir", "chaleur", "chaud", "ventilateur", "silence", "batterie", "économie"]
        ]
        for m in PerformanceMode.allCases {
            list.append(AppCommand(id: "perf_mode_\(m.rawValue)", title: m == .off ? "Désactiver le Boost" : "Boost : mode \(m.title)",
                                   subtitle: m.summary, keywords: keywords[m] ?? [], icon: .symbol(m.symbol, Theme.warn),
                                   assistantSafe: true) { ctx in
                ctx.app.performance.boost.setMode(m)
                return .message(m == .off ? "Boost désactivé : toutes les apps ont retrouvé leur priorité." : "Boost : mode \(m.title).")
            })
        }
        list.append(AppCommand(id: "perf_benchmark", title: "Lancer le benchmark", subtitle: "Processeur, GPU, mémoire, SSD et réactivité en ≈ 25 s",
                               keywords: ["benchmark", "score", "test", "vitesse", "performances", "fps", "geekbench"],
                               icon: .symbol("speedometer", Theme.warn),
                               risk: .confirm("Pendant ≈ 25 s, ton Mac travaille à fond (processeur, GPU, et 1 Go écrit sur le SSD) : les autres apps ralentissent le temps du test."),
                               assistantSafe: true) { ctx in
            let p = ctx.app.performance
            ctx.app.page = .performance
            p.tab = .bench
            AppContext.showMainWindow()
            p.bench.runFull(mode: p.boost.effectiveMode, onBattery: ctx.app.monitor.battery.map { !$0.onAC } ?? false)
            return .done
        })
        list.append(AppCommand(id: "perf_boost_test", title: "Mesurer l'effet du Boost", subtitle: "10 s : ton app au premier plan avec et sans le Boost",
                               keywords: ["boost", "test", "preuve", "gain", "comparer"], icon: .symbol("bolt.badge.checkmark", Theme.warn),
                               assistantSafe: true) { ctx in
            ctx.app.page = .performance
            ctx.app.performance.tab = .bench
            AppContext.showMainWindow()
            ctx.app.performance.bench.runBoostDemo()
            return .done
        })
        list.append(AppCommand(id: "perf_endurance", title: "Test d'endurance thermique", subtitle: "3 minutes à plein régime pour voir quand le Mac ralentit",
                               keywords: ["endurance", "stress", "chauffe", "thermique", "throttling", "stabilité"],
                               icon: .symbol("thermometer.high", Theme.warn),
                               risk: .confirm("Ton Mac va tourner à plein régime pendant 3 minutes : il va chauffer (et ventiler, s'il a un ventilateur).")) { ctx in
            ctx.app.page = .performance
            ctx.app.performance.tab = .bench
            AppContext.showMainWindow()
            ctx.app.performance.bench.runEndurance()
            return .done
        })
        list.append(AppCommand(id: "perf_restore_all", title: "Rétablir les apps ralenties", subtitle: "Toutes retrouvent leur pleine vitesse",
                               keywords: ["boost", "rétablir", "ralenties", "priorité"], icon: .symbol("arrow.uturn.backward", Theme.warn),
                               assistantSafe: true) { ctx in
            let n = ctx.app.performance.boost.demotions.count
            ctx.app.performance.boost.restoreAll()
            return .message(n == 0 ? "Aucune app n'était ralentie." : Fmt.plural(n, "app a retrouvé sa vitesse.", "apps ont retrouvé leur vitesse."))
        })
        let hud = PerformanceTweak.all.first { $0.id == "metal_hud" }
        if let hud {
            let on = tweaks.isApplied(hud)
            list.append(AppCommand(id: "perf_fps_counter", title: on ? "Masquer le compteur d'images (FPS)" : "Afficher le compteur d'images (FPS) dans les jeux",
                                   subtitle: "Le compteur d'Apple, dans les jeux ouverts ensuite",
                                   keywords: ["fps", "images par seconde", "compteur", "hud", "metal", "jeux"],
                                   icon: .symbol("speedometer", Theme.warn), assistantSafe: true) { ctx in
                let t = ctx.app.performance.tweaks
                t.refresh()
                if t.isApplied(hud) { t.restore(hud) } else { t.apply(hud) }
                return .message(t.message?.text ?? "Fait.")
            })
        }
        list.append(AppCommand(id: "perf_fluidity", title: "Rendre macOS plus fluide", subtitle: "Animations, Dock, écrans : des réglages réversibles",
                               keywords: ["fluidité", "animations", "rapide", "dock", "hz", "fréquence", "écran"],
                               icon: .symbol("wind", Theme.warn), assistantSafe: true) { ctx in
            ctx.app.page = .performance
            ctx.app.performance.tab = .tweaks
            AppContext.showMainWindow()
            return .done
        })
        list.append(AppCommand(id: "perf_temperature", title: "Température et consommation du Mac", subtitle: "Puce, GPU, puissance, ventilateurs",
                               keywords: ["température", "chaleur", "chaud", "watts", "consommation", "ventilateur", "capteurs"],
                               icon: .symbol("thermometer.medium", Theme.warn), assistantSafe: true) { _ in
            let s = await Task.detached(priority: .userInitiated) { () -> PerformanceSensorSample in
                _ = PerformanceSensorReader.shared.sample()
                usleep(400_000)
                return PerformanceSensorReader.shared.sample()
            }.value
            return .message(Self.summary(s))
        })
        return list
    }

    /// "Puce 54 °C · 6,8 W · GPU 12 %"
    nonisolated static func summary(_ s: PerformanceSensorSample) -> String {
        var parts: [String] = []
        if let t = s.chipTemp { parts.append("Puce \(Fmt.int(t)) °C") }
        if let w = s.systemPower { parts.append("\(Fmt.dec(w)) W") }
        if let g = s.gpuUsage { parts.append("GPU \(Fmt.int(g * 100)) %") }
        if let f = s.fans.first { parts.append("ventilateur \(Fmt.int(f.rpm)) tr/min") }
        return parts.isEmpty ? "Capteurs indisponibles sur ce Mac." : parts.joined(separator: " · ")
    }

    // MARK: Diagnosis

    func diagnosis(app: AppModel) -> [PerformanceFinding] {
        let m = app.monitor
        let front: String? = DemoData.isEnabled ? PerformanceDemo.frontID
            : NSWorkspace.shared.frontmostApplication?.executableURL.map { ProcessList.identity(of: $0.path).key }
        let input = PerformanceDiagnosisInput(
            processes: processes, frontID: front, ownID: ProcessList.identity(of: Bundle.main.executablePath ?? "").key,
            demoted: Set(boost.demotions.map(\.key)), protected: protectedIDs(), cpuLoad: m.cpu, pressure: m.pressure, swapUsed: m.swapUsed, memTotal: m.memTotal,
            diskFree: m.diskFree, diskTotal: m.diskTotal, uptime: m.uptime, thermal: m.thermal, sensors: sensors.current,
            lowPower: DemoData.isEnabled ? false : ProcessInfo.processInfo.isLowPowerModeEnabled, mode: boost.mode, rosetta: rosetta,
            displays: tweaks.displays, startupCount: app.startup.activeCount)
        return PerformanceDiagnosis.findings(input)
    }

    /// The process list groups covered by the user's "never slowed" rules.
    private func protectedIDs() -> Set<String> {
        let rules = boost.rules.protected
        return Set(processes.filter { g in
            rules.contains(g.id) || (g.appPath.flatMap(PerformancePlanner.bundleIdentifier).map(rules.contains) ?? false)
        }.map(\.id))
    }

    func perform(_ action: PerformanceFinding.Action, app: AppModel) {
        switch action {
        case .slow(let id):
            guard let g = processes.first(where: { $0.id == id }) else { return }
            let bundleID = g.appPath.flatMap { path in NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path }?.bundleIdentifier }
            let pids = g.pids.compactMap { pid in PerformanceProcScan.start(of: pid).map { PerformancePID(pid: pid, start: $0) } }
            let background = Set(pids.filter { (PerformanceProcScan.priority(of: $0.pid) ?? 31) <= 4 })
            // Its extensions work for the others (File Provider, Quick Look…): never slowed, as in the sweeps.
            let paths = Dictionary(PerformanceProcScan.current().map { ($0.id.pid, $0.path) }, uniquingKeysWith: { a, _ in a })
            let serving = Set(pids.filter { PerformancePlanner.isServing(paths[$0.pid] ?? "") })
            boost.slowNow(PerformanceGroup(key: g.id, name: g.name, appPath: g.appPath, bundleID: bundleID,
                                           kind: g.appPath == nil ? .daemon : .app, pids: pids, cpu: g.cpu, memory: g.memory,
                                           alreadyBackground: background, serving: serving))
        case .quit(let id):
            guard let g = processes.first(where: { $0.id == id }),
                  CommandRunner.confirm("Quitter \(g.name) ?", "Les documents non enregistrés de cette app pourraient être perdus.", button: "Quitter")
            else { return }
            quit(g)
        case .mode(let m):
            boost.setMode(m)
        case .energy(let level):
            Task { await boost.setEnergy(level) }
        case .refresh(let id):
            if let d = tweaks.displays.first(where: { $0.id == id }) { tweaks.setBestRefresh(d) }
        case .page(let p):
            app.page = p
        case .tab(let t):
            tab = t
        }
    }

    // MARK: Checks and dump

    /// `--dump --only performance --boost-live-test`: the Performance mode for real, 3 seconds, then everything back.
    /// Checks in the kernel that the background apps really went to the background band, and came back.
    static func liveBoostTest(rules: PerformanceRules) -> [String] {
        var lines = ["Test réel du gouverneur (mode Performance, 3 s) :"]
        let engine = PerformanceGovernorEngine()
        let ctx = PerformanceSweepContext(mode: .performance, frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                          apps: PerformanceBoost.runningApps(), rules: rules)
        let r = engine.sweepNow(ctx)
        let pids = r.demotions.flatMap(\.pids)
        let moved = pids.filter { PerformanceProcScan.priority(of: $0.pid) == 4 }.count
        lines.append("  \(r.demotions.count) groupes, \(pids.count) processus déplacés ; \(moved) au niveau 4 dans le noyau")
        lines.append("  " + r.demotions.map { "\($0.name) (\($0.pids.count))" }.joined(separator: ", "))
        usleep(3_000_000)
        let restored = engine.restoreAllNow()
        let still = pids.filter { PerformanceProcScan.start(of: $0.pid) == $0.start && PerformanceProcScan.priority(of: $0.pid) == 4 }
        lines.append("  rétablis : \(restored) ; encore en arrière-plan : \(still.count)" + (still.isEmpty ? " ✓" : " ✗ " + still.map { "\($0.pid)" }.joined(separator: " ")))
        return lines
    }

    func selfTest() -> [String] {
        PerformanceChecks.run()
    }

    func dump() -> [String] {
        var lines = PerformanceSensorReader.shared.describe()
        _ = PerformanceSensorReader.shared.sample()
        usleep(800_000)
        let s = PerformanceSensorReader.shared.sample()
        func t(_ v: Double?) -> String { v.map { "\(Fmt.dec($0)) °C" } ?? "—" }
        func w(_ v: Double?) -> String { v.map { "\(Fmt.dec($0)) W" } ?? "—" }
        lines.append("Températures : processeur \(t(s.chipTemp)) · point chaud \(t(s.hotspotTemp)) · GPU \(t(s.gpuTemp)) · SSD \(t(s.ssdTemp)) · batterie \(t(s.batteryTemp))")
        lines.append("Puissance : Mac \(w(s.systemPower)) · chargeur \(w(s.adapterPower)) · GPU \(w(s.gpuPower)) · processeur \(w(s.cpuPower))")
        if let p = s.pCluster { lines.append("Cœurs performance : \(Fmt.int(p.frequency)) / \(Fmt.int(p.maxFrequency)) MHz, actifs \(Fmt.int(p.active * 100)) %") }
        if let e = s.eCluster { lines.append("Cœurs économes : \(Fmt.int(e.frequency)) / \(Fmt.int(e.maxFrequency)) MHz, actifs \(Fmt.int(e.active * 100)) %") }
        lines.append("GPU : \(s.gpuUsage.map { "\(Fmt.int($0 * 100)) %" } ?? "—") à \(s.gpuFrequency.map { "\(Fmt.int($0)) MHz" } ?? "—")")
        for f in s.fans { lines.append("Ventilateur \(f.id + 1) : \(Fmt.int(f.rpm)) tr/min (\(Fmt.int(f.minRPM))–\(Fmt.int(f.maxRPM)))") }
        if let e = PerformancePower.energy() { lines.append("Énergie macOS : \(e.level.title) (clé \(e.key))") }
        lines.append("Mode Jeu : " + (PerformancePower.gamePolicyTool == nil ? "outil absent (Xcode requis)" : (PerformancePower.gamePolicy()?.rawValue ?? "?")))
        tweaks.refresh()
        for tw in PerformanceTweak.all { lines.append("Fluidité · \(tw.title) : \(tweaks.isApplied(tw) ? "appliqué" : "d'origine")") }
        for d in tweaks.displays {
            lines.append("Écran \(d.name) \(d.resolution) : \(Int(d.current)) Hz, jusqu'à \(Int(d.best)) Hz\(d.builtIn ? " (intégré)" : "")")
        }
        lines.append("Accessibilité : transparence réduite \(tweaks.reduceTransparency ? "oui" : "non"), animations réduites \(tweaks.reduceMotion ? "oui" : "non")")
        // What each mode would move right now (nothing is changed).
        if !DemoData.isEnabled {
            var t = Date()
            func lap() -> String { defer { t = Date() }; return Fmt.dec(Date().timeIntervalSince(t) * 1000) }
            let procs = PerformanceProcScan.current()
            let a = lap()
            let apps = PerformanceBoost.runningApps()
            let b = lap()
            let audio = PerformanceAudio.activePIDs()
            let c = lap()
            let taps = PerformanceAudio.eventTapPIDs()
            let d = lap()
            let groups = PerformancePlanner.groups(procs, apps: apps, audio: audio, taps: taps)
            let e = lap()
            lines.append("Premier balayage (ms) : processus \(a) · apps \(b) · son \(c) · clavier \(d) · regroupement \(e)")
            t = Date()
            let procs2 = PerformanceProcScan.current()
            let a2 = lap()
            let apps2 = PerformanceBoost.runningApps()
            let b2 = lap()
            let audio2 = PerformanceAudio.activePIDs()
            let c2 = lap()
            let taps2 = PerformanceAudio.eventTapPIDs()
            let d2 = lap()
            _ = PerformancePlanner.groups(procs2, apps: apps2, audio: audio2, taps: taps2)
            let e2 = lap()
            lines.append("Balayages suivants (ms) : processus \(a2) · apps \(b2) · son \(c2) · clavier \(d2) · regroupement \(e2)")
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let front = procs.first { $0.id.pid == frontPID }.map { ProcessList.identity(of: $0.path).key }
            let own = ProcessList.identity(of: Bundle.main.executablePath ?? "").key
            lines.append("Processus de la session : \(procs.count) en \(groups.count) groupes · son actif : \(groups.values.filter(\.audio).map(\.name).joined(separator: ", "))")
            for mode in [PerformanceMode.smart, .performance] {
                var moved: [String] = []
                var kept: [String: Int] = [:]
                for g in groups.values.sorted(by: { $0.name < $1.name }) {
                    switch PerformancePlanner.verdict(g, mode: mode, frontKey: front, ownKey: own, rules: boost.rules, busyFor: 0) {
                    case .demote: moved.append("\(g.name) [\(g.kind.rawValue)]")
                    case .keep(let why): kept[why, default: 0] += 1
                    }
                }
                lines.append("Mode \(mode.title) (calme) ralentirait : " + (moved.isEmpty ? "rien" : moved.joined(separator: ", ")))
                lines.append("  gardés : " + kept.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
            }
        }
        if CommandLine.arguments.contains("--boost-live-test") && !DemoData.isEnabled {
            lines += Self.liveBoostTest(rules: boost.rules)
        }
        if CommandLine.arguments.contains("--bench") {
            lines.append("Benchmark :")
            lines += PerformanceBenchModel.runFromCommandLine().map { "  " + $0 }
        }
        return lines
    }
}
