import SwiftUI

struct ProtectionPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.protection
        VStack(alignment: .leading, spacing: 18) {
            PageHero(symbol: "lock.shield", title: "Protection et confidentialité",
                     subtitle: "Les défenses de ton Mac, les menaces et qui t'observe.",
                     tint: Theme.good, seed: 33, tip: model.tab.tip) {
                HStack(spacing: 16) {
                    if model.hasAudit {
                        Gauge(value: model.securityRatio, text: "\(model.securityScore)", caption: "note \(model.grade)",
                              tint: model.securityScore >= 85 ? Theme.good : (model.securityScore >= 65 ? Theme.warn : Theme.bad),
                              size: 74, lineWidth: 6)
                            .help("Indice de sécurité sur 100 : chaque point pèse selon sa gravité (\(model.passedCount) sur \(model.scoredCount) en ordre).")
                    }
                    ScanButton(title: model.hasAudit ? "Refaire le bilan" : "Lancer le bilan", symbol: "checkmark.shield",
                               running: model.isAuditing || app.startup.isScanning || model.isCheckingAccess, activity: .checking) {
                        ProtectionActions.fullReview(app)
                    }
                }
            }

            PillPicker(options: ProtectionTab.allCases, selection: $model.tab, label: { $0.title }, badge: { tab in
                switch tab {
                case .security: return model.issues.isEmpty ? nil : "\(model.issues.count)"
                case .threats: return model.visibleThreats.isEmpty ? nil : "\(model.visibleThreats.count)"
                case .persistence: return app.startup.flagged.isEmpty ? nil : "\(app.startup.flagged.count)"
                case .permissions:
                    let n = model.keyboardTaps.filter { $0.risk == .bad }.count + model.extensions.filter(\.forced).count
                    return n == 0 ? nil : "\(n)"
                case .privacy: return model.traces.isEmpty ? nil : "\(model.traces.count)"
                case .realtime: return model.realtime.anyOn ? "actif" : nil
                }
            })

            switch model.tab {
            case .security:
                if model.isAuditing && !model.hasAudit {
                    ScanProgressCard(title: "J'inspecte les défenses de ton Mac…", label: "FileVault, coupe-feu, partages, réseau, secrets…", progress: nil,
                                     activity: .checking)
                } else if !model.hasAudit {
                    ProtectionIntro()
                } else {
                    SecurityTab()
                }
            case .threats: ThreatsTab()
            case .persistence: PersistenceTab()
            case .permissions: AccessTab()
            case .privacy:
                if model.hasAudit { PrivacyTab() } else { ProtectionIntro() }
            case .realtime: RealtimeTab()
            }
        }
    }
}

extension ProtectionTab {
    /// The « ? » next to the page title follows the tab: each one is explained the first time it is opened.
    var tip: HelpTip {
        switch self {
        case .security:
            return HelpTip(id: "protection.security", title: "Le bilan de sécurité",
                           text: "Une quarantaine de points inspirés des référentiels de sécurité pour macOS (CIS Benchmark, NIST mSCP), vérifiés en lecture seule. « Corriger » agit après ton accord ; sinon « Réglage » ouvre le bon panneau, car macOS garde la main sur sa sécurité. Le niveau Renforcé ajoute les recommandations pour un Mac qui voyage ou des données sensibles.")
        case .threats:
            return HelpTip(id: "protection.threats", title: "Les logiciels malveillants",
                           text: "XProtect, l'antimalware de macOS, ne vérifie un fichier qu'à son ouverture : j'applique ses signatures à tout ce qui est déjà sur ton Mac, et je cherche les traces des familles connues et les comportements d'intrus. Glisse un téléchargement dans le cadre pour le vérifier avant de l'ouvrir. Rien ne quitte ton Mac, et ce que tu neutralises part à la Corbeille.")
        case .persistence:
            return HelpTip(id: "protection.persistence", title: "Ce qui démarre tout seul",
                           text: "Presque tous les logiciels malveillants sur Mac s'installent pour redémarrer avec lui. Je vérifie qui a signé chaque programme et je signale ce qui trahit un intrus : se faire passer pour Apple, télécharger puis exécuter du code, se cacher dans un dossier partagé.")
        case .permissions:
            return HelpTip(id: "protection.permissions", title: "Qui t'observe",
                           text: "Ce qui peut lire ce que tu tapes, voir les pages que tu visites ou accepter des connexions du réseau, et les apps à qui tu as ouvert la caméra, le micro ou tes dossiers. La plupart du temps ce sont des outils que tu as choisis ; ce qui ne l'est pas saute aux yeux.")
        case .privacy:
            return HelpTip(id: "protection.privacy", title: "Les traces",
                           text: "Coche ce que tu veux effacer : l'effacement est définitif. L'historique de Safari est synchronisé avec iCloud : efface-le depuis Safari › Historique › Effacer l'historique… pour que la suppression se propage sur tous tes appareils.")
        case .realtime:
            return HelpTip(id: "protection.realtime", title: "La protection en temps réel",
                           text: "Je te préviens dès qu'un programme s'ajoute au démarrage, qu'une menace arrive dans Téléchargements, que la caméra ou le micro s'allume, ou que tes réglages réseau changent. Tout réagit aux événements de macOS : aucune analyse permanente, ton Mac ne ralentit pas.")
        }
    }
}

@MainActor
enum ProtectionActions {
    /// The whole review: macOS' defenses, what starts on its own, who can watch, the traces.
    static func fullReview(_ app: AppModel) {
        let protection = app.protection, startup = app.startup
        Task {
            async let a: Void = protection.audit()
            async let b: Void = startup.scan()
            async let c: Void = protection.checkAccess()
            _ = await (a, b, c)
        }
    }
}

struct ProtectionIntro: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Card(padding: 20) {
            HStack(alignment: .center, spacing: 18) {
                IconBadge(symbol: "lock.shield.fill", tint: Theme.good, size: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Un bilan complet en quelques secondes").font(.serif(22)).foregroundStyle(Theme.text)
                    Text("Chiffrement, coupe-feu, partages, mots de passe laissés en clair… en lecture seule.")
                        .font(.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Rechercher les menaces") {
                    app.protection.tab = .threats
                    Task { await app.protection.scan(deep: false) }
                }
                .buttonStyle(SoftButtonStyle())
                Button("Lancer le bilan") { ProtectionActions.fullReview(app) }
                    .buttonStyle(SoftButtonStyle(prominent: true))
            }
        }
    }
}

// MARK: - Security

struct SecurityTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.protection
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                let tint = model.issues.isEmpty ? Theme.good : (model.issues.contains { $0.status == .bad } ? Theme.bad : Theme.warn)
                IconBadge(symbol: model.issues.isEmpty ? "checkmark.shield" : "exclamationmark.shield", tint: tint, size: 28)
                Text(model.issues.isEmpty
                     ? (model.hardened ? "Même les recommandations renforcées sont suivies. Chapeau." : "Toutes les protections de ce niveau sont actives.")
                     : "\(Fmt.plural(model.issues.count, "point mérite", "points méritent")) ton attention, les plus graves d'abord.")
                    .font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                Spacer(minLength: 12)
                Text("Niveau").font(.ui(12)).foregroundStyle(Theme.text3)
                PillPicker(options: ProtectionLevelChoice.allCases, selection: Binding(
                    get: { model.hardened ? .hardened : .essential },
                    set: { model.hardened = $0 == .hardened }), label: { $0.title })
                    .help(model.hardened ? "Toutes les recommandations, pour un Mac qui voyage ou des données sensibles."
                                         : "Ce que tout Mac devrait avoir. Les points renforcés restent affichés, sans compter dans la note.")
            }
            if let m = model.fixMessage {
                Callout(symbol: m.ok ? "checkmark.circle" : "exclamationmark.triangle", title: m.ok ? "Corrigé" : "Pas tout à fait",
                        text: m.text, tint: m.ok ? Theme.good : Theme.warn)
            }
            ForEach(SecurityCategory.allCases) { category in
                let list = model.allChecks.filter { $0.category == category }
                if !list.isEmpty {
                    let counted = list.filter { $0.scored && $0.status != .unknown && ($0.level == .essential || model.hardened) }
                    Panel(title: category.title, subtitle: "\(counted.filter(\.passed).count) sur \(counted.count) en ordre",
                          symbol: category.symbol, tint: counted.allSatisfy(\.passed) ? Theme.good : Theme.warn) {
                        VStack(alignment: .leading, spacing: 2) {
                            // What needs a look gets a full row; what is in order fits in a line of chips.
                            ForEach(list.filter { $0.status != .ok }) { c in SecurityCheckRow(check: c) }
                            let fine = list.filter { $0.status == .ok }
                            if !fine.isEmpty {
                                FlowLayout(spacing: 6, lineSpacing: 6) {
                                    ForEach(fine) { c in
                                        Tag(text: c.title, symbol: "checkmark", tint: Theme.good, filled: true)
                                            .help(c.detail)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                            }
                            if category == .updates && model.isCheckingUpdates {
                                HStack(spacing: 10) {
                                    BusyMascot(.downloading, pixel: 1.5)
                                    Text("Je demande aux serveurs d'Apple s'il y a des mises à jour…").font(.ui(11.5)).foregroundStyle(Theme.text3)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
        }
    }
}

enum ProtectionLevelChoice: String, CaseIterable, Identifiable {
    case essential, hardened
    var id: String { rawValue }
    var title: String { self == .essential ? "Essentiel" : "Renforcé" }
}

struct SecurityCheckRow: View {
    @Environment(AppModel.self) private var app
    var check: SecurityCheck
    @State private var confirm = false

    var body: some View {
        let model = app.protection
        let counted = check.level == .essential || model.hardened
        let issue = check.status == .warn || check.status == .bad
        HoverRow {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(symbol: check.symbol, tint: counted ? check.status.color : Theme.text3, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(check.title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                        if check.weight == 3 { Tag(text: "Critique", tint: Theme.text3) }
                        if check.level == .hardened { Tag(text: "Renforcé", symbol: "shield.lefthalf.filled", tint: Theme.text2) }
                    }
                    Text(check.detail).font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    if let advice = check.advice, issue {
                        Text(advice).font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    StatusBadge(status: counted || !issue ? check.status : .info,
                                text: check.status == .ok ? "En ordre" : (!counted && issue ? "Conseillé" : nil))
                    if issue {
                        HStack(spacing: 6) {
                            if let url = check.settingsURL {
                                Button("Réglage") { Finder.open(url) }.buttonStyle(SoftButtonStyle(small: true))
                            }
                            if let fix = check.fix {
                                if model.fixing.contains(check.id) {
                                    BusyMascot(.typing, pixel: 1)
                                } else {
                                    Button("Corriger") { confirm = true }
                                        .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                                        .help(fix.title)
                                }
                            }
                        }
                    }
                }
            }
        }
        .opacity(counted || !issue ? 1 : 0.8)
        .confirmAction(check.fix?.title ?? "", message: check.fix?.explanation ?? "", button: check.fix?.title ?? "Corriger",
                       isPresented: $confirm, destructive: false) {
            Task { await model.apply(check) }
        }
    }
}

// MARK: - Persistence

struct PersistenceTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let startup = app.startup
        let anchors = app.protection.anchors
        VStack(alignment: .leading, spacing: 14) {
            if startup.isScanning && startup.items.isEmpty {
                ScanProgressCard(title: "Je vérifie les signatures…", label: "Agents, services, ouverture à la connexion, cron…", progress: nil,
                                 activity: .inspecting)
            } else if startup.items.isEmpty && anchors.isEmpty {
                Card {
                    EmptyHint(text: startup.lastScan == nil ? "Lance le bilan pour lister ce qui démarre tout seul." : "Aucun agent ni service tiers. Rien ne se lance en douce.",
                              symbol: "checkmark.seal")
                }
            } else {
                DashboardMetricStrip(metrics: [
                    DashboardMetric(symbol: "list.bullet", value: "\(startup.items.count + anchors.count)", label: "Points de démarrage"),
                    DashboardMetric(symbol: "checkmark.seal", value: "\(startup.items.filter { $0.signature.isTrusted }.count)", label: "Signés et vérifiés",
                                    tint: Theme.good),
                    DashboardMetric(symbol: "exclamationmark.triangle", value: "\(startup.flagged.count + anchors.filter { $0.risk >= .warn }.count)",
                                    label: "À examiner", tint: startup.flagged.isEmpty ? Theme.good : Theme.warn)
                ])
                if let msg = startup.message {
                    Callout(symbol: startup.messageOK ? "checkmark.circle" : "exclamationmark.triangle", title: startup.messageOK ? "Fait" : "Pas tout à fait",
                            text: msg, tint: startup.messageOK ? Theme.good : Theme.warn)
                }
                if !startup.flagged.isEmpty {
                    Panel(title: "Points d'attention", subtitle: "Souvent un reste d'app ou un outil maison, parfois un intrus : regarde de près ce qui est en rouge.",
                          symbol: "exclamationmark.triangle", tint: Theme.warn) {
                        LaunchItemList(items: startup.flagged)
                    }
                }
                ForEach(LaunchDomain.allCases, id: \.self) { d in
                    let items = startup.items.filter { $0.domain == d && !$0.isFlagged }
                    if !items.isEmpty {
                        ProtectionFoldPanel(title: d.title, subtitle: d.folder.replacingOccurrences(of: FS.home, with: "~"), symbol: "folder",
                                            count: items.count) {
                            LaunchItemList(items: items)
                        }
                    }
                }
                ForEach(ProtectionAnchor.Kind.allCases, id: \.self) { kind in
                    let list = anchors.filter { $0.kind == kind }
                    if !list.isEmpty {
                        ProtectionFoldPanel(title: kind.title, symbol: kind.symbol, tint: list.contains { $0.risk >= .warn } ? Theme.warn : Theme.accent,
                                            count: list.count, startsOpen: list.contains { $0.risk >= .warn }) {
                            VStack(spacing: 2) {
                                ForEach(list) { a in AnchorRow(anchor: a) }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A panel that shows only its title line until it is clicked: for the long lists that are rarely read.
struct ProtectionFoldPanel<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    var symbol: String
    var tint: Color = Theme.accent
    var count: Int
    var startsOpen = false
    @ViewBuilder var content: Content
    @State private var open: Bool?

    var body: some View {
        let isOpen = open ?? startsOpen
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { open = !isOpen }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if Theme.icons != .hidden {
                            Image(systemName: symbol).font(.ui(12, .medium)).foregroundStyle(Theme.icons == .tinted ? tint : Theme.text3)
                        }
                        Text(title).font(.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                        if let subtitle {
                            Text(subtitle).font(.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Text("\(count)").font(.ui(12, .semibold)).foregroundStyle(Theme.text2).monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.ui(11, .semibold))
                            .foregroundStyle(Theme.text3)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Replier" : "Afficher")
                if isOpen {
                    content
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)
                }
            }
        }
    }
}

struct AnchorRow: View {
    @Environment(AppModel.self) private var app
    var anchor: ProtectionAnchor

    var body: some View {
        HoverRow {
            HStack(alignment: .top, spacing: 12) {
                if let p = anchor.path, p.hasSuffix(".app") || p.hasSuffix(".app/") {
                    FileIcon(path: p, size: 24)
                } else {
                    IconBadge(symbol: anchor.kind.symbol, tint: anchor.risk.color, size: 24)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(anchor.name).font(.ui(12.5, .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Text(anchor.detail).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(2).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if anchor.risk >= .warn { StatusBadge(status: anchor.risk) }
                BorderlessMenu(indicator: false) {
                    if let p = anchor.path, FS.exists(p) { Button("Afficher dans le Finder") { Finder.reveal(p) } }
                    if anchor.kind == .loginItem { Button("Ouvrir Ouverture et extensions") { Finder.open(SettingsPane.loginItems) } }
                    if anchor.kind == .systemExtension { Button("Ouvrir les extensions") { Finder.open(SettingsPane.loginItems) } }
                    Button("Demander à Claude ce que c'est") {
                        app.assistant.explain(anchor.name, details: ["Type : \(anchor.kind.title)", anchor.detail])
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.ui(14)).foregroundStyle(Theme.text2)
                }
            }
        }
    }
}

struct LaunchItemList: View {
    var items: [LaunchItem]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(items) { item in
                LaunchItemRow(item: item)
            }
        }
    }
}

struct LaunchItemRow: View {
    @Environment(AppModel.self) private var app
    var item: LaunchItem
    @State private var confirmRemove = false

    var body: some View {
        let startup = app.startup
        HoverRow {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let a = item.appPath {
                        FileIcon(path: a, size: 28)
                    } else {
                        IconBadge(symbol: item.domain == .globalDaemon ? "gearshape.2" : "person.crop.circle.badge.clock", tint: Theme.text2, size: 28)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    FlowLayout(spacing: 6, lineSpacing: 4) {
                        Text(item.label).font(.ui(12.5, .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        if item.running { Tag(text: "En cours", symbol: "circle.fill", tint: Theme.good, filled: true) }
                        if item.disabled { Tag(text: "Désactivé", tint: Theme.text3) }
                        if !item.flags.contains(where: { $0.rawValue == item.signature.label }) {
                            Tag(text: item.signature.label, symbol: item.signature.isTrusted ? "checkmark.seal" : "seal",
                                tint: item.signature.isTrusted ? Theme.good : Theme.warn, filled: true)
                        }
                        ForEach(item.flags, id: \.self) { f in
                            Tag(text: f.rawValue, symbol: f.severity.symbol, tint: f.severity.color, filled: true)
                        }
                        if item.keepAlive { Tag(text: "Relancé s'il s'arrête", tint: Theme.text3) }
                    }
                    Text(item.commandLine).font(.mono(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if startup.busy.contains(item.id) {
                    BusyMascot(.typing, pixel: 1)
                } else {
                    BorderlessMenu(indicator: false) {
                        Button(item.disabled ? "Réactiver" : "Désactiver") {
                            Task { await startup.setDisabled(item, !item.disabled) }
                        }
                        Button("Afficher dans le Finder") { Finder.reveal(item.plistPath) }
                        Button("Demander à Claude ce que c'est") {
                            app.assistant.explain(item.label, details: [
                                "Type : \(item.domain.title.lowercased())",
                                "Programme : \(item.commandLine)",
                                "Signature : \(item.signature.label)",
                                item.flags.isEmpty ? "Aucun signal particulier" : "Signalé : \(item.flags.map(\.rawValue).joined(separator: ", "))"
                            ])
                        }
                        if let p = item.program, FS.exists(p) {
                            Button("Afficher le programme") { Finder.reveal(p) }
                        }
                        if item.domain == .userAgent {
                            Divider()
                            Button("Supprimer…", role: .destructive) { confirmRemove = true }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.ui(14)).foregroundStyle(Theme.text2)
                    }
                    .help(item.domain.needsAdmin ? "Modifier un service système demande ton mot de passe" : "Actions")
                }
            }
        }
        .help(item.plistPath)
        .confirmAction("Supprimer « \(item.label) » ?",
                       message: "L'agent est arrêté et son fichier va dans la Corbeille. Si l'app qui l'a installé est encore là, elle risque de le recréer : désinstalle-la plutôt depuis Applications.",
                       button: "Supprimer", isPresented: $confirmRemove) {
            Task { await startup.remove(item) }
        }
    }
}

struct FullDiskAccessCard: View {
    @Environment(AppModel.self) private var app
    var reason: String

    var body: some View {
        Card(padding: 22) {
            HStack(alignment: .top, spacing: 18) {
                IconBadge(symbol: "externaldrive.badge.checkmark", tint: Theme.accent, size: 40)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accès complet au disque requis").font(.serif(20)).foregroundStyle(Theme.text)
                    Text(reason)
                        .font(.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Ouvrir le réglage") { Finder.open(Permissions.fullDiskAccessURL) }
                            .buttonStyle(SoftButtonStyle(prominent: true))
                        Button("J'ai donné l'accès") { app.refreshPermissions() }
                            .buttonStyle(SoftButtonStyle())
                    }
                }
            }
        }
    }
}

// MARK: - Privacy

struct PrivacyTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.protection
        let groups = model.traces.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
        VStack(alignment: .leading, spacing: 14) {
            if let r = model.traceReport {
                Callout(symbol: "checkmark.seal", title: "Traces effacées", text: r.summary, tint: r.failures.isEmpty ? Theme.good : Theme.warn)
            }
            ForEach(groups, id: \.self) { g in
                Panel(title: g, symbol: g == "Système" ? "macbook" : "globe") {
                    VStack(spacing: 2) {
                        ForEach(model.traces.filter { $0.group == g }) { t in
                            TraceRow(trace: t)
                        }
                    }
                }
            }
        }
    }
}

struct TraceRow: View {
    @Environment(AppModel.self) private var app
    var trace: PrivacyTrace

    var body: some View {
        let model = app.protection
        let blocked = trace.blockedReason != nil || trace.needsFullDiskAccess
        HoverRow {
            HStack(spacing: 12) {
                CheckBox(state: model.traceSelection.contains(trace.id) ? .on : .off, disabled: blocked) { model.toggle(trace) }
                IconBadge(symbol: trace.symbol, tint: Theme.accent, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trace.title).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
                    if let reason = trace.blockedReason {
                        ThemedLabel(title: reason, symbol: "lock").font(.ui(11)).foregroundStyle(Theme.warn)
                    } else if trace.needsFullDiskAccess {
                        ThemedLabel(title: "Accès complet au disque requis", symbol: "lock").font(.ui(11)).foregroundStyle(Theme.warn)
                    } else {
                        Text(trace.detail).font(.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    if let n = trace.count {
                        Text(Fmt.plural(n, "entrée", "entrées")).font(.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                    }
                    if trace.size > 0 {
                        Text(Fmt.bytes(trace.size)).font(.ui(10.5)).foregroundStyle(Theme.text3)
                    }
                }
            }
        }
    }
}

struct PrivacyActionBar: View {
    @Environment(AppModel.self) private var app
    @State private var confirm = false

    var body: some View {
        let model = app.protection
        ActionBar {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.plural(model.selectedTraces.count, "trace sélectionnée", "traces sélectionnées"))
                    .font(.serif(18)).foregroundStyle(Theme.text)
                Text("L'effacement est définitif.").font(.ui(11)).foregroundStyle(Theme.text3)
            }
            Spacer()
            Button {
                confirm = true
            } label: {
                HStack(spacing: 6) {
                    if model.isCleaningTraces { BusyMascot(.sweeping, pixel: 1, ink: Theme.onAccent) }
                    Text("Effacer les traces")
                }
            }
            .buttonStyle(SoftButtonStyle(prominent: true))
            .disabled(model.selectedTraces.isEmpty || model.isCleaningTraces)
        }
        .confirmAction("Effacer ces traces ?",
                       message: model.selectedTraces.map { "• \($0.group) : \($0.title)" }.joined(separator: "\n"),
                       button: "Effacer", isPresented: $confirm) {
            Task { await model.cleanTraces() }
        }
    }
}
