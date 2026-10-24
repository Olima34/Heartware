import Foundation
import AppKit

/// One thing that slows or heats the Mac right now, with what can be done about it.
struct PerformanceFinding: Identifiable, Equatable {
    enum Action: Equatable {
        /// Move this group (process list id) to the efficiency cores.
        case slow(String)
        /// Quit this group (process list id), after a confirmation.
        case quit(String)
        case mode(PerformanceMode)
        case energy(PerformanceEnergyLevel)
        case refresh(UInt32)
        case page(Page)
        case tab(PerformanceTab)
    }

    struct Button: Equatable {
        var label: String
        var action: Action
    }

    let id: String
    var status: Status
    var symbol: String
    var title: String
    var detail: String
    var buttons: [Button] = []
}

/// Everything the diagnosis looks at, read beforehand (the rules themselves are pure and self-tested).
struct PerformanceDiagnosisInput {
    var processes: [ProcessGroup]
    var frontID: String?
    var ownID: String?
    var demoted: Set<String>
    /// Groups the user never wants slowed (process list ids).
    var protected: Set<String> = []
    var cpuLoad: Double
    var pressure: MemoryPressure
    var swapUsed: UInt64
    var memTotal: UInt64
    var diskFree: Int64
    var diskTotal: Int64
    var uptime: TimeInterval
    var thermal: ProcessInfo.ThermalState
    var sensors: PerformanceSensorSample
    var lowPower: Bool
    var mode: PerformanceMode
    var rosetta: [String]
    var displays: [PerformanceDisplay]
    var startupCount: Int
}

enum PerformanceDiagnosis {
    /// Apple's background activities, by process name: what they are and whether slowing them is offered.
    private struct Activity {
        let id: String
        let names: [String]
        let threshold: Double
        let title: String
        let detail: String
        let symbol: String
        let slowable: Bool
    }

    private static let activities: [Activity] = [
        Activity(id: "spotlight", names: ["mds_stores", "mds", "mdworker_shared", "mdworker", "corespotlightd"], threshold: 30,
                 title: "Spotlight indexe tes fichiers",
                 detail: "Normal après une mise à jour ou l'arrivée de nombreux fichiers : ça se calme tout seul. Laisse ton Mac branché pour que ça aille vite.",
                 symbol: "magnifyingglass", slowable: true),
        Activity(id: "photos", names: ["photoanalysisd", "mediaanalysisd"], threshold: 20, title: "Photos analyse ta photothèque",
                 detail: "Reconnaissance des visages, des objets et des textes. Ce travail peut attendre : le Boost le passe sur les cœurs économes.",
                 symbol: "photo.on.rectangle", slowable: true),
        Activity(id: "backup", names: ["backupd", "backupd-helper"], threshold: 10, title: "Sauvegarde Time Machine en cours",
                 detail: "La sauvegarde lit beaucoup le disque. Elle se termine d'elle-même ; macOS la ralentit déjà quand tu travailles.",
                 symbol: "clock.arrow.circlepath", slowable: false),
        Activity(id: "update", names: ["softwareupdated", "UpdateBrainService", "com.apple.MobileSoftwareUpdate.UpdateBrainService"],
                 threshold: 20, title: "Une mise à jour de macOS se prépare",
                 detail: "Téléchargement et préparation de la mise à jour : temporaire.", symbol: "arrow.down.circle", slowable: false),
        Activity(id: "icloud", names: ["bird", "cloudd", "fileproviderd"], threshold: 25, title: "iCloud synchronise tes fichiers",
                 detail: "Envoi ou réception de fichiers iCloud Drive. Ça s'arrête quand tout est à jour.", symbol: "icloud", slowable: false)
    ]

    static func findings(_ i: PerformanceDiagnosisInput) -> [PerformanceFinding] {
        var out: [PerformanceFinding] = []
        let byName = Dictionary(i.processes.map { ($0.name, $0) }, uniquingKeysWith: { a, b in a.cpu >= b.cpu ? a : b })

        // Heat: macOS holds the processor back (kernel_task takes the processor time away from the apps).
        let kernel = byName["kernel_task"]?.cpu ?? 0
        let hot = i.thermal == .serious || i.thermal == .critical || (i.sensors.hotspotTemp ?? 0) >= 105 || kernel >= 80
        if hot {
            var f = PerformanceFinding(id: "heat", status: .bad, symbol: "thermometer.high",
                                       title: "Ton Mac se protège de la chaleur",
                                       detail: "Il ralentit volontairement pour refroidir\(i.sensors.chipTemp.map { " (puce à \(Fmt.int($0)) °C)" } ?? "").",
                                       buttons: [])
            if i.mode != .cool { f.buttons.append(.init(label: "Mode Fraîcheur", action: .mode(.cool))) }
            out.append(f)
        } else if i.cpuLoad >= 0.8, let p = i.sensors.pCluster, p.active >= 0.7, p.speedRatio < 0.75, p.maxFrequency > 0 {
            out.append(PerformanceFinding(id: "throttle", status: .warn, symbol: "gauge.with.dots.needle.33percent",
                                          title: "Processeur bridé",
                                          detail: "Les cœurs performance tournent à \(ghz(p.frequency)) au lieu de \(ghz(p.maxFrequency)) : la chaleur ou l'économie d'énergie les retient.",
                                          buttons: i.mode == .cool ? [] : [.init(label: "Mode Fraîcheur", action: .mode(.cool))]))
        }

        // Apps busy in the background.
        let skip: Set<String> = ["kernel_task", "WindowServer", "launchd", "Heartware", "Heartware", "Heartware"]
        let activityNames = Set(activities.flatMap(\.names))
        let hogs = i.processes
            .filter { $0.cpu >= 40 && $0.id != i.frontID && $0.id != i.ownID && !skip.contains($0.name) && !activityNames.contains($0.name)
                && !i.demoted.contains($0.id) }
            .sorted { $0.cpu > $1.cpu }
        for g in hogs.prefix(3) {
            if i.protected.contains(g.id) {
                // Its work in the background is the point (an export, a build, a recording): nothing to slow.
                out.append(PerformanceFinding(id: "busy-" + g.id, status: .info, symbol: "hammer",
                                              title: "\(g.name) travaille en arrière-plan (\(Fmt.int(g.cpu)) %)",
                                              detail: "Elle fait partie des apps jamais ralenties : exports, compilations, enregistrements et machines virtuelles gardent toute leur vitesse."))
                continue
            }
            var buttons: [PerformanceFinding.Button] = []
            if g.isMine && g.appPath.map({ PerformancePlanner.isAppFolder($0 + "/") }) == true {
                buttons.append(.init(label: "Ralentir", action: .slow(g.id)))
            }
            if g.isMine || g.appPath != nil { buttons.append(.init(label: "Quitter", action: .quit(g.id))) }
            out.append(PerformanceFinding(id: "hog-" + g.id, status: g.cpu >= 90 ? .bad : .warn, symbol: "flame",
                                          title: "\(g.name) prend \(Fmt.int(g.cpu)) % de processeur en arrière-plan",
                                          detail: g.cpu >= 100 ? "C'est plus d'un cœur entier à plein régime : de la chaleur et de la batterie pour une app que tu ne regardes pas."
                                              : "Une app en arrière-plan ne devrait presque rien consommer.",
                                          buttons: buttons))
        }

        for a in activities {
            let groups = a.names.compactMap { byName[$0] }
            let cpu = groups.reduce(0) { $0 + $1.cpu }
            guard cpu >= a.threshold else { continue }
            var f = PerformanceFinding(id: a.id, status: .info, symbol: a.symbol, title: a.title,
                                       detail: a.detail + " (\(Fmt.int(cpu)) % de processeur)")
            if a.slowable, let g = groups.filter({ $0.isMine && !i.demoted.contains($0.id) }).max(by: { $0.cpu < $1.cpu }) {
                f.buttons.append(.init(label: "Ralentir", action: .slow(g.id)))
            }
            out.append(f)
        }

        if let ws = byName["WindowServer"], ws.cpu >= 35 {
            out.append(PerformanceFinding(id: "windowserver", status: .warn, symbol: "macwindow.on.rectangle",
                                          title: "L'affichage travaille beaucoup",
                                          detail: "WindowServer, qui dessine l'écran, prend \(Fmt.int(ws.cpu)) % : beaucoup de fenêtres, d'écrans ou d'effets de transparence. Les réglages Fluidité allègent son travail.",
                                          buttons: [.init(label: "Fluidité", action: .tab(.tweaks))]))
        }

        // Memory.
        if i.pressure != .normal || i.swapUsed > i.memTotal / 2 {
            let mine = i.processes.filter { ($0.isMine || $0.appPath != nil) && $0.id != i.ownID && $0.name != "kernel_task" }
                .sorted { $0.memory > $1.memory }
            var f = PerformanceFinding(id: "memory", status: i.pressure == .critical ? .bad : (i.pressure == .warning ? .warn : .info),
                                       symbol: "memorychip",
                                       title: i.pressure == .normal ? "Beaucoup de mémoire d'échange" : "La mémoire vive est saturée",
                                       detail: "macOS compresse la mémoire et déborde sur le disque (\(Fmt.bytes(i.swapUsed)) d'échange) : tout devient plus lent."
                                           + (mine.isEmpty ? "" : " Les plus gourmandes : " + mine.prefix(3).map { "\($0.name) (\(Fmt.bytes($0.memory)))" }.joined(separator: ", ") + "."))
            if let top = mine.first { f.buttons.append(.init(label: "Quitter \(top.name)", action: .quit(top.id))) }
            out.append(f)
        }

        if i.diskTotal > 0 && (Double(i.diskFree) / Double(i.diskTotal) < 0.1 || i.diskFree < 15_000_000_000) {
            out.append(PerformanceFinding(id: "disk", status: .warn, symbol: "internaldrive",
                                          title: "Disque presque plein",
                                          detail: "Il reste \(Fmt.bytes(i.diskFree)) : macOS a besoin de place pour la mémoire d'échange et ses caches, et ralentit quand il en manque.",
                                          buttons: [.init(label: "Nettoyer", action: .page(.cleanup))]))
        }

        if i.lowPower && i.mode != .cool {
            out.append(PerformanceFinding(id: "lowpower", status: .info, symbol: "battery.25",
                                          title: "L'économie d'énergie bride ton Mac",
                                          detail: "macOS limite la vitesse de la puce pour l'autonomie et la chaleur. Pour jouer ou exporter, repasse en automatique.",
                                          buttons: [.init(label: "Automatique", action: .energy(.automatic))]))
        }

        for d in i.displays where d.canGoFaster {
            out.append(PerformanceFinding(id: "display-\(d.id)", status: .warn, symbol: "display",
                                          title: "\(d.name) peut afficher \(Int(d.best.rounded())) images par seconde",
                                          detail: "Il tourne à \(Int(max(d.current, 60).rounded())) Hz alors qu'il en accepte \(Int(d.best.rounded())) à la même résolution : tout serait plus fluide, jeux compris.",
                                          buttons: [.init(label: "Passer à \(Int(d.best.rounded())) Hz", action: .refresh(d.id))]))
        }

        if !i.rosetta.isEmpty {
            out.append(PerformanceFinding(id: "rosetta", status: .info, symbol: "cpu",
                                          title: Fmt.plural(i.rosetta.count, "app tourne sous Rosetta", "apps tournent sous Rosetta"),
                                          detail: "\(i.rosetta.prefix(4).joined(separator: ", ")) : écrites pour les processeurs Intel et traduites à la volée, elles sont plus lentes et plus chaudes. Une version Apple silicon existe peut-être.",
                                          buttons: [.init(label: "Applications", action: .page(.apps))]))
        }

        if i.uptime > 14 * 86400 {
            out.append(PerformanceFinding(id: "uptime", status: .info, symbol: "power",
                                          title: "Allumé depuis \(Fmt.duration(i.uptime))",
                                          detail: "Un redémarrage rend la mémoire que certaines apps ne libèrent jamais, et termine les mises à jour en attente."))
        }

        if i.startupCount > 12 {
            out.append(PerformanceFinding(id: "startup", status: .info, symbol: "power.circle",
                                          title: "\(i.startupCount) éléments démarrent avec ton Mac",
                                          detail: "Chacun prend un peu de mémoire et de processeur en permanence. Désactive ceux dont tu ne te sers pas.",
                                          buttons: [.init(label: "Démarrage", action: .tab(.startup))]))
        }

        if i.mode == .off {
            out.append(PerformanceFinding(id: "boost-off", status: .info, symbol: "wand.and.stars",
                                          title: "Le Boost est désactivé",
                                          detail: "En mode Intelligent, les apps qui s'emballent en arrière-plan passent sur les cœurs économes : moins de chaleur, plus de fluidité pour ce que tu fais.",
                                          buttons: [.init(label: "Activer", action: .mode(.smart))]))
        }
        return out.sorted { $0.status > $1.status }
    }

    static func ghz(_ mhz: Double) -> String {
        mhz >= 1000 ? "\(Fmt.dec(mhz / 1000)) GHz" : "\(Fmt.int(mhz)) MHz"
    }

    /// Apps running through Rosetta on Apple silicon.
    static func rosettaApps() -> [String] {
        #if arch(arm64)
        if DemoData.isEnabled { return [] }
        return NSWorkspace.shared.runningApplications
            .filter { $0.executableArchitecture == NSBundleExecutableArchitectureX86_64 && $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        #else
        return []
        #endif
    }
}
