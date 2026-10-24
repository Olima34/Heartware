import SwiftUI
import AppKit

/// The Raccourcis page, one part at a time: the user's shortcuts (apps, folders, sites, actions), the window layouts
/// of `WindowsModel`, and Heartware's own keys.
struct HotkeysPage: View {
    @Environment(AppModel.self) private var app

    static let tip = HelpTip(
        id: "hotkeys.page",
        title: "Une touche pour tout ouvrir",
        text: "Un raccourci marche partout, même quand Heartware est caché. Pour une app déjà devant, appuie de nouveau : elle se masque.",
        steps: ["Cherche une app ou une action, ou tape l'adresse d'un site.",
                "Clique sur « Aucun », puis tape ta combinaison. ⌫ la retire, Échap annule.",
                "Dans le lanceur, ⌘K donne un raccourci au résultat choisi."])

    var body: some View {
        @Bindable var model = app.hotkeys
        VStack(alignment: .leading, spacing: 16) {
            PageHero(symbol: "keyboard", title: "Raccourcis",
                     subtitle: "Une touche pour chaque app, site ou action, et tes fenêtres rangées au clavier.",
                     tint: Theme.brand, seed: 57, tip: Self.tip)
            HStack(spacing: 10) {
                PillPicker(options: HotkeysTab.allCases, selection: $model.tab, label: \.title, badge: badge)
                Spacer(minLength: 8)
                switch model.tab {
                case .apps: addButtons
                case .windows: WindowsToolbar()
                case .heartware: EmptyView()
                }
            }
            switch model.tab {
            case .apps: HotkeysListSection()
            case .windows: WindowsSection()
            case .heartware: HotkeysHeartwareSection()
            }
        }
        .sheet(isPresented: $model.showCommandPicker) { HotkeysCommandPicker() }
    }

    private func badge(_ tab: HotkeysTab) -> String? {
        switch tab {
        case .apps: return app.hotkeys.sidebarBadge
        case .windows: return app.windows.trusted ? nil : "!"
        case .heartware: return nil
        }
    }

    private var addButtons: some View {
        let model = app.hotkeys
        return HStack(spacing: 8) {
            Button { model.chooseApp() } label: { ThemedLabel(title: "Ajouter une app", symbol: "plus") }
                .buttonStyle(SoftButtonStyle(prominent: true))
            Button { model.showCommandPicker = true } label: { ThemedLabel(title: "Une action", symbol: "sparkles") }
                .buttonStyle(SoftButtonStyle())
            BorderlessMenu {
                Button("Un dossier…") { model.chooseFolder() }
                Button("Un fichier…") { model.chooseFile() }
            } label: {
                Text("Autre…").font(.ui(12.5, .medium)).foregroundStyle(Theme.text2)
            }
        }
    }
}

// MARK: - Apps et actions

/// The search, then the user's shortcuts; while typing, the matching ones and what else can get one.
private struct HotkeysListSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.hotkeys
        let query = model.search.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 12) {
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HotkeysSearchField(text: $model.search)
                        .padding(.bottom, 6)
                    if !query.isEmpty {
                        HotkeysSearchResults(query: query)
                    } else if model.bindings.isEmpty {
                        Text("Aucun raccourci pour l'instant : prends une suggestion ou cherche une app.")
                            .font(.ui(12)).foregroundStyle(Theme.text3)
                            .padding(.horizontal, 8).padding(.vertical, 8)
                    } else {
                        ForEach(model.bindings) { b in
                            HotkeysRow(binding: b)
                        }
                    }
                }
            }
            if query.isEmpty { HotkeysSuggestions() }
        }
    }
}

private struct HotkeysSearchField: View {
    @Binding var text: String
    static let prompt = "Chercher une app, une action, ou taper l'adresse d'un site…"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.ui(12)).foregroundStyle(Theme.text3)
            if Snapshot.isActive {
                Text(text.isEmpty ? Self.prompt : text)
                    .font(.ui(12.5))
                    .foregroundStyle(text.isEmpty ? Theme.text3 : Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(Self.prompt, text: $text)
                    .textFieldStyle(.plain)
                    .font(.ui(12.5))
                    .onExitCommand { text = "" }
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.ui(12)).foregroundStyle(Theme.text3)
                }
                .buttonStyle(.plain)
                .help("Effacer")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(Theme.bg.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(8)).strokeBorder(Theme.border, lineWidth: Theme.line))
    }
}

/// A compact row that lights up under the pointer (every list of the Raccourcis page).
struct HotkeysHoverRow<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(hovering ? Theme.hover.opacity(0.6) : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// One of the user's shortcuts.
private struct HotkeysRow: View {
    @Environment(AppModel.self) private var app
    var binding: HotkeysBinding
    @State private var warning: String?

    var body: some View {
        let model = app.hotkeys
        HotkeysHoverRow {
            HStack(spacing: 10) {
                CommandIconView(icon: model.icon(binding.target), size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(binding.target.title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if let note = warning ?? model.takeovers[binding.id] {
                        Text(note).font(.ui(11)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(binding.target.kind).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if model.refused.contains(binding.id) {
                    StatusBadge(status: .bad, text: "Pris ailleurs")
                }
                ShortcutRecorder(combo: binding.combo) { combo in
                    if let other = model.conflict(for: combo, except: binding.id) {
                        warning = "Déjà utilisé par \(other)"
                    } else {
                        warning = nil
                        model.setCombo(combo, for: binding.id)
                    }
                }
                Button { model.fire(binding.id) } label: {
                    Image(systemName: "play.circle").font(.ui(14)).foregroundStyle(Theme.text2)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Essayer")
                BorderlessMenu(indicator: false) {
                    if case .app = binding.target {
                        Toggle("Masquer l'app si elle est déjà devant",
                               isOn: Binding(get: { binding.toggles }, set: { model.setToggles($0, for: binding.id) }))
                        Divider()
                    }
                    Button("Supprimer ce raccourci", role: .destructive) { model.remove(binding.id) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.ui(14)).foregroundStyle(Theme.text3)
                        .frame(width: 20, height: 20)
                }
                .help("Plus d'options")
            }
        }
    }
}

/// What the search finds that has no shortcut yet: an action, an app, a site, or a window layout (its own keys).
private struct HotkeysCandidate: Identifiable {
    enum Kind {
        case target(HotkeysTarget)
        case window(WindowsAction)
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let icon: CommandIcon
    var keywords: [String] = []
}

private struct HotkeysSearchResults: View {
    @Environment(AppModel.self) private var app
    var query: String
    private static let limit = 12

    var body: some View {
        let model = app.hotkeys
        let mine = model.bindings.filter { Fuzzy.best(query, title: $0.target.title, keywords: [$0.target.kind]) != nil }
        let site = HotkeysModel.siteCandidate(query).map { HotkeysTarget.website(url: $0) }.flatMap { model.binding(for: $0) == nil ? $0 : nil }
        let others = candidates
        VStack(alignment: .leading, spacing: 2) {
            ForEach(mine) { b in
                HotkeysRow(binding: b)
            }
            if let site {
                HotkeysCandidateRow(candidate: HotkeysCandidate(id: site.key, kind: .target(site), title: site.title,
                                                                subtitle: "Site web · s'ouvre dans ton navigateur", icon: model.icon(site)))
            }
            if !others.isEmpty {
                if !mine.isEmpty || site != nil {
                    Text("À ASSOCIER").font(.ui(10, .semibold)).tracking(0.7).foregroundStyle(Theme.text3)
                        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                }
                ForEach(others.prefix(Self.limit)) { c in
                    HotkeysCandidateRow(candidate: c)
                }
                if others.count > Self.limit {
                    Text("… et \(others.count - Self.limit) autres : précise ta recherche.")
                        .font(.ui(11.5)).foregroundStyle(Theme.text3).padding(.horizontal, 8).padding(.top, 4)
                }
            }
            if mine.isEmpty, site == nil, others.isEmpty {
                Text("Rien ne correspond. Un dossier ou un fichier ? Passe par « Autre… ».")
                    .font(.ui(12)).foregroundStyle(Theme.text3).padding(.horizontal, 8).padding(.vertical, 8)
            }
        }
    }

    /// Every action of the app and every installed app without a shortcut, best matches first.
    private var candidates: [HotkeysCandidate] {
        let bound = Set(app.hotkeys.bindings.map(\.target.key))
        var all: [HotkeysCandidate] = []
        for c in ModuleRegistry.commands(app) where !c.id.hasPrefix("hk_") {
            if let a = HotkeysModel.windowAction(c.id) {
                all.append(HotkeysCandidate(id: c.id, kind: .window(a), title: a.title, subtitle: "Fenêtres · " + (a.detail ?? "la fenêtre au premier plan"),
                                            icon: c.icon, keywords: c.keywords))
                continue
            }
            let target = HotkeysTarget.command(id: c.id, title: c.title)
            guard !bound.contains(target.key) else { continue }
            all.append(HotkeysCandidate(id: c.id, kind: .target(target), title: c.title, subtitle: c.subtitle ?? c.group.title,
                                        icon: c.icon, keywords: c.keywords))
        }
        for a in app.launcher.installedApps {
            let target = HotkeysTarget.app(path: a.path, name: a.name)
            guard !bound.contains(target.key) else { continue }
            all.append(HotkeysCandidate(id: "app:" + a.path, kind: .target(target), title: a.name, subtitle: "App", icon: .file(a.path)))
        }
        var seen = Set<String>()
        return all.compactMap { c in Fuzzy.best(query, title: c.title, keywords: c.keywords).map { (c, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
            .filter { seen.insert($0.id).inserted }
    }
}

private struct HotkeysCandidateRow: View {
    @Environment(AppModel.self) private var app
    var candidate: HotkeysCandidate
    @State private var warning: String?

    var body: some View {
        HotkeysHoverRow {
            HStack(spacing: 10) {
                switch candidate.kind {
                case .window(let a): WindowsMiniScreen(action: a, width: 24).frame(width: 24, height: 24)
                case .target: CommandIconView(icon: candidate.icon, size: 24)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.title).font(.ui(12.5)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(warning ?? candidate.subtitle).font(.ui(11)).foregroundStyle(warning == nil ? Theme.text3 : Theme.warn).lineLimit(1)
                }
                Spacer(minLength: 8)
                ShortcutRecorder(combo: combo) { set($0) }
                if case .target(let target) = candidate.kind {
                    Button { app.hotkeys.add(target) } label: {
                        Image(systemName: "plus.circle").font(.ui(14)).foregroundStyle(Theme.accent)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Ajouter avec ⌃⌥⌘ + une lettre libre")
                } else {
                    Color.clear.frame(width: 20, height: 20)
                }
                // Lines up with the « … » menu of the shortcuts above.
                Color.clear.frame(width: 20, height: 20)
            }
        }
    }

    private var combo: KeyCombo? {
        switch candidate.kind {
        case .window(let a): return app.windows.combos[a]
        case .target(let t): return app.hotkeys.binding(for: t)?.combo
        }
    }

    private func set(_ new: KeyCombo?) {
        switch candidate.kind {
        case .window(let a):
            app.windows.setCombo(new, for: a)
            warning = app.windows.refusal
        case .target(let t):
            guard let new else {
                app.hotkeys.unbind(t)
                return
            }
            if let other = app.hotkeys.bind(t, combo: new) {
                warning = "\(new.display) est déjà utilisé par \(other)"
            } else if let id = app.hotkeys.binding(for: t)?.id, let note = app.hotkeys.takeovers[id] {
                HUD.show(note, symbol: "exclamationmark.triangle.fill")
            }
        }
    }
}

/// Common apps of this Mac without a shortcut, one click each.
private struct HotkeysSuggestions: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.hotkeys
        let list = model.suggestions
        if !list.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Text("Suggestions").font(.ui(11.5, .medium)).foregroundStyle(Theme.text3).padding(.top, 5)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, target in
                        Button { model.add(target) } label: {
                            HStack(spacing: 6) {
                                CommandIconView(icon: model.icon(target), size: 16)
                                Text(target.title).font(.ui(12)).foregroundStyle(Theme.text).lineLimit(1)
                                Image(systemName: "plus").font(.ui(9.5, .bold)).foregroundStyle(Theme.accent)
                            }
                            .padding(.leading, 6)
                            .padding(.trailing, 9)
                            .padding(.vertical, 4)
                            .background(PillShape().fill(Theme.card))
                            .overlay(PillShape().strokeBorder(Theme.border, lineWidth: Theme.line))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Lui donner ⌃⌥⌘ + une lettre libre")
                    }
                }
            }
        }
    }
}

/// Picks one of the app's actions (the launcher's catalogue) for a shortcut.
private struct HotkeysCommandPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        // A window layout keeps its own keys (Fenêtres), not a second shortcut.
        let all = ModuleRegistry.commands(app).filter { !$0.id.hasPrefix("hk_") && HotkeysModel.windowAction($0.id) == nil }
        let shown = query.isEmpty ? Array(all.prefix(80))
            : all.compactMap { c in Fuzzy.best(query, title: c.title, keywords: c.keywords).map { (c, $0) } }.sorted { $0.1 > $1.1 }.prefix(80).map(\.0)
        VStack(alignment: .leading, spacing: 12) {
            Text("Une action pour ce raccourci").font(.serif(20)).foregroundStyle(Theme.text)
            TextField("Chercher : analyse, mode sombre, Caféine…", text: $query).textFieldStyle(.roundedBorder)
            List(shown, id: \.id) { c in
                Button {
                    app.hotkeys.add(.command(id: c.id, title: c.title))
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        CommandIconView(icon: c.icon, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title).font(.ui(12.5)).foregroundStyle(Theme.text)
                            if let s = c.subtitle { Text(s).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1) }
                        }
                        Spacer()
                        if case .confirm = c.risk { Image(systemName: "exclamationmark.shield").foregroundStyle(Theme.warn).help("Demandera confirmation") }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 380)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct HotkeysBottomBar: View {
    var body: some View { EmptyView() }
}
