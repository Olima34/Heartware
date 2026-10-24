import SwiftUI

/// The floating search panel: the launcher, or the file search in its own window (`LauncherScope`).
struct LauncherView: View {
    static let width: CGFloat = 860
    static let height: CGFloat = 500
    static let previewWidth: CGFloat = 340

    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            switch app.launcher.mode {
            case .search: search
            case .translator: TranslatorPanelView()
            case .assign(let target, let title): LauncherAssignView(target: target, title: title)
            case .quickLook(let path): LauncherQuickLookPanel(path: path)
            }
        }
        .frame(width: Self.width, height: Self.height)
        // The command palette: frosted glass above the other windows, macOS draws its shadow.
        .floatingSurface(radius: 14, shadow: false, ownWindow: true)
        .background(TranslatorHost(channel: .launcher))
        .onAppear {
            DispatchQueue.main.async {
                focused = true
                // A search typed elsewhere ("Chercher « facture » dans les fichiers") goes on, instead of being replaced.
                DispatchQueue.main.async { app.launcher.moveCursorToEnd() }
            }
        }
        .onChange(of: app.launcher.mode) { _, mode in
            if mode == .search { DispatchQueue.main.async { focused = true } }
        }
        // The actions panel closed: the keyboard goes back to the search.
        .onChange(of: app.launcher.actionsTarget == nil) { _, closed in
            if closed { DispatchQueue.main.async { focused = true } }
        }
    }

    private var search: some View {
        @Bindable var model = app.launcher
        let files = model.scope == .files
        let placeholder = files ? "Rechercher un fichier ou un dossier…" : "Apps, calculs, traductions, commandes…"
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                if files {
                    CommandIconView(icon: .symbol("doc.text.magnifyingglass", Theme.accent), size: 24)
                } else {
                    BrandMark(size: 20)
                }
                if Snapshot.isActive {
                    Text(model.query.isEmpty ? placeholder : model.query).font(.ui(17))
                        .foregroundStyle(model.query.isEmpty ? Theme.text3 : Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(placeholder, text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.ui(17))
                        .foregroundStyle(Theme.text)
                        .focused($focused)
                }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.ui(14)).foregroundStyle(Theme.text3)
                    }
                    .buttonStyle(.plain)
                }
                if files { LauncherIndexBadge() }
            }
            .padding(.horizontal, 18)
            .frame(height: 50)
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 0) {
                results
                    .frame(maxWidth: .infinity, alignment: .top)
                if let pane = model.selectedPane, model.showDetails {
                    Rectangle().fill(Theme.border).frame(width: 1)
                    pane()
                        .frame(width: Self.previewWidth)
                } else if let path = model.selectedFile, model.showDetails {
                    Rectangle().fill(Theme.border).frame(width: 1)
                    LauncherPreview(path: path)
                        .frame(width: Self.previewWidth)
                }
            }
            .frame(height: Self.height - 50 - 38 - 2, alignment: .top)
            .overlay(alignment: .bottomTrailing) {
                if model.actionsTarget != nil {
                    ZStack(alignment: .bottomTrailing) {
                        // A click beside the panel closes it.
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { model.closeActions() }
                        LauncherActionsPanel().padding(10)
                    }
                }
            }
            .clipped()
            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .overlay {
            // `--tab glisser`: the pile of dragged files (on screen it has its own window, above every app).
            if Snapshot.isActive, let stack = model.snapshotStack { LauncherDragStackView(stack: stack).allowsHitTesting(false) }
        }
    }

    @ViewBuilder
    private var results: some View {
        if Snapshot.isActive {
            ScrollArea { list }
        } else {
            ScrollViewReader { proxy in
                ScrollView { list }
                    .onChange(of: app.launcher.selection) { _, s in
                        // Only for the arrow keys: a trackpad scroll is never pulled back to the selection.
                        if app.launcher.scrollToSelection { proxy.scrollTo(s) }
                    }
                    // The visible part of the list: a dragged file leaves its row only if the row can be seen.
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { app.launcher.listViewport = $0 }
            }
        }
    }

    private var list: some View {
        let model = app.launcher
        let offsets = Self.offsets(model.sections)
        return VStack(alignment: .leading, spacing: 0) {
            if model.sections.isEmpty {
                if model.scope == .files {
                    LauncherFilesEmpty()
                } else {
                    Text("Aucun résultat.")
                        .font(.ui(12.5)).foregroundStyle(Theme.text3).padding(18)
                }
            }
            ForEach(Array(model.sections.enumerated()), id: \.element.id) { si, section in
                Text(section.title.uppercased())
                    .font(.ui(11, .semibold)).tracking(0.66).foregroundStyle(Theme.text3)
                    .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 4)
                // Identified by their place in the whole list, like `.id(index)`: the arrows scroll to the right row,
                // never to the row of another section that has the same place in its own.
                ForEach(offsets[si]..<offsets[si] + section.items.count, id: \.self) { index in
                    let item = section.items[index - offsets[si]]
                    LauncherRow(command: item, selected: index == model.selection, hotkey: app.hotkeys.combo(for: item)?.display,
                                marked: LauncherModel.filePath(of: item).map(model.marked.contains) ?? false)
                        .modifier(LauncherFileDrag(command: item))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.rowFrames[index] = $0 }
                        .id(index)
                        .onTapGesture {
                            if model.actionsTarget != nil { model.closeActions(); return }
                            model.selection = index
                            // ⌘-click in the file window picks the file (and opens nothing).
                            if NSEvent.modifierFlags.contains(.command), model.toggleMark(item) { return }
                            model.runSelected()
                        }
                        // Every movement of the pointer (not only entering a row): after a trackpad scroll,
                        // the row under the pointer is selected as soon as the mouse moves again.
                        .onContinuousHover { phase in
                            if case .active = phase { model.hover(index) }
                        }
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var footer: some View {
        let model = app.launcher
        let onFile = model.selectedFile != nil
        let primary = model.selectedPrimary
        let picking = model.scope == .files
        let picked = model.marked.count
        return HStack(spacing: 14) {
            // Opens the app on the dashboard (from the file window: on Raccourcis, where its index is set up).
            Button {
                model.hide()
                if model.scope == .files {
                    app.hotkeys.show(.chamois, app: app)
                } else {
                    LauncherAppActions.openMain(app, .dashboard)
                }
            } label: {
                HStack(spacing: 5) {
                    BrandMark(size: 11)
                    Text("Chamois").font(.serif(12))
                }
                .foregroundStyle(Theme.text2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.scope == .files ? "Réglages de la recherche de fichiers" : "Ouvrir Chamois sur le tableau de bord")
            if picked == 0 { hint("↑↓", "Naviguer") }
            if !onFile { hint("⌘↩", "Action secondaire") }
            if onFile, picking { hint("⌘↩", model.selectedFile.map(model.marked.contains) == true ? "Retirer" : "Sélectionner") }
            if onFile, model.selectedFile.map(model.isFolder) == true { hint("⇥", "Entrer") }
            if onFile, picked == 0 { hint("⌘Y", "Coup d'œil") }
            hint("⎋", picked > 0 && model.query.isEmpty ? "Désélectionner" : "Fermer")
            Spacer(minLength: 8)
            if picked > 0 { LauncherPickedChip(count: picked) { model.marked = [] } }
            if let primary {
                HStack(spacing: 6) {
                    Text(primary).font(.ui(12, .medium)).foregroundStyle(Theme.text)
                    LauncherKeyCaps(keys: ["↩"])
                }
                Rectangle().fill(Theme.border).frame(width: 1, height: 16)
                Button {
                    model.toggleActions()
                } label: {
                    HStack(spacing: 6) {
                        Text("Actions").font(.ui(12, .medium)).foregroundStyle(Theme.text2)
                        LauncherKeyCaps(keys: ["⌘", "K"])
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Toutes les actions sur ce résultat")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background(Theme.fill1)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        LauncherKeyHint(key: key, label: label)
    }

    private static func offsets(_ sections: [LauncherSection]) -> [Int] {
        var out: [Int] = []
        var n = 0
        for s in sections { out.append(n); n += s.items.count }
        return out
    }
}

struct LauncherRow: View {
    var command: AppCommand
    var selected: Bool
    /// The keyboard shortcut given to this result in Raccourcis, shown like Raycast does.
    var hotkey: String? = nil
    /// Picked in the file window (⌘-click or ⌘↩), to be dragged with the others.
    var marked = false

    var body: some View {
        HStack(spacing: 12) {
            CommandIconView(icon: command.icon, size: 24)
                .overlay(alignment: .bottomTrailing) {
                    if marked {
                        Image(systemName: "checkmark")
                            .font(.ui(7.5, .heavy)).foregroundStyle(Theme.onAccent)
                            .frame(width: 14, height: 14)
                            .background(PillShape().fill(Theme.accent))
                            .overlay(PillShape().strokeBorder(Theme.bg, lineWidth: 1.5))
                            .offset(x: 4, y: 4)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title).font(.ui(13, selected ? .medium : .regular)).foregroundStyle(Theme.text).lineLimit(1)
                if let s = command.subtitle, !s.isEmpty {
                    Text(s).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if case .confirm = command.risk {
                Image(systemName: "exclamationmark.shield").font(.ui(11)).foregroundStyle(Theme.warn).help("Demande confirmation")
            }
            if selected, let h = command.hint {
                Text(h).font(.ui(11)).foregroundStyle(Theme.text3)
            }
            if let hotkey {
                Text(hotkey).font(.ui(10.5, .semibold)).foregroundStyle(Theme.text2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: Theme.r(5), style: .continuous).fill(Theme.fill2))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        // The active row carries the glass bubble; files picked for a drag keep the faint accent.
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous)
            if marked { shape.fill(Theme.accentSoft).overlay { shape.strokeBorder(Theme.accentRim, lineWidth: Theme.line) } }
            if selected { StillBubble(radius: 8) }
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

/// The footer of the file window once files are picked: how many, and a way to let go of them all.
struct LauncherPickedChip: View {
    var count: Int
    var clear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").font(.ui(11.5, .semibold)).foregroundStyle(Theme.accent)
            // How to use them, when the footer has room for it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    label
                    Text("· glisse pour copier").font(.ui(11)).foregroundStyle(Theme.text3)
                }
                label
            }
            Button(action: clear) {
                Image(systemName: "xmark").font(.ui(9, .bold)).foregroundStyle(Theme.text3)
                    .frame(width: 16, height: 16)
                    .background(PillShape().fill(Theme.track))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Tout désélectionner (⎋)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(PillShape().fill(Theme.accent.opacity(0.12)))
        .help("Glisse l'un d'eux hors de la fenêtre : ils sont tous copiés là où tu les lâches (jamais déplacés).")
    }

    private var label: some View {
        Text(Fmt.plural(count, "sélectionné", "sélectionnés")).font(.ui(12, .medium)).foregroundStyle(Theme.text).fixedSize()
    }
}

struct CommandIconView: View {
    var icon: CommandIcon
    var size: CGFloat = 24

    var body: some View {
        switch icon {
        case .symbol(let name, let tint):
            // A neutral vignette, unless the theme tints its icons.
            let tinted = Theme.icons == .tinted
            Image(systemName: name)
                .font(.system(size: size * 0.48, weight: .medium))
                .foregroundStyle(tinted ? tint : Theme.text2)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Theme.r(size * 0.26), style: .continuous).fill(tinted ? tint.opacity(0.13) : Theme.fill2))
        case .file(let path):
            FileIcon(path: path, size: size)
        case .emoji(let e):
            Text(e).font(.system(size: size * 0.78)).frame(width: size, height: size)
        case .color(let c):
            RoundedRectangle(cornerRadius: Theme.r(size * 0.26)).fill(c).frame(width: size, height: size)
                .overlay(RoundedRectangle(cornerRadius: Theme.r(size * 0.26)).strokeBorder(Theme.borderStrong, lineWidth: Theme.line))
        case .spark:
            BrandMark(size: size * 0.8).frame(width: size, height: size)
        }
    }
}

/// ⌘K: the panel waits for the keys of the new shortcut.
struct LauncherAssignView: View {
    @Environment(AppModel.self) private var app
    var target: HotkeysTarget
    var title: String

    var body: some View {
        let current = app.hotkeys.binding(for: target)?.combo
        VStack(spacing: 18) {
            Spacer()
            CommandIconView(icon: app.hotkeys.icon(target), size: 56)
            VStack(spacing: 6) {
                Text("Un raccourci pour « \(title) »").font(.serif(24)).foregroundStyle(Theme.text)
                Text(target.kind).font(.ui(12)).foregroundStyle(Theme.text3)
            }
            Text(current?.display ?? "Tape les touches…")
                .font(.ui(26, .semibold))
                .foregroundStyle(current == nil ? Theme.text3 : Theme.text)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: Theme.r(12)).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.r(12)).strokeBorder(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            Text(app.launcher.assignMessage ?? (current == nil
                 ? "Avec ⌘, ⌃ ou ⌥. Il marchera partout, même quand Chamois est caché."
                 : "Tape d'autres touches pour le changer."))
                .font(.ui(12.5)).foregroundStyle(app.launcher.assignMessage == nil ? Theme.text2 : Theme.warn)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Spacer()
            HStack(spacing: 16) {
                LauncherKeyHint(key: "⌫", label: current == nil ? "Aucun raccourci" : "Retirer le raccourci")
                LauncherKeyHint(key: "⎋", label: "Annuler")
                Spacer()
                Text("Tous tes raccourcis : section Raccourcis").font(.ui(11)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Theme.fill1)
        }
    }
}

/// A key and what it does, in the panel's footers.
struct LauncherKeyHint: View {
    var key: String
    var label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key).font(.ui(10.5, .semibold)).foregroundStyle(Theme.text2)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: Theme.r(5), style: .continuous).fill(Theme.fill2))
            Text(label).font(.ui(11)).foregroundStyle(Theme.text3)
        }
    }
}

/// A file, a folder or an app of the results can be dragged anywhere (Finder, Mail, a message, the Desktop…).
/// A file or a folder is copied there, with the other picked files if it is one of them (see `LauncherDrag`).
struct LauncherFileDrag: ViewModifier {
    @Environment(AppModel.self) private var app
    var command: AppCommand

    func body(content: Content) -> some View {
        if let path = LauncherModel.filePath(of: command), !DemoData.isEnabled {
            content.simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in app.launcher.beginFileDrag(path, fromRow: true) })
        } else if case .file(let path) = command.icon, command.group == .apps, !DemoData.isEnabled {
            content.onDrag {
                let provider = NSItemProvider(object: URL(fileURLWithPath: path) as NSURL)
                provider.suggestedName = (path as NSString).lastPathComponent
                return provider
            } preview: {
                LauncherDragPreview(path: path)
            }
        } else {
            content
        }
    }
}

/// What follows the pointer while dragging: the file's icon and name.
struct LauncherDragPreview: View {
    var path: String

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(path: path, size: 32)
            Text((path as NSString).lastPathComponent).font(.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Theme.r(9)).fill(Theme.cardRaised))
    }
}

/// The file window's index, at the right of its search field: instant, being built, or Spotlight.
struct LauncherIndexBadge: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.launcher.indexState {
        case .ready(let count): Tag(text: "Index · " + Fmt.plural(count, "fichier", "fichiers"), symbol: "bolt.fill", tint: Theme.good, filled: true)
        case .building:
            HStack(spacing: 6) {
                BusyMascot(.sorting, pixel: 1)
                Tag(text: "Indexation…", tint: Theme.text2)
            }
        case .off: Tag(text: "Spotlight", symbol: "magnifyingglass", tint: Theme.text2)
        }
    }
}

/// The file window with nothing to show: what to type, Spotlight at work, or nothing found.
struct LauncherFilesEmpty: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.launcher
        let q = m.query.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 12) {
            if q.isEmpty {
                Text("Tape le nom d'un fichier ou d'un dossier.").font(.ui(14, .medium)).foregroundStyle(Theme.text)
                VStack(alignment: .leading, spacing: 7) {
                    tip("~/Documents/", "parcourt tes dossiers (⇥ entre dans le dossier choisi)")
                    tip("dans devis cuisine", "cherche aussi dans le contenu des fichiers")
                    tip("⌘K", "les actions du fichier choisi : ouvrir avec, convertir, partager, mettre à la corbeille…")
                    tip("⌘-clic", "choisit plusieurs fichiers (⌘↩ au clavier) ; glisse-les, ils sont copiés là où tu les lâches")
                }
                if m.indexState == .off, !DemoData.isEnabled {
                    Text("Pour l'instant, c'est Spotlight qui cherche (une seconde ou plus). L'index instantané répond en un millième de seconde ; sans l'accès complet au disque, macOS te demandera d'autoriser Documents, Bureau et Téléchargements.")
                        .font(.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    Button("Activer la recherche instantanée") { m.enableIndex() }
                        .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                }
            } else if m.fileSearchPending {
                HStack(spacing: 12) {
                    BusyMascot(.searching, pixel: 2)
                    Text("Spotlight cherche « \(q) »…").font(.ui(12.5)).foregroundStyle(Theme.text3)
                }
            } else {
                Text(q.count < 2 ? "Tape au moins deux lettres." : "Aucun fichier ne correspond à « \(q) ».")
                    .font(.ui(12.5)).foregroundStyle(Theme.text3)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(18)
    }

    private func tip(_ typed: String, _ what: String) -> some View {
        HStack(spacing: 10) {
            Text(typed).font(.mono(11.5, .medium)).foregroundStyle(Theme.text)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: Theme.r(5), style: .continuous).fill(Theme.fill2))
            Text(what).font(.ui(12)).foregroundStyle(Theme.text3)
        }
    }
}
