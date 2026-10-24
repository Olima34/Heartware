import Foundation
import Observation

struct MaintenanceTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let needsAdmin: Bool
    let command: String
    var warning: String? = nil

    /// Tasks that delete something, interrupt work or keep the Mac busy for long ask first.
    var confirmation: String? {
        switch id {
        case "spotlight": return warning
        case "snapshots": return "Les instantanés locaux de Time Machine seront supprimés : tu ne pourras plus revenir à ces versions de tes fichiers."
        case "finder": return "Les fenêtres du Finder se ferment, et une copie en cours serait interrompue."
        case "simulators": return "Les simulateurs dont la version d'iOS n'est plus installée seront supprimés définitivement, avec leurs données."
        default: return nil
        }
    }

    var available: Bool {
        DemoData.isEnabled || id != "simulators" || FS.exists("/Applications/Xcode.app") || Shell.exists("/usr/bin/xcrun") && FS.exists(FS.home + "/Library/Developer/CoreSimulator")
    }

    static let all: [MaintenanceTask] = [
        MaintenanceTask(id: "ram", title: "Libérer la mémoire vive",
                        detail: "Vide les caches disque gardés en mémoire (commande purge). Utile après un gros export ou une longue compilation ; le reste du temps, macOS gère très bien sa mémoire seul.",
                        symbol: "memorychip", needsAdmin: true, command: "/usr/sbin/purge"),
        MaintenanceTask(id: "dns", title: "Vider le cache DNS",
                        detail: "Règle les sites qui ne s'ouvrent plus après un changement de box, de VPN ou de DNS.",
                        symbol: "network", needsAdmin: true, command: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"),
        MaintenanceTask(id: "launchservices", title: "Reconstruire Launch Services",
                        detail: "Corrige les doublons du menu « Ouvrir avec » et les fichiers qui s'ouvrent avec la mauvaise app.",
                        symbol: "list.bullet.rectangle", needsAdmin: false,
                        command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -r -domain local -domain system -domain user"),
        MaintenanceTask(id: "quicklook", title: "Réinitialiser Coup d'œil",
                        detail: "Répare les aperçus et les vignettes qui restent blancs dans le Finder.",
                        symbol: "eye", needsAdmin: false, command: "/usr/bin/qlmanage -r; /usr/bin/qlmanage -r cache"),
        MaintenanceTask(id: "spotlight", title: "Réindexer Spotlight",
                        detail: "Reconstruit l'index de recherche quand Spotlight ne trouve plus tes fichiers ou tes apps.",
                        symbol: "magnifyingglass", needsAdmin: true, command: "/usr/bin/mdutil -E /",
                        warning: "Ton Mac travaillera en tâche de fond pendant une à quelques heures."),
        MaintenanceTask(id: "snapshots", title: "Purger les instantanés Time Machine locaux",
                        detail: "Récupère l'espace « purgeable » réservé par les instantanés que macOS garde sur le disque interne.",
                        symbol: "clock.arrow.circlepath", needsAdmin: true, command: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4"),
        MaintenanceTask(id: "dock", title: "Relancer le Dock",
                        detail: "Remet d'aplomb le Dock, Mission Control et le Launchpad quand ils se figent.",
                        symbol: "dock.rectangle", needsAdmin: false, command: "/usr/bin/killall Dock"),
        MaintenanceTask(id: "finder", title: "Relancer le Finder",
                        detail: "Débloque un Finder lent ou qui n'affiche plus les nouveaux fichiers.",
                        symbol: "folder", needsAdmin: false, command: "/usr/bin/killall Finder"),
        MaintenanceTask(id: "simulators", title: "Supprimer les simulateurs obsolètes",
                        detail: "Efface les simulateurs dont la version d'iOS n'est plus installée dans Xcode.",
                        symbol: "ipad.and.iphone", needsAdmin: false, command: "/usr/bin/xcrun simctl delete unavailable")
    ]
}

struct TaskResult {
    var ok: Bool
    var message: String
    var date: Date
}

enum PerformanceTab: String, CaseIterable, Identifiable {
    case boost, monitor, bench, tweaks, startup, maintenance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .boost: return "Boost"
        case .monitor: return "Moniteur"
        case .bench: return "Benchmark"
        case .tweaks: return "Fluidité"
        case .startup: return "Démarrage"
        case .maintenance: return "Maintenance"
        }
    }
}

enum ProcessSort: String, CaseIterable, Identifiable {
    case cpu, memory
    var id: String { rawValue }
    var title: String { self == .cpu ? "Processeur" : "Mémoire" }
}

@Observable
@MainActor
final class PerformanceModel {
    var tab: PerformanceTab = .boost
    var processes: [ProcessGroup] = []
    // Boost, sensors, benchmark and Fluidité (PerformanceModule.swift and the files next to it).
    let sensors = PerformanceSensors()
    let boost = PerformanceBoost()
    let bench = PerformanceBenchModel()
    let tweaks = PerformanceTweaks()
    var rosetta: [String] = []
    var sort: ProcessSort = .cpu
    var runningTasks: Set<String> = []
    var results: [String: TaskResult] = [:]
    var snapshotCount: Int?
    var lastQuit: String?

    @ObservationIgnored private var timer: Timer?
    /// The views showing processes: in the main window (Moniteur, Boost, Menu d'état) and in the menu bar panel.
    @ObservationIgnored private var windowSamplers = 0
    @ObservationIgnored private var panelSamplers = 0
    @ObservationIgnored private var windowOnScreen = true
    @ObservationIgnored private var sampling = false
    @ObservationIgnored private var lastSample = Date.distantPast

    /// The list of processes is from the last few seconds (a page left in a hidden window keeps an old one).
    var processesFresh: Bool { !processes.isEmpty && Date().timeIntervalSince(lastSample) < 6 }

    var sortedProcesses: [ProcessGroup] {
        processes.sorted { sort == .cpu ? ($0.cpu, $0.memory) > ($1.cpu, $1.memory) : $0.memory > $1.memory }
    }

    var topByCPU: [ProcessGroup] { processes.sorted { $0.cpu > $1.cpu } }

    /// Views that show processes call this on appear and `stopSampling` on disappear (`inMainWindow` false: the menu bar
    /// panel). The list is read every 3 s while one of them is on screen: the panel, or the main window when it is.
    func startSampling(inMainWindow: Bool = true) {
        // A snapshot is a still frame: no sample may land halfway through the render.
        guard !Snapshot.isActive else { return }
        if inMainWindow { windowSamplers += 1 } else { panelSamplers += 1 }
        updateTimer()
    }

    func stopSampling(inMainWindow: Bool = true) {
        if inMainWindow { windowSamplers = max(0, windowSamplers - 1) } else { panelSamplers = max(0, panelSamplers - 1) }
        updateTimer()
    }

    /// The main window came on screen or went away (minimised, hidden, covered, on another Space).
    func setWindowOnScreen(_ on: Bool) {
        windowOnScreen = on
        updateTimer()
    }

    private var needsSampling: Bool { panelSamplers > 0 || (windowSamplers > 0 && windowOnScreen) }

    private func updateTimer() {
        guard needsSampling else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        // Back on screen: fresh figures right away, unless the last ones are only a moment old.
        if Date().timeIntervalSince(lastSample) > 1.5 { Task { await sampleProcesses() } }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            _ = MainActor.assumeIsolated { Task { await self?.sampleProcesses() } }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// `ps` and the Rosetta apps are read off the main thread; only the result lands here.
    func sampleProcesses() async {
        guard !sampling else { return }
        sampling = true
        let (list, translated) = await Task.detached(priority: .utility) {
            (ProcessList.sample(), PerformanceDiagnosis.rosettaApps())
        }.value
        processes = list
        if translated != rosetta { rosetta = translated }
        lastSample = Date()
        sampling = false
    }

    func quit(_ g: ProcessGroup, force: Bool = false) {
        guard !DemoData.isEnabled else {
            lastQuit = DemoData.refusal
            return
        }
        let ok = ProcessList.quit(g, force: force)
        lastQuit = ok ? "\(g.name) a été fermé." : "\(g.name) n'a pas pu être fermé (processus système ou d'un autre utilisateur)."
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await sampleProcesses()
        }
    }

    // MARK: Maintenance

    func lastRun(_ t: MaintenanceTask) -> Date? {
        if DemoData.isEnabled { return results[t.id]?.date ?? DemoData.maintenanceRuns[t.id] }
        return results[t.id]?.date ?? UserDefaults.standard.object(forKey: "maintenance.\(t.id)") as? Date
    }

    func run(_ t: MaintenanceTask) async {
        guard !runningTasks.contains(t.id) else { return }
        runningTasks.insert(t.id)
        let out = await Task.detached(priority: .userInitiated) {
            t.needsAdmin ? Shell.runAsAdmin(t.command) : Shell.sh(t.command, timeout: 120)
        }.value
        runningTasks.remove(t.id)
        // killall exits with 1 when nothing was running: still fine.
        let ok = out.ok || (t.command.hasPrefix("killall") && out.status == 1)
        let msg = ok ? "Terminé" : (out.err.isEmpty ? "Échec (code \(out.status))" : out.err.trimmingCharacters(in: .whitespacesAndNewlines))
        results[t.id] = TaskResult(ok: ok, message: msg, date: Date())
        if ok {
            UserDefaults.standard.set(Date(), forKey: "maintenance.\(t.id)")
            ActionLog.write("MAINTENANCE \(t.title)")
        }
        if t.id == "snapshots" { await countSnapshots() }
    }

    func countSnapshots() async {
        snapshotCount = await Task.detached(priority: .utility) {
            Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).out.split(separator: "\n").filter { $0.contains("com.apple") }.count
        }.value
    }
}
