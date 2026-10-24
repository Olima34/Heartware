import SwiftUI
import Charts

// MARK: - Benchmark tab

struct PerformanceBenchTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PerformanceBenchHero()
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                      spacing: 14) {
                ForEach(PerformanceBenchTest.allCases) { t in PerformanceBenchCard(test: t) }
            }
            HStack(alignment: .top, spacing: 14) {
                PerformanceBoostTestPanel()
                PerformanceEndurancePanel()
            }
            .fixedSize(horizontal: false, vertical: true)
            PerformanceBenchHistory()
        }
    }
}

struct PerformanceBenchHero: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let p = app.performance
        let bench = p.bench
        let running = bench.job == .full
        Card(padding: 20) {
            HStack(alignment: .center, spacing: 22) {
                ZStack {
                    ProgressRing(progress: running ? bench.progress : 1, tint: Theme.accent, lineWidth: 7)
                    VStack(spacing: 0) {
                        Text(running ? "\(Fmt.int(bench.progress * 100)) %" : bench.latest.map { Fmt.int($0.total) } ?? "—")
                            .font(.serif(30)).foregroundStyle(Theme.text).monospacedDigit()
                            .minimumScaleFactor(0.6).lineLimit(1)
                        Text(running ? "en cours" : "points").font(.ui(11)).foregroundStyle(Theme.text3)
                    }
                    .padding(14)
                }
                .frame(width: 112, height: 112)
                .help("1 000 points = un MacBook Air M2 au calme, sur secteur.")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Benchmark de ton Mac").font(.serif(22)).foregroundStyle(Theme.text)
                    Text(running ? "Mesure : \(bench.currentTest?.title.lowercased() ?? "préparation")…"
                         : bench.latest.map { "Dernière mesure \(Fmt.relative($0.date)), \($0.context)." }
                            ?? "Processeur, graphisme, mémoire, disque et réactivité, mesurés en 25 secondes.")
                        .font(.ui(12.5)).foregroundStyle(Theme.text2)
                    HStack(spacing: 10) {
                        ScanButton(title: bench.latest == nil ? "Lancer le benchmark" : "Mesurer à nouveau", symbol: "speedometer",
                                   running: running, runningTitle: "Mesure…", activity: .lifting) {
                            bench.runFull(mode: p.boost.effectiveMode, onBattery: app.monitor.battery.map { !$0.onAC } ?? false)
                        }
                        .disabled(bench.isRunning && !running)
                        if running {
                            Button("Annuler") { bench.cancelJob() }.buttonStyle(SoftButtonStyle())
                        }
                    }
                    .padding(.top, 4)
                    if let msg = bench.message {
                        Text(msg).font(.ui(11.5)).foregroundStyle(Theme.warn)
                    }
                }
                Spacer(minLength: 12)
                if running {
                    BusyMascot(.lifting, pixel: 4)
                }
                if !running, let last = bench.latest, let base = bench.baseline, let delta = last.gain(over: base) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(PerformanceBenchFormat.delta(delta))
                            .font(.serif(30)).foregroundStyle(PerformanceBenchFormat.deltaColor(delta))
                        Text("par rapport au \(Fmt.day(base.date))").font(.ui(11)).foregroundStyle(Theme.text3)
                        Text(base.context).font(.ui(11)).foregroundStyle(Theme.text3)
                    }
                }
            }
        }
    }
}

enum PerformanceBenchFormat {
    static func delta(_ d: Double) -> String {
        let pct = (d * 100).rounded()
        return (pct > 0 ? "+" : (pct < 0 ? "−" : "")) + Fmt.int(abs(pct)) + " %"
    }

    static func deltaColor(_ d: Double) -> Color {
        if d > 0.02 { return Theme.good }
        if d < -0.02 { return Theme.bad }
        return Theme.text2
    }
}

struct PerformanceBenchCard: View {
    @Environment(AppModel.self) private var app
    var test: PerformanceBenchTest

    var body: some View {
        let bench = app.performance.bench
        let live = bench.job == .full ? bench.partial[test.rawValue] : nil
        let latest = bench.job == .full ? nil : bench.latest
        let raw = live ?? latest?.value(test)
        let score = raw.map(test.score)
        let baseScore = latest == nil ? nil : bench.baseline?.score(test)
        let active = bench.job == .full && bench.currentTest == test
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    IconBadge(symbol: test.symbol, tint: Theme.accent)
                    Text(test.title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 4)
                    if active {
                        BusyMascot(.lifting, pixel: 1)
                    } else if let score, let baseScore, baseScore > 0 {
                        Text(PerformanceBenchFormat.delta(score / baseScore - 1)).font(.ui(11, .semibold))
                            .foregroundStyle(PerformanceBenchFormat.deltaColor(score / baseScore - 1))
                    }
                }
                Text(score.map { Fmt.int($0) } ?? "—").font(.serif(28)).foregroundStyle(Theme.text).monospacedDigit()
                Text(detail(raw, result: latest)).font(.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(1)
                UsageBar(fraction: (score ?? 0) / 2500, tint: Theme.accent, height: 5)
            }
        }
        .help(test.detail)
    }

    private func detail(_ raw: Double?, result: PerformanceBenchResult?) -> String {
        guard let raw else { return test == .disk ? "Il faut 6 Go libres" : "Pas encore mesuré" }
        switch test {
        case .disk:
            if let w = result?.extra["diskWrite"], let r = result?.extra["diskRead"] { return "Écriture \(Fmt.int(w)) · lecture \(Fmt.int(r)) Mo/s" }
        case .latency:
            if let m = result?.extra["latencyMedian"] { return "Médiane \(Fmt.int(m)) µs · 99 % sous \(Fmt.int(raw)) µs" }
        default:
            break
        }
        return test.format(raw)
    }
}

// MARK: - Boost test

struct PerformanceBoostTestPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let bench = app.performance.bench
        let running = bench.job == .boostDemo
        Panel(title: "Test du Boost", subtitle: "Ce que le Boost change sur ton Mac, en 10 secondes.", symbol: "bolt.badge.checkmark") {
            VStack(alignment: .leading, spacing: 12) {
                if bench.boostDemo == nil && !running {
                    Text("Ton app seule, puis avec des tâches lourdes en fond, puis avec le Boost.")
                        .font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
                if let r = bench.boostDemo, !running {
                    VStack(spacing: 8) {
                        bar("Ton app seule", 1, tint: Theme.text3)
                        bar("Avec des tâches de fond", r.contendedRatio, tint: Theme.bad)
                        bar("Avec le Boost", r.boostedRatio, tint: Theme.good)
                    }
                    Text(summary(r)).font(.ui(11.5, .medium)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                } else if running {
                    HStack(spacing: 10) {
                        ProgressRing(progress: bench.progress, tint: Theme.accent, lineWidth: 4).frame(width: 26, height: 26)
                        Text(bench.progress < 0.33 ? "L'app seule…" : (bench.progress < 0.66 ? "Avec des tâches de fond…" : "Avec le Boost…"))
                            .font(.ui(12)).foregroundStyle(Theme.text2)
                    }
                }
                HStack(spacing: 8) {
                    Button(running ? "Test en cours…" : (bench.boostDemo == nil ? "Lancer le test (10 s)" : "Refaire le test")) { bench.runBoostDemo() }
                        .buttonStyle(SoftButtonStyle(prominent: !running))
                        .disabled(bench.isRunning)
                    if running { Button("Annuler") { bench.cancelJob() }.buttonStyle(SoftButtonStyle()) }
                }
            }
        }
    }

    private func bar(_ label: String, _ ratio: Double, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.ui(11.5)).foregroundStyle(Theme.text2).frame(width: 150, alignment: .leading)
            UsageBar(fraction: ratio / 1.1, tint: tint, height: 8)
            Text("\(Fmt.int(ratio * 100)) %").font(.ui(12, .semibold)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 46, alignment: .trailing)
        }
    }

    private func summary(_ r: PerformanceBoostDemoResult) -> String {
        var s = "Le Boost rend \(PerformanceBenchFormat.delta(r.gain)) de vitesse à l'app au premier plan"
        if let a = r.contended.power, let b = r.boosted.power, a > b {
            s += ", et le Mac consomme \(Fmt.dec(a - b)) W de moins"
            if let ta = r.contended.temp, let tb = r.boosted.temp, ta > tb + 1 { s += " (\(Fmt.int(ta - tb)) °C de moins sur la puce)" }
        }
        let kept = r.contended.background > 0 ? r.boosted.background / r.contended.background : 0
        return s + ". Les tâches de fond continuent à \(Fmt.int(kept * 100)) % de leur vitesse."
    }
}

// MARK: - Endurance

struct PerformanceEndurancePanel: View {
    @Environment(AppModel.self) private var app
    @State private var asking = false

    var body: some View {
        let bench = app.performance.bench
        let running = bench.job == .endurance
        let windows = running ? bench.liveWindows : (bench.endurance?.windows ?? [])
        Panel(title: "Endurance thermique", subtitle: "Trois minutes à plein régime : quand ralentit-il pour refroidir ?",
              symbol: "thermometer.high") {
            VStack(alignment: .leading, spacing: 12) {
                if windows.count >= 2 {
                    PerformanceEnduranceChart(windows: windows).frame(height: 110)
                    if !running, let e = bench.endurance {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Fmt.pct(e.stability)).font(.serif(26)).foregroundStyle(e.stability >= 0.9 ? Theme.good : Theme.warn)
                            Text("de stabilité").font(.ui(12)).foregroundStyle(Theme.text2)
                        }
                        Text(summary(e)).font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }
                } else if !running {
                    Text("À 100 % de stabilité, ton Mac tient le rythme sans brider sa puce.")
                        .font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
                if running {
                    HStack(spacing: 10) {
                        ProgressRing(progress: bench.progress, tint: Theme.warn, lineWidth: 4).frame(width: 26, height: 26)
                        Text("Encore \(Fmt.duration((1 - bench.progress) * PerformanceBenchModel.enduranceDuration))").font(.ui(12)).foregroundStyle(Theme.text2)
                    }
                }
                HStack(spacing: 8) {
                    Button(running ? "Test en cours…" : "Lancer (3 min)") { asking = true }
                        .buttonStyle(SoftButtonStyle())
                        .disabled(bench.isRunning)
                    if running { Button("Annuler") { bench.cancelJob() }.buttonStyle(SoftButtonStyle()) }
                }
            }
        }
        .confirmAction("Lancer le test d'endurance ?",
                       message: "Ton Mac va tourner à plein régime pendant 3 minutes : il va chauffer, et ventiler s'il a un ventilateur. Tu peux l'arrêter à tout moment.",
                       button: "Lancer", isPresented: $asking, destructive: false) {
            bench.runEndurance()
        }
    }

    private func summary(_ e: PerformanceEnduranceResult) -> String {
        guard let first = e.windows.first, let last = e.windows.last else { return "" }
        var parts: [String] = []
        if let a = first.temp, let b = last.temp { parts.append("La puce est passée de \(Fmt.int(a)) à \(Fmt.int(b)) °C") }
        if let a = first.pFrequency, let b = last.pFrequency, a > 0 {
            parts.append("les cœurs performance de \(PerformanceDiagnosis.ghz(a)) à \(PerformanceDiagnosis.ghz(b))")
        }
        return parts.isEmpty ? "Mesuré \(Fmt.relative(e.date))." : parts.joined(separator: ", ") + "."
    }
}

struct PerformanceEnduranceChart: View {
    var windows: [PerformanceEnduranceResult.Window]

    var body: some View {
        let best = max(1, windows.map(\.rate).max() ?? 1)
        Chart {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, w in
                LineMark(x: .value("s", w.second), y: .value("Vitesse", w.rate / best * 100), series: .value("courbe", "vitesse"))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                if let t = w.temp {
                    LineMark(x: .value("s", w.second), y: .value("Température", t), series: .value("courbe", "température"))
                        .foregroundStyle(Theme.warn)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
        }
        .chartYScale(domain: 0...110)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisValueLabel { Text("\(Int(v.as(Double.self) ?? 0)) s").font(.ui(9.5)).foregroundStyle(Theme.text3) }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel { Text("\(Int(v.as(Double.self) ?? 0))").font(.ui(9.5)).foregroundStyle(Theme.text3) }
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                LegendDot(color: Theme.accent, label: "Vitesse", value: "%")
                LegendDot(color: Theme.warn, label: "Puce", value: "°C")
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: Theme.r(6)).fill(Theme.card.opacity(0.9)))
        }
    }
}

// MARK: - History

struct PerformanceBenchHistory: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let history = app.performance.bench.history
        Panel(title: "Historique", subtitle: "Chaque mesure, avec le mode du Boost actif.",
              symbol: "chart.bar") {
            if history.isEmpty {
                EmptyHint(text: "Lance un premier benchmark : les suivants s'y compareront.", symbol: "speedometer")
            } else {
                let recent = Array(history.suffix(12).enumerated())
                Chart {
                    ForEach(recent, id: \.element.id) { i, r in
                        BarMark(x: .value("Mesure", "\(i + 1)"), y: .value("Score", r.total))
                            .foregroundStyle(PerformanceStyle.mode(r.mode).opacity(r.mode == .off ? 0.55 : 1))
                            .cornerRadius(Theme.r(3))
                            .annotation(position: .top) {
                                Text(Fmt.int(r.total)).font(.ui(9.5)).foregroundStyle(Theme.text3)
                            }
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine().foregroundStyle(Theme.border)
                        AxisValueLabel { Text("\(Int(v.as(Double.self) ?? 0))").font(.ui(9.5)).foregroundStyle(Theme.text3) }
                    }
                }
                .frame(height: 130)
                FlowLayout(spacing: 14, lineSpacing: 6) {
                    ForEach(PerformanceMode.allCases) { m in
                        LegendDot(color: PerformanceStyle.mode(m), label: m == .off ? "Boost désactivé" : m.title, value: "")
                    }
                }
                VStack(spacing: 0) {
                    ForEach(history.suffix(5).reversed()) { r in
                        HStack(spacing: 10) {
                            Text(Fmt.day(r.date)).font(.ui(12)).foregroundStyle(Theme.text).frame(width: 110, alignment: .leading)
                            Text(r.context).font(.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
                            Spacer()
                            if let t = r.tempEnd { Text("\(Fmt.int(t)) °C").font(.ui(11)).foregroundStyle(Theme.text3) }
                            Text(Fmt.int(r.total)).font(.ui(12.5, .semibold)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 56, alignment: .trailing)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }
}
