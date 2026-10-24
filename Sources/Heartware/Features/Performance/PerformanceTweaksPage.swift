import SwiftUI

// MARK: - Fluidité tab

struct PerformanceTweaksTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let t = app.performance.tweaks
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Text("\(t.appliedCount) sur \(PerformanceTweak.all.count) appliqués").font(.ui(12)).foregroundStyle(Theme.text3)
                Spacer()
                Button("Tout rétablir") { t.restore(PerformanceTweak.all) }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(t.appliedCount == 0)
                Button("Tout appliquer") { t.apply(t.everyday) }
                    .buttonStyle(SoftButtonStyle(prominent: true))
            }
            if let msg = t.message {
                Label(msg.text, systemImage: msg.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.ui(11.5)).foregroundStyle(msg.ok ? Theme.good : Theme.warn)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    section(.windows)
                    section(.finder)
                }
                VStack(spacing: 14) {
                    section(.dock)
                    section(.games)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                PerformanceDisplaysPanel()
                PerformanceAccessibilityPanel()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            t.refresh()
            Task { await app.performance.boost.refreshPowerState() }
        }
    }

    private func section(_ s: PerformanceTweakSection) -> some View {
        let t = app.performance.tweaks
        return Panel(title: s.title, symbol: s.symbol) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(PerformanceTweak.all.filter { $0.section == s }) { tweak in
                    Toggle(isOn: Binding(get: { t.isApplied(tweak) }, set: { $0 ? t.apply(tweak) : t.restore(tweak) })) {
                        HStack(alignment: .top, spacing: 10) {
                            IconBadge(symbol: tweak.symbol, tint: Theme.accent, size: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tweak.title).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
                                Text(tweak.detail).font(.ui(11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .help(tweak.restart.note ?? "")
                    .switchToggles()
                }
                if s == .finder {
                    Button("Relancer le Finder") { t.relaunchFinder() }.buttonStyle(SoftButtonStyle(small: true))
                }
                if s == .games {
                    gameMode
                }
            }
        }
    }

    @ViewBuilder
    private var gameMode: some View {
        let b = app.performance.boost
        HStack(alignment: .top, spacing: 10) {
            IconBadge(symbol: "gamecontroller", tint: Theme.accent, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mode Jeu de macOS").font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
                Text(gameModeText(b)).font(.ui(11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Mode Performance") {
                b.setMode(.performance)
                app.performance.tab = .boost
            }
            .buttonStyle(SoftButtonStyle(small: true))
            .disabled(b.mode == .performance)
        }
    }

    private func gameModeText(_ b: PerformanceBoost) -> String {
        guard b.gameModeAvailable else {
            return "macOS l'active seul pour les jeux en plein écran. Le Boost Performance libère en plus les cœurs pour le jeu."
        }
        switch b.gamePolicy {
        case .on?: return "Forcé par le Boost Performance : priorité au jeu et latence Bluetooth réduite."
        case .off?: return "Désactivé dans macOS."
        default: return "Automatique (jeux en plein écran). Le mode Performance du Boost peut le forcer."
        }
    }
}

struct PerformanceDisplaysPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let t = app.performance.tweaks
        Panel(title: "Écrans", subtitle: "Plus d'images par seconde, plus de fluidité.", symbol: "display") {
            VStack(alignment: .leading, spacing: 10) {
                if t.displays.isEmpty {
                    EmptyHint(text: "Aucun écran lu.")
                }
                ForEach(t.displays) { d in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).font(.ui(12.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                            Text("\(d.resolution) · \(d.current > 0 ? "\(Int(d.current.rounded())) Hz" : "60 Hz")").font(.ui(11)).foregroundStyle(Theme.text3)
                        }
                        Spacer(minLength: 8)
                        if d.canGoFaster {
                            Button("Passer à \(Int(d.best.rounded())) Hz") { t.setBestRefresh(d) }
                                .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                        } else {
                            Tag(text: "Au maximum", symbol: "checkmark", tint: Theme.good, filled: true)
                        }
                    }
                }
            }
        }
    }
}

struct PerformanceAccessibilityPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let t = app.performance.tweaks
        Panel(title: "Effets visuels", subtitle: "Ils allègent le travail de la puce graphique.", symbol: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                row("Réduire la transparence", "Supprime le flou derrière les menus, le Dock et les barres latérales.", on: t.reduceTransparency)
                row("Réduire les animations", "Fondus au lieu des glissements entre les bureaux et en plein écran.", on: t.reduceMotion)
                Button("Ouvrir les réglages d'affichage") { Finder.open(PerformanceTweaks.accessibilitySettings) }
                    .buttonStyle(SoftButtonStyle(small: true))
            }
        }
    }

    private func row(_ title: String, _ detail: String, on: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
                Text(detail).font(.ui(11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Tag(text: on ? "Activé" : "Désactivé", tint: on ? Theme.good : Theme.text3, filled: on)
        }
    }
}
