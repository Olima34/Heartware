import Foundation

/// Pure checks of the Optimisation page, run by `--selftest`: sensor decoding, frequency maths, the governor's rules,
/// the parsers of macOS' tools, scores and the diagnosis. Nothing here touches a process or a setting.
enum PerformanceChecks {
    @MainActor
    static func run() -> [String] {
        var f: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { f.append(what) } }

        // SMC values.
        let flt = withUnsafeBytes(of: Float(42.5)) { Array($0) }
        check(PerformanceSMC.decode(type: "flt ", bytes: flt) == 42.5, "SMC : flottant mal décodé")
        check(PerformanceSMC.decode(type: "sp78", bytes: [0x2A, 0x80]) == 42.5, "SMC : sp78 mal décodé")
        check(PerformanceSMC.decode(type: "fpe2", bytes: [0x1F, 0x40]) == 2000, "SMC : fpe2 (ventilateur) mal décodé")
        check(PerformanceSMC.decode(type: "ui16", bytes: [0x01, 0x02]) == 258, "SMC : ui16 mal décodé")
        check(PerformanceSMC.decode(type: "ioft", bytes: [1, 2, 3]) == nil, "SMC : type inconnu accepté")
        check(PerformanceSMC.name(PerformanceSMC.code("PSTR")) == "PSTR", "SMC : code de clé")
        check(!PerformanceSensorReader.plausible(-1.5) && !PerformanceSensorReader.plausible(0) && PerformanceSensorReader.plausible(54),
              "capteurs : températures absurdes acceptées")

        // Frequencies: two steps, the cluster idle half of the time.
        let table = [600.0, 2_400]
        if let c = PerformanceIOReport.cluster([[("IDLE", 100), ("V0P1", 50), ("V1P0", 50)]], table: table) {
            check(abs(c.frequency - 1_500) < 0.01, "fréquences : moyenne fausse (\(c.frequency))")
            check(abs(c.active - 0.5) < 0.001, "fréquences : activité fausse (\(c.active))")
            check(abs(c.speedRatio - 0.625) < 0.001, "fréquences : rapport à la fréquence maximale")
        } else {
            f.append("fréquences : cluster non calculé")
        }
        check(PerformanceIOReport.cluster([], table: table) == nil, "fréquences : cluster vide accepté")
        var hz = Data()
        for v in [UInt32(600_000_000), 0, UInt32(3_504_000_000), 0] { withUnsafeBytes(of: v.littleEndian) { hz.append(contentsOf: $0) } }
        check(PerformanceIOReport.frequencies(hz) == [600, 3_504], "fréquences : table en Hz mal lue")
        var khz = Data()
        for v in [UInt32(600_000), 0] { withUnsafeBytes(of: v.littleEndian) { khz.append(contentsOf: $0) } }
        check(PerformanceIOReport.frequencies(khz) == [600], "fréquences : table en kHz mal lue")
        check(abs(PerformanceIOReport.joules(2_000_000_000, unit: "nJ") - 2) < 1e-9, "énergie : nanojoules")

        // macOS' tools.
        let pmset = """
        System-wide power settings:
        Currently in use:
         standby              1
         lowpowermode         1
         sleep                1
        """
        check(PerformancePower.parse(pmset) == PerformanceEnergy(level: .low, key: "lowpowermode"), "pmset : économie d'énergie non lue")
        check(PerformancePower.parse("Currently in use:\n powermode            2\n") == PerformanceEnergy(level: .high, key: "powermode"),
              "pmset : haute performance non lue")
        check(PerformancePower.parse("Battery Power:\n lowpowermode 1\n") == nil, "pmset : réglage hors « Currently in use » lu")
        check(PerformancePower.command(.high, key: "lowpowermode") == "/usr/bin/pmset -a lowpowermode 1", "pmset : commande hors limites")
        let custom = "Battery Power:\n lowpowermode         1\n sleep 1\nAC Power:\n lowpowermode         0\n"
        check(PerformancePower.parseSources(custom, key: "lowpowermode") == ["b": 1, "c": 0], "pmset : réglages par source mal lus")
        check(PerformancePower.restoreCommand(["b": 1, "c": 0], key: "lowpowermode")
              == "/usr/bin/pmset -b lowpowermode 1 && /usr/bin/pmset -c lowpowermode 0", "pmset : rétablissement par source")
        check(PerformancePower.restoreCommand(["b": 7], key: "lowpowermode") == nil, "pmset : valeur absurde rétablie")
        check(PerformancePower.parseGamePolicy("Game mode enablement policy is currently \u{1B}[0;33mautomatic\u{1B}[0;0m.") == .auto,
              "mode Jeu : politique automatique non lue")
        check(PerformancePower.parseGamePolicy("Game mode enablement policy is currently on.") == .on, "mode Jeu : politique forcée non lue")
        check(PerformanceBoost.isGame(bundle: URL(fileURLWithPath: "/Users/x/Library/Application Support/Steam/steamapps/common/Jeu/Jeu.app")),
              "jeux : un jeu Steam n'est pas reconnu")

        f += governorChecks()

        // Scores.
        for t in PerformanceBenchTest.allCases where abs(t.score(t.reference) - 1000) > 0.001 {
            f.append("benchmark : \(t.title) ne vaut pas 1 000 à la référence")
        }
        check(PerformanceBenchTest.latency.score(PerformanceBenchTest.latency.reference / 2) > 1999, "benchmark : une latence plus basse doit valoir plus")
        // Twice the reference on one test, half on another: 1 000 overall.
        let r = PerformanceBenchResult(date: Date(), mode: .off,
                                       values: ["cpuSingle": 2 * PerformanceBenchTest.cpuSingle.reference, "gpu": PerformanceBenchTest.gpu.reference / 2],
                                       chip: "test", onBattery: false, lowPower: false)
        check(abs(r.total - 1000) < 0.01, "benchmark : moyenne géométrique fausse (\(r.total))")
        let demo = PerformanceBoostDemoResult(date: Date(), alone: .init(foreground: 100, background: 0),
                                              contended: .init(foreground: 70, background: 300), boosted: .init(foreground: 98, background: 120))
        check(abs(demo.contendedRatio - 0.7) < 1e-9 && abs(demo.boostedRatio - 0.98) < 1e-9 && abs(demo.gain - 0.4) < 1e-9,
              "test du Boost : rapports faux")
        let endurance = PerformanceEnduranceResult(date: Date(), windows: [.init(second: 10, rate: 100), .init(second: 20, rate: 90)])
        check(abs(endurance.stability - 0.9) < 1e-9, "endurance : stabilité fausse")

        // Preferences.
        check(PerformanceTweakValue.bool(false).matches(.double(0)), "réglages : 0 et false différents")
        check(PerformanceTweakValue.double(0.001).matches(.double(0.0012)), "réglages : tolérance des délais")
        check(!PerformanceTweakValue.string("scale").matches(.string("genie")), "réglages : chaînes confondues")
        check(!PerformanceTweakValue.bool(true).matches(nil), "réglages : valeur absente prise pour appliquée")
        check(Set(PerformanceTweak.all.map(\.id)).count == PerformanceTweak.all.count, "réglages : identifiants en double")
        check(PerformanceDisplay(id: 1, name: "x", resolution: "", current: 60, best: 144, builtIn: false).canGoFaster
              && !PerformanceDisplay(id: 1, name: "x", resolution: "", current: 0, best: 60, builtIn: true).canGoFaster,
              "écrans : fréquence possible mal évaluée")

        f += diagnosisChecks()
        if !DemoData.isEnabled { f += priorityCheck() + inheritanceCheck() }
        return f.map { "Optimisation : " + $0 }
    }

    /// The governor's rules on made-up processes.
    private static func governorChecks() -> [String] {
        var f: [String] = []
        let home = "/Users/test"
        func proc(_ pid: Int32, _ path: String) -> PerformanceProc {
            PerformanceProc(id: PerformancePID(pid: pid, start: UInt64(pid)), path: path, cpuTime: 0, priority: 31, memory: 1_000)
        }
        let procs = [
            proc(10, "/Applications/Jeu.app/Contents/MacOS/Jeu"),
            proc(11, "/Applications/Navigateur.app/Contents/MacOS/Navigateur"),
            proc(12, "/Applications/Navigateur.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper (Renderer)"),
            proc(13, "/Applications/Musique.app/Contents/MacOS/Musique"),
            proc(14, "/Applications/Fenêtres.app/Contents/MacOS/Fenêtres"),
            proc(15, "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
            proc(16, "/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/photoanalysisd"),
            proc(17, "/usr/libexec/trustd"),
            proc(18, home + "/Applications/Nuage.app/Contents/MacOS/Nuage"),
            proc(19, "/Applications/Exporteur.app/Contents/MacOS/Exporteur")
        ]
        let apps: [Int32: PerformanceAppInfo] = [
            10: .init(name: "Jeu", bundleID: "fr.jeu", kind: .app),
            11: .init(name: "Navigateur", bundleID: "fr.navigateur", kind: .app),
            13: .init(name: "Musique", bundleID: "fr.musique", kind: .app),
            14: .init(name: "Fenêtres", bundleID: "fr.fenetres", kind: .menuBar),
            15: .init(name: "Finder", bundleID: "com.apple.finder", kind: .app),
            18: .init(name: "Nuage", bundleID: "com.getdropbox.dropbox", kind: .menuBar),
            19: .init(name: "Exporteur", bundleID: "fr.handbrake.HandBrake", kind: .app)
        ]
        let groups = PerformancePlanner.groups(procs, apps: apps, audio: [13], taps: [14], home: home)
        let browser = groups["/Applications/Navigateur.app"]
        if browser?.pids.count != 2 || browser?.kind != .app { f.append("gouverneur : les processus d'aide ne rejoignent pas leur app") }
        if groups["/System/Library/CoreServices/Finder.app"]?.kind != .other { f.append("gouverneur : le Finder serait ralenti") }
        if groups["/usr/libexec/trustd"]?.kind != .other { f.append("gouverneur : un service système serait ralenti") }
        let photo = groups["/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/photoanalysisd"]
        if photo?.kind != .daemon || photo?.name != "Analyse des photos" { f.append("gouverneur : l'analyse des photos n'est pas reconnue") }
        if groups[home + "/Applications/Nuage.app"]?.kind != .menuBar { f.append("gouverneur : les apps de ~/Applications sont ignorées") }

        let rules = PerformanceRules.initial
        func v(_ key: String, _ mode: PerformanceMode, busy: TimeInterval = 0, rules r: PerformanceRules = rules) -> PerformanceVerdict {
            guard let g = groups[key] else { return .keep("absent") }
            return PerformancePlanner.verdict(g, mode: mode, frontKey: "/Applications/Jeu.app", ownKey: "/Applications/Heartware.app",
                                              rules: r, busyFor: busy)
        }
        let isDemote: (PerformanceVerdict) -> Bool = { if case .demote = $0 { return true } else { return false } }
        if isDemote(v("/Applications/Jeu.app", .performance)) { f.append("gouverneur : l'app au premier plan serait ralentie") }
        if v("/Applications/Navigateur.app", .performance) != .demote(.mode) { f.append("gouverneur : Performance ne ralentit pas l'arrière-plan") }
        if isDemote(v("/Applications/Navigateur.app", .smart)) { f.append("gouverneur : Intelligent ralentit une app calme") }
        if isDemote(v("/Applications/Navigateur.app", .smart, busy: PerformancePlanner.busyDuration - 1)) {
            f.append("gouverneur : Intelligent ralentit une app agitée moins de 20 s")
        }
        if v("/Applications/Navigateur.app", .smart, busy: PerformancePlanner.busyDuration) != .demote(.busy) {
            f.append("gouverneur : Intelligent ne ralentit pas une app qui s'emballe")
        }
        if isDemote(v("/Applications/Navigateur.app", .off, busy: 5)) { f.append("gouverneur : le mode désactivé ralentit") }
        if isDemote(v("/Applications/Musique.app", .performance)) { f.append("gouverneur : une app qui joue du son serait ralentie") }
        if isDemote(v("/Applications/Fenêtres.app", .performance, busy: 5)) { f.append("gouverneur : une app qui surveille le clavier serait ralentie") }
        if isDemote(v("/Applications/Exporteur.app", .performance)) { f.append("gouverneur : une app protégée par défaut serait ralentie") }
        // The other apps wait for their files from a sync client: slowed only when it runs wild, whatever the mode.
        if isDemote(v(home + "/Applications/Nuage.app", .performance)) { f.append("gouverneur : Performance ralentit un client de synchronisation calme") }
        if v(home + "/Applications/Nuage.app", .performance, busy: PerformancePlanner.busyDuration) != .demote(.busy) {
            f.append("gouverneur : un client de synchronisation qui s'emballe reste à pleine vitesse")
        }
        if isDemote(v(home + "/Applications/Nuage.app", .smart)) { f.append("gouverneur : Intelligent ralentit un client calme") }
        // Extensions work for the others (File Provider, Quick Look…), and a VPN or a password manager for every app.
        let withExtension = PerformancePlanner.groups(
            procs + [proc(20, "/Applications/Navigateur.app/Contents/PlugIns/Fichiers.appex/Contents/MacOS/Fichiers")], apps: apps,
            audio: [], taps: [], home: home)["/Applications/Navigateur.app"]
        if withExtension?.movable.contains(where: { $0.pid == 20 }) != false || withExtension?.pids.count != 3 {
            f.append("gouverneur : une extension d'app serait ralentie avec son app")
        }
        let vpn = PerformanceGroup(key: "/Applications/Tunnel.app", name: "Tunnel", bundleID: "com.wireguard.macos", kind: .app,
                                   pids: [PerformancePID(pid: 30, start: 30)])
        if isDemote(PerformancePlanner.verdict(vpn, mode: .performance, frontKey: nil, ownKey: "/Applications/Heartware.app",
                                               rules: rules, busyFor: 90)) {
            f.append("gouverneur : un VPN serait ralenti")
        }
        var custom = rules
        custom.alwaysSlow = ["/Applications/Navigateur.app"]
        if v("/Applications/Navigateur.app", .smart, rules: custom) != .demote(.rule) { f.append("gouverneur : la règle « toujours ralentir » ignorée") }
        custom.protected.append("fr.navigateur")
        custom.alwaysSlow = []
        if isDemote(v("/Applications/Navigateur.app", .performance, rules: custom)) { f.append("gouverneur : une app protégée serait ralentie") }
        let own = PerformancePlanner.verdict(PerformanceGroup(key: "/Applications/Heartware.app", name: "x", kind: .app, pids: []),
                                             mode: .performance, frontKey: nil, ownKey: "/Applications/Heartware.app", rules: rules, busyFor: 90)
        if isDemote(own) { f.append("gouverneur : Heartware se ralentirait lui-même") }
        if !PerformanceMode.performance.isWide || !PerformanceMode.cool.isWide || PerformanceMode.smart.isWide {
            f.append("gouverneur : étendue des modes")
        }
        return f
    }

    /// The kernel lever itself, on a throwaway child process of the self-test: into the background band and back.
    private static func priorityCheck() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["5"]
        guard (try? p.run()) != nil else { return ["priorité : processus de test non lancé"] }
        defer { p.terminate() }
        let pid = p.processIdentifier
        usleep(50_000)
        guard let start = PerformanceProcScan.start(of: pid) else { return ["priorité : processus de test introuvable"] }
        var f: [String] = []
        let id = PerformancePID(pid: pid, start: start)
        if !PerformanceProcScan.setBackground(id, true) || PerformanceProcScan.priority(of: pid) != 4 {
            f.append("priorité : le processus n'est pas passé en arrière-plan")
        }
        if !PerformanceProcScan.setBackground(id, false) || PerformanceProcScan.priority(of: pid) == 4 {
            f.append("priorité : le processus n'est pas revenu au premier plan")
        }
        if PerformanceProcScan.setBackground(PerformancePID(pid: pid, start: start &+ 1), true) {
            f.append("priorité : un numéro de processus réutilisé serait touché")
        }
        return f
    }

    /// A child started by a slowed process is born in the background band (the kernel copies it): it must be found and
    /// restored with its parent. Checked on a throwaway shell of the self-test and the child it starts.
    private static func inheritanceCheck() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.4; sleep 5"]
        guard (try? p.run()) != nil else { return ["héritage : processus de test non lancé"] }
        defer {
            p.terminate()
            _ = Shell.run("/usr/bin/pkill", ["-P", "\(p.processIdentifier)"], timeout: 2)
        }
        let pid = p.processIdentifier
        usleep(100_000)
        guard let start = PerformanceProcScan.start(of: pid) else { return ["héritage : processus de test introuvable"] }
        let parent = PerformancePID(pid: pid, start: start)
        guard PerformanceProcScan.setBackground(parent, true) else { return ["héritage : parent non déplacé"] }
        var d = PerformanceDemotion(key: "test", name: "test", appPath: nil, bundleID: nil, pids: [parent], since: Date(), cause: .manual, cpuBefore: 0)
        usleep(700_000)
        PerformanceGovernorEngine.adoptDescendants(&d, procs: PerformanceProcScan.current())
        var f: [String] = []
        guard let child = d.pids.first(where: { $0 != parent }) else { return ["héritage : l'enfant d'un processus ralenti n'est pas retrouvé"] }
        if PerformanceProcScan.priority(of: child.pid) != 4 { f.append("héritage : l'enfant n'a pas hérité de la bande d'arrière-plan") }
        for x in d.pids { PerformanceProcScan.setBackground(x, false) }
        if PerformanceProcScan.priority(of: child.pid) == 4 { f.append("héritage : l'enfant reste en arrière-plan après le rétablissement") }
        return f
    }

    /// The diagnosis on a made-up Mac in trouble.
    private static func diagnosisChecks() -> [String] {
        var f: [String] = []
        let ps = [
            ProcessGroup(id: "/Applications/Jeu.app", name: "Jeu", appPath: "/Applications/Jeu.app", pids: [1], cpu: 180, memory: 4_000_000_000, isMine: true),
            ProcessGroup(id: "/Applications/Discussion.app", name: "Discussion", appPath: "/Applications/Discussion.app", pids: [2], cpu: 85,
                         memory: 2_000_000_000, isMine: true),
            ProcessGroup(id: "/usr/libexec/photoanalysisd", name: "photoanalysisd", appPath: nil, pids: [3], cpu: 60, memory: 300_000_000, isMine: true),
            ProcessGroup(id: "kernel_task", name: "kernel_task", appPath: nil, pids: [0], cpu: 12, memory: 0, isMine: false)
        ]
        var input = PerformanceDiagnosisInput(
            processes: ps, frontID: "/Applications/Jeu.app", ownID: nil, demoted: [], cpuLoad: 0.5, pressure: .warning,
            swapUsed: 6_000_000_000, memTotal: 8_000_000_000, diskFree: 9_000_000_000, diskTotal: 256_000_000_000, uptime: 20 * 86400,
            thermal: .nominal, sensors: PerformanceSensorSample(), lowPower: true, mode: .off, rosetta: ["Vieux Logiciel"],
            displays: [PerformanceDisplay(id: 7, name: "Moniteur", resolution: "", current: 60, best: 144, builtIn: false)], startupCount: 20)
        let ids = Set(PerformanceDiagnosis.findings(input).map(\.id))
        for expected in ["hog-/Applications/Discussion.app", "photos", "memory", "disk", "lowpower", "display-7", "rosetta", "uptime", "startup", "boost-off"]
        where !ids.contains(expected) {
            f.append("diagnostic : « \(expected) » manquant")
        }
        if ids.contains("hog-/Applications/Jeu.app") { f.append("diagnostic : l'app au premier plan signalée comme gourmande") }
        if ids.contains("heat") { f.append("diagnostic : chaleur signalée sans raison") }
        input.thermal = .serious
        input.demoted = ["/Applications/Discussion.app"]
        let hot = PerformanceDiagnosis.findings(input)
        if hot.first?.id != "heat" { f.append("diagnostic : la chaleur n'arrive pas en tête") }
        if hot.contains(where: { $0.id == "hog-/Applications/Discussion.app" }) { f.append("diagnostic : une app déjà ralentie signalée") }
        input.demoted = []
        input.protected = ["/Applications/Discussion.app"]
        let kept = PerformanceDiagnosis.findings(input).first { $0.id.hasSuffix("/Applications/Discussion.app") }
        if kept?.id != "busy-/Applications/Discussion.app" || kept?.buttons.isEmpty == false {
            f.append("diagnostic : une app protégée se voit proposer d'être ralentie ou quittée")
        }
        return f
    }
}
