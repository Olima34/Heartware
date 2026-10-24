import SwiftUI

/// The Monitor tab's sensors: temperature and power curves, frequencies, temperatures and fans.
struct PerformanceSensorsRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = app.performance.sensors
        if s.current.isEmpty && s.chipHistory.isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 14) {
                Panel(title: "Température du processeur", subtitle: "Les deux dernières minutes", symbol: "thermometer.medium") {
                    HistoryChart(values: s.chipHistory, tint: Theme.warn, unit: "°C", maxY: 110)
                        .frame(height: 120)
                }
                Panel(title: "Consommation", subtitle: "Le Mac entier, écran compris", symbol: "bolt") {
                    HistoryChart(values: s.powerHistory, tint: Theme.palette[2], unit: "W",
                                 maxY: max(20, ((s.powerHistory.max() ?? 0) * 1.25 / 10).rounded(.up) * 10))
                        .frame(height: 120)
                }
                Panel(title: "Puce", subtitle: "Fréquences et capteurs", symbol: "cpu") {
                    PerformanceChipDetails(sample: s.current)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PerformanceChipDetails: View {
    var sample: PerformanceSensorSample

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let p = sample.pCluster { cluster("Cœurs performance", p, tint: Theme.accent) }
            if let e = sample.eCluster { cluster("Cœurs économes", e, tint: Theme.palette[1]) }
            if let g = sample.gpuUsage {
                meter("GPU", fraction: g, value: [Fmt.pct(g), sample.gpuFrequency.map { "\(Fmt.int($0)) MHz" }, sample.gpuPower.map { "\(Fmt.dec($0)) W" }]
                    .compactMap { $0 }.joined(separator: " · "), tint: Theme.palette[4])
            }
            ForEach(sample.fans) { f in
                meter("Ventilateur \(sample.fans.count > 1 ? "\(f.id + 1)" : "")", fraction: f.fraction, value: "\(Fmt.int(f.rpm)) tr/min", tint: Theme.palette[3])
            }
            FlowLayout(spacing: 12, lineSpacing: 6) {
                temp("Point chaud", sample.hotspotTemp)
                temp("GPU", sample.gpuTemp)
                temp("SSD", sample.ssdTemp)
                temp("Batterie", sample.batteryTemp)
            }
            .padding(.top, 2)
        }
    }

    private func cluster(_ title: String, _ c: PerformanceCluster, tint: Color) -> some View {
        meter(title, fraction: c.speedRatio * c.active, value: "\(PerformanceDiagnosis.ghz(c.frequency)) · actifs \(Fmt.int(c.active * 100)) %", tint: tint)
    }

    private func meter(_ title: String, fraction: Double, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.ui(11.5)).foregroundStyle(Theme.text2)
                Spacer(minLength: 6)
                Text(value).font(.ui(11.5, .medium)).monospacedDigit().foregroundStyle(Theme.text).lineLimit(1)
            }
            UsageBar(fraction: fraction, tint: tint, height: 4)
        }
    }

    @ViewBuilder
    private func temp(_ label: String, _ value: Double?) -> some View {
        if let value {
            LegendDot(color: PerformanceStyle.temperature(value), label: label, value: "\(Fmt.int(value)) °C")
        }
    }
}
