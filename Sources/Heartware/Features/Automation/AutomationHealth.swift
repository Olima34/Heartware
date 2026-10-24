import SwiftUI
import Charts

/// One snapshot a day of the Mac's health, kept in `automation-health.json`.
struct AutomationHealthSample: Codable, Identifiable, Equatable {
    var id: Date { day }
    /// Midnight of the day it was taken.
    var day: Date
    var diskFree: Int64
    var diskTotal: Int64
    /// Memory in use, 0…1.
    var memoryUsed: Double
    /// Maximum capacity over design capacity, 0…1 (nil without a battery).
    var batteryHealth: Double?
    var batteryCycles: Int?
    /// `AppModel.healthScore`, 0…100.
    var score: Int
    /// What the Cleanup page would free with its default selection (nil when it was not measured).
    var junk: Int64?
}

enum AutomationHealthRange: Int, CaseIterable, Identifiable {
    case month = 30, quarter = 90, year = 365

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .month: return "30 jours"
        case .quarter: return "90 jours"
        case .year: return "1 an"
        }
    }
}

enum AutomationHealth {
    static let maxSamples = 400

    static func needsSample(_ samples: [AutomationHealthSample], now: Date, calendar: Calendar = .current) -> Bool {
        guard let last = samples.last else { return true }
        return !calendar.isDate(last.day, inSameDayAs: now)
    }

    /// Adds the sample, replacing one of the same day, sorted by day and capped.
    static func recording(_ sample: AutomationHealthSample, into samples: [AutomationHealthSample],
                          calendar: Calendar = .current) -> [AutomationHealthSample] {
        var out = samples.filter { !calendar.isDate($0.day, inSameDayAs: sample.day) }
        out.append(sample)
        out.sort { $0.day < $1.day }
        if out.count > maxSamples { out.removeFirst(out.count - maxSamples) }
        return out
    }

    /// The samples of the last `range` days, today included.
    static func window(_ samples: [AutomationHealthSample], range: AutomationHealthRange, now: Date,
                       calendar: Calendar = .current) -> [AutomationHealthSample] {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(range.rawValue - 1), to: today) else { return samples }
        return samples.filter { $0.day >= start }
    }

    /// Last value minus first value over the samples that have one.
    static func change(_ samples: [AutomationHealthSample], _ value: (AutomationHealthSample) -> Double?) -> Double? {
        let values = samples.compactMap(value)
        guard values.count > 1, let first = values.first, let last = values.last else { return nil }
        return last - first
    }
}

// MARK: - Views

/// The health history tab: one chart per measure, today's value and the change over the period in its header.
struct AutomationHealthView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.automation
        let shown = AutomationHealth.window(model.samples, range: model.range, now: Date())
        let last = shown.last
        VStack(alignment: .leading, spacing: 18) {
            if !model.settings.healthEnabled && model.samples.isEmpty {
                AutomationHealthIntro()
            } else {
                HStack(spacing: 12) {
                    PillPicker(options: AutomationHealthRange.allCases, selection: Binding(get: { model.range }, set: { model.range = $0 }),
                               label: { $0.title })
                    Text(shown.isEmpty ? "Aucun instantané sur cette période" : Fmt.plural(shown.count, "instantané", "instantanés"))
                        .font(.ui(11.5)).foregroundStyle(Theme.text3)
                    Spacer()
                    if !model.settings.healthEnabled {
                        StatusBadge(status: .warn, text: "Historique en pause")
                    }
                    Button {
                        Task { await model.recordHealth(app: app) }
                    } label: {
                        Label("Instantané maintenant", systemImage: "camera.metering.center.weighted")
                    }
                    .buttonStyle(SoftButtonStyle(small: true))
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    chartPanel("Score de santé", value: last.map { "\($0.score)" },
                               change: delta(AutomationHealth.change(shown) { Double($0.score) }, { Fmt.int($0) }, unit: " pts"),
                               symbol: "heart.text.square", tint: Theme.good) {
                        let scores = shown.map { ($0.day, Double($0.score)) }
                        AutomationHealthChart(points: scores, tint: Theme.good,
                                              yDomain: max(0, (scores.map(\.1).min() ?? 50) - 10)...100, unit: "")
                    }
                    chartPanel("Espace libre", value: last.map { Fmt.bytes($0.diskFree) },
                               change: delta(AutomationHealth.change(shown) { Double($0.diskFree) / 1e9 }, { Fmt.dec($0) }, unit: " Go"),
                               symbol: "internaldrive", tint: Theme.accent) {
                        AutomationHealthChart(points: shown.map { ($0.day, Double($0.diskFree) / 1e9) }, tint: Theme.accent, yDomain: nil, unit: " Go")
                    }
                    chartPanel("Mémoire utilisée", value: last.map { Fmt.pct($0.memoryUsed) }, change: nil,
                               symbol: "memorychip", tint: Theme.palette[4]) {
                        AutomationHealthChart(points: shown.map { ($0.day, $0.memoryUsed * 100) }, tint: Theme.palette[4], yDomain: 0...100, unit: " %")
                    }
                    chartPanel("Santé de la batterie", value: last?.batteryHealth.map(Fmt.pct), change: batteryLine(shown),
                               symbol: "battery.75percent", tint: Theme.palette[1]) {
                        let points = shown.compactMap { s in s.batteryHealth.map { (s.day, $0 * 100) } }
                        if points.isEmpty {
                            EmptyHint(text: "Pas de batterie sur ce Mac.", symbol: "powerplug")
                        } else {
                            AutomationHealthChart(points: points, tint: Theme.palette[1], yDomain: max(0, (points.map(\.1).min() ?? 80) - 5)...100, unit: " %")
                        }
                    }
                }
                chartPanel("Fichiers inutiles trouvés", value: last?.junk.map(Fmt.bytes), change: nil, symbol: "sparkles", tint: Theme.brand) {
                    AutomationJunkChart(points: shown.compactMap { s in s.junk.map { (s.day, Double($0) / 1e9) } })
                }
            }
        }
    }

    /// "+3 pts sur la période"
    private func delta(_ v: Double?, _ fmt: (Double) -> String, unit: String) -> String? {
        guard let v else { return nil }
        let sign = v > 0 ? "+" : (v < 0 ? "−" : "±")
        return "\(sign)\(fmt(abs(v)))\(unit) sur la période"
    }

    /// The change of the battery's capacity, and its charge cycles.
    private func batteryLine(_ shown: [AutomationHealthSample]) -> String? {
        let change = delta(AutomationHealth.change(shown) { $0.batteryHealth.map { $0 * 100 } }, { Fmt.dec($0) }, unit: " pts")
        let cycles = shown.last(where: { $0.batteryCycles != nil })?.batteryCycles.map { Fmt.plural($0, "cycle", "cycles") }
        let parts = [change, cycles].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func chartPanel<C: View>(_ title: String, value: String?, change: String?, symbol: String, tint: Color,
                                     @ViewBuilder chart: () -> C) -> some View {
        Panel(title: title, subtitle: change, symbol: symbol, tint: tint) {
            if let value { Text(value).font(.serif(20)).foregroundStyle(Theme.text).monospacedDigit() }
        } content: {
            chart().frame(height: 150)
        }
    }
}

/// Shown before the first snapshot.
private struct AutomationHealthIntro: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Card(padding: 22) {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Suis la forme de ton Mac au fil des mois").font(.serif(22)).foregroundStyle(Theme.text)
                    Text("Un instantané par jour, puis ses courbes sur 30 jours, 90 jours ou un an.")
                        .font(.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    Button {
                        app.automation.setHealthEnabled(true, app: app)
                    } label: {
                        Label("Commencer l'historique", systemImage: "waveform.path.ecg")
                    }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
                Sparkline(values: [62, 64, 61, 70, 72, 69, 75, 78, 76, 83, 81, 86], maxValue: 100, tint: Theme.good)
                    .frame(width: 220, height: 90)
                    .padding(.top, 10)
            }
        }
    }
}

struct AutomationHealthChart: View {
    var points: [(Date, Double)]
    var tint: Color
    var yDomain: ClosedRange<Double>?
    var unit: String

    var body: some View {
        if points.count < 2 {
            EmptyHint(text: points.isEmpty ? "Pas encore de mesure." : "Il faut au moins deux jours pour tracer une courbe.", symbol: "chart.xyaxis.line")
        } else {
            let domain = yDomain ?? Self.padded(points.map(\.1))
            Chart(points, id: \.0) { p in
                AreaMark(x: .value("Jour", p.0, unit: .day), yStart: .value("min", domain.lowerBound), yEnd: .value(unit, p.1))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.3), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Jour", p.0, unit: .day), y: .value(unit, p.1))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: domain)
            .chartXAxis { AutomationChartAxis.x(points.map(\.0)) }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel {
                        Text("\(Fmt.int(v.as(Double.self) ?? 0))\(unit)").font(.ui(9.5)).foregroundStyle(Theme.text3)
                    }
                }
            }
            .environment(\.locale, Fmt.fr)
        }
    }

    static func padded(_ values: [Double]) -> ClosedRange<Double> {
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = max((hi - lo) * 0.15, 1)
        return max(0, lo - pad)...(hi + pad)
    }
}

struct AutomationJunkChart: View {
    var points: [(Date, Double)]

    var body: some View {
        if points.isEmpty {
            EmptyHint(text: "Pas encore de mesure.", symbol: "chart.bar")
        } else {
            Chart(points, id: \.0) { p in
                BarMark(x: .value("Jour", p.0, unit: .day), y: .value("Go", p.1))
                    .foregroundStyle(Theme.brand.opacity(0.85))
                    .cornerRadius(Theme.r(2))
            }
            .chartXAxis { AutomationChartAxis.x(points.map(\.0)) }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel {
                        Text("\(Fmt.dec(v.as(Double.self) ?? 0)) Go").font(.ui(9.5)).foregroundStyle(Theme.text3)
                    }
                }
            }
            .environment(\.locale, Fmt.fr)
        }
    }
}

enum AutomationChartAxis {
    /// Four to six date labels whatever the period: days for a month, months for a year.
    static func x(_ dates: [Date]) -> some AxisContent {
        let span = (dates.last ?? Date()).timeIntervalSince(dates.first ?? Date()) / 86400
        let stride: Calendar.Component = span > 120 ? .month : (span > 40 ? .weekOfYear : .day)
        let count = span > 120 ? 2 : (span > 40 ? 3 : max(1, Int(span / 5)))
        return AxisMarks(values: .stride(by: stride, count: count)) { _ in
            AxisGridLine().foregroundStyle(Theme.border.opacity(0.6))
            AxisValueLabel(format: span > 120 ? .dateTime.month(.abbreviated) : .dateTime.day().month(.abbreviated))
                .font(.ui(9.5))
                .foregroundStyle(Theme.text3)
        }
    }
}
