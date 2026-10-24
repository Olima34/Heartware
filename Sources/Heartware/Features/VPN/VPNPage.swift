import SwiftUI

/// What the VPN explains once, in its « ? ».
enum VPNTips {
    static let about = HelpTip(
        id: "media.vpn", title: "Le VPN de Windscribe",
        text: "Windscribe fait passer ta connexion par un serveur du pays choisi : les sites te croient en France, même depuis l'étranger. Gratuit et sans pub : 10 pays, 10 Go par mois avec une adresse e-mail confirmée (2 Go sans). Windscribe dit ne garder aucun journal de ta navigation, et ton fournisseur d'accès ne voit plus qu'une connexion chiffrée. Heartware pilote l'app Windscribe de ce Mac, sans rien envoyer d'autre.")
}

/// « VPN » on the Multimédia page: Windscribe's state, the free countries, the data of the month.
struct VPNTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VPNStatusCard()
            VPNCountriesPanel()
        }
        .onAppear { app.vpn.refresh() }
    }
}

// MARK: - State

private struct VPNStatusCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.vpn
        // The installation replaces the « not installed » lines while it goes on.
        let installing = m.phase == .notInstalled ? m.install : nil
        Card(padding: 22) {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(installing.map(VPNText.installHeadline) ?? VPNText.headline(m.phase, usage: m.usage))
                            .font(.serif(24)).foregroundStyle(Theme.text)
                        HelpTipButton(tip: VPNTips.about, size: 15)
                    }
                    if let step = installing {
                        VPNInstallLine(step: step)
                    } else if let detail = VPNText.detail(m.phase, publicIP: m.publicIP) {
                        Text(detail)
                            .font(.ui(12.5))
                            .foregroundStyle(isFailure(m.phase) ? Theme.warn : Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) { buttons(m) }
                        .padding(.top, 4)
                    if installing == nil, m.phase != .notInstalled, m.phase != .unknown {
                        VPNVisibilityRow()
                    }
                }
                Spacer(minLength: 0)
                side(m)
            }
        }
    }

    private func isFailure(_ phase: VPNPhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    @ViewBuilder
    private func side(_ m: VPNModel) -> some View {
        switch m.phase {
        case .connecting, .starting, .disconnecting:
            BusyMascot(.beaming, pixel: 4)
        case .notInstalled:
            if m.install?.running == true { BusyMascot(.downloading, pixel: 4) }
        case .connected, .ready, .outOfData, .failed:
            if let usage = m.usage { VPNUsageView(usage: usage) }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func buttons(_ m: VPNModel) -> some View {
        switch m.phase {
        case .notInstalled:
            installButtons(m)
        case .unknown:
            Button { m.refresh() } label: { label("Vérifier", "arrow.clockwise") }
                .buttonStyle(SoftButtonStyle())
        case .closed, .ready:
            Button { m.connect(.fr) } label: { label("Se connecter en France", "lock.shield") }
                .buttonStyle(SoftButtonStyle(prominent: true))
            Button { m.openWindscribe() } label: { label("Ouvrir Windscribe", "macwindow") }
                .buttonStyle(SoftButtonStyle())
        case .loggedOut:
            Button { m.openWindscribe() } label: { label("Ouvrir Windscribe pour te connecter à ton compte", "person.crop.circle") }
                .buttonStyle(SoftButtonStyle(prominent: true))
                .help("Connecte-toi, ou crée ton compte gratuitement avec ton e-mail")
            Button { m.refresh() } label: { label("C'est fait", "arrow.clockwise") }
                .buttonStyle(SoftButtonStyle())
        case .connecting:
            Button { m.disconnect() } label: { label("Annuler", "xmark") }
                .buttonStyle(SoftButtonStyle())
        case .connected:
            Button { m.disconnect() } label: { label("Déconnecter", "lock.open") }
                .buttonStyle(SoftButtonStyle(prominent: true))
            Button { m.openWindscribe() } label: { label("Ouvrir Windscribe", "macwindow") }
                .buttonStyle(SoftButtonStyle())
        case .outOfData:
            Button { m.openPlans() } label: { label("Voir le Build-A-Plan", "cart") }
                .buttonStyle(SoftButtonStyle(prominent: true))
            Button { m.refresh() } label: { label("Vérifier", "arrow.clockwise") }
                .buttonStyle(SoftButtonStyle())
        case .failed:
            Button { m.connect(m.target ?? .fr) } label: { label("Réessayer", "arrow.clockwise") }
                .buttonStyle(SoftButtonStyle(prominent: true))
            Button { m.openWindscribe() } label: { label("Ouvrir Windscribe", "macwindow") }
                .buttonStyle(SoftButtonStyle())
        case .starting, .disconnecting:
            EmptyView()
        }
    }

    @ViewBuilder
    private func installButtons(_ m: VPNModel) -> some View {
        switch m.install {
        case .some(let step) where step.running:
            Button("Annuler") { m.cancelInstall() }
                .buttonStyle(SoftButtonStyle())
        case .opened:
            Button { m.refresh() } label: { label("C'est fait", "checkmark") }
                .buttonStyle(SoftButtonStyle(prominent: true))
            Button("Recommencer") { m.installWindscribe() }
                .buttonStyle(SoftButtonStyle())
        case .failed:
            Button { m.installWindscribe() } label: { label("Réessayer", "arrow.clockwise") }
                .buttonStyle(SoftButtonStyle(prominent: true))
            Button("Page de téléchargement") { m.openDownloadPage() }
                .buttonStyle(SoftButtonStyle())
        default:
            Button { m.installWindscribe() } label: { label("Installer Windscribe", "arrow.down.circle") }
                .buttonStyle(SoftButtonStyle(prominent: true))
                .help(VPNInstaller.brewPath() == nil || Snapshot.isActive
                      ? "L'installateur officiel, depuis windscribe.com" : "L'installateur officiel, par Homebrew")
        }
    }

    private func label(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            if Theme.icons != .hidden { Image(systemName: symbol).font(.ui(11.5, .semibold)) }
            Text(text)
        }
    }
}

/// The user's yes to Windscribe's own « Hide from Dock » and « Start minimized ».
private struct VPNVisibilityRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.vpn
        // Unreadable (a format Heartware does not know): left alone, unless it was asked before.
        let unreadable = m.windscribeVisibility == nil && !DemoData.isEnabled && !Snapshot.isActive
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { m.keepHidden }, set: { m.setKeepHidden($0) })) {
                Text("Garder Windscribe invisible (sans fenêtre ni icône dans le Dock)")
                    .font(.ui(11.5)).foregroundStyle(Theme.text2)
            }
            .switchToggles()
            .controlSize(.mini)
            .fixedSize()
            .disabled(unreadable && !m.keepHidden)
            if m.visibilityPending {
                Text("· au prochain démarrage de Windscribe").font(.ui(11)).foregroundStyle(Theme.text3)
            }
        }
        .help(unreadable
              ? "Heartware ne reconnaît pas ce réglage de cette version de Windscribe : il n'y touche pas."
              : "Les réglages « Masquer du Dock » et « Démarrer réduit » de Windscribe, écrits quand il est fermé (une copie est gardée).")
    }
}

/// Where the installation stands, in a line.
private struct VPNInstallLine: View {
    var step: VPNInstallStep

    var body: some View {
        switch step {
        case .brew(let line):
            Text(line).font(.mono(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
        case .downloading(let received, let expected):
            VStack(alignment: .leading, spacing: 5) {
                Text(expected > 0 ? "Téléchargement · \(VPNFormat.size(received)) sur \(VPNFormat.size(expected))" : "Téléchargement…")
                    .font(.ui(11.5)).foregroundStyle(Theme.text3).monospacedDigit()
                if expected > 0 {
                    UsageBar(fraction: Double(received) / Double(expected), tint: VPNStyle.tint, height: 6)
                        .frame(width: 280)
                }
            }
        case .checking:
            Text("Je vérifie la signature de l'installateur…").font(.ui(11.5)).foregroundStyle(Theme.text3)
        case .opened:
            Text("Suis sa fenêtre : macOS te demande ton mot de passe, puis Windscribe s'ouvre.")
                .font(.ui(12.5)).foregroundStyle(Theme.text2)
        case .failed(let message):
            Text(message).font(.ui(11.5, .medium)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The data of the month, big, with what is left.
private struct VPNUsageView: View {
    var usage: VPNUsage

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(VPNFormat.size(usage.used)).font(.serif(40)).foregroundStyle(Theme.text).monospacedDigit()
            Text(usage.limit.map { "sur \(VPNFormat.size($0)) ce mois-ci" } ?? "ce mois-ci, sans limite")
                .font(.ui(11.5)).foregroundStyle(Theme.text3)
            if usage.limit != nil {
                UsageBar(fraction: usage.fraction, tint: tint, height: 7)
                    .frame(width: 200)
            }
            if let left = usage.remaining, !usage.exhausted {
                Text("\(VPNFormat.size(left)) restants").font(.ui(11, .medium)).foregroundStyle(Theme.text2).monospacedDigit()
            }
            if usage.unconfirmedEmail {
                Text("Confirme ton e-mail chez Windscribe : 10 Go par mois")
                    .font(.ui(11, .medium)).foregroundStyle(Theme.warn)
            }
        }
        .frame(minWidth: 230, alignment: .trailing)
    }

    private var tint: Color {
        let f = usage.fraction
        if f >= 0.9 { return Theme.bad }
        if f >= 0.7 { return Theme.warn }
        return VPNStyle.tint
    }
}

// MARK: - Countries

private struct VPNCountriesPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.vpn
        Panel(title: "Pays", subtitle: "Les 10 pays gratuits de Windscribe : un clic pour t'y connecter",
              symbol: "globe.europe.africa", tint: VPNStyle.tint) {
            FlowLayout(spacing: 6, lineSpacing: 8) {
                ForEach(VPNCountry.allCases) { country in
                    VPNCountryChip(country: country, state: state(of: country, m), enabled: enabled(m)) {
                        m.connect(country)
                    }
                }
            }
        }
    }

    private func state(of country: VPNCountry, _ m: VPNModel) -> VPNCountryChip.State {
        switch m.phase {
        case .connected(let c) where c.country == country: return .connected
        case .connecting(let c) where c == country: return .connecting
        default: return .idle
        }
    }

    private func enabled(_ m: VPNModel) -> Bool {
        switch m.phase {
        case .closed, .ready, .connected, .failed, .unknown: return true
        default: return false
        }
    }
}

private struct VPNCountryChip: View {
    enum State { case idle, connecting, connected }

    var country: VPNCountry
    var state: State
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        let on = state == .connected
        Button {
            if !on { action() }
        } label: {
            HStack(spacing: 6) {
                if Theme.icons != .hidden { Text(country.flag).font(.ui(14)) }
                Text(country.name).font(.ui(12.5, on || country == .fr ? .semibold : .medium))
                if on, Theme.icons != .hidden { Image(systemName: "checkmark").font(.ui(10, .bold)) }
                if state == .connecting { Text("…").font(.ui(12.5, .semibold)) }
            }
            .foregroundStyle(on ? Theme.onAccent : Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(PillShape().fill(on ? Theme.accent : (state == .connecting ? Theme.selected : Theme.card)))
            .overlay(PillShape().strokeBorder(on ? Color.clear : (state == .connecting ? Theme.accent : Theme.border), lineWidth: Theme.line))
            .contentShape(PillShape())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || state == .connecting)
        .opacity(enabled || state != .idle ? 1 : 0.5)
        .help(on ? "Connecté \(country.inName)" : "Se connecter \(country.inName)")
    }
}
