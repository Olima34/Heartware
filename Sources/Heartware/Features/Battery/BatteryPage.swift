import SwiftUI
import AppKit

struct BatteryPage: View {
    @Environment(AppModel.self) private var app
    static var tint: Color { Theme.good }

    static let tip = HelpTip(id: "battery.page", title: "Ménager ta batterie",
                             text: "Une batterie lithium vieillit plus vite quand elle reste pleine, surtout au chaud : entre 20 et 80 %, elle garde sa capacité plus longtemps. Avant un voyage, passe la limite à 100 % la veille, puis reviens à 80 % au retour. Depuis le lanceur, tape « limite 80 », « limite 100 » ou « batterie ».")

    var body: some View {
        let m = app.battery
        VStack(alignment: .leading, spacing: 18) {
            PageHero(symbol: Page.battery.symbol, title: "Batterie",
                     subtitle: "Sa limite de recharge, tes alertes et sa santé.",
                     tint: Self.tint, seed: 83, tip: Self.tip) {
                if let r = m.reading { BatteryLevelPill(reading: r) }
            }
            if let r = m.reading {
                BatteryChargeCard(reading: r)
                TileRow {
                    BatteryLimitPanel()
                    BatteryAlertsPanel()
                }
                BatteryHealthRow(reading: r)
            } else {
                Card(padding: 24) {
                    EmptyHint(text: "Pas de batterie sur ce Mac : il tourne toujours sur le secteur, rien à protéger ici.", symbol: "powerplug")
                }
            }
        }
        .onAppear {
            m.pageVisible = true
            m.refresh()
            m.refreshLimit()
        }
        .onDisappear { m.pageVisible = false }
    }
}

/// Nothing to act on in bulk here.
struct BatteryBottomBar: View {
    var body: some View { EmptyView() }
}

/// The level in the page header.
private struct BatteryLevelPill: View {
    var reading: BatteryReading

    var body: some View {
        HStack(spacing: 6) {
            if Theme.icons != .hidden {
                Image(systemName: BatterySymbol.name(reading)).font(.ui(12, .semibold))
            }
            Text("\(reading.percent) % · \(reading.onAC ? "secteur" : "batterie")").font(.ui(12, .semibold)).monospacedDigit()
        }
        .foregroundStyle(Theme.text2)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(PillShape().fill(Theme.card))
        .overlay(PillShape().strokeBorder(Theme.border, lineWidth: Theme.line))
    }
}

enum BatterySymbol {
    static func name(_ r: BatteryReading) -> String {
        if r.isCharging { return "battery.100percent.bolt" }
        switch r.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - Charge

private struct BatteryChargeCard: View {
    @Environment(AppModel.self) private var app
    var reading: BatteryReading

    var body: some View {
        let m = app.battery
        let r = reading
        let limit = m.activeLimit
        let low = r.percent <= (m.settings.lowAlert ? m.settings.lowLevel : 20)
        let tint = low ? Theme.bad : BatteryPage.tint
        Card(padding: 24) {
            HStack(alignment: .center, spacing: 28) {
                ZStack {
                    ProgressRing(progress: Double(r.percent) / 100, tint: tint, lineWidth: 9)
                    VStack(spacing: 4) {
                        if Theme.icons != .hidden {
                            Image(systemName: BatterySymbol.name(r)).font(.ui(20, .medium)).foregroundStyle(tint)
                        }
                        Text("\(r.percent) %").font(.serif(30)).foregroundStyle(Theme.text).monospacedDigit()
                    }
                }
                .frame(width: 140, height: 140)
                VStack(alignment: .leading, spacing: 12) {
                    Text(BatteryRules.headline(r, limit: limit)).font(.serif(26)).foregroundStyle(Theme.text)
                    Text(BatteryRules.detail(r, limit: limit))
                        .font(.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    BatteryScale(percent: r.percent, tint: tint, limit: limit,
                                 low: m.settings.lowAlert ? m.settings.lowLevel : nil,
                                 high: m.settings.highAlert ? m.settings.highLevel : nil)
                        .frame(maxWidth: 560)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// The level on a 0–100 % bar, with the charge limit and the alert levels marked on it.
private struct BatteryScale: View {
    var percent: Int
    var tint: Color
    var limit: Int?
    var low: Int?
    var high: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Theme.r(5)).fill(Theme.track)
                    RoundedRectangle(cornerRadius: Theme.r(5)).fill(tint).frame(width: max(4, w * CGFloat(percent) / 100))
                    if let limit, limit < 100 { mark(limit, w, Theme.text) }
                    if let high { mark(high, w, Theme.accent) }
                    if let low { mark(low, w, Theme.warn) }
                }
            }
            .frame(height: 12)
            HStack(spacing: 16) {
                if let limit, limit < 100 { LegendDot(color: Theme.text, label: "Limite de recharge", value: "\(limit) %") }
                if let high { LegendDot(color: Theme.accent, label: "Alerte de charge", value: "\(high) %") }
                if let low { LegendDot(color: Theme.warn, label: "Alerte batterie faible", value: "\(low) %") }
            }
        }
    }

    private func mark(_ v: Int, _ w: CGFloat, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 3, height: 20)
            .offset(x: min(w - 3, max(0, w * CGFloat(v) / 100 - 1.5)))
    }
}

// MARK: - Limit

private struct BatteryLimitPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.battery
        Panel(title: "Limite de recharge",
              subtitle: "80 % est le plus doux pour la batterie.",
              symbol: "bolt.badge.checkmark", tint: BatteryPage.tint) {
            VStack(alignment: .leading, spacing: 12) {
                if let l = m.limit, !l.supported {
                    Text("Pas de limite de recharge sur ce Mac ou ce macOS : l'alerte de charge, à côté, te dit quand débrancher.")
                        .font(.ui(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                } else if let l = m.limit {
                    // Setting the limit asks macOS: the bubble follows the click, it is not dragged.
                    GlassGroup(selection: l.limit, axis: .horizontal, radius: 8) {
                    HStack(spacing: 8) {
                        ForEach(l.choices, id: \.self) { v in
                            BatteryChip(label: v >= 100 ? "100 %" : "\(v) %", on: l.limit == v, busy: m.applying == v) {
                                Task {
                                    let outcome = await m.setLimit(v)
                                    if case .message(let text) = outcome { HUD.show(text, symbol: m.limitRefused == nil ? "checkmark.circle.fill" : "gearshape") }
                                    if case .failed(let text) = outcome { HUD.show(text, symbol: "xmark.octagon.fill") }
                                }
                            }
                            .help(v >= 100 ? "Recharger jusqu'à 100 %" : "Arrêter la recharge à \(v) %")
                            .glassItem(v)
                        }
                    }
                    }
                    if l.limit == nil {
                        Text("macOS n'a pas donné sa limite actuelle.").font(.ui(11.5)).foregroundStyle(Theme.text3)
                    }
                } else {
                    HStack(spacing: 8) {
                        BusyMascot(.charging, pixel: 1.5)
                        Text("Lecture du réglage de macOS…").font(.ui(12)).foregroundStyle(Theme.text3)
                    }
                }
                if let asked = m.limitRefused {
                    Callout(symbol: "gearshape", title: "À finir dans Réglages Système",
                            text: "Dans Batterie, règle « Limite de recharge » sur \(asked) % : je verrai le changement tout seul.",
                            tint: Theme.warn)
                }
                Button("Ouvrir les réglages Batterie") { m.openSettings() }
                    .buttonStyle(SoftButtonStyle(small: true))
            }
        }
    }
}

/// A choice among a few values, filled when it is the current one.
private struct BatteryChip: View {
    var label: String
    var on: Bool
    var busy = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if busy { BusyMascot(.charging, pixel: 1) }
                Text(label).font(.ui(12.5, .medium)).monospacedDigit()
            }
            .foregroundStyle(on ? Theme.text : Theme.text2)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .chipGround(on, radius: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Alerts

private struct BatteryAlertsPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.battery
        Panel(title: "Alertes", subtitle: "Une notification à chaque passage de seuil",
              symbol: "bell", tint: BatteryPage.tint) {
            VStack(alignment: .leading, spacing: 14) {
                alert(title: "Batterie faible", detail: "Sur batterie : il est temps de brancher le chargeur.",
                      isOn: Binding(get: { m.settings.lowAlert }, set: { m.setLowAlert($0) }),
                      choices: BatteryRules.lowChoices, value: m.settings.lowLevel) { m.setLowLevel($0) }
                Divider().overlay(Theme.border)
                alert(title: "Charge atteinte", detail: "En recharge : tu peux débrancher.",
                      isOn: Binding(get: { m.settings.highAlert }, set: { m.setHighAlert($0) }),
                      choices: BatteryRules.highChoices, value: m.settings.highLevel) { m.setHighLevel($0) }
                if !Notifier.available && !DemoData.isEnabled {
                    Text("Les notifications ne marchent que dans l'app installée (\(AppEdition.name).app).")
                        .font(.ui(11)).foregroundStyle(Theme.warn)
                }
            }
        }
    }

    private func alert(title: String, detail: String, isOn: Binding<Bool>, choices: [Int], value: Int,
                       choose: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
                    Text(detail).font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .switchToggles()
            .controlSize(.small)
            GlassGroup(selection: isOn.wrappedValue ? value : nil, axis: .horizontal, radius: 8, pick: { choose($0) }) {
                HStack(spacing: 6) {
                    ForEach(choices, id: \.self) { v in
                        BatteryChip(label: "\(v) %", on: isOn.wrappedValue && value == v) { choose(v) }
                            .glassItem(v)
                    }
                }
            }
            .opacity(isOn.wrappedValue ? 1 : 0.6)
        }
    }
}

// MARK: - Health

private struct BatteryHealthRow: View {
    var reading: BatteryReading
    private var r: BatteryReading { reading }

    var body: some View {
        var list = [
            DashboardMetric(symbol: "heart", value: r.health.map(Fmt.pct) ?? "—", label: "Capacité maximale",
                            detail: capacityDetail, tint: (r.health ?? 1) < 0.8 ? Theme.warn : BatteryPage.tint),
            DashboardMetric(symbol: "arrow.triangle.2.circlepath", value: r.cycleCount.map(Fmt.int) ?? "—", label: "Cycles",
                            detail: r.designCycles.map { "prévue pour \(Fmt.int($0))" }, tint: Theme.palette[1]),
            DashboardMetric(symbol: "powerplug", value: r.adapterWatts.map { "\($0) W" } ?? "—", label: "Chargeur",
                            detail: r.onAC ? (r.adapterName ?? "branché") : "débranché", tint: Theme.palette[4])
        ]
        if let t = r.temperature {
            list.append(DashboardMetric(symbol: "thermometer.medium", value: "\(Fmt.dec(t)) °C", label: "Température",
                                        detail: t >= 40 ? "chaude : la recharge peut ralentir" : "normale", tint: t >= 40 ? Theme.warn : Theme.palette[2]))
        } else {
            list.append(DashboardMetric(symbol: "bolt", value: r.batteryPower.map { power($0) } ?? "—", label: "Flux de la batterie",
                                        detail: flowDetail, tint: Theme.palette[2]))
        }
        return DashboardMetricStrip(metrics: list)
    }

    private var capacityDetail: String {
        guard let m = r.maxCapacity, let d = r.designCapacity else { return "par rapport à une batterie neuve" }
        return "\(Fmt.int(m)) mAh sur \(Fmt.int(d))"
    }

    private func power(_ w: Double) -> String {
        abs(w) < 0.05 ? "0 W" : (w > 0 ? "+" : "−") + Fmt.dec(abs(w)) + " W"
    }

    private var flowDetail: String {
        guard let w = r.batteryPower, abs(w) >= 0.05 else { return "ni recharge ni décharge" }
        return w > 0 ? "elle se recharge" : "elle alimente le Mac"
    }
}
