import SwiftUI
import AppKit

/// Where the pointer hides: everywhere, or only in some apps.
enum ToolboxCursorScope: String, CaseIterable, Identifiable {
    case everywhere, chosenApps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everywhere: return "Dans toutes les apps"
        case .chosenApps: return "Seulement dans les apps choisies"
        }
    }
}

struct ToolboxCursorTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.toolbox
        VStack(alignment: .leading, spacing: 14) {
            Card(padding: 24) {
                HStack(alignment: .center, spacing: 28) {
                    ZStack {
                        ProgressRing(progress: m.cursor.enabled ? 1 : 0, tint: Theme.brand, lineWidth: 9)
                        VStack(spacing: 4) {
                            if Theme.icons != .hidden {
                                Image(systemName: m.cursor.enabled ? "cursorarrow.slash" : "cursorarrow")
                                    .font(.ui(22, .medium))
                                    .foregroundStyle(m.cursor.enabled ? Theme.brand : Theme.text3)
                            }
                            Text(m.cursor.enabled ? ToolboxCursorRule.label(m.cursor.delay) : "—")
                                .font(.serif(24))
                                .foregroundStyle(Theme.text)
                                .monospacedDigit()
                        }
                    }
                    .frame(width: 140, height: 140)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(m.cursor.enabled ? "Le curseur se cache tout seul" : "Le curseur reste toujours visible")
                            .font(.serif(26)).foregroundStyle(Theme.text)
                        Text(subtitle(m))
                            .font(.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            ForEach(ToolboxCursorRule.delays, id: \.self) { seconds in
                                let on = m.cursor.enabled && m.cursor.delay == seconds
                                Button {
                                    m.cursor.delay = seconds
                                    m.cursor.enabled = true
                                } label: {
                                    Text(ToolboxCursorRule.label(seconds))
                                        .font(.ui(12.5, .semibold))
                                        .foregroundStyle(on ? Theme.onBrand : Theme.text)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(RoundedRectangle(cornerRadius: Theme.r(9)).fill(on ? Theme.brand : Theme.bg))
                                        .overlay(RoundedRectangle(cornerRadius: Theme.r(9)).strokeBorder(on ? Color.clear : Theme.border, lineWidth: Theme.line))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Cacher le curseur après \(ToolboxCursorRule.label(seconds)) sans bouger la souris")
                            }
                            if m.cursor.enabled {
                                Button("Désactiver") { m.cursor.enabled = false }
                                    .buttonStyle(SoftButtonStyle(destructive: true))
                                    .padding(.leading, 6)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            ToolboxCursorAppsPanel()
        }
    }

    private func subtitle(_ m: ToolboxModel) -> String {
        guard m.cursor.enabled else { return "Choisis après combien de temps sans bouger la souris il disparaît." }
        let where_ = m.cursor.onlyApps
            ? (m.cursor.apps.isEmpty ? " dès qu'une app choisie sera au premier plan" : " quand une app choisie est au premier plan")
            : ""
        return "Il disparaît après \(ToolboxCursorRule.label(m.cursor.delay)) sans bouger la souris\(where_)."
    }
}

/// Everywhere, or only in the apps of a list (a reader, a video player…).
private struct ToolboxCursorAppsPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.toolbox
        let scope = Binding<ToolboxCursorScope>(get: { m.cursor.onlyApps ? .chosenApps : .everywhere },
                                                set: { m.cursor.onlyApps = $0 == .chosenApps })
        Panel(title: "Dans quelles apps", symbol: "macwindow", tint: Theme.brand) {
            VStack(alignment: .leading, spacing: 12) {
                PillPicker(options: ToolboxCursorScope.allCases, selection: scope, label: { $0.title })
                if m.cursor.onlyApps {
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(m.cursor.apps) { a in
                            chip(a, m)
                        }
                        addMenu(m)
                    }
                    if m.cursor.apps.isEmpty {
                        Text("Aucune app pour l'instant : le curseur ne se cachera nulle part.")
                            .font(.ui(11.5)).foregroundStyle(Theme.warn)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chip(_ a: ToolboxCursorApp, _ m: ToolboxModel) -> some View {
        HStack(spacing: 7) {
            if let path = a.path {
                FileIcon(path: path, size: 18)
            }
            Text(a.name).font(.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
            Button { m.removeCursorApp(a.bundleID) } label: {
                Image(systemName: "xmark").font(.ui(9, .bold)).foregroundStyle(Theme.text3)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Retirer \(a.name)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(PillShape().fill(Theme.bg))
        .overlay(PillShape().strokeBorder(Theme.border, lineWidth: Theme.line))
    }

    private func addMenu(_ m: ToolboxModel) -> some View {
        BorderlessMenu(indicator: false) {
            let candidates = m.cursorCandidates()
            if !candidates.isEmpty {
                Section("Apps ouvertes") {
                    ForEach(candidates) { a in
                        Button(a.name) { m.addCursorApp(a) }
                    }
                }
            }
            Button("Autre app…") { m.chooseCursorApp() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.ui(10, .bold))
                Text("Ajouter une app").font(.ui(12, .medium))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(PillShape().strokeBorder(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: Theme.line, dash: [3, 2])))
        }
    }
}
