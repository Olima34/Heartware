import SwiftUI

/// What the launcher finds, under Heartware's keys: the instant file index, the results taken out of the search,
/// and the most used commands (one click gives them a shortcut).
struct HotkeysLauncherSection: View {
    @Environment(AppModel.self) private var app

    /// What the launcher understands: shown next to « Ouvrir le lanceur ».
    static let tip = HelpTip(
        id: "launcher.typing",
        title: "Ce que tu peux taper",
        text: """
        Le nom d'une app, un calcul (1250*1,2 + 15%), une conversion (10 km en miles), l'heure d'une ville (heure Tokyo), \
        un réglage (wifi), une phrase à traduire, un lien YouTube à télécharger ou n'importe quelle action de Heartware.
        """,
        steps: [
            "⌘K : les actions du résultat choisi (quitter une app, convertir un fichier, lui donner un raccourci, le masquer…).",
            "Un lien YouTube collé : ↩ le télécharge, ses options sont à droite.",
            "« trad bonjour en anglais » ouvre le traducteur ; son engrenage (⌘,) règle les langues.",
            "« ~/Documents/ » ou « dans devis » passe à la fenêtre Fichiers."
        ])

    var body: some View {
        let hidden = hiddenRows
        let top = mostUsed
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Recherche du lanceur")
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    indexRow
                    if !hidden.isEmpty { hiddenRow(hidden) }
                    if !top.isEmpty { mostUsedRow(top) }
                }
            }
        }
    }

    // MARK: Index

    private var indexRow: some View {
        @Bindable var launcher = app.launcher
        return HotkeysLauncherRow(symbol: "bolt", tint: Theme.accent, title: "Index instantané des fichiers", detail: indexDetail) {
            switch launcher.indexState {
            case .ready(let count):
                StatusBadge(status: .ok, text: Fmt.plural(count, "fichier", "fichiers"))
                Button("Tout relire") { if !DemoData.isEnabled { launcher.fileIndex.rebuild() } }
                    .buttonStyle(SoftButtonStyle(small: true))
                    .help("Relit tout ton dossier personnel, en arrière-plan")
            case .building:
                BusyMascot(.sorting, pixel: 1)
                StatusBadge(status: .info, text: "Indexation…")
            case .off:
                if launcher.includeFiles {
                    Button("Activer") { if !DemoData.isEnabled { launcher.enableIndex() } }
                        .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                        .help("Sans l'accès complet au disque, macOS demandera d'autoriser Documents, Bureau et Téléchargements")
                }
            }
            Toggle("", isOn: $launcher.includeFiles).labelsHidden().switchToggles().fixedSize()
                .help("Sans l'index, Spotlight cherche les fichiers, en une seconde ou plus")
        }
    }

    private var indexDetail: String {
        let launcher = app.launcher
        switch launcher.indexState {
        case .ready: return "La fenêtre Fichiers trouve dès la première lettre"
        case .building: return "Lecture de ton dossier personnel…"
        case .off:
            guard launcher.includeFiles else { return "Désactivé : Spotlight cherche, plus lentement" }
            return app.fullDiskAccess ? "Spotlight cherche en attendant"
                : "macOS demandera l'accès à Documents, Bureau et Téléchargements"
        }
    }

    // MARK: Hidden

    private func hiddenRow(_ hidden: [(id: String, title: String)]) -> some View {
        let launcher = app.launcher
        return HotkeysLauncherRow(symbol: "eye.slash", tint: Theme.color(index: 4), title: "Masqués de la recherche",
                                  detail: hidden.map(\.title).joined(separator: ", ")) {
            if let only = hidden.first, hidden.count == 1 {
                Button("Réafficher") { launcher.hiddenIDs.removeAll { $0 == only.id } }
                    .buttonStyle(SoftButtonStyle(small: true))
            } else {
                BorderlessMenu {
                    ForEach(hidden, id: \.id) { row in
                        Button(row.title) { launcher.hiddenIDs.removeAll { $0 == row.id } }
                    }
                    Divider()
                    Button("Tout réafficher") { launcher.hiddenIDs.removeAll() }
                } label: {
                    Text("Réafficher").font(.ui(12, .medium)).foregroundStyle(Theme.text2)
                }
            }
        }
        .help("⌘K › Masquer de la recherche, sur un résultat du lanceur")
    }

    /// The apps and commands taken out of the search, with their names.
    private var hiddenRows: [(id: String, title: String)] {
        let ids = app.launcher.hiddenIDs
        guard !ids.isEmpty else { return [] }
        let all = ModuleRegistry.commands(app) + LauncherAppIndex.commands(app.launcher.installedApps)
        let titles = Dictionary(all.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return ids.map { ($0, titles[$0] ?? $0) }
    }

    // MARK: Most used

    private func mostUsedRow(_ top: [(command: AppCommand, count: Int)]) -> some View {
        HotkeysHoverRow {
            HStack(alignment: .top, spacing: 10) {
                IconBadge(symbol: "chart.bar", tint: Theme.color(index: 1), size: 26)
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Les plus utilisées").font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text("Un clic leur donne ⌃⌥⌘ + une lettre libre").font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(top, id: \.command.id) { item in
                            HotkeysUsageChip(command: item.command, count: item.count)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The commands the launcher ran most, best first: only those of the catalogue that could take a shortcut here.
    private var mostUsed: [(command: AppCommand, count: Int)] {
        let usage = CommandRunner.usage.value
        guard !usage.isEmpty else { return [] }
        let commands = Dictionary(ModuleRegistry.commands(app).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return HotkeysModel.mostUsed(usage.mapValues(\.count), catalog: Set(commands.keys))
            .compactMap { id, count in commands[id].map { ($0, count) } }
    }
}

/// One of the most used commands: its count, then its shortcut, or a « + » that gives it one.
private struct HotkeysUsageChip: View {
    @Environment(AppModel.self) private var app
    var command: AppCommand
    var count: Int

    var body: some View {
        let combo = app.hotkeys.combo(for: command)
        let used = "Lancée " + Fmt.plural(count, "fois", "fois")
        if let combo {
            label(trailing: Text(combo.display).font(.ui(11, .medium)).foregroundStyle(Theme.text2))
                .help(used)
        } else {
            Button { app.hotkeys.add(.command(id: command.id, title: command.title)) } label: {
                label(trailing: Image(systemName: "plus").font(.ui(9.5, .bold)).foregroundStyle(Theme.accent))
            }
            .buttonStyle(.plain)
            .help(used + " · lui donner ⌃⌥⌘ + une lettre libre")
        }
    }

    private func label(trailing: some View) -> some View {
        HStack(spacing: 6) {
            CommandIconView(icon: command.icon, size: 16)
            Text(command.title).font(.ui(12)).foregroundStyle(Theme.text).lineLimit(1)
            Text("\(count)").font(.ui(11)).monospacedDigit().foregroundStyle(Theme.text3)
            trailing
        }
        .padding(.leading, 6)
        .padding(.trailing, 9)
        .padding(.vertical, 4)
        .background(PillShape().fill(Theme.card))
        .overlay(PillShape().strokeBorder(Theme.border, lineWidth: Theme.line))
        .contentShape(Rectangle())
    }
}

/// A setting of the launcher on one line, like Heartware's keys above it: its name and state, its controls on the right.
private struct HotkeysLauncherRow<Controls: View>: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    @ViewBuilder var controls: Controls

    var body: some View {
        HotkeysHoverRow {
            HStack(spacing: 10) {
                IconBadge(symbol: symbol, tint: tint, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(detail).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) { controls }
            }
            .frame(minHeight: 32)
        }
    }
}
