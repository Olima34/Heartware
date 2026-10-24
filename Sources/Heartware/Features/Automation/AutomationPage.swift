import SwiftUI
import AppKit

struct AutomationPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.automation
        VStack(alignment: .leading, spacing: 18) {
            PageHero(symbol: Page.automation.symbol, title: "Automatisations",
                     subtitle: "Ton Mac s'entretient tout seul, selon tes règles.",
                     tint: Theme.warn, seed: 73, tip: Self.tip(model.tab)) {
                PillPicker(options: AutomationTab.allCases, selection: Binding(get: { model.tab }, set: { model.tab = $0 }),
                           label: { $0.title })
            }
            switch model.tab {
            case .rules: AutomationRulesTab()
            case .downloads: AutomationDownloadsTab()
            case .health: AutomationHealthView()
            case .journal: AutomationJournalTab()
            }
        }
    }

    /// The first visit to each tab explains it once.
    static func tip(_ tab: AutomationTab) -> HelpTip {
        switch tab {
        case .rules, .journal:
            return HelpTip(id: "automation.rules", title: "Tes automatisations",
                           text: "Tout est éteint au départ. Avant d'activer une règle, tu vois ce qu'elle ferait maintenant, sans que rien ne bouge ; ensuite elle passe toute seule, et se coupe d'un clic. Chaque passage est noté dans le Journal.")
        case .downloads:
            return HelpTip(id: "automation.downloads", title: "Ranger les téléchargements",
                           text: "Seul le premier niveau du dossier est regardé. Les téléchargements en cours (.crdownload, .part, .download), les fichiers cachés, les dossiers et ce qui a bougé il y a moins de 10 minutes sont laissés tranquilles. La première règle qui correspond s'applique ; un fichier déplacé ne remplace jamais un fichier existant (« photo.jpg » devient « photo 2.jpg »).")
        case .health:
            return HelpTip(id: "automation.health", title: "L'historique de santé",
                           text: "Un instantané par jour où le Mac a servi : espace libre, mémoire, batterie, score de santé et fichiers inutiles. Il pèse quelques centaines d'octets et reste sur ton Mac, dans le dossier de données de l'app.")
        }
    }
}

/// The action bar: runs the downloads rules once their dry run is on screen.
struct AutomationBottomBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.automation
        if model.tab == .downloads, let preview = model.downloadsPreview, !preview.moves.isEmpty {
            let size = preview.moves.reduce(Int64(0)) { $0 + $1.file.size }
            let trashed = preview.moves.filter { $0.action == .trash }.count
            ActionBar {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.plural(preview.moves.count, "fichier à ranger", "fichiers à ranger"))
                        .font(.serif(18)).foregroundStyle(Theme.text).monospacedDigit()
                    Text("\(Fmt.bytes(size)) · \(trashed > 0 ? "\(trashed) vers la Corbeille, " : "")rien n'est supprimé définitivement")
                        .font(.ui(11)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Button {
                    Task { await model.preview(.downloads) }
                } label: {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SoftButtonStyle())
                Button {
                    AutomationUI.run("auto_tidy_downloads", app: app)
                } label: {
                    Text(model.busy.contains(.downloads) ? "Rangement…" : "Ranger maintenant")
                }
                .buttonStyle(SoftButtonStyle(prominent: true))
                .disabled(model.busy.contains(.downloads))
            }
        }
    }
}

/// Shared helpers of the page.
@MainActor
enum AutomationUI {
    /// Runs one of the module's launcher commands: same confirmation, same feedback.
    static func run(_ id: String, app: AppModel) {
        guard let c = app.automation.commands(app: app).first(where: { $0.id == id }) else { return }
        Task { await CommandRunner.execute(c, app: app) }
    }

    /// "dans 3 h", "dans 4 j"…
    static func until(_ d: Date, now: Date = Date()) -> String {
        let s = d.timeIntervalSince(now)
        if s < 90 { return "dans un instant" }
        if s < 3600 { return "dans \(Int(s / 60)) min" }
        if s < 86400 { return "dans \(Int((s / 3600).rounded())) h" }
        return "dans \(Int((s / 86400).rounded())) j"
    }

    /// "Téléchargements" for the default folder, "~/…" otherwise.
    static func folderName(_ path: String) -> String {
        path == AutomationDownloads.defaultFolder ? "Téléchargements" : FS.pretty(path)
    }

    static func chooseFolder(start: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choisir"
        if let start, FS.isDirectory(start) { panel.directoryURL = URL(fileURLWithPath: start) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: - Rules tab

private struct AutomationRulesTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.automation
        let next = AutomationKind.allCases.compactMap { k in model.nextRun(k).map { (k, $0) } }.min { $0.1 < $1.1 }
        let last = model.journal.first { $0.setting != true }
        VStack(alignment: .leading, spacing: 14) {
            if let notice = model.integrityNotice {
                VStack(alignment: .trailing, spacing: 8) {
                    Callout(symbol: "exclamationmark.shield", title: "Automatisations coupées par prudence", text: notice, tint: Theme.warn)
                    Button("J'ai compris") { model.integrityNotice = nil }
                        .buttonStyle(SoftButtonStyle(small: true))
                }
            }
            // One strip instead of four tiles: the numbers, without the boxes.
            Card(padding: 12) {
                HStack(spacing: 0) {
                    figure("\(model.activeCount) sur \(AutomationKind.allCases.count)", "actives")
                    figure(next.map { AutomationUI.until($0.1) } ?? "—", next.map { "prochain passage · \($0.0.title)" } ?? "prochain passage")
                    figure(Fmt.bytes(model.handled(days: 30)), "rangés ou libérés en 30 jours")
                    figure(last.map { Fmt.relative($0.date) } ?? "—", last.map { "dernier passage · \($0.title)" } ?? "dernier passage")
                }
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    AutomationCleanupCard()
                    AutomationTrashCard()
                }
                VStack(spacing: 14) {
                    AutomationDownloadsCard()
                    AutomationHealthCard()
                    AutomationAlertsCard()
                }
            }
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.serif(18)).foregroundStyle(Theme.text).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Title, state and explanation of an automation card.
private struct AutomationCardHeader: View {
    @Environment(AppModel.self) private var app
    var kind: AutomationKind
    var text: String

    var body: some View {
        let model = app.automation
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: kind.symbol, tint: kind.tint, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(kind.title).font(.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                    if model.isEnabled(kind) {
                        StatusBadge(status: .ok, text: "Active")
                    } else if model.pending == kind {
                        Tag(text: "Aperçu avant activation", symbol: "eye", tint: Theme.warn, filled: true)
                    } else {
                        Tag(text: "Désactivée", symbol: "pause.circle", tint: Theme.text3)
                    }
                }
                Text(text).font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// "Prochain passage dans 4 j · dernier il y a 3 j"
private struct AutomationScheduleLine: View {
    @Environment(AppModel.self) private var app
    var kind: AutomationKind

    var body: some View {
        let model = app.automation
        if let next = model.nextRun(kind) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock").font(.ui(11)).foregroundStyle(Theme.text3)
                Text("Prochain passage \(AutomationUI.until(next)) (\(Fmt.day(next)))"
                     + (model.lastRun(kind).map { " · dernier \(Fmt.relative($0))" } ?? ""))
                    .font(.ui(11.5)).foregroundStyle(Theme.text2)
            }
        }
    }
}

/// The buttons of a card, depending on its state: off, dry run before activation, on.
private struct AutomationControls: View {
    @Environment(AppModel.self) private var app
    var kind: AutomationKind
    var commandID: String

    var body: some View {
        let model = app.automation
        let busy = model.busy.contains(kind)
        HStack(spacing: 8) {
            if model.isEnabled(kind) {
                Button("Exécuter maintenant") { AutomationUI.run(commandID, app: app) }
                    .buttonStyle(SoftButtonStyle(small: true))
                    .disabled(busy)
                Button(model.shownPreviews.contains(kind) ? "Masquer l'aperçu" : "Aperçu à blanc") { model.togglePreview(kind) }
                    .buttonStyle(SoftButtonStyle(small: true))
                Spacer()
                Button("Désactiver") { model.deactivate(kind) }
                    .buttonStyle(SoftButtonStyle(small: true))
            } else if model.pending == kind {
                Button("Activer") { model.confirmActivation(kind) }
                    .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                    .disabled(busy)
                Button("Annuler") { model.pending = nil }
                    .buttonStyle(SoftButtonStyle(small: true))
                Spacer()
                Text("Ceci n'est qu'un aperçu : rien n'a bougé.").font(.ui(11)).foregroundStyle(Theme.text3)
            } else {
                Button {
                    model.beginActivation(kind)
                } label: {
                    Label("Voir l'aperçu et activer", systemImage: "eye")
                }
                .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                Button("Exécuter une fois") { AutomationUI.run(commandID, app: app) }
                    .buttonStyle(SoftButtonStyle(small: true))
                    .disabled(busy)
                Spacer()
            }
        }
    }
}

/// A framed list inside a card for the dry run.
private struct AutomationPreviewBox<Content: View>: View {
    var title: String
    var busy: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: busy ? "hourglass" : "eye").font(.ui(10.5, .semibold)).foregroundStyle(Theme.text3)
                Text(busy ? "Aperçu en cours…" : title).font(.ui(11, .semibold)).foregroundStyle(Theme.text3)
            }
            if !busy { content }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.r(10)).fill(Theme.bg.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(10)).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: Theme.line, dash: [4, 3])))
    }
}

private struct AutomationPreviewRow: View {
    var symbol: String? = nil
    var path: String? = nil
    var title: String
    var detail: String
    var value: String

    var body: some View {
        HStack(spacing: 8) {
            if let path {
                FileIcon(path: path, size: 18)
            } else if let symbol {
                Image(systemName: symbol).font(.ui(11)).foregroundStyle(Theme.text3).frame(width: 18)
            }
            Text(title).font(.ui(12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            Text(detail).font(.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
            Spacer(minLength: 6)
            Text(value).font(.ui(11.5, .medium)).foregroundStyle(Theme.text2).monospacedDigit()
        }
    }
}

private struct AutomationCleanupCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.automation
        let showPreview = model.pending == .cleanup || model.shownPreviews.contains(.cleanup)
        Card {
            AutomationCardHeader(kind: .cleanup,
                                 text: "Les caches et journaux cochés par défaut dans Nettoyage. Jamais la Corbeille ni tes fichiers.")
            HStack {
                Text("Fréquence").font(.ui(12)).foregroundStyle(Theme.text2)
                Spacer()
                PillPicker(options: [AutomationFrequency.weekly, .monthly],
                           selection: Binding(get: { model.settings.cleanupFrequency }, set: { model.settings.cleanupFrequency = $0 }),
                           label: { $0.title })
            }
            AutomationScheduleLine(kind: .cleanup)
            if showPreview {
                let lines = model.cleanupPreview ?? []
                let total = lines.reduce(Int64(0)) { $0 + $1.size }
                AutomationPreviewBox(title: "Un passage maintenant libérerait \(Fmt.bytes(total))", busy: model.busy.contains(.cleanup)) {
                    if lines.isEmpty {
                        Text("Rien à nettoyer : ton Mac est déjà propre.").font(.ui(11.5)).foregroundStyle(Theme.text2)
                    }
                    ForEach(lines.prefix(6)) { l in
                        AutomationPreviewRow(symbol: l.symbol, title: l.title, detail: Fmt.plural(l.count, "élément", "éléments"), value: Fmt.bytes(l.size))
                    }
                    if lines.count > 6 {
                        Text("… et \(Fmt.plural(lines.count - 6, "autre catégorie", "autres catégories"))").font(.ui(10.5)).foregroundStyle(Theme.text3)
                    }
                }
            }
            AutomationControls(kind: .cleanup, commandID: "auto_cleanup_now")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private enum AutomationTrashAge: Int, CaseIterable, Identifiable {
    case week = 7, twoWeeks = 15, month = 30, twoMonths = 60, quarter = 90

    var id: Int { rawValue }
    var title: String { "\(rawValue) j" }
}

private struct AutomationTrashCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.automation
        let days = model.settings.trashDays
        let showPreview = model.pending == .trash || model.shownPreviews.contains(.trash)
        Card {
            AutomationCardHeader(kind: .trash,
                                 text: "Supprime définitivement ce qui dort dans la Corbeille depuis plus de \(days) jours.")
            HStack {
                Text("Plus ancien que").font(.ui(12)).foregroundStyle(Theme.text2)
                Spacer()
                PillPicker(options: AutomationTrashAge.allCases,
                           selection: Binding(get: { AutomationTrashAge(rawValue: days) ?? .month },
                                              set: { model.settings.trashDays = $0.rawValue }),
                           label: { $0.title })
            }
            AutomationScheduleLine(kind: .trash)
            if !app.fullDiskAccess {
                PermissionCard(permission: .fullDiskAccess,
                               reason: "macOS protège la Corbeille : sans l'accès complet au disque, impossible de savoir depuis quand chaque élément y est.")
            }
            if Preferences.alwaysTrash && !DemoData.isEnabled {
                Text("En pause : ton réglage « Toujours passer par la Corbeille » interdit les suppressions définitives.")
                    .font(.ui(11.5)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            if showPreview {
                let preview = model.trashPreview
                let expired = preview?.expired ?? []
                let total = expired.reduce(Int64(0)) { $0 + $1.size }
                AutomationPreviewBox(title: "Un passage maintenant supprimerait \(Fmt.plural(expired.count, "élément", "éléments")) (\(Fmt.bytes(total)))",
                                     busy: model.busy.contains(.trash)) {
                    if preview?.expired == nil {
                        Text("Corbeille illisible sans l'accès complet au disque.").font(.ui(11.5)).foregroundStyle(Theme.warn)
                    } else if expired.isEmpty {
                        Text("Rien n'y dort depuis plus de \(days) jours.").font(.ui(11.5)).foregroundStyle(Theme.text2)
                    }
                    ForEach(expired.prefix(6)) { item in
                        AutomationPreviewRow(path: item.path, title: item.name,
                                             detail: item.added.map { "à la Corbeille \(Fmt.relative($0))" } ?? "",
                                             value: Fmt.bytes(item.size))
                    }
                    if expired.count > 6 {
                        Text("… et \(Fmt.plural(expired.count - 6, "autre élément", "autres éléments"))").font(.ui(10.5)).foregroundStyle(Theme.text3)
                    }
                    if let preview, preview.total > expired.count {
                        Text("\(Fmt.plural(preview.total - expired.count, "élément plus récent reste", "éléments plus récents restent")) dans la Corbeille.")
                            .font(.ui(10.5)).foregroundStyle(Theme.text3)
                    }
                }
            }
            AutomationControls(kind: .trash, commandID: "auto_trash_old")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AutomationDownloadsCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.automation
        let rules = model.settings.rules
        let active = rules.filter { $0.enabled && !$0.isIncomplete }
        let showPreview = model.pending == .downloads || model.shownPreviews.contains(.downloads)
        Card {
            AutomationCardHeader(kind: .downloads,
                                 text: "Range ou met à la Corbeille les fichiers de \(AutomationUI.folderName(model.downloadsFolder)) selon tes règles.")
            HStack {
                Text("Fréquence").font(.ui(12)).foregroundStyle(Theme.text2)
                Spacer()
                PillPicker(options: [AutomationFrequency.hourly, .daily],
                           selection: Binding(get: { model.settings.downloadsFrequency }, set: { model.settings.downloadsFrequency = $0 }),
                           label: { $0.title })
            }
            AutomationScheduleLine(kind: .downloads)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(active.count) sur \(Fmt.plural(rules.count, "règle active", "règles actives"))").font(.ui(12)).foregroundStyle(Theme.text2)
                Spacer()
                Button {
                    model.tab = .downloads
                } label: {
                    Label("Gérer les règles", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(SoftButtonStyle(small: true))
            }
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(active) { r in
                    Tag(text: r.name, symbol: r.action == .trash ? "trash" : "folder", tint: Theme.warn, filled: true)
                }
            }
            if showPreview {
                let moves = model.downloadsPreview?.moves ?? []
                AutomationPreviewBox(title: "Un passage maintenant toucherait \(Fmt.plural(moves.count, "fichier", "fichiers"))",
                                     busy: model.busy.contains(.downloads)) {
                    if model.downloadsPreview?.unreadable == true {
                        Text("Dossier illisible : macOS demande ton accord pour Téléchargements.").font(.ui(11.5)).foregroundStyle(Theme.warn)
                    } else if moves.isEmpty {
                        Text("Rien à ranger : tout est déjà en ordre.").font(.ui(11.5)).foregroundStyle(Theme.text2)
                    }
                    ForEach(moves.prefix(5)) { m in
                        AutomationPreviewRow(path: m.file.path, title: m.file.name, detail: m.ruleName,
                                             value: m.destination.map { "→ " + ($0 as NSString).lastPathComponent } ?? "→ Corbeille")
                    }
                    if moves.count > 5 {
                        Button("Voir les \(moves.count) fichiers") { model.tab = .downloads }
                            .buttonStyle(.plain).font(.ui(11, .medium)).foregroundStyle(Theme.accent)
                    }
                }
            }
            AutomationControls(kind: .downloads, commandID: "auto_tidy_downloads")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AutomationHealthCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.automation
        let recent = AutomationHealth.window(model.samples, range: .month, now: Date())
        Card {
            AutomationCardHeader(kind: .health,
                                 text: "Un instantané par jour de l'espace, de la mémoire, de la batterie et du score de santé.")
            if recent.count > 1 {
                HStack(spacing: 12) {
                    // From 50 to 100: the part of the scale where the score actually moves.
                    Sparkline(values: recent.map { Double(max(0, $0.score - 50)) }, maxValue: 50, tint: Theme.good)
                        .frame(height: 34)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(recent.last?.score ?? 0)").font(.serif(22)).foregroundStyle(Theme.text)
                        Text("score du jour").font(.ui(10.5)).foregroundStyle(Theme.text3)
                    }
                }
            }
            HStack(spacing: 8) {
                if model.settings.healthEnabled {
                    Button {
                        model.tab = .health
                    } label: {
                        Label("Voir les graphiques", systemImage: "chart.xyaxis.line")
                    }
                    .buttonStyle(SoftButtonStyle(small: true))
                    Spacer()
                    Button("Désactiver") { model.setHealthEnabled(false, app: app) }
                        .buttonStyle(SoftButtonStyle(small: true))
                } else {
                    Button {
                        model.setHealthEnabled(true, app: app)
                    } label: {
                        Label("Commencer l'historique", systemImage: "waveform.path.ecg")
                    }
                    .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                    if !model.samples.isEmpty {
                        Button("Voir l'historique") { model.tab = .health }
                            .buttonStyle(SoftButtonStyle(small: true))
                    }
                    Spacer()
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The disk / memory / heat alerts: same switch as the menu bar page (`Preferences.alertsKey`).
private struct AutomationAlertsCard: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Preferences.alertsKey) private var alerts = false

    var body: some View {
        let model = app.automation
        let available = Alerts.available || DemoData.isEnabled
        Panel(title: "Alertes et notifications", symbol: "bell.badge", tint: Theme.bad) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { DemoData.isEnabled || alerts }, set: { on in
                    // The demo never writes the real preferences.
                    guard !DemoData.isEnabled else { return HUD.show(DemoData.refusal, symbol: "theatermasks") }
                    alerts = on
                    if on { Alerts.requestPermission() }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("M'alerter quand mon Mac est en difficulté").font(.ui(12.5)).foregroundStyle(Theme.text)
                        Text("Disque plein, mémoire saturée, chaleur critique").font(.ui(11)).foregroundStyle(Theme.text3)
                    }
                }
                .disabled(!available)
                .help("Disque plein à plus de 92 %, mémoire saturée (pression critique), chaleur critique qui ralentit le processeur. Au plus une alerte de chaque sorte toutes les 6 heures.")
                Rectangle().fill(Theme.border).frame(height: 1)
                Toggle(isOn: Binding(get: { model.settings.notify }, set: { model.settings.notify = $0 })) {
                    Text("Me prévenir après chaque passage automatique").font(.ui(12.5)).foregroundStyle(Theme.text)
                }
                .disabled(!available)
                if !available {
                    Text("Les notifications demandent l'app assemblée (scripts/build_app.sh).").font(.ui(11)).foregroundStyle(Theme.text3)
                }
            }
            .switchToggles()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Downloads tab

private struct AutomationDownloadsTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.automation
        VStack(alignment: .leading, spacing: 14) {
            Panel(title: "Dossier surveillé", symbol: "folder", tint: Theme.warn) {
                HStack(spacing: 8) {
                    if model.settings.downloadsFolder.isEmpty == false {
                        Button("Téléchargements") { model.settings.downloadsFolder = "" }
                            .buttonStyle(SoftButtonStyle(small: true))
                    }
                    Button("Changer…") {
                        if let path = AutomationUI.chooseFolder(start: model.downloadsFolder) {
                            if AutomationDownloads.isAllowedSource(path) {
                                model.settings.downloadsFolder = path == AutomationDownloads.defaultFolder ? "" : FS.pretty(path)
                            } else {
                                HUD.show("Choisis un dossier de ton dossier personnel, hors Bibliothèque, dossiers cachés et paquets.", symbol: "exclamationmark.triangle.fill")
                            }
                        }
                    }
                    .buttonStyle(SoftButtonStyle(small: true))
                }
            } content: {
                HStack(spacing: 10) {
                    FileIcon(path: model.downloadsFolder, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AutomationUI.folderName(model.downloadsFolder)).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
                            .help(model.downloadsFolder)
                        Text("Son premier niveau seulement, sans les téléchargements en cours")
                            .font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                            .help("Ignorés : .crdownload, .part, .download (en cours), les fichiers cachés, les dossiers et tout ce qui a bougé il y a moins de 10 minutes.")
                    }
                }
            }
            Panel(title: "Règles", subtitle: "Dans l'ordre : la première qui correspond s'applique. Rien n'est supprimé définitivement.",
                  symbol: "list.number", tint: Theme.warn) {
                Button {
                    model.addRule()
                } label: {
                    Label("Ajouter une règle", systemImage: "plus")
                }
                .buttonStyle(SoftButtonStyle(small: true))
            } content: {
                VStack(spacing: 4) {
                    if model.settings.rules.isEmpty {
                        EmptyHint(text: "Aucune règle. Ajoute-en une pour commencer.", symbol: "list.bullet")
                    }
                    ForEach(model.settings.rules) { rule in
                        AutomationRuleRow(rule: rule, first: rule.id == model.settings.rules.first?.id,
                                          last: rule.id == model.settings.rules.last?.id)
                        if model.editingRule == rule.id, let binding = model.binding(for: rule.id) {
                            AutomationRuleEditor(rule: binding)
                        }
                    }
                }
            }
            AutomationDownloadsPreviewPanel()
        }
    }
}

private struct AutomationRuleRow: View {
    @Environment(AppModel.self) private var app
    var rule: AutomationRule
    var first: Bool
    var last: Bool

    var body: some View {
        let model = app.automation
        let count = model.downloadsPreview?.moves.filter { $0.ruleID == rule.id }.count ?? 0
        HoverRow(selected: model.editingRule == rule.id) {
            HStack(spacing: 10) {
                CheckBox(state: rule.enabled ? .on : .off) {
                    if let b = model.binding(for: rule.id) { b.wrappedValue.enabled.toggle() }
                }
                IconBadge(symbol: rule.kinds.first?.symbol ?? "doc", tint: rule.enabled ? Theme.warn : Theme.text3, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name).font(.ui(12.5, .medium)).foregroundStyle(rule.enabled ? Theme.text : Theme.text3)
                    HStack(spacing: 5) {
                        Text(rule.condition)
                        Image(systemName: "arrow.right").font(.ui(9, .semibold))
                        Image(systemName: rule.action == .trash ? "trash" : "folder").font(.ui(9.5))
                        Text(rule.outcome).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.ui(11)).foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 8)
                if rule.isIncomplete {
                    StatusBadge(status: .warn, text: "À compléter")
                } else if rule.enabled && count > 0 {
                    Tag(text: Fmt.plural(count, "fichier", "fichiers"), tint: Theme.warn, filled: true)
                }
                HStack(spacing: 2) {
                    iconButton("chevron.up", help: "Monter") { model.moveRule(rule.id, by: -1) }.disabled(first)
                    iconButton("chevron.down", help: "Descendre") { model.moveRule(rule.id, by: 1) }.disabled(last)
                    iconButton(model.editingRule == rule.id ? "checkmark" : "pencil", help: "Modifier") {
                        model.editingRule = model.editingRule == rule.id ? nil : rule.id
                    }
                    iconButton("trash", help: "Supprimer la règle") {
                        if CommandRunner.confirm("Supprimer la règle « \(rule.name) » ?", "Les fichiers déjà rangés ne bougent pas.", button: "Supprimer") {
                            model.deleteRule(rule.id)
                        }
                    }
                }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.ui(11, .medium)).foregroundStyle(Theme.text2)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct AutomationRuleEditor: View {
    @Environment(AppModel.self) private var app
    @Binding var rule: AutomationRule
    @State private var extensions = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Nom") {
                if Snapshot.isActive {
                    Text(rule.name).font(.ui(12.5))
                } else {
                    TextField("Nom de la règle", text: $rule.name).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                }
            }
            row("Types") {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(AutomationFileKind.allCases) { k in
                        let on = rule.kinds.contains(k)
                        Button {
                            if on { rule.kinds.removeAll { $0 == k } } else { rule.kinds.append(k) }
                        } label: {
                            Tag(text: k.title, symbol: k.symbol, tint: on ? Theme.warn : Theme.text3, filled: on)
                        }
                        .buttonStyle(.plain)
                        .help(k.extensions.sorted().map { "." + $0 }.joined(separator: " "))
                    }
                }
            }
            row("Extensions") {
                if Snapshot.isActive {
                    Text(rule.extensions.joined(separator: ", ")).font(.ui(12.5))
                } else {
                    TextField("en plus, ex. torrent, epub", text: $extensions)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        .onChange(of: extensions) { _, text in rule.extensions = AutomationRule.parseExtensions(text) }
                }
            }
            row("Âge minimal") {
                PillPicker(options: AutomationAge.allCases,
                           selection: Binding(get: { AutomationAge(rawValue: rule.minAgeDays) ?? .week }, set: { rule.minAgeDays = $0.rawValue }),
                           label: { $0.title })
            }
            row("Action") {
                PillPicker(options: AutomationRuleAction.allCases, selection: $rule.action, label: { $0.title })
            }
            if rule.action == .move {
                row("Dossier") {
                    HStack(spacing: 8) {
                        Text(rule.destination.isEmpty ? "Aucun dossier choisi" : FS.pretty(FS.expand(rule.destination)))
                            .font(.ui(12)).foregroundStyle(rule.destination.isEmpty ? Theme.warn : Theme.text)
                        Button("Choisir…") {
                            if let path = AutomationUI.chooseFolder(start: FS.expand(rule.destination)) {
                                if AutomationDownloads.isAllowedDestination(path) {
                                    rule.destination = FS.pretty(path)
                                } else {
                                    HUD.show("Choisis un dossier de ton dossier personnel, hors Bibliothèque, dossiers cachés et paquets.",
                                             symbol: "exclamationmark.triangle.fill")
                                }
                            }
                        }
                        .buttonStyle(SoftButtonStyle(small: true))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Terminé") { app.automation.editingRule = nil }
                    .buttonStyle(SoftButtonStyle(prominent: true, small: true))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.r(10)).fill(Theme.bg.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(10)).strokeBorder(Theme.border, lineWidth: Theme.line))
        .padding(.leading, 36)
        .padding(.bottom, 6)
        .onAppear { extensions = rule.extensions.joined(separator: ", ") }
    }

    private func row<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.ui(12)).foregroundStyle(Theme.text2).frame(width: 90, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

private struct AutomationDownloadsPreviewPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.automation
        let preview = model.downloadsPreview
        let moves = preview?.moves ?? []
        Panel(title: "Aperçu à blanc", subtitle: "Ce que tes règles feraient maintenant, sans rien toucher",
              symbol: "eye", tint: Theme.warn) {
            Button {
                Task { await model.preview(.downloads) }
            } label: {
                Label(model.busy.contains(.downloads) ? "Aperçu…" : "Actualiser", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SoftButtonStyle(small: true))
            .disabled(model.busy.contains(.downloads))
        } content: {
            VStack(spacing: 2) {
                if preview?.unreadable == true {
                    Text("Dossier illisible : accepte la demande d'accès de macOS, ou accorde l'accès complet au disque.")
                        .font(.ui(12)).foregroundStyle(Theme.warn).frame(maxWidth: .infinity, alignment: .leading)
                } else if preview == nil {
                    EmptyHint(text: "« Actualiser » montre ce que tes règles feraient. macOS peut te demander l'accès au dossier.", symbol: "eye")
                } else if moves.isEmpty {
                    EmptyHint(text: "Rien à ranger parmi les \(Fmt.plural(preview?.files ?? 0, "élément", "éléments")) du dossier : tout est en ordre.",
                              symbol: "checkmark.circle")
                }
                ForEach(moves.prefix(60)) { m in
                    HoverRow {
                        HStack(spacing: 10) {
                            FileIcon(path: m.file.path, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.file.name).font(.ui(12.5)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                Text("\(m.ruleName) · arrivé \(m.file.added.map(Fmt.relative) ?? "?")").font(.ui(10.5)).foregroundStyle(Theme.text3)
                            }
                            Spacer(minLength: 8)
                            Text(Fmt.bytes(m.file.size)).font(.ui(11.5)).foregroundStyle(Theme.text2).monospacedDigit()
                            HStack(spacing: 4) {
                                Image(systemName: m.action == .trash ? "trash" : "folder").font(.ui(10))
                                Text(m.destination.map { FS.pretty($0) } ?? "Corbeille").lineLimit(1).truncationMode(.head)
                            }
                            .font(.ui(11)).foregroundStyle(m.action == .trash ? Theme.palette[5] : Theme.warn)
                            .frame(width: 230, alignment: .trailing)
                        }
                    }
                }
                if moves.count > 60 {
                    Text("… et \(Fmt.plural(moves.count - 60, "autre fichier", "autres fichiers"))").font(.ui(11)).foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
            }
        }
    }
}

// MARK: - Journal tab

private struct AutomationJournalTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.automation
        Panel(title: "Dernières exécutions", symbol: "list.bullet.rectangle", tint: Theme.palette[4]) {
            HStack(spacing: 8) {
                Button("Journal détaillé") {
                    if FS.exists(ActionLog.file) { NSWorkspace.shared.open(URL(fileURLWithPath: ActionLog.file)) } else { Finder.reveal(ActionLog.folder) }
                }
                .buttonStyle(SoftButtonStyle(small: true))
                .disabled(DemoData.isEnabled)
                .help("Chaque fichier supprimé ou déplacé, un par ligne")
                Button("Effacer") {
                    if CommandRunner.confirm("Effacer ce journal ?", "Seul ce résumé est effacé ; le journal détaillé reste.", button: "Effacer") {
                        model.clearJournal()
                    }
                }
                .buttonStyle(SoftButtonStyle(small: true))
                .disabled(model.journal.isEmpty)
            }
        } content: {
            VStack(spacing: 2) {
                if model.journal.isEmpty {
                    EmptyHint(text: "Rien pour l'instant : les passages des automatisations s'afficheront ici.", symbol: "clock")
                }
                ForEach(model.journal) { e in
                    HoverRow {
                        HStack(alignment: .top, spacing: 12) {
                            IconBadge(symbol: e.kind.symbol, tint: e.kind.tint, size: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(e.title).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
                                    Tag(text: e.automatic ? "Automatique" : "Manuel", symbol: e.automatic ? "clock.arrow.2.circlepath" : "hand.tap")
                                    if e.failures > 0 { StatusBadge(status: .warn, text: Fmt.plural(e.failures, "échec", "échecs")) }
                                }
                                Text(e.detail).font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Fmt.relative(e.date)).font(.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                                // No clock time in the demo: same-day renders stay identical.
                                Text(DemoData.isEnabled ? Fmt.day(e.date) : "\(Fmt.day(e.date)), \(Fmt.clock(e.date))")
                                    .font(.ui(10.5)).foregroundStyle(Theme.text3)
                            }
                        }
                    }
                }
            }
        }
    }
}
