import SwiftUI
import AppKit

/// Réglages › Réseau: the connection, the speed test and the open ports, in grouped rows like the other tabs.
/// Drawn with the app's own components, so that `--snapshot --page reglages` can show it.
struct NetworkSettings: View {
    static let width: CGFloat = 560
    static let height: CGFloat = 600

    /// A fixed part for the snapshots; nil follows the model (`showInSettings`).
    var section: NetworkTab? = nil
    @Environment(AppModel.self) private var app
    /// The settings window is on screen (closed, minimised or covered: the live readings stop).
    @State private var onScreen = true

    var body: some View {
        let m = app.network
        let shown = section ?? m.tab
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                PillPicker(options: NetworkTab.allCases, selection: Binding(get: { shown }, set: { m.tab = $0 }), label: { $0.title }, badge: { tab in
                    tab == .ports && m.portsState.date != nil ? "\(m.ports.count)" : (tab == .speed && m.speedState.isRunning ? "…" : nil)
                })
                Spacer()
            }
            ScrollArea {
                Group {
                    switch shown {
                    case .connection: NetworkConnectionSection()
                    case .speed: NetworkSpeedSection()
                    case .ports: NetworkPortsSection()
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
        .background { if !Snapshot.isActive { MascotWindowProbe(onScreen: $onScreen) } }
        .onAppear { m.setWindowOnScreen(onScreen) }
        .onChange(of: onScreen) { _, now in m.setWindowOnScreen(now) }
    }
}

// MARK: - Connection

private struct NetworkConnectionSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.network
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Wi-Fi")
            NetworkGroup {
                if let w = m.wifi, w.connected {
                    NetworkRow(label: "Réseau") {
                        Text(w.ssid ?? "Nom masqué par macOS").font(.ui(12.5, .medium))
                            .foregroundStyle(w.ssid == nil ? Theme.text3 : Theme.text)
                    }
                    NetworkRow(label: "Signal") {
                        HStack(spacing: 8) {
                            UsageBar(fraction: w.signalFraction, tint: w.rssi >= -67 ? Theme.good : Theme.warn, height: 5).frame(width: 70)
                            NetworkValue(text: "\(w.signalLabel) · \(w.rssi) dBm")
                        }
                    }
                    NetworkRow(label: "Canal") {
                        NetworkValue(text: [w.channel.map { "\($0)" }, w.band.map { "\($0) GHz" }, w.width.map { "\($0) MHz" }]
                            .compactMap { $0 }.joined(separator: " · "))
                    }
                    NetworkRow(label: "Liaison") { NetworkValue(text: "\(Fmt.int(w.txRate)) Mbit/s · \(w.phy)") }
                    NetworkRow(label: "Sécurité", last: true) {
                        NetworkValue(text: w.security, warn: w.security.hasPrefix("Ouvert") || w.security.hasPrefix("WEP"))
                    }
                } else {
                    NetworkRow(label: "Wi-Fi", last: true) {
                        NetworkValue(text: m.wifi == nil ? "Pas d'interface Wi-Fi" : (m.wifi!.powerOn ? "Pas connecté" : "Éteint"), dim: true)
                    }
                }
            }
            if m.wifiNameHidden {
                PermissionCard(permission: .location,
                               reason: "macOS ne montre le nom du Wi-Fi qu'aux apps autorisées à la localisation. Ta position n'est ni lue ni gardée.")
            }

            SectionLabel(text: "Adresses")
            NetworkAddressRows()

            SectionLabel(text: "Trafic")
            NetworkGroup {
                NetworkRow(label: "En ce moment", last: true) {
                    HStack(spacing: 12) {
                        Sparkline(values: m.trafficIn, maxValue: max(m.trafficIn.max() ?? 1, m.trafficOut.max() ?? 1, 50_000),
                                  tint: Theme.palette[1])
                            .frame(width: 120, height: 22)
                        Text("↓ \(m.rateIn.map(Fmt.speed) ?? "—")   ↑ \(m.rateOut.map(Fmt.speed) ?? "—")")
                            .font(.mono(12, .medium)).foregroundStyle(Theme.text).monospacedDigit()
                    }
                }
            }
        }
        .onAppear { m.startLive() }
        .onDisappear { m.stopLive() }
    }
}

private struct NetworkAddressRows: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.network
        let a = m.addresses
        NetworkGroup {
            ForEach(a.interfaces) { i in
                NetworkRow(label: i.displayName, detail: i.bsdName) {
                    VStack(alignment: .trailing, spacing: 1) {
                        if let v4 = i.ipv4.first ?? i.ipv6.first { NetworkCopyText(text: v4, font: .mono(12, .medium)) }
                        if !i.ipv4.isEmpty, let v6 = i.ipv6.first { NetworkCopyText(text: v6, font: .mono(10)).opacity(0.75) }
                    }
                }
            }
            if a.interfaces.isEmpty {
                NetworkRow(label: "Réseau") { NetworkValue(text: "Aucune connexion", dim: true) }
            }
            NetworkRow(label: "Routeur", detail: "ta box") {
                if let r = a.router { NetworkCopyText(text: r, font: .mono(12, .medium)) } else { NetworkValue(text: "—", dim: true) }
            }
            NetworkRow(label: "DNS") {
                if a.dns.isEmpty {
                    NetworkValue(text: "—", dim: true)
                } else {
                    NetworkCopyText(text: a.dns.prefix(2).joined(separator: "\n"), font: .mono(12, .medium))
                }
            }
            NetworkRow(label: "IP publique", detail: m.publicIPState.isRunning ? "…" : nil, last: true) {
                HStack(spacing: 8) {
                    if let ip = m.publicIP {
                        NetworkCopyText(text: ip, font: .mono(12, .medium))
                    } else if case .failed = m.publicIPState {
                        NetworkValue(text: "Pas de réponse", warn: true)
                    }
                    Button(m.publicIP == nil ? "Afficher" : "Redemander") { Task { await m.fetchPublicIP() } }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .disabled(m.publicIPState.isRunning)
                        .help("Demandée à \(NetworkModel.publicIPService), seulement sur ce clic")
                }
            }
        }
    }
}

// MARK: - Speed and latency

private struct NetworkSpeedSection: View {
    @Environment(AppModel.self) private var app
    @State private var confirmClear = false

    var body: some View {
        let m = app.network
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Débit")
            NetworkGroup {
                VStack(alignment: .leading, spacing: 12) {
                    if m.speedState.isRunning {
                        HStack(spacing: 10) {
                            BusyMascot(.beaming, pixel: 2)
                            Text("Mesure en cours…").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                            Spacer()
                            Button("Annuler") { m.cancelSpeedTest() }.buttonStyle(SoftButtonStyle(small: true))
                        }
                        UsageBar(fraction: m.speedProgress, tint: Theme.accent, height: 6)
                    } else if let r = m.lastSpeed {
                        HStack(alignment: .top, spacing: 0) {
                            metric("Réception", NetworkFormat.bits(r.download))
                            metric("Envoi", NetworkFormat.bits(r.upload))
                            if let rpm = r.responsiveness {
                                metric("Réactivité", "\(Fmt.int(rpm)) RPM", tint: rating(r.rating))
                            }
                        }
                        HStack {
                            Text("Testé \(Fmt.relative(r.date))\(r.baseRTT.map { " · \(NetworkFormat.ms($0)) au repos" } ?? "")")
                                .font(.ui(11)).foregroundStyle(Theme.text3)
                            Spacer()
                            Button("Relancer") { m.runSpeedTest() }.buttonStyle(SoftButtonStyle(small: true))
                        }
                    } else {
                        HStack {
                            Text("Une vingtaine de secondes, ligne saturée.").font(.ui(12)).foregroundStyle(Theme.text3)
                            Spacer()
                            Button("Lancer le test") { m.runSpeedTest() }.buttonStyle(SoftButtonStyle(prominent: true, small: true))
                        }
                    }
                    if case .failed(let why) = m.speedState {
                        Text(why).font(.ui(11.5)).foregroundStyle(Theme.warn)
                    }
                }
                .padding(14)
            }

            SectionLabel(text: "Latence")
            NetworkGroup {
                NetworkPingRow(title: "Internet", host: NetworkModel.internetHost, stats: m.pingInternet, state: m.pingState)
                NetworkPingRow(title: "Ta box", host: m.pingRouterHost ?? m.addresses.router ?? "—", stats: m.pingRouter, state: m.pingState,
                               unreachable: m.pingState.date != nil && (m.pingRouterHost == nil || m.pingRouter.received == 0))
                HStack {
                    Spacer()
                    if m.pingState.isRunning {
                        BusyMascot(.beaming, pixel: 1)
                    } else {
                        Button(m.pingState.date == nil ? "Mesurer" : "Remesurer") { m.runPing() }
                            .buttonStyle(SoftButtonStyle(small: true))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            if !m.history.isEmpty {
                SectionLabel(text: "Historique")
                NetworkGroup {
                    NetworkRow(label: Fmt.plural(m.history.count, "test", "tests"), last: true) {
                        HStack(spacing: 12) {
                            if m.history.count > 1 {
                                Sparkline(values: m.history.suffix(20).map(\.download), tint: Theme.palette[1]).frame(width: 110, height: 22)
                            }
                            if let best = m.history.max(by: { $0.download < $1.download }) {
                                NetworkValue(text: "record \(NetworkFormat.bits(best.download))")
                            }
                            Button("Effacer") { confirmClear = true }.buttonStyle(SoftButtonStyle(small: true))
                        }
                    }
                }
            }
        }
        .confirmAction("Effacer l'historique des tests ?",
                       message: m.history.count == 1 ? "La mesure gardée sur ce Mac sera oubliée."
                           : "Les \(Fmt.int(m.history.count)) mesures gardées sur ce Mac seront oubliées.",
                       button: "Effacer", isPresented: $confirmClear) {
            m.clearHistory()
        }
    }

    private func metric(_ label: String, _ value: String, tint: Color = Theme.text) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.ui(11)).foregroundStyle(Theme.text3)
            Text(value).font(.serif(22)).foregroundStyle(tint).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rating(_ r: NetworkSpeedResult.Rating?) -> Color {
        switch r {
        case .high: return Theme.good
        case .medium: return Theme.text
        case .low, nil: return Theme.warn
        }
    }
}

private struct NetworkPingRow: View {
    var title: String
    var host: String
    var stats: NetworkPingStats
    var state: NetworkState
    var unreachable = false

    var body: some View {
        NetworkRow(label: title, detail: host) {
            if let avg = stats.average ?? (stats.samples.isEmpty ? nil : stats.samples.reduce(0, +) / Double(stats.samples.count)) {
                HStack(spacing: 10) {
                    Sparkline(values: stats.samples, maxValue: (stats.samples.max() ?? 1) * 1.3, tint: color(avg)).frame(width: 60, height: 18)
                    Text(NetworkFormat.ms(avg)).font(.mono(12.5, .semibold)).foregroundStyle(Theme.text).monospacedDigit()
                    if let jitter = stats.jitter {
                        Text("± \(NetworkFormat.ms(jitter))").font(.ui(11)).foregroundStyle(Theme.text3)
                    }
                    if stats.loss > 0 {
                        Text("perte \(Fmt.pct(stats.loss))").font(.ui(11)).foregroundStyle(Theme.warn)
                    }
                }
            } else if unreachable {
                HStack(spacing: 8) {
                    NetworkValue(text: "Injoignable", warn: true)
                    Button("Réseau local…") { Finder.open(PermissionKind.localNetwork.settingsURL) }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .help("Autorise \(AppEdition.name) à joindre ta box, ou elle ignore les pings")
                }
            } else {
                NetworkValue(text: state.isRunning ? "…" : "—", dim: true)
            }
        }
    }

    private func color(_ ms: Double) -> Color {
        ms < 30 ? Theme.good : (ms < 80 ? Theme.accent : Theme.warn)
    }
}

// MARK: - Ports

private struct NetworkPortsSection: View {
    @Environment(AppModel.self) private var app
    @State private var quitting: NetworkPort?

    var body: some View {
        let m = app.network
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel(text: summary(m))
                if m.portsState.isRunning { BusyMascot(.beaming, pixel: 1) }
                Button("Actualiser") { Task { await m.scanPorts() } }
                    .buttonStyle(SoftButtonStyle(small: true))
                    .disabled(m.portsState.isRunning)
                Button(m.portsIncludeSystem ? "Services système inclus" : "Avec les services système") { Task { await m.scanPorts(admin: true) } }
                    .buttonStyle(SoftButtonStyle(small: true))
                    .disabled(m.portsState.isRunning || m.portsIncludeSystem)
                    .help("macOS te demande ton mot de passe, l'app ne le voit pas")
            }
            if case .failed(let why) = m.portsState {
                Text(why).font(.ui(11.5)).foregroundStyle(Theme.warn)
            }
            NetworkGroup {
                if m.ports.isEmpty {
                    NetworkRow(label: m.portsState.date == nil ? "Lecture…" : "Aucun port ouvert", last: true) { EmptyView() }
                } else {
                    ForEach(Array(m.ports.enumerated()), id: \.element.id) { i, p in
                        NetworkPortRow(port: p, last: i == m.ports.count - 1) { quitting = p }
                    }
                }
            }
        }
        .task { if m.portsState == .idle { await m.scanPorts() } }
        .confirmAction(confirmTitle, message: confirmMessage, button: quitting?.appPath != nil ? "Quitter" : "Arrêter",
                       isPresented: Binding(get: { quitting != nil }, set: { if !$0 { quitting = nil } })) {
            if let p = quitting { m.quit(p) }
        }
    }

    private func summary(_ m: NetworkModel) -> String {
        guard let d = m.portsState.date else { return "Ports à l'écoute" }
        let exposed = m.ports.filter(\.isExposed).count
        return [Fmt.plural(m.ports.count, "port", "ports"), exposed > 0 ? "\(exposed) sur le réseau" : nil, Fmt.relative(d)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var confirmTitle: String {
        guard let p = quitting else { return "" }
        return p.appPath != nil ? "Quitter \(p.displayName) ?" : "Arrêter \(p.process) ?"
    }

    private var confirmMessage: String {
        guard let p = quitting else { return "" }
        if p.appPath != nil { return "Le port \(p.port) se fermera avec l'app. Elle te demandera d'enregistrer si besoin." }
        return "\(p.process) (PID \(p.pid)) recevra une demande d'arrêt : ce qu'il n'a pas enregistré peut être perdu."
    }
}

private struct NetworkPortRow: View {
    var port: NetworkPort
    var last: Bool
    var onQuit: () -> Void

    var body: some View {
        let p = port
        HStack(spacing: 10) {
            Text(verbatim: String(p.port))
                .font(.mono(13, .semibold)).foregroundStyle(Theme.text)
                .frame(width: 50, alignment: .leading)
            if let path = p.appPath {
                FileIcon(path: path, size: 20)
            } else {
                IconBadge(symbol: p.isSystem ? "gearshape.2" : "terminal", tint: p.isSystem ? Theme.text3 : Theme.text2, size: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(p.displayName).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text([NetworkPorts.describe(p) ?? (p.appName != nil && p.appName != p.process ? p.process : nil), "PID \(p.pid)"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 8)
            Tag(text: p.isExposed ? "Réseau" : "Ce Mac", symbol: p.isExposed ? "dot.radiowaves.left.and.right" : "lock",
                tint: p.isExposed ? Theme.warn : Theme.good, filled: true)
                .help(p.addresses.map(NetworkPorts.describe(address:)).joined(separator: ", "))
            Group {
                if p.isSystem {
                    Text("macOS").font(.ui(11)).foregroundStyle(Theme.text3)
                } else {
                    Button(p.appPath != nil ? "Quitter" : "Arrêter", action: onQuit).buttonStyle(SoftButtonStyle(small: true))
                }
            }
            .frame(minWidth: 62, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.border).frame(height: max(1, Theme.line)) } }
    }
}

// MARK: - Small pieces

/// A group of rows on a card, like the grouped forms of the other tabs.
private struct NetworkGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
    }
}

/// A label on the left, its value on the right.
private struct NetworkRow<Value: View>: View {
    var label: String
    var detail: String? = nil
    var last = false
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).font(.ui(12.5)).foregroundStyle(Theme.text2).lineLimit(1)
            if let detail { Text(detail).font(.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1) }
            Spacer(minLength: 12)
            value
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 34)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.border).frame(height: max(1, Theme.line)) } }
    }
}

private struct NetworkValue: View {
    var text: String
    var warn = false
    var dim = false

    var body: some View {
        Text(text).font(.ui(12.5, .medium)).foregroundStyle(warn ? Theme.warn : (dim ? Theme.text3 : Theme.text))
            .multilineTextAlignment(.trailing).lineLimit(2)
    }
}

/// Text that copies itself on click.
private struct NetworkCopyText: View {
    var text: String
    var font: Font

    var body: some View {
        Button {
            guard !DemoData.isEnabled else { return HUD.show(DemoData.refusal, symbol: "theatermasks") }
            _ = NetworkModel.copy(text)
            HUD.show("Copié : \(text)", symbol: "doc.on.clipboard.fill")
        } label: {
            Text(text).font(font).foregroundStyle(Theme.text).multilineTextAlignment(.trailing).lineLimit(2).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help("Cliquer pour copier")
    }
}
