import SwiftUI

/// Heartware's own keys in one list, then what the launcher finds (`HotkeysLauncherSection`). Each key stays saved by
/// its module, through that module's own setter (lanceur, presse-papiers, roue), or as a shortcut of this page for the
/// actions (fenêtre Fichiers, Vidéo seule).
struct HotkeysHeartwareSection: View {
    @Environment(AppModel.self) private var app
    /// Why a key was refused, by row (the launcher keeps its own).
    @State private var warnings: [String: String] = [:]

    static let videoOnly = HotkeysTarget.command(id: AdBlockVideoOnly.commandID, title: "Vidéo seule")

    var body: some View {
        let launcher = app.launcher
        VStack(alignment: .leading, spacing: 12) {
            keys(launcher)
            HotkeysLauncherSection()
        }
    }

    private func keys(_ launcher: LauncherModel) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HotkeysHeartwareRow(symbol: "command", tint: Theme.brand, title: "Ouvrir le lanceur",
                                  detail: "Chercher une app, un fichier, calculer, traduire…",
                                  warning: launcher.comboRefusal ?? launcherRefused,
                                  combo: launcher.combo, set: { launcher.setCombo($0) },
                                  openTitle: "Ouvrir le lanceur", tip: HotkeysLauncherSection.tip) { launcher.show() }
                HotkeysHeartwareRow(symbol: "doc.text.magnifyingglass", tint: Theme.accent, title: "Rechercher des fichiers",
                                  detail: "La fenêtre Fichiers du lanceur",
                                  warning: warnings["files"],
                                  combo: app.hotkeys.binding(for: LauncherModel.filesHotkeyTarget)?.combo,
                                  set: { bind(LauncherModel.filesHotkeyTarget, $0, row: "files") },
                                  openTitle: "Ouvrir la fenêtre Fichiers") { launcher.showFiles() }
                HotkeysHeartwareRow(symbol: "doc.on.clipboard", tint: Theme.palette[2], title: "Historique du presse-papiers",
                                  detail: "Tout ce que tu as copié, prêt à recoller",
                                  warning: nil,
                                  combo: app.clipboard.combo, set: { app.clipboard.setCombo($0) },
                                  openTitle: "Ouvrir l'historique") { app.clipboard.window.show() }
                HotkeysHeartwareRow(symbol: "dial.medium", tint: Theme.palette[3], title: "Roue du Convertisseur",
                                  detail: "Sur les fichiers choisis dans le Finder",
                                  warning: nil,
                                  combo: app.wheel.combo, set: { app.wheel.setCombo($0) },
                                  openTitle: "Ouvrir la roue") { app.page = .wheel }
                HotkeysHeartwareRow(symbol: "pip", tint: Theme.palette[5], title: "Vidéo seule",
                                  detail: "La vidéo de Safari, seule dans une petite fenêtre",
                                  warning: warnings["video"],
                                  combo: app.hotkeys.binding(for: Self.videoOnly)?.combo,
                                  set: { bind(Self.videoOnly, $0, row: "video") },
                                  openTitle: "Ouvrir le lecteur sans pub") { app.media.show(.player, app: app) }
            }
        }
    }

    /// The launcher's key, refused by macOS (not by Heartware): only in the running app, where it was registered.
    private var launcherRefused: String? {
        let l = app.launcher
        guard l.combo != nil, !l.hotKeyActive, !DemoData.isEnabled, !Snapshot.isActive else { return nil }
        return "macOS a refusé ce raccourci : choisis-en un avec ⌘ ou ⌃."
    }

    private func bind(_ target: HotkeysTarget, _ combo: KeyCombo?, row: String) {
        warnings[row] = nil
        guard let combo else {
            app.hotkeys.unbind(target)
            return
        }
        if let other = app.hotkeys.bind(target, combo: combo) {
            warnings[row] = "\(combo.display) est déjà utilisé par \(other) : choisis-en un autre."
        } else if let id = app.hotkeys.binding(for: target)?.id, let note = app.hotkeys.takeovers[id] {
            warnings[row] = note
        }
    }
}

private struct HotkeysHeartwareRow: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    var warning: String?
    var combo: KeyCombo?
    var set: (KeyCombo?) -> Void
    var openTitle: String
    /// What is worth knowing once about it: its « ? » sits next to the title.
    var tip: HelpTip?
    var open: () -> Void

    var body: some View {
        HotkeysHoverRow {
            HStack(spacing: 10) {
                IconBadge(symbol: symbol, tint: tint, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        if let tip { HelpTipButton(tip: tip, size: 11.5) }
                    }
                    Text(warning ?? detail)
                        .font(.ui(11))
                        .foregroundStyle(warning == nil ? Theme.text3 : Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                ShortcutRecorder(combo: combo, onChange: set)
                Button(action: open) {
                    Image(systemName: "arrow.right.circle").font(.ui(14)).foregroundStyle(Theme.text2)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(openTitle)
            }
        }
    }
}
