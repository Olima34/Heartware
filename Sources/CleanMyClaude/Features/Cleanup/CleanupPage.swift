import SwiftUI

struct CleanupPage: View {
    @Environment(AppModel.self) private var app

    static let tip = HelpTip(id: "cleanup.page", title: "Le nettoyage",
                             text: "Je mesure chaque catégorie sans rien toucher, puis tu coches ce qui part. Caches et journaux se reconstruisent seuls ; tes fichiers personnels passent par la Corbeille, et ce qu'utilise une app ouverte reste verrouillé. Je garde exprès tes transcripts de Claude Code et ce que l'app Claude gère elle-même.")

    var body: some View {
        let model = app.cleanup
        VStack(alignment: .leading, spacing: 18) {
            PageHero(symbol: "sparkles", title: "Nettoyage du système",
                     subtitle: "Je trouve ce qui encombre ton Mac, tu choisis ce qui part.",
                     seed: 21, tip: Self.tip) {
                ScanButton(title: model.hasResults ? "Relancer l'analyse" : "Analyser", running: model.isScanning, activity: .sweeping) {
                    Task { await model.scan() }
                }
            }

            if model.isScanning {
                ScanProgressCard(title: "J'inspecte les recoins de ton Mac…", label: model.progressLabel, progress: model.progress, activity: .sweeping)
            } else if !model.hasResults {
                CleanupIntro()
            } else {
                summary(model)
                if let r = model.lastReport {
                    Callout(symbol: r.failures.isEmpty ? "checkmark.seal" : "exclamationmark.triangle",
                            title: r.freed > 0 ? "\(Fmt.bytes(r.freed)) libérés" : "Nettoyage terminé",
                            text: r.summary,
                            tint: r.failures.isEmpty ? Theme.good : Theme.warn)
                }
                CleanupGroupList()
            }
        }
    }

    private func summary(_ model: CleanupModel) -> some View {
        let items = model.targets.reduce(0) { $0 + $1.items.count }
        return DashboardMetricStrip(metrics: [
            DashboardMetric(symbol: "magnifyingglass", value: Fmt.bytes(model.totalSize), label: "Trouvé",
                            detail: Fmt.plural(items, "élément", "éléments")),
            DashboardMetric(symbol: "hand.thumbsup", value: Fmt.bytes(model.recommendedSize), label: "Sans risque",
                            detail: "se reconstruit seul", tint: Theme.brand),
            DashboardMetric(symbol: "leaf", value: Fmt.bytes(app.history.totalFreed), label: "Libéré au total",
                            detail: app.history.runs > 0 ? "en \(Fmt.plural(app.history.runs, "nettoyage", "nettoyages"))" : nil,
                            tint: Theme.palette[2])
        ])
    }
}

// MARK: - Intro

struct CleanupIntro: View {
    var body: some View {
        Card(padding: 22) {
            HStack(alignment: .center, spacing: 20) {
                PixelMascot(pixel: 3)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Prêt quand tu l'es").font(.serif(22)).foregroundStyle(Theme.text)
                    Text("Je mesure tout sans rien toucher, puis tu choisis.").font(.ui(13)).foregroundStyle(Theme.text2)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(CleanupGroup.allCases) { g in
                            Tag(text: g.title, symbol: g.symbol, tint: Theme.color(index: g.tint))
                                .help(g.blurb)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Progress

/// The waiting card of a page: the mascot at work, what is being looked at, how far along.
struct ScanProgressCard: View {
    var title: String
    var label: String
    var progress: Double?
    var activity: MascotActivity = .inspecting

    var body: some View {
        Card(padding: 22) {
            HStack(spacing: 18) {
                BusyMascot(activity, pixel: 4)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.serif(20)).foregroundStyle(Theme.text)
                    Text(label.isEmpty ? " " : label)
                        .font(.ui(12))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let progress {
                        UsageBar(fraction: progress, tint: Theme.accent, height: 6)
                            .animation(.easeOut(duration: 0.25), value: progress)
                    } else {
                        ScanIndeterminateBar()
                    }
                }
            }
        }
    }
}

/// A bar for a task that gives no progress (a still, partly filled bar in snapshots, where AppKit controls do not render).
struct ScanIndeterminateBar: View {
    var body: some View {
        if Snapshot.isActive {
            UsageBar(fraction: 0.35, tint: Theme.accent, height: 6)
        } else {
            ProgressView().progressViewStyle(.linear).tint(Theme.accent)
        }
    }
}

// MARK: - Groups

/// Every category in one card, one line each: a click unfolds its contents.
struct CleanupGroupList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let groups = CleanupGroup.allCases.filter { !app.cleanup.targets(in: $0).isEmpty }
        Card(padding: 0) {
            VStack(spacing: 0) {
                ForEach(groups) { g in
                    CleanupGroupRow(group: g)
                    if g != groups.last {
                        Rectangle().fill(Theme.border).frame(height: max(1, Theme.line))
                    }
                }
            }
        }
    }
}

struct CleanupGroupRow: View {
    @Environment(AppModel.self) private var app
    var group: CleanupGroup
    @State private var hovering = false

    var body: some View {
        let model = app.cleanup
        let tint = Theme.color(index: group.tint)
        let targets = model.targets(in: group)
        let open = model.openGroups.contains(group) || targets.contains { model.expanded.contains($0.id) }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CheckBox(state: model.state(of: group), disabled: targets.allSatisfy { $0.cleanable.isEmpty }) {
                    model.toggle(group)
                }
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        if open {
                            model.openGroups.remove(group)
                            for t in targets { model.expanded.remove(t.id) }
                        } else {
                            model.openGroups.insert(group)
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        IconBadge(symbol: group.symbol, tint: tint, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title).font(.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                            Text(group.blurb).font(.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.tail)
                        }
                        .help(group.blurb)
                        Spacer(minLength: 10)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Fmt.bytes(model.size(of: group))).font(.serif(18)).foregroundStyle(Theme.text).monospacedDigit()
                            let sel = model.selectedSize(of: group)
                            Text(sel > 0 ? "\(Fmt.bytes(sel)) cochés" : "rien de coché")
                                .font(.ui(11)).foregroundStyle(sel > 0 ? Theme.text2 : Theme.text3)
                        }
                        Image(systemName: "chevron.right")
                            .font(.ui(11, .semibold))
                            .foregroundStyle(Theme.text3)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 24, height: 24)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "Replier" : "Voir le détail")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(hovering ? Theme.hover.opacity(0.35) : .clear)
            .onHover { hovering = $0 }

            if open {
                VStack(spacing: 0) {
                    ForEach(targets) { t in
                        Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 1).padding(.leading, 52)
                        CleanupTargetRow(target: t, tint: tint)
                    }
                }
                .padding(.leading, 24)
                .padding(.bottom, 4)
            }
        }
    }
}

struct CleanupTargetRow: View {
    @Environment(AppModel.self) private var app
    var target: CleanupTarget
    var tint: Color
    @State private var showAll = false

    var body: some View {
        let model = app.cleanup
        let open = model.expanded.contains(target.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                CheckBox(state: model.state(of: target), disabled: target.cleanable.isEmpty) { model.toggle(target) }
                Image(systemName: target.symbol)
                    .font(.ui(13))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(target.title).font(.ui(13, .medium)).foregroundStyle(Theme.text)
                        if target.mode == .trash { Tag(text: "Corbeille", symbol: "arrow.uturn.backward", tint: Theme.text3) }
                    }
                    Text(target.explanation).font(.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1).help(target.explanation)
                }
                Spacer(minLength: 8)
                if target.needsFullDiskAccess {
                    Button("Accès complet requis") { Finder.open(Permissions.fullDiskAccessURL) }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .help("macOS protège ce dossier : accorde l'accès complet au disque à \(AppEdition.name)")
                } else {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Fmt.bytes(target.size)).font(.ui(13, .medium)).foregroundStyle(Theme.text).monospacedDigit()
                        let locked = target.items.count - target.cleanable.count
                        if locked > 0 {
                            Label("\(locked) verrouillé\(locked > 1 ? "s" : "") (app ouverte)", systemImage: "lock")
                                .font(.ui(10.5)).foregroundStyle(Theme.warn)
                        } else {
                            Text(Fmt.plural(target.items.count, "élément", "éléments")).font(.ui(10.5)).foregroundStyle(Theme.text3)
                        }
                    }
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            if open { model.expanded.remove(target.id) } else { model.expanded.insert(target.id) }
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.ui(11, .semibold))
                            .foregroundStyle(Theme.text3)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(open ? "Masquer le détail" : "Voir le détail")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if open {
                let items = showAll ? target.items : Array(target.items.prefix(25))
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        CleanupItemRow(item: item)
                    }
                    if target.items.count > 25 {
                        Button(showAll ? "Afficher moins" : "Afficher les \(target.items.count - 25) autres") {
                            withAnimation { showAll.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.accent)
                        .padding(.vertical, 8)
                    }
                }
                .padding(.leading, 50)
                .padding(.trailing, 16)
                .padding(.bottom, 10)
            }
        }
    }
}

struct CleanupItemRow: View {
    @Environment(AppModel.self) private var app
    var item: CleanupItem
    @State private var hovering = false

    var body: some View {
        let model = app.cleanup
        HStack(spacing: 10) {
            CheckBox(state: model.selection.contains(item.id) ? .on : .off, disabled: item.blockedReason != nil) {
                model.toggle(item)
            }
            FileIcon(path: item.path, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.ui(12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                if let reason = item.blockedReason {
                    Label(reason, systemImage: "lock").font(.ui(10.5)).foregroundStyle(Theme.warn)
                } else if let d = item.detail {
                    Text(d).font(.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if hovering {
                Button { Finder.reveal(item.path) } label: {
                    Image(systemName: "magnifyingglass").font(.ui(10.5)).foregroundStyle(Theme.text2)
                }
                .buttonStyle(.plain)
                .help("Afficher dans le Finder")
            }
            Text(Fmt.bytes(item.size)).font(.ui(11.5)).foregroundStyle(Theme.text2).monospacedDigit()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: Theme.r(7)).fill(hovering ? Theme.hover.opacity(0.5) : .clear))
        .onHover { hovering = $0 }
        .help(FS.pretty(item.path))
    }
}

// MARK: - Bottom bar

struct CleanupActionBar: View {
    @Environment(AppModel.self) private var app
    @State private var confirm = false

    var body: some View {
        let model = app.cleanup
        ActionBar {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Fmt.bytes(model.selectedSize)) à libérer")
                    .font(.serif(18)).foregroundStyle(Theme.text).monospacedDigit()
                Text(Fmt.plural(model.selectedCount, "élément sélectionné", "éléments sélectionnés"))
                    .font(.ui(11)).foregroundStyle(Theme.text3)
            }
            Spacer()
            Button("Sélection conseillée") { model.selectRecommended() }
                .buttonStyle(SoftButtonStyle())
            Button("Tout décocher") { model.clearSelection() }
                .buttonStyle(SoftButtonStyle())
                .disabled(model.selection.isEmpty)
            Button {
                confirm = true
            } label: {
                HStack(spacing: 6) {
                    if model.isCleaning { BusyMascot(.sweeping, pixel: 1, ink: Theme.onAccent) }
                    Text(model.isCleaning ? "Nettoyage…" : "Nettoyer")
                }
            }
            .buttonStyle(SoftButtonStyle(prominent: true))
            .disabled(model.selection.isEmpty || model.isCleaning)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .confirmAction("Nettoyer \(Fmt.bytes(model.selectedSize)) ?", message: confirmMessage(model),
                       button: "Nettoyer", isPresented: $confirm) {
            Task { await model.clean() }
        }
    }

    private func confirmMessage(_ model: CleanupModel) -> String {
        var parts: [String] = []
        if model.selectedDeletesForGood { parts.append("Les caches, journaux et la Corbeille seront supprimés définitivement : les apps recréent ce dont elles ont besoin.") }
        if model.selectedNeedsTrash { parts.append("Tes fichiers personnels iront dans la Corbeille : tu pourras encore les récupérer.") }
        if Preferences.alwaysTrash { parts = ["Tout ira dans la Corbeille (réglage « Toujours passer par la Corbeille »)."] }
        return parts.joined(separator: "\n\n")
    }
}

/// The bar pinned at the bottom of a page.
struct ActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .background(Theme.bg.opacity(0.6))
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
