import SwiftUI
import Charts

struct PerformancePage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.performance
        VStack(alignment: .leading, spacing: 18) {
            PageHero(symbol: "bolt", title: "Optimisation et performances",
                     subtitle: "Plus de puissance, un Mac plus frais, et la preuve en chiffres.",
                     tint: Theme.warn, seed: 45, tip: model.tab.tip)
            PillPicker(options: PerformanceTab.allCases, selection: $model.tab, label: { $0.title }, badge: { tab in
                switch tab {
                case .startup: return app.startup.activeCount > 0 ? "\(app.startup.activeCount)" : nil
                case .boost: return model.boost.demotions.isEmpty ? nil : "\(model.boost.demotions.count)"
                case .bench: return model.bench.isRunning ? "…" : nil
                default: return nil
                }
            })
            switch model.tab {
            case .boost: PerformanceBoostTab()
            case .monitor:
                // Processes and sensors are only sampled while their tab is on screen.
                MonitorTab()
                    .onAppear {
                        app.performance.startSampling()
                        app.performance.sensors.show(.monitor, true)
                    }
                    .onDisappear {
                        app.performance.stopSampling()
                        app.performance.sensors.show(.monitor, false)
                    }
            case .bench: PerformanceBenchTab()
            case .tweaks: PerformanceTweaksTab()
            case .startup: StartupTab()
            case .maintenance: MaintenanceTab()
            }
        }
    }
}

extension PerformanceTab {
    /// The « ? » next to the page title follows the tab: each one is explained the first time it is opened.
    var tip: HelpTip {
        switch self {
        case .boost:
            return HelpTip(id: "performance.boost", title: "Le Boost",
                           text: "Ce qui tourne en arrière-plan passe sur les cœurs économes de la puce : il continue, plus lentement et plus au frais, et retrouve toute sa vitesse dès que tu y reviens. L'app au premier plan, celles qui jouent du son, surveillent le clavier ou travaillent en fond pour toi (exports, enregistrements, machines virtuelles) ne sont jamais ralenties. Un clic droit sur une app change ses règles.")
        case .monitor:
            return HelpTip(id: "performance.monitor", title: "Le moniteur",
                           text: "La puce, la mémoire et les capteurs en direct, mesurés seulement quand cet onglet est à l'écran. La croix d'une ligne quitte l'app ; un clic droit demande à Claude ce qu'est un processus inconnu.")
        case .bench:
            return HelpTip(id: "performance.bench", title: "Le benchmark",
                           text: "Processeur, graphisme, mémoire, disque et réactivité, mesurés en 25 secondes : 1 000 points, c'est un MacBook Air M2 au calme, sur secteur. Ferme les apps lourdes pour un score stable ; chaque mesure retient le mode du Boost, pour comparer avant et après.")
        case .tweaks:
            return HelpTip(id: "performance.tweaks", title: "La fluidité",
                           text: "Des réglages cachés de macOS qui raccourcissent ou suppriment les animations : chaque geste paraît plus rapide, et la puce graphique travaille moins. Chacun se rétablit exactement comme avant d'un clic.")
        case .startup:
            return HelpTip(id: "performance.startup", title: "Le démarrage",
                           text: "Ces agents tournent en arrière-plan dès l'ouverture de session : mises à jour automatiques, synchronisation, assistants… Désactiver ceux dont tu ne te sers pas allège le démarrage, et c'est réversible à tout moment.")
        case .maintenance:
            return HelpTip(id: "performance.maintenance", title: "Les petites réparations",
                           text: "Des remèdes ciblés pour des soucis précis : inutile de tout lancer « au cas où », macOS s'entretient très bien tout seul. Les tâches marquées d'un cadenas demandent ton mot de passe, dans la fenêtre de macOS.")
        }
    }
}

// MARK: - Monitor

struct MonitorTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.monitor
        VStack(alignment: .leading, spacing: 14) {
            TileRow {
                GaugeCard(title: "Processeur", value: m.cpu, text: Fmt.pct(m.cpu), tint: Theme.load(m.cpu),
                          detail: "Utilisateur \(Fmt.pct(m.cpuUser)) · système \(Fmt.pct(m.cpuSystem))\n\(m.coreCount) cœurs · charge \(Fmt.dec(m.loadAverage))")
                GaugeCard(title: "Mémoire", value: m.memFraction, text: Fmt.pct(m.memFraction),
                          tint: m.pressure == .normal ? Theme.accent : (m.pressure == .warning ? Theme.warn : Theme.bad),
                          detail: "\(Fmt.bytes(m.memUsed)) sur \(Fmt.bytes(m.memTotal))\nPression : \(m.pressure.label)")
                GaugeCard(title: "Mémoire d'échange", value: m.swapTotal > 0 ? Double(m.swapUsed) / Double(m.swapTotal) : 0,
                          text: Fmt.bytes(m.swapUsed), tint: m.swapUsed > m.memTotal / 4 ? Theme.warn : Theme.palette[1],
                          detail: m.swapUsed > 0 ? "macOS déborde sur le disque quand la mémoire manque" : "Aucun débordement sur le disque")
                if let t = app.performance.sensors.current.chipTemp {
                    GaugeCard(title: "Température", value: min(1, t / 110), text: "\(Fmt.int(t))°",
                              tint: PerformanceStyle.temperature(t),
                              detail: "Processeur · \(m.thermalLabel.lowercased()) pour macOS\nAllumé depuis \(Fmt.duration(m.uptime))")
                } else {
                    GaugeCard(title: "Température", value: thermalValue(m.thermal), text: m.thermalLabel,
                              tint: m.thermal == .nominal ? Theme.good : Theme.warn,
                              detail: "Allumé depuis \(Fmt.duration(m.uptime))")
                }
            }
            PerformanceSensorsRow()
            HStack(alignment: .top, spacing: 14) {
                Panel(title: "Processeur", subtitle: "Les deux dernières minutes", symbol: "cpu") {
                    HistoryChart(values: m.cpuHistory.map { $0 * 100 }, tint: Theme.accent, unit: "%", maxY: 100)
                        .frame(height: 140)
                }
                Panel(title: "Mémoire", subtitle: "Répartition en temps réel", symbol: "memorychip") {
                    VStack(alignment: .leading, spacing: 12) {
                        HistoryChart(values: m.memHistory.map { $0 * 100 }, tint: Theme.palette[4], unit: "%", maxY: 100)
                            .frame(height: 80)
                        SegmentedBar(segments: [(Double(m.memApp), Theme.palette[4]), (Double(m.memWired), Theme.palette[5]),
                                                (Double(m.memCompressed), Theme.palette[7]), (Double(m.memCached), Theme.palette[8].opacity(0.6))],
                                     total: Double(m.memTotal))
                        FlowLayout(spacing: 14, lineSpacing: 6) {
                            LegendDot(color: Theme.palette[4], label: "Apps", value: Fmt.bytes(m.memApp))
                            LegendDot(color: Theme.palette[5], label: "Réservée", value: Fmt.bytes(m.memWired))
                            LegendDot(color: Theme.palette[7], label: "Compressée", value: Fmt.bytes(m.memCompressed))
                            LegendDot(color: Theme.palette[8].opacity(0.6), label: "Fichiers en cache", value: Fmt.bytes(m.memCached))
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            ProcessTable()
        }
    }

    private func thermalValue(_ t: ProcessInfo.ThermalState) -> Double {
        switch t {
        case .nominal: return 0.25
        case .fair: return 0.5
        case .serious: return 0.8
        case .critical: return 1
        @unknown default: return 0
        }
    }
}

struct GaugeCard: View {
    var title: String
    var value: Double
    var text: String
    var tint: Color
    var detail: String

    var body: some View {
        Card(padding: 16) {
            HStack(spacing: 14) {
                Gauge(value: value, text: text, tint: tint, size: 66, lineWidth: 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                    Text(detail).font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct HistoryChart: View {
    var values: [Double]
    var tint: Color
    var unit: String
    var maxY: Double

    var body: some View {
        // Newest sample on the right edge, so the chart fills up from the right.
        let shift = max(0, SystemMonitor.historyLength - values.count)
        let points = values.enumerated().map { (offset: $0.offset + shift, element: $0.element) }
        Chart(points, id: \.offset) { p in
            AreaMark(x: .value("t", p.offset), y: .value(unit, p.element))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", p.offset), y: .value(unit, p.element))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
                .interpolationMethod(.monotone)
        }
        .chartXScale(domain: 0...max(1, SystemMonitor.historyLength - 1))
        .chartYScale(domain: 0...maxY)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, maxY / 2, maxY]) { v in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel { Text("\(Int(v.as(Double.self) ?? 0))\(unit == "%" ? " %" : "")").font(.ui(9.5)).foregroundStyle(Theme.text3) }
            }
        }
    }
}

struct ProcessTable: View {
    @Environment(AppModel.self) private var app
    @State private var confirm: ProcessGroup?
    @State private var asking = false

    var body: some View {
        @Bindable var model = app.performance
        Panel(title: "Qui consomme quoi", subtitle: "Mis à jour toutes les 3 secondes", symbol: "list.bullet.rectangle") {
            PillPicker(options: ProcessSort.allCases, selection: $model.sort, label: { $0.title })
        } content: {
            VStack(spacing: 0) {
                if let msg = model.lastQuit {
                    Text(msg).font(.ui(11.5)).foregroundStyle(Theme.text2).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                }
                HStack {
                    Text("App ou processus").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Processeur").frame(width: 90, alignment: .trailing)
                    Text("Mémoire").frame(width: 90, alignment: .trailing)
                    Color.clear.frame(width: 28)
                }
                .font(.ui(10.5, .semibold))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                let list = Array(model.sortedProcesses.prefix(14))
                let maxCPU = max(100, list.map(\.cpu).max() ?? 100)
                let maxMem = Double(list.map(\.memory).max() ?? 1)
                ForEach(list) { g in
                    HoverRow {
                        HStack(spacing: 10) {
                            if let a = g.appPath { FileIcon(path: a, size: 22) } else {
                                Image(systemName: "gearshape").font(.ui(12)).foregroundStyle(Theme.text3).frame(width: 22, height: 22)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(g.name).font(.ui(12.5)).foregroundStyle(Theme.text).lineLimit(1)
                                if g.processCount > 1 {
                                    Text("\(g.processCount) processus").font(.ui(10.5)).foregroundStyle(Theme.text3)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(Fmt.dec(g.cpu) + " %").font(.ui(12)).monospacedDigit().foregroundStyle(Theme.text2)
                                UsageBar(fraction: g.cpu / maxCPU, tint: Theme.load(g.cpu / 100), height: 3).frame(width: 60)
                            }
                            .frame(width: 90, alignment: .trailing)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(Fmt.bytes(g.memory)).font(.ui(12)).monospacedDigit().foregroundStyle(Theme.text2)
                                UsageBar(fraction: Double(g.memory) / maxMem, tint: Theme.palette[4], height: 3).frame(width: 60)
                            }
                            .frame(width: 90, alignment: .trailing)
                            Button { confirm = g; asking = true } label: {
                                Image(systemName: "xmark.circle").font(.ui(13)).foregroundStyle(Theme.text3)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 28)
                            .disabled(!g.isMine && g.appPath == nil)
                            .help("Quitter")
                        }
                    }
                    .contextMenu {
                        Button("Demander à Claude ce que c'est") {
                            app.assistant.explain(g.name, details: [
                                g.appPath.map { "App : \(FS.pretty($0))" } ?? "Processus (pas une app)",
                                "\(g.processCount) processus, \(Fmt.dec(g.cpu)) % de processeur, \(Fmt.bytes(g.memory)) de mémoire"
                            ])
                        }
                        if let a = g.appPath { Button("Afficher dans le Finder") { Finder.reveal(a) } }
                    }
                }
                if list.isEmpty {
                    EmptyHint(text: "Lecture des processus…")
                }
            }
        }
        .alert("Quitter \(confirm?.name ?? "") ?", isPresented: $asking) {
            Button("Quitter") { if let g = confirm { model.quit(g) } }
            Button("Forcer à quitter", role: .destructive) { if let g = confirm { model.quit(g, force: true) } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les documents non enregistrés de cette app pourraient être perdus en forçant.")
        }
    }
}

// MARK: - Startup

struct StartupTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let startup = app.startup
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Text(startup.lastScan.map { "Analysé \(Fmt.relative($0))." } ?? "Pas encore analysé.")
                    .font(.ui(12)).foregroundStyle(Theme.text3)
                Spacer()
                Button("Apps ouvertes à la connexion…") { Finder.open(SettingsPane.loginItems) }
                    .buttonStyle(SoftButtonStyle())
                ScanButton(title: startup.lastScan == nil ? "Analyser" : "Actualiser", symbol: "arrow.clockwise", running: startup.isScanning,
                           activity: .searching) {
                    Task { await startup.scan() }
                }
            }
            if let msg = startup.message {
                Callout(symbol: startup.messageOK ? "checkmark.circle" : "exclamationmark.triangle", title: startup.messageOK ? "Fait" : "Pas tout à fait",
                          text: msg, tint: startup.messageOK ? Theme.good : Theme.warn)
            }
            let items = startup.thirdParty.sorted { a, b in a.disabled != b.disabled ? !a.disabled : a.label < b.label }
            if items.isEmpty {
                Card {
                    EmptyHint(text: startup.lastScan == nil ? "Lance l'analyse pour voir ce qui démarre tout seul." : "Aucun agent tiers. Ton démarrage est léger comme une plume.",
                              symbol: "leaf")
                }
            } else {
                Panel(title: "\(Fmt.plural(startup.activeCount, "élément actif", "éléments actifs")) sur \(items.count)",
                      subtitle: "Hors composants d'Apple. Les services système demandent ton mot de passe.", symbol: "power") {
                    LaunchItemList(items: items)
                }
            }
        }
        .task { if app.startup.lastScan == nil { await app.startup.scan() } }
    }
}

// MARK: - Maintenance

struct MaintenanceTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let tasks = MaintenanceTask.all.filter(\.available)
        Card(padding: 6) {
            VStack(spacing: 0) {
                ForEach(tasks) { t in
                    MaintenanceRow(task: t)
                    if t.id != tasks.last?.id {
                        Rectangle().fill(Theme.border).frame(height: max(1, Theme.line) * 0.5).padding(.leading, 56)
                    }
                }
            }
        }
        .task { if app.performance.snapshotCount == nil { await app.performance.countSnapshots() } }
    }
}

/// One repair on one line: what it fixes, then its button on the right.
struct MaintenanceRow: View {
    @Environment(AppModel.self) private var app
    var task: MaintenanceTask

    var body: some View {
        let model = app.performance
        HoverRow {
            HStack(alignment: .center, spacing: 12) {
                IconBadge(symbol: task.symbol, tint: Theme.warn, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(task.title).font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                        if task.needsAdmin {
                            Image(systemName: "lock.fill").font(.ui(10)).foregroundStyle(Theme.text3).help("Demande ton mot de passe")
                        }
                    }
                    Text(task.detail).font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    if task.id == "snapshots", let n = model.snapshotCount {
                        Text(n == 0 ? "Aucun instantané local en ce moment." : "\(Fmt.plural(n, "instantané local", "instantanés locaux")) sur le disque.")
                            .font(.ui(11)).foregroundStyle(Theme.text3)
                    }
                    if let w = task.warning {
                        Label(w, systemImage: "exclamationmark.triangle").font(.ui(11)).foregroundStyle(Theme.warn)
                    }
                    if let r = model.results[task.id] {
                        Label(r.message, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.ui(11)).foregroundStyle(r.ok ? Theme.good : Theme.bad).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.results[task.id] == nil, let d = model.lastRun(task) {
                    Text("Dernière fois \(Fmt.relative(d))").font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1).fixedSize()
                }
                Button {
                    if let text = task.confirmation, !CommandRunner.confirm("\(task.title) ?", text, button: "Lancer") { return }
                    Task { await model.run(task) }
                } label: {
                    HStack(spacing: 6) {
                        if model.runningTasks.contains(task.id) { BusyMascot(.typing, pixel: 1) }
                        Text(model.runningTasks.contains(task.id) ? "En cours…" : "Lancer")
                    }
                }
                .buttonStyle(SoftButtonStyle(small: true))
                .fixedSize()
                .disabled(model.runningTasks.contains(task.id) || (task.id == "snapshots" && model.snapshotCount == 0))
            }
        }
    }
}
