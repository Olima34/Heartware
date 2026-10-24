import SwiftUI

/// ⌘K on a file: its actions in a panel at the bottom right of the launcher, like Raycast's.
struct LauncherActionsPanel: View {
    static let width: CGFloat = 384
    static let rowHeight: CGFloat = 32
    static let maxListHeight: CGFloat = 268

    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = app.launcher
        let name = model.actionsTarget?.title ?? ""
        let choosingApp = model.openWithApps != nil
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if choosingApp {
                    Image(systemName: "chevron.left").font(.ui(10, .semibold)).foregroundStyle(Theme.text3)
                }
                Text(choosingApp ? "Ouvrir « \(name) » avec…" : name)
                    .font(.ui(11.5, .semibold)).foregroundStyle(Theme.text3)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 5)
            list
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 8) {
                if Snapshot.isActive {
                    Text(model.actionFilter.isEmpty ? placeholder : model.actionFilter)
                        .font(.ui(13)).foregroundStyle(model.actionFilter.isEmpty ? Theme.text3 : Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(placeholder, text: $model.actionFilter)
                        .textFieldStyle(.plain)
                        .font(.ui(13))
                        .foregroundStyle(Theme.text)
                        .focused($focused)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .frame(width: Self.width)
        .floatingSurface(radius: 10)
        .themedShadow(color: .black.opacity(0.28), radius: 18, y: 6)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: model.openWithApps == nil) { _, _ in DispatchQueue.main.async { focused = true } }
    }

    private var placeholder: String {
        app.launcher.openWithApps == nil ? "Rechercher une action…" : "Rechercher une app…"
    }

    /// The rows, with a line between two groups (not while searching: the best match comes first then).
    private var entries: [Entry] {
        let model = app.launcher
        guard model.openWithApps == nil else { return model.visibleApps.indices.map { Entry(index: $0, separated: false) } }
        let actions = model.visibleActions
        let grouped = model.actionFilter.trimmingCharacters(in: .whitespaces).isEmpty
        return actions.indices.map { i in Entry(index: i, separated: grouped && i > 0 && actions[i - 1].group != actions[i].group) }
    }

    private struct Entry: Identifiable {
        let index: Int
        let separated: Bool
        var id: Int { index }
    }

    private var listHeight: CGFloat {
        let rows = entries
        let height = CGFloat(rows.count) * Self.rowHeight + CGFloat(rows.filter(\.separated).count) * 9 + 8
        return min(Self.maxListHeight, max(Self.rowHeight + 8, height))
    }

    @ViewBuilder
    private var list: some View {
        if Snapshot.isActive {
            ScrollArea { rows }.frame(height: listHeight, alignment: .top).clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView { rows }
                    .frame(height: listHeight)
                    .onChange(of: app.launcher.actionSelection) { _, s in proxy.scrollTo(s) }
            }
        }
    }

    private var rows: some View {
        let model = app.launcher
        let actions = model.visibleActions
        let apps = model.visibleApps
        return VStack(spacing: 0) {
            if entries.isEmpty {
                Text(model.openWithApps == nil ? "Aucune action." : "Aucune app.")
                    .font(.ui(12)).foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
            }
            ForEach(entries) { entry in
                let i = entry.index
                // The line above a group and its first action share one id: scrolling to that action brings both
                // into view (with two views under the same id, the list could stop at the line and hide the action).
                VStack(spacing: 0) {
                    if entry.separated {
                        Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
                    }
                    Group {
                        if model.openWithApps != nil {
                            LauncherOpenWithRow(app: apps[i], selected: i == model.actionSelection)
                        } else {
                            LauncherActionRow(action: actions[i], selected: i == model.actionSelection)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.actionSelection = i
                        model.runSelectedAction()
                    }
                    .onContinuousHover { phase in
                        if case .active = phase, model.actionSelection != i { model.actionSelection = i }
                    }
                }
                .id(i)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }
}

struct LauncherActionRow: View {
    var action: LauncherAction
    var selected: Bool

    var body: some View {
        let tint = action.destructive ? Theme.bad : Theme.text
        HStack(spacing: 10) {
            if Theme.icons != .hidden {
                Image(systemName: action.symbol)
                    .font(.ui(12.5, .medium))
                    .foregroundStyle(action.destructive ? Theme.bad : (Theme.icons == .tinted ? Theme.accent : Theme.text2))
                    .frame(width: 18)
            }
            Text(action.title).font(.ui(13, selected ? .medium : .regular)).foregroundStyle(tint).lineLimit(1)
            Spacer(minLength: 8)
            LauncherKeyCaps(keys: action.shortcut?.keys ?? [])
        }
        .padding(.horizontal, 8)
        .frame(height: LauncherActionsPanel.rowHeight)
        .background {
            if selected && action.destructive {
                RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous).fill(Theme.bad.opacity(0.14))
            } else if selected {
                StillBubble(radius: 8)
            }
        }
    }
}

struct LauncherOpenWithRow: View {
    var app: LauncherOpenWithApp
    var selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(path: app.path, size: 20)
            Text(app.name).font(.ui(13, selected ? .medium : .regular)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 8)
            if app.isDefault {
                Text("Par défaut").font(.ui(10.5, .medium)).foregroundStyle(Theme.text3)
            }
            if selected { LauncherKeyCaps(keys: ["↩"]) }
        }
        .padding(.horizontal, 8)
        .frame(height: LauncherActionsPanel.rowHeight)
        .background { if selected { StillBubble(radius: 8) } }
    }
}

/// Keys drawn as caps, one per symbol ("⇧" "⌘" "D").
struct LauncherKeyCaps: View {
    var keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.ui(10.5, .medium)).foregroundStyle(Theme.text2)
                    .frame(minWidth: 19, minHeight: 19)
                    .padding(.horizontal, key.count > 1 ? 4 : 0)
                    .background(RoundedRectangle(cornerRadius: Theme.r(5), style: .continuous).fill(Theme.fill2))
            }
        }
    }
}

/// "Coup d'œil": the selected file over the whole panel, drawn by Quick Look.
struct LauncherQuickLookPanel: View {
    var path: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                FileIcon(path: path, size: 24)
                Text((path as NSString).lastPathComponent)
                    .font(.ui(15, .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(FS.pretty((path as NSString).deletingLastPathComponent))
                    .font(.ui(11.5)).foregroundStyle(Theme.text3)
                    .lineLimit(1).truncationMode(.head)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            Rectangle().fill(Theme.border).frame(height: 1)
            Group {
                if Snapshot.isActive || DemoData.isEnabled {
                    LauncherDemoPreview(path: path)
                } else {
                    LauncherQuickLook(url: URL(fileURLWithPath: path), style: .normal)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.card)
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 14) {
                LauncherKeyHint(key: "↑↓", label: "Fichier précédent ou suivant")
                LauncherKeyHint(key: "↩", label: "Ouvrir")
                LauncherKeyHint(key: "⌘↩", label: "Afficher dans le Finder")
                Spacer()
                LauncherKeyHint(key: "⎋", label: "Retour aux résultats")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Theme.fill1)
        }
    }
}
