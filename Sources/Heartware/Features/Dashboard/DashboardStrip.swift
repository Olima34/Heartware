import SwiftUI

/// One figure of a `DashboardMetricStrip`.
struct DashboardMetric: Identifiable {
    var id: String { label }
    var symbol: String
    var value: String
    var label: String
    /// A few words after the label, on the same line (the whole line is also the tooltip).
    var detail: String? = nil
    var tint: Color = Theme.accent
}

/// A row of figures in a single card: the compact form of a row of stat tiles, two short lines per figure.
/// Used by the dashboard and the maintenance pages (Nettoyage, Protection, Batterie, Mises à jour).
struct DashboardMetricStrip: View {
    var metrics: [DashboardMetric]

    var body: some View {
        Card(padding: 12) {
            HStack(spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.offset) { i, m in
                    if i > 0 {
                        Rectangle().fill(Theme.border).frame(width: max(1, Theme.line)).padding(.vertical, 2)
                    }
                    cell(m)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cell(_ m: DashboardMetric) -> some View {
        let line = [m.label, m.detail].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 10) {
            IconBadge(symbol: m.symbol, tint: m.tint, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.value)
                    .font(.serif(20))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                Text(line)
                    .font(.ui(11))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .help(line)
    }
}
