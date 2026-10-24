import SwiftUI
import AppKit

// MARK: - Boost tab

struct PerformanceBoostTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let p = app.performance
        VStack(alignment: .leading, spacing: 14) {
            PerformanceLiveTiles()
            PerformanceModePanel()
            HStack(alignment: .top, spacing: 14) {
                PerformanceDemotedPanel()
                PerformanceBusyPanel()
            }
            .fixedSize(horizontal: false, vertical: true)
            PerformanceDiagnosisPanel()
            PerformanceRulesPanel()
        }
        .onAppear {
            p.sensors.show(.boost, true)
            p.startSampling()
            p.tweaks.refresh()
            Task { await p.boost.refreshPowerState() }
        }
        .onDisappear {
            p.sensors.show(.boost, false)
            p.stopSampling()
        }
    }
}

/// Temperature, power, cores and GPU, live.
struct PerformanceLiveTiles: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = app.performance.sensors
        let c = s.current
        let m = app.monitor
        TileRow {
            PerformanceSensorTile(symbol: "thermometer.medium", label: "Température",
                                  value: c.chipTemp.map { "\(Fmt.int($0)) °C" } ?? m.thermalLabel,
                                  detail: c.chipTemp == nil ? "Capteur indisponible, état selon macOS"
                                      : "Processeur · \(m.thermalLabel.lowercased()) pour macOS",
                                  tint: PerformanceStyle.temperature(c.chipTemp), history: s.chipHistory, maxValue: 110)
            PerformanceSensorTile(symbol: "bolt", label: "Consommation",
                                  value: c.systemPower.map { "\(Fmt.dec($0)) W" } ?? "—",
                                  detail: powerDetail(c, battery: m.battery),
                                  tint: Theme.palette[2], history: s.powerHistory, maxValue: nil)
            PerformanceSensorTile(symbol: "cpu", label: "Cœurs performance",
                                  value: c.pCluster.map { PerformanceDiagnosis.ghz($0.frequency) } ?? Fmt.pct(m.cpu),
                                  detail: c.pCluster.map { "Actifs \(Fmt.int($0.active * 100)) % · jusqu'à \(PerformanceDiagnosis.ghz($0.maxFrequency))" }
                                      ?? "Processeur, tous cœurs",
                                  tint: Theme.accent, history: m.cpuHistory.map { $0 * 100 }, maxValue: 100)
            PerformanceSensorTile(symbol: "cube.transparent", label: "Graphisme (GPU)",
                                  value: c.gpuUsage.map { "\(Fmt.int($0 * 100)) %" } ?? "—",
                                  detail: [c.gpuFrequency.map { "\(Fmt.int($0)) MHz" }, c.gpuPower.map { "\(Fmt.dec($0)) W" }]
                                      .compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Au repos",
                                  tint: Theme.palette[4], history: s.gpuHistory.map { $0 * 100 }, maxValue: 100)
        }
    }

    private func powerDetail(_ c: PerformanceSensorSample, battery: BatteryInfo?) -> String {
        if let a = c.adapterPower, a > 0.5 { return "Chargeur : \(Fmt.dec(a)) W" }
        if let b = battery, !b.onAC { return "Sur batterie · \(Fmt.pct(b.level))" }
        return "Le Mac entier, écran compris"
    }
}

struct PerformanceSensorTile: View {
    var symbol: String
    var label: String
    var value: String
    var detail: String
    var tint: Color
    var history: [Double]
    var maxValue: Double?

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    IconBadge(symbol: symbol, tint: tint)
                    Text(label).font(.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
                }
                Text(value)
                    .font(.serif(28))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text(detail).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Sparkline(values: history, maxValue: maxValue, tint: tint)
                    .frame(height: 26)
            }
        }
    }
}

enum PerformanceStyle {
    static func temperature(_ t: Double?) -> Color {
        guard let t else { return Theme.text3 }
        if t < 70 { return Theme.good }
        if t < 90 { return Theme.warn }
        return Theme.bad
    }

    static func mode(_ m: PerformanceMode) -> Color {
        switch m {
        case .off: return Theme.text3
        case .smart: return Theme.accent
        case .performance: return Theme.warn
        case .cool: return Theme.palette[1]
        }
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Modes

struct PerformanceModePanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var b = app.performance.boost
        Panel(title: "Mode du Boost", symbol: "bolt") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(PerformanceMode.allCases) { m in
                        PerformanceModeCard(mode: m, selected: b.mode == m) { b.setMode(m) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                if b.mode == .smart {
                    Toggle(isOn: $b.gameBoost) {
                        PerformanceOptionLabel(title: "Passer en Performance quand un jeu est au premier plan",
                                               detail: b.gameInFront.map { "En ce moment : \($0) au premier plan, mode Performance actif." }
                                                   ?? "Reconnus à leur catégorie ou à Steam, Epic, GOG.")
                    }
                    .switchToggles()
                    Toggle(isOn: $b.heatAssist) {
                        PerformanceOptionLabel(title: "Refroidir automatiquement quand le Mac chauffe",
                                               detail: b.coolingDown ? "En ce moment : la puce chauffe, tout l'arrière-plan est sur les cœurs économes."
                                                   : "L'arrière-plan passe sur les cœurs économes jusqu'au retour au calme.")
                    }
                    .switchToggles()
                }
                if b.mode == .performance {
                    Toggle(isOn: Binding(get: { b.forceGameMode }, set: { b.setForceGameMode($0) })) {
                        PerformanceOptionLabel(title: "Forcer le mode Jeu de macOS",
                                               detail: b.gameModeAvailable ? "Priorité au jeu, latence Bluetooth divisée par deux."
                                                   : "Il faut Xcode ; sinon macOS l'active seul en plein écran.")
                    }
                    .switchToggles()
                    .disabled(!b.gameModeAvailable)
                }
                if b.mode == .cool {
                    Text("Fraîcheur active aussi l'économie d'énergie de macOS (mot de passe demandé), remise comme avant ensuite.")
                        .font(.ui(11.5)).foregroundStyle(Theme.text3)
                }

                Rectangle().fill(Theme.border).frame(height: max(1, Theme.line))
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mode d'énergie de macOS").font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                        Text("Demande ton mot de passe.")
                            .font(.ui(11)).foregroundStyle(Theme.text3)
                    }
                    Spacer(minLength: 8)
                    if b.energyBusy { BusyMascot(.lifting, pixel: 1) }
                    if let e = b.energy {
                        PillPicker(options: e.levels, selection: Binding(get: { e.level }, set: { level in
                            Task { await b.setEnergy(level) }
                        }), label: { $0.title })
                        .disabled(b.energyBusy)
                    } else {
                        Text("Indisponible").font(.ui(11.5)).foregroundStyle(Theme.text3)
                    }
                }
                if let msg = b.message {
                    Label(msg.text, systemImage: msg.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.ui(11.5)).foregroundStyle(msg.ok ? Theme.good : Theme.warn)
                }
            }
        }
    }
}

struct PerformanceOptionLabel: View {
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
            Text(detail).font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PerformanceModeCard: View {
    var mode: PerformanceMode
    var selected: Bool
    var action: () -> Void

    var body: some View {
        let tint = PerformanceStyle.mode(mode)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    IconBadge(symbol: mode.symbol, tint: tint, size: 26)
                    Spacer(minLength: 4)
                    if selected {
                        Text("Actif").font(.ui(10, .semibold)).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(PillShape().fill(Theme.accent))
                    }
                }
                Text(mode.title).font(.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                Text(mode.summary).font(.ui(11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).fill(selected ? Theme.selected : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? max(1.5, Theme.line) : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Slowed and busy apps

struct PerformanceDemotedPanel: View {
    @Environment(AppModel.self) private var app
    @State private var expanded = false

    var body: some View {
        let b = app.performance.boost
        Panel(title: "Sur les cœurs économes", subtitle: "Elles continuent leur travail, plus au frais.", symbol: "tortoise") {
            if !b.demotions.isEmpty {
                Button("Tout rétablir") { b.restoreAll() }.buttonStyle(SoftButtonStyle(small: true))
            }
        } content: {
            VStack(spacing: 2) {
                if b.demotions.isEmpty {
                    EmptyHint(text: b.mode == .off ? "Le Boost est désactivé : rien n'est ralenti."
                              : "Rien n'est ralenti : aucune app ne te vole de puissance en ce moment.", symbol: "leaf")
                }
                let sorted = b.demotions.sorted { ($0.cpuNow, $0.cpuBefore) > ($1.cpuNow, $1.cpuBefore) }
                let shown = expanded ? sorted : Array(sorted.prefix(6))
                ForEach(shown) { d in
                    HoverRow {
                        HStack(spacing: 10) {
                            PerformanceGroupIcon(appPath: d.appPath)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name).font(.ui(12.5)).foregroundStyle(Theme.text).lineLimit(1)
                                Text(d.reason).font(.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("\(Fmt.int(d.cpuNow)) %").font(.ui(12)).monospacedDigit().foregroundStyle(Theme.text2)
                                Text("depuis \(Fmt.relative(d.since))").font(.ui(10)).foregroundStyle(Theme.text3).lineLimit(1)
                            }
                            Button("Rétablir") { b.restore(d) }.buttonStyle(SoftButtonStyle(small: true))
                        }
                    }
                    .contextMenu {
                        Button("Ne jamais ralentir \(d.name)") { b.protect(bundleID: d.bundleID, key: d.key) }
                        Button(b.rules.alwaysSlow.contains(d.key) ? "Ne plus ralentir systématiquement" : "Toujours ralentir en arrière-plan") {
                            b.toggleAlwaysSlow(key: d.key, bundleID: d.bundleID)
                        }
                        if let path = d.appPath { Button("Afficher dans le Finder") { Finder.reveal(path) } }
                    }
                }
                if sorted.count > 6 {
                    Button(expanded ? "Afficher moins" : "Et \(Fmt.plural(sorted.count - 6, "autre, au repos", "autres, au repos")) : tout afficher") {
                        expanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.ui(11.5, .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 4)
                }
            }
        }
    }
}

struct PerformanceBusyPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let b = app.performance.boost
        Panel(title: "S'agitent en arrière-plan",
              subtitle: b.mode == .smart ? "Au-delà de \(Fmt.int(PerformancePlanner.busyCPU)) % de processeur pendant 20 s, le mode Intelligent les ralentit."
                  : "Les apps en arrière-plan à pleine vitesse.",
              symbol: "flame") {
            VStack(spacing: 2) {
                if b.mode == .off {
                    EmptyHint(text: "Active le Boost pour suivre ce qui tourne en arrière-plan.", symbol: "eye.slash")
                } else if b.busy.isEmpty {
                    EmptyHint(text: "Tout est calme en arrière-plan.", symbol: "checkmark.circle")
                }
                ForEach(b.busy, id: \.key) { g in
                    HoverRow {
                        HStack(spacing: 10) {
                            PerformanceGroupIcon(appPath: g.appPath)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(g.name).font(.ui(12.5)).foregroundStyle(Theme.text).lineLimit(1)
                                Text(kindLabel(g.kind)).font(.ui(10.5)).foregroundStyle(Theme.text3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(Fmt.int(g.cpu)) %").font(.ui(12)).monospacedDigit().foregroundStyle(Theme.load(g.cpu / 100))
                            Button("Ralentir") { b.slowNow(g) }.buttonStyle(SoftButtonStyle(small: true))
                        }
                    }
                    .contextMenu {
                        Button("Ne jamais ralentir \(g.name)") { b.protect(bundleID: g.bundleID, key: g.key) }
                        Button("Toujours ralentir en arrière-plan") { b.toggleAlwaysSlow(key: g.key, bundleID: g.bundleID) }
                    }
                }
            }
        }
    }

    private func kindLabel(_ k: PerformanceGroupKind) -> String {
        switch k {
        case .app: return "App"
        case .menuBar: return "Barre des menus"
        case .helper: return "Processus d'aide"
        case .daemon: return "Service d'Apple"
        case .other: return "Système"
        }
    }
}

struct PerformanceGroupIcon: View {
    var appPath: String?

    var body: some View {
        if let appPath {
            FileIcon(path: appPath, size: 22)
        } else if Theme.icons != .hidden {
            Image(systemName: "gearshape.2").font(.ui(12)).foregroundStyle(Theme.text3).frame(width: 22, height: 22)
        }
    }
}

// MARK: - Diagnosis

struct PerformanceDiagnosisPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let p = app.performance
        let findings = p.diagnosis(app: app)
        let serious = findings.filter { $0.status >= .warn }
        Panel(title: "Ce qui ralentit ou chauffe ton Mac",
              subtitle: serious.isEmpty ? "Rien d'anormal en ce moment. Mis à jour en direct." : Fmt.plural(serious.count, "point à regarder", "points à regarder") + ", mis à jour en direct.",
              symbol: "stethoscope") {
            VStack(alignment: .leading, spacing: 10) {
                if findings.isEmpty {
                    EmptyHint(text: p.processes.isEmpty ? "Lecture des processus…" : "Ton Mac tourne comme une horloge.", symbol: "checkmark.seal")
                }
                ForEach(findings) { f in
                    HStack(alignment: .top, spacing: 12) {
                        IconBadge(symbol: f.symbol, tint: f.status.color, size: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(f.title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                                if f.status >= .warn { StatusBadge(status: f.status) }
                            }
                            Text(f.detail).font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 6) {
                            ForEach(f.buttons, id: \.label) { button in
                                Button(button.label) { p.perform(button.action, app: app) }
                                    .buttonStyle(SoftButtonStyle(prominent: button.action == f.buttons.first?.action && f.status >= .warn, small: true))
                                    .fixedSize()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if f.id != findings.last?.id {
                        Rectangle().fill(Theme.border).frame(height: max(1, Theme.line) * 0.5)
                    }
                }
            }
        }
    }
}

// MARK: - Rules

struct PerformanceRulesPanel: View {
    @Environment(AppModel.self) private var app

    /// Names of the apps protected by default (shown even when they are not installed).
    static let knownNames: [String: String] = [
        "com.obsproject.obs-studio": "OBS Studio", "com.streamlabs.slobs": "Streamlabs", "com.ecamm.EcammLive": "Ecamm Live",
        "com.apple.FinalCut": "Final Cut Pro", "com.apple.Compressor": "Compressor", "com.apple.motionapp": "Motion",
        "com.apple.logic10": "Logic Pro", "com.apple.mainstage3": "MainStage", "com.blackmagic-design.DaVinciResolve": "DaVinci Resolve",
        "com.blackmagic-design.DaVinciResolveLite": "DaVinci Resolve", "fr.handbrake.HandBrake": "HandBrake",
        "org.blenderfoundation.blender": "Blender", "com.apple.dt.Xcode": "Xcode", "com.docker.docker": "Docker", "com.utmapp.UTM": "UTM",
        "com.parallels.desktop.console": "Parallels Desktop", "com.vmware.fusion": "VMware Fusion", "com.apple.ScreenSharing": "Partage d'écran",
        "com.apple.screencaptureui": "Capture d'écran", "com.apple.QuickTimePlayerX": "QuickTime Player",
        "com.electron.ollama": "Ollama", "ai.elementlabs.lmstudio": "LM Studio"
    ]

    static func name(_ id: String) -> String {
        if let n = knownNames[id] { return n }
        if id.hasPrefix("/") { return (id as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }
        if !DemoData.isEnabled, let n = AppNames.name(for: id) { return n }
        return id
    }

    var body: some View {
        let b = app.performance.boost
        Panel(title: "Tes règles", subtitle: "Clic droit sur une app pour changer.", symbol: "slider.horizontal.3") {
            Button("Règles par défaut") { b.resetRules() }.buttonStyle(SoftButtonStyle(small: true))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Jamais ralenties")
                // One chip per name (DaVinci Resolve and its free edition share theirs).
                let protected = Dictionary(grouping: b.rules.protected, by: Self.name)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(b.rules.protected.map(Self.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }, id: \.self) { name in
                        PerformanceRuleChip(title: name) {
                            for id in protected[name] ?? [] { b.unprotect(id) }
                        }
                    }
                }
                SectionLabel(text: "Toujours ralenties en arrière-plan")
                if b.rules.alwaysSlow.isEmpty {
                    Text("Aucune pour l'instant.").font(.ui(11.5)).foregroundStyle(Theme.text3)
                } else {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(b.rules.alwaysSlow, id: \.self) { key in
                            PerformanceRuleChip(title: Self.name(key)) { b.toggleAlwaysSlow(key: key, bundleID: nil) }
                        }
                    }
                }
            }
        }
    }
}

struct PerformanceRuleChip: View {
    var title: String
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.ui(11, .medium)).foregroundStyle(Theme.text2).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text3)
            }
            .buttonStyle(.plain)
            .help("Retirer")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(PillShape().fill(Theme.track))
    }
}

// MARK: - Bottom bar

struct PerformanceBottomBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let p = app.performance
        if p.bench.isRunning && p.tab != .bench {
            ActionBar {
                ProgressRing(progress: p.bench.progress, tint: Theme.accent, lineWidth: 3).frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mesure en cours").font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                    Text(p.bench.currentTest?.title ?? (p.bench.job == .endurance ? "Endurance thermique" : "Test du Boost"))
                        .font(.ui(11)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Button("Voir") { p.tab = .bench }.buttonStyle(SoftButtonStyle())
                Button("Annuler") { p.bench.cancelJob() }.buttonStyle(SoftButtonStyle())
            }
        } else if p.tab == .boost && !p.boost.demotions.isEmpty {
            ActionBar {
                IconBadge(symbol: "tortoise", tint: Theme.accent, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.plural(p.boost.demotions.count, "app sur les cœurs économes", "apps sur les cœurs économes"))
                        .font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                    Text(p.boost.demotions.prefix(4).map(\.name).joined(separator: ", ")).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer()
                Button("Tout rétablir") { p.boost.restoreAll() }.buttonStyle(SoftButtonStyle())
            }
        }
    }
}
