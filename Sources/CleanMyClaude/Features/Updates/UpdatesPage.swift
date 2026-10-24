import SwiftUI
import AppKit

struct UpdatesPage: View {
    @Environment(AppModel.self) private var app

    static let tip = HelpTip(id: "updates.page", title: "Tu gardes la main",
                             text: "Les flux des apps, l'App Store et les serveurs d'Apple ne sont interrogés que quand tu cliques sur « Vérifier ». Homebrew met à jour d'un clic ; les autres apps et l'App Store installent eux-mêmes : je t'y emmène, sans rien télécharger à leur place. Seule exception, que tu peux couper : je demande à GitHub s'il existe une nouvelle version de moi-même.")

    var body: some View {
        let m = app.updates
        VStack(alignment: .leading, spacing: 18) {
            PageHero(symbol: "arrow.down.circle", title: "Mises à jour",
                     subtitle: "Homebrew, tes apps et macOS au même endroit. Rien ne s'installe sans ton clic.",
                     tint: Theme.good, seed: 52, tip: Self.tip) {
                ScanButton(title: m.hasChecked ? "Tout revérifier" : "Tout vérifier", symbol: "arrow.triangle.2.circlepath",
                           running: m.isCheckingAnything, runningTitle: "Vérification…", activity: .downloading) {
                    Task { await m.checkAll() }
                }
            }
            UpdatesSummary()
            UpdatesSelfCard()
            UpdatesBrewPanel()
            TileRow {
                UpdatesAppsPanel(kind: .sparkle)
                UpdatesAppsPanel(kind: .store)
            }
            UpdatesMacOSPanel()
        }
        .task { await m.loadInventory() }
    }
}

// MARK: - Summary

private struct UpdatesSummary: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.updates
        let macOS = m.macOS ?? app.protection.pending
        DashboardMetricStrip(metrics: [
            DashboardMetric(symbol: "mug", value: m.brewPath == nil ? "—" : (m.brewState.date == nil ? "?" : "\(m.brewOutdated.count)"),
                            label: "Homebrew",
                            detail: m.brewPath == nil ? "pas installé" : (m.brewState.date.map { "vérifié \(Fmt.relative($0))" } ?? "pas encore vérifié"),
                            tint: Theme.warn),
            DashboardMetric(symbol: "sparkles", value: m.sparkleState.date == nil ? "?" : "\(m.sparkleAvailable.count)", label: "Apps",
                            detail: "sur \(m.sparkleApps.count)", tint: Theme.palette[4]),
            DashboardMetric(symbol: "bag", value: m.storeState.date == nil ? "?" : "\(m.storeAvailable.count)", label: "App Store",
                            detail: "sur \(m.storeApps.count)", tint: Theme.accent),
            DashboardMetric(symbol: "apple.logo",
                            value: macOS.map { $0.status == .ok ? "À jour" : ($0.status == .warn ? "\(max(1, m.macOSLabels.count))" : "?") } ?? "?",
                            label: "macOS", detail: macOS?.status == .warn ? "à installer" : nil, tint: Theme.text2)
        ])
    }
}

// MARK: - Homebrew

private struct UpdatesBrewPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var m = app.updates
        let jobRunning = m.brewJob?.isRunning ?? false
        Panel(title: "Homebrew", subtitle: subtitle(m), symbol: "mug", tint: Theme.warn) {
            if m.brewPath != nil {
                HStack(spacing: 10) {
                    Toggle(isOn: $m.greedy) {
                        Text("Inclure les casks qui se mettent à jour seuls").font(.ui(11.5)).foregroundStyle(Theme.text2)
                    }
                    .switchToggles()
                    .controlSize(.mini)
                    .fixedSize()
                    .help("brew outdated --greedy : liste aussi les apps qui ont leur propre système de mise à jour.")
                    .onChange(of: m.greedy) { _, _ in
                        if m.brewState.date != nil { Task { await m.checkBrew() } }
                    }
                    Button("brew update") { m.refreshBrew() }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .disabled(jobRunning || m.brewState.isChecking)
                        .help("Télécharge la dernière liste des paquets, sans rien mettre à jour.")
                    UpdatesCheckButton(state: m.brewState) { Task { await m.checkBrew() } }
                        .disabled(jobRunning)
                }
            }
        } content: {
            if m.brewPath == nil {
                HStack(spacing: 12) {
                    Text("Homebrew n'est pas installé sur ce Mac.")
                        .font(.ui(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Découvrir brew.sh") { m.openLink("https://brew.sh/fr/") }.buttonStyle(SoftButtonStyle(small: true))
                }
            } else {
                content(m)
            }
            if let job = m.brewJob {
                UpdatesConsole(job: job, onCancel: m.cancelBrew, onClose: m.dismissBrewJob)
            }
        }
    }

    private func subtitle(_ m: UpdatesModel) -> String {
        guard m.brewPath != nil else { return "Le gestionnaire de paquets de macOS." }
        guard m.brewState.date != nil else { return "Formules et casks en retard sur la liste de Homebrew." }
        let n = m.brewOutdated.count
        return n == 0 ? "Tous tes paquets sont à jour." : "\(Fmt.plural(n, "paquet a", "paquets ont")) une version plus récente."
    }

    @ViewBuilder
    private func content(_ m: UpdatesModel) -> some View {
        switch m.brewState {
        case .idle:
            EmptyHint(text: "Clique sur « Vérifier » : rien ne s'installe.", symbol: "mug")
        case .checking where m.brewPackages.isEmpty:
            EmptyHint(text: "Homebrew cherche ce qui est en retard…", symbol: "hourglass")
        case .failed(let message):
            Callout(symbol: "exclamationmark.triangle", title: "Homebrew n'a pas répondu", text: message, tint: Theme.warn)
        default:
            if m.brewPackages.isEmpty {
                EmptyHint(text: "Tout est à jour. Rien à faire !", symbol: "checkmark.seal")
            } else {
                VStack(spacing: 2) {
                    ForEach(m.brewPackages) { p in
                        UpdatesBrewRow(package: p)
                    }
                }
            }
        }
    }
}

private struct UpdatesBrewRow: View {
    @Environment(AppModel.self) private var app
    var package: UpdatesBrewPackage

    var body: some View {
        let m = app.updates
        let p = package
        let busy = m.brewJob?.isRunning == true && m.brewJob?.ids.contains(p.id) == true
        HoverRow {
            HStack(spacing: 10) {
                IconBadge(symbol: p.isCask ? "macwindow" : "terminal", tint: p.isCask ? Theme.palette[4] : Theme.warn, size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(p.name).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                        if p.isCask { Tag(text: "app (cask)") }
                        if p.pinned { Tag(text: "épinglée", symbol: "pin.fill", tint: Theme.text2) }
                        if p.autoUpdates { Tag(text: "se met à jour seule", symbol: "arrow.triangle.2.circlepath") }
                    }
                    HStack(spacing: 5) {
                        Text(p.installed).font(.mono(11)).foregroundStyle(Theme.text3)
                        Image(systemName: "arrow.right").font(.ui(8.5, .bold)).foregroundStyle(Theme.text3)
                        Text(p.current).font(.mono(11, .medium)).foregroundStyle(Theme.good)
                    }
                }
                Spacer(minLength: 10)
                if p.needsPassword {
                    UpdatesTerminalHint(command: p.command)
                } else if p.pinned {
                    Text("Épinglée : « brew unpin \(p.name) » pour la débloquer")
                        .font(.ui(11)).foregroundStyle(Theme.text3)
                } else if busy {
                    HStack(spacing: 6) {
                        UpdatesSpinner(activity: .unpacking)
                        Text("En cours…").font(.ui(11.5)).foregroundStyle(Theme.text2)
                    }
                } else {
                    Button("Mettre à jour") { m.upgrade(p) }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .disabled(m.brewJob?.isRunning == true || m.brewState.isChecking)
                }
            }
        }
    }
}

/// For casks whose installer asks for the administrator password: the command to paste in the Terminal.
private struct UpdatesTerminalHint: View {
    var command: String

    var body: some View {
        HStack(spacing: 8) {
            Tag(text: "À faire dans le Terminal", symbol: "key.fill", tint: Theme.warn, filled: true)
                .help("Son installeur (.pkg) demande ton mot de passe d'administrateur : Homebrew doit le lancer dans un Terminal.")
            Text(command)
                .font(.mono(11))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Theme.r(6)).fill(Theme.track))
            Button {
                _ = CommandRunner.copy(command)
                HUD.show("Commande copiée : colle-la dans le Terminal", symbol: "doc.on.clipboard.fill")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(SoftButtonStyle(small: true))
            .help("Copier la commande")
            Button("Terminal") {
                guard !DemoData.isEnabled else { return HUD.show(DemoData.refusal) }
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                                   configuration: NSWorkspace.OpenConfiguration())
            }
            .buttonStyle(SoftButtonStyle(small: true))
        }
    }
}

/// The live output of the Homebrew command, like a small Terminal.
private struct UpdatesConsole: View {
    var job: UpdatesBrewJob
    var onCancel: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                switch job.outcome {
                case .running: UpdatesSpinner(activity: .unpacking)
                case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.bad)
                case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(Theme.text3)
                }
                Text(job.title).font(.ui(12, .semibold)).foregroundStyle(Theme.text)
                Text(outcomeLabel).font(.ui(11)).foregroundStyle(Theme.text3)
                Spacer()
                if job.isRunning {
                    Button("Annuler", action: onCancel).buttonStyle(SoftButtonStyle(small: true))
                } else {
                    Button("Copier le journal") {
                        _ = CommandRunner.copy(job.lines.joined(separator: "\n"))
                        HUD.show("Journal copié", symbol: "doc.on.clipboard.fill")
                    }
                    .buttonStyle(SoftButtonStyle(small: true))
                    Button("Masquer", action: onClose).buttonStyle(SoftButtonStyle(small: true))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(job.lines.suffix(12).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.mono(10.5))
                        .foregroundStyle(color(line))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if job.lines.isEmpty {
                    Text("Démarrage…").font(.mono(10.5)).foregroundStyle(Theme.text3)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
        }
        .padding(.top, 4)
    }

    private var outcomeLabel: String {
        switch job.outcome {
        case .running: return "en cours depuis \(Fmt.duration(Date().timeIntervalSince(job.started)))"
        case .succeeded: return "terminé"
        case .failed(let code): return "échec (code \(code))"
        case .cancelled: return "annulé"
        }
    }

    private func color(_ line: String) -> Color {
        if line.hasPrefix("$ ") { return Theme.text2 }
        if line.hasPrefix("==>") { return Theme.accent }
        if line.hasPrefix("Error") || line.hasPrefix("Erreur") { return Theme.bad }
        if line.hasPrefix("Warning") { return Theme.warn }
        if line.hasPrefix("🍺") || line.hasPrefix("✔") { return Theme.good }
        return Theme.text2.opacity(0.85)
    }
}

// MARK: - Apps

enum UpdatesAppsKind { case sparkle, store }

private struct UpdatesAppsPanel: View {
    @Environment(AppModel.self) private var app
    var kind: UpdatesAppsKind

    var body: some View {
        let m = app.updates
        let apps = kind == .sparkle ? m.sparkleApps : m.storeApps
        let state = kind == .sparkle ? m.sparkleState : m.storeState
        Panel(title: kind == .sparkle ? "Apps qui se mettent à jour seules" : "App Store",
              subtitle: kind == .sparkle
                ? "Je lis leur flux Sparkle, l'app installe elle-même."
                : "Versions comparées à celles de l'App Store français.",
              symbol: kind == .sparkle ? "sparkles" : "bag", tint: kind == .sparkle ? Theme.palette[4] : Theme.accent) {
            if !apps.isEmpty {
                UpdatesCheckButton(state: state) {
                    Task { kind == .sparkle ? await m.checkSparkle() : await m.checkStore() }
                }
            }
        } content: {
            if !m.inventoryLoaded {
                EmptyHint(text: "Recherche des apps installées…", symbol: "hourglass")
            } else if apps.isEmpty {
                EmptyHint(text: kind == .sparkle ? "Aucune app ne déclare de flux Sparkle public." : "Aucune app de l'App Store dans Applications.",
                          symbol: kind == .sparkle ? "sparkles" : "bag")
            } else {
                list(apps, state: state)
            }
            if kind == .sparkle, m.sparkleWithoutFeed > 0 {
                Text("Et \(Fmt.plural(m.sparkleWithoutFeed, "app qui vérifie", "apps qui vérifient")) elles-mêmes au lancement.")
                    .font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func list(_ apps: [UpdatesApp], state: UpdatesState) -> some View {
        let available = apps.filter { $0.result.release != nil }
        let upToDate = apps.filter { if case .upToDate = $0.result { return true } else { return false } }
        let failed = apps.filter {
            switch $0.result {
            case .failed, .unknown: return true
            default: return false
            }
        }
        let unchecked = apps.filter { $0.result == .unchecked }
        VStack(alignment: .leading, spacing: 10) {
            if case .failed(let message) = state {
                Callout(symbol: "exclamationmark.triangle", title: message,
                        text: "Aucune réponse n'est arrivée : vérifie ta connexion à Internet, puis clique sur « Vérifier ».", tint: Theme.warn)
            } else if state.date != nil && available.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.good)
                    Text("Rien de nouveau : tout est à jour.").font(.ui(12.5)).foregroundStyle(Theme.text2)
                }
                .padding(.vertical, 4)
            }
            ForEach(available) { a in UpdatesAppRow(entry: a) }
            if !unchecked.isEmpty {
                if state.date == nil {
                    Text(kind == .sparkle
                         ? "Clique sur « Vérifier » pour lire le flux de \(Fmt.plural(unchecked.count, "app", "apps")) :"
                         : "Clique sur « Vérifier » pour comparer \(Fmt.plural(unchecked.count, "app", "apps")) à l'App Store :")
                        .font(.ui(11.5)).foregroundStyle(Theme.text3)
                }
                UpdatesAppTags(apps: unchecked, tint: Theme.text2)
            }
            if !upToDate.isEmpty {
                SectionLabel(text: "À jour")
                UpdatesAppTags(apps: upToDate, tint: Theme.good)
            }
            if !failed.isEmpty {
                SectionLabel(text: "Non vérifiées")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(failed) { a in
                        HStack(spacing: 6) {
                            FileIcon(path: a.path, size: 16)
                            Text(a.name).font(.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                            if case .failed(let why) = a.result {
                                Text(why).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                            } else if case .unknown(let why, let link) = a.result {
                                Text(why).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                                if let link {
                                    Button("Voir") { app.updates.openLink(link) }
                                        .buttonStyle(SoftButtonStyle(small: true))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct UpdatesAppTags: View {
    var apps: [UpdatesApp]
    var tint: Color

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(apps) { a in
                HStack(spacing: 5) {
                    FileIcon(path: a.path, size: 15)
                    Text(a.name).font(.ui(11, .medium)).foregroundStyle(Theme.text)
                    Text(a.version).font(.mono(10)).foregroundStyle(tint)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(PillShape().fill(Theme.track))
            }
        }
    }
}

private struct UpdatesAppRow: View {
    @Environment(AppModel.self) private var app
    var entry: UpdatesApp

    var body: some View {
        let m = app.updates
        let a = entry
        if let r = a.result.release {
            HStack(alignment: .top, spacing: 11) {
                FileIcon(path: a.path, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(a.name).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(r.installed ?? a.version).font(.mono(11)).foregroundStyle(Theme.text3)
                        Image(systemName: "arrow.right").font(.ui(8.5, .bold)).foregroundStyle(Theme.text3)
                        Text(r.version).font(.mono(11, .medium)).foregroundStyle(Theme.good)
                        if let d = r.date {
                            Text("· publiée \(Fmt.relative(d))").font(.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                        }
                    }
                    if let notes = r.notes {
                        Text(notes).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        if let store = r.storeURL {
                            Button("Mettre à jour dans l'App Store") { m.openLink(store) }
                                .buttonStyle(SoftButtonStyle(small: true))
                        } else {
                            Button("Ouvrir l'app") { m.open(a) }
                                .buttonStyle(SoftButtonStyle(small: true))
                                .help("Son propre système de mise à jour s'en charge (menu de l'app, « Rechercher les mises à jour »).")
                            if let notes = r.notesURL {
                                Button("Notes de version") { m.openLink(notes) }
                                    .buttonStyle(SoftButtonStyle(small: true))
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous).fill(Theme.track.opacity(0.5)))
        }
    }
}

// MARK: - macOS

private struct UpdatesMacOSPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.updates
        let check = m.macOS ?? app.protection.pending
        Panel(title: "macOS", subtitle: "Mises à jour système et de sécurité", symbol: "apple.logo", tint: Theme.text2) {
            HStack(spacing: 8) {
                UpdatesCheckButton(state: m.macOSState) { Task { await m.checkMacOS() } }
                Button("Ouvrir Mise à jour de logiciels") { m.openLink(SettingsPane.updates) }
                    .buttonStyle(SoftButtonStyle(small: true))
            }
        } content: {
            if m.macOSState.isChecking {
                HStack(spacing: 14) {
                    BusyMascot(.downloading, pixel: 2.5)
                    Text("macOS interroge les serveurs d'Apple (jusqu'à une minute)…").font(.ui(12)).foregroundStyle(Theme.text3)
                }
                .padding(.vertical, 4)
            } else if let check {
                HStack(alignment: .top, spacing: 12) {
                    IconBadge(symbol: check.status.symbol, tint: check.status.color, size: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        if check.status == .warn {
                            Text("À installer depuis Réglages Système").font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                            FlowLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(check.detail.components(separatedBy: ", "), id: \.self) { label in
                                    Tag(text: label, symbol: "arrow.down.circle", tint: Theme.warn, filled: true)
                                }
                            }
                            if let advice = check.advice {
                                Text(advice).font(.ui(11.5)).foregroundStyle(Theme.text3)
                            }
                        } else {
                            Text(check.detail).font(.ui(12.5)).foregroundStyle(Theme.text2)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                EmptyHint(text: "Clique sur « Vérifier » : rien ne s'installe.", symbol: "apple.logo")
            }
        }
    }
}

// MARK: - Bottom bar

/// The action bar pinned at the bottom of the page (EmptyView when there is nothing to act on).
struct UpdatesBottomBar: View {
    @Environment(AppModel.self) private var app
    @State private var confirm = false

    var body: some View {
        let m = app.updates
        if let job = m.brewJob, job.isRunning {
            ActionBar {
                BusyMascot(.unpacking, pixel: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                    Text(job.lines.last ?? "Démarrage…").font(.mono(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer()
                Button("Annuler") { m.cancelBrew() }.buttonStyle(SoftButtonStyle())
            }
        } else if !m.brewUpgradable.isEmpty {
            let list = m.brewUpgradable
            ActionBar {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.plural(list.count, "mise à jour Homebrew prête", "mises à jour Homebrew prêtes"))
                        .font(.serif(18)).foregroundStyle(Theme.text)
                    Text(list.prefix(5).map(\.name).joined(separator: ", ") + (list.count > 5 ? "…" : ""))
                        .font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer()
                if !m.brewManual.isEmpty {
                    Text("\(Fmt.plural(m.brewManual.count, "cask reste", "casks restent")) à faire dans le Terminal")
                        .font(.ui(11)).foregroundStyle(Theme.text3)
                }
                Button("Tout mettre à jour") { confirm = true }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .disabled(m.brewState.isChecking)
            }
            .confirmAction("Mettre à jour \(Fmt.plural(list.count, "paquet", "paquets")) ?",
                           message: "Homebrew va télécharger et installer : \(list.map(\.name).joined(separator: ", ")). Tu peux suivre et annuler en direct.",
                           button: "Tout mettre à jour", isPresented: $confirm, destructive: false) {
                m.upgradeAll()
            }
        }
    }
}

// MARK: - Small pieces

/// "Vérifier", or a spinner while the source is being checked.
struct UpdatesCheckButton: View {
    var state: UpdatesState
    var action: () -> Void

    var body: some View {
        if state.isChecking {
            HStack(spacing: 6) {
                UpdatesSpinner(activity: .searching)
                Text("Vérification…").font(.ui(11.5)).foregroundStyle(Theme.text2)
            }
        } else {
            Button(state.date == nil ? "Vérifier" : "Revérifier", action: action)
                .buttonStyle(SoftButtonStyle(prominent: state.date == nil, small: true))
        }
    }
}

/// The mascot at work, small, in a row of the page or of the update panel.
struct UpdatesSpinner: View {
    var activity: MascotActivity = .downloading

    var body: some View {
        BusyMascot(activity, pixel: 1)
    }
}
