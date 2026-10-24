import SwiftUI

// MARK: - Access

struct AccessTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.protection
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text(model.accessChecked.map { "Vérifié \(Fmt.relative($0))." } ?? "Le clavier, les extensions de navigateur et les ports ouverts.")
                    .font(.ui(12)).foregroundStyle(Theme.text3)
                Spacer()
                Button {
                    Task { await model.checkAccess() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isCheckingAccess { BusyMascot(.checking, pixel: 1) }
                        Text(model.accessChecked == nil ? "Vérifier" : "Revérifier")
                    }
                }
                .buttonStyle(SoftButtonStyle(prominent: model.accessChecked == nil))
                .disabled(model.isCheckingAccess)
            }
            if model.accessChecked == nil && !model.isCheckingAccess {
                Card { EmptyHint(text: "Lance la vérification pour voir qui lit ton clavier, tes pages et ton réseau.", symbol: "eye") }
            } else {
                KeyboardTapsPanel()
                ExtensionsPanel()
                PortsPanel()
            }
            GrantsSection()
        }
    }
}

struct KeyboardTapsPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let taps = app.protection.keyboardTaps
        let others = taps.filter { $0.risk != .ok }
        Panel(title: "Peut lire tout ce que tu tapes",
              subtitle: others.isEmpty ? "Seuls des composants d'Apple écoutent le clavier. Aucun enregistreur de frappe."
                                       : "Ils reçoivent chaque touche, mots de passe compris : normal pour un lanceur, pas pour un inconnu.",
              symbol: "keyboard", tint: others.contains { $0.risk == .bad } ? Theme.bad : (others.isEmpty ? Theme.good : Theme.warn)) {
            VStack(spacing: 2) {
                ForEach(others) { t in
                    HoverRow {
                        HStack(spacing: 12) {
                            if let a = t.appPath { FileIcon(path: a, size: 26) } else { IconBadge(symbol: "keyboard", tint: t.risk.color, size: 26) }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(t.name).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
                                    Tag(text: t.signature.label, symbol: t.signature.isTrusted ? "checkmark.seal" : "seal",
                                        tint: t.signature.isTrusted ? Theme.good : Theme.bad, filled: true)
                                    if t.canModify { Tag(text: "Peut modifier les touches", tint: Theme.text3) }
                                }
                                Text(FS.pretty(t.path)).font(.mono(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if t.risk == .bad { StatusBadge(status: .bad, text: "Suspect") }
                            BorderlessMenu(indicator: false) {
                                Button("Afficher dans le Finder") { Finder.reveal(t.appPath ?? t.path) }
                                Button("Gérer la surveillance de la saisie") { Finder.open(SettingsPane.privacy("Privacy_ListenEvent")) }
                                Button("Gérer l'accessibilité") { Finder.open(SettingsPane.privacy("Privacy_Accessibility")) }
                                Button("Demander à Claude ce que c'est") {
                                    app.assistant.explain(t.name, details: ["Écoute le clavier", "Programme : \(t.path)", "Signature : \(t.signature.label)"])
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle").font(.ui(14)).foregroundStyle(Theme.text2)
                            }
                        }
                    }
                }
                let apple = taps.count - others.count
                if apple > 0 {
                    Text("Et \(Fmt.plural(apple, "composant", "composants")) d'Apple (accessibilité, saisie de texte).")
                        .font(.ui(11)).foregroundStyle(Theme.text3).padding(.horizontal, 10).padding(.top, 4)
                }
            }
        }
    }
}

struct ExtensionsPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let list = app.protection.extensions
        let forced = list.filter(\.forced)
        Panel(title: "Extensions de navigateur",
              subtitle: list.isEmpty ? "Aucune extension installée." :
                (forced.isEmpty ? "\(Fmt.plural(list.count, "extension", "extensions")), dont \(list.filter(\.readsEverything).count) qui lisent toutes les pages que tu visites."
                                : "\(Fmt.plural(forced.count, "extension imposée", "extensions imposées")) par un réglage : tu ne peux pas la retirer toi-même. Hors entreprise, c'est la marque d'un logiciel publicitaire."),
              symbol: "puzzlepiece.extension", tint: forced.isEmpty ? Theme.accent : Theme.bad) {
            VStack(spacing: 2) {
                ForEach(list.prefix(14)) { e in
                    HoverRow {
                        HStack(spacing: 10) {
                            IconBadge(symbol: e.browser == "Safari" ? "safari" : "globe", tint: e.forced ? Theme.bad : (e.readsEverything ? Theme.warn : Theme.accent), size: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(e.name).font(.ui(12.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                                    Tag(text: e.browser, tint: Theme.text3)
                                    if !e.enabled { Tag(text: "Désactivée", tint: Theme.text3) }
                                }
                                Text(e.forced ? "Installée par un réglage ou un autre programme, pas par toi" : (e.readsEverything ? "Peut lire et modifier toutes les pages" : "Accès limité à certains sites"))
                                    .font(.ui(11)).foregroundStyle(e.forced ? Theme.bad : Theme.text3)
                            }
                            Spacer()
                            BorderlessMenu(indicator: false) {
                                if FS.exists(e.container) { Button("Afficher dans le Finder") { Finder.reveal(e.container) } }
                                if e.browser == "Safari" { Button("Gérer dans Safari") { Finder.open(SettingsPane.extensions) } }
                                if e.forced { Button("Voir les profils installés") { Finder.open(SettingsPane.profiles) } }
                                Button("Demander à Claude ce que c'est") {
                                    app.assistant.explain(e.name, details: ["Extension \(e.browser)", "Identifiant : \(e.identifier)",
                                                                            e.readsEverything ? "Lit toutes les pages" : "Accès limité"])
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle").font(.ui(14)).foregroundStyle(Theme.text2)
                            }
                        }
                    }
                }
                if list.count > 14 {
                    Text("et \(list.count - 14) autres").font(.ui(11)).foregroundStyle(Theme.text3).padding(.horizontal, 10)
                }
            }
        }
    }
}

struct PortsPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let ports = app.protection.exposedPorts
        Panel(title: "Ouvert sur le réseau",
              subtitle: ports.isEmpty ? "Aucun de tes programmes n'accepte de connexion venue d'un autre appareil."
                                      : "Ils acceptent des connexions des autres appareils du réseau, Wi-Fi public compris.",
              symbol: "network", tint: ports.contains { !$0.isSystem } ? Theme.warn : Theme.good) {
            Button("Détails") {
                app.network.showInSettings(.ports)
            }
            .buttonStyle(SoftButtonStyle(small: true))
        } content: {
            VStack(spacing: 2) {
                ForEach(ports.prefix(10)) { p in
                    HoverRow {
                        HStack(spacing: 10) {
                            if let a = p.appPath { FileIcon(path: a, size: 22) } else { IconBadge(symbol: "server.rack", tint: Theme.text2, size: 22) }
                            Text(p.displayName).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
                            if let d = NetworkPorts.describe(p) { Text(d).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1) }
                            Spacer()
                            Text(verbatim: "port \(p.port)").font(.mono(11)).foregroundStyle(Theme.text2)
                        }
                    }
                }
            }
        }
    }
}

struct GrantsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.protection
        if let grants = model.grants {
            let services = TCCService.all.filter { s in grants.contains { $0.service == s } }
            if !services.isEmpty {
                Panel(title: "Autorisations accordées", symbol: "hand.raised", tint: Theme.accent) {
                    VStack(spacing: 2) {
                        ForEach(services, id: \.key) { s in
                            GrantRow(service: s, grants: grants.filter { $0.service == s })
                        }
                    }
                }
            }
        } else if model.hasAudit || model.accessChecked != nil {
            FullDiskAccessCard(reason: "macOS ne montre les autorisations (caméra, micro, écran, accessibilité…) qu'aux apps qui ont l'accès complet au disque.")
        }
    }
}

/// One permission on one line: its apps as icons (name and date on hover), and the way to the setting.
private struct GrantRow: View {
    var service: TCCService
    var grants: [PermissionGrant]

    var body: some View {
        HoverRow {
            HStack(spacing: 10) {
                IconBadge(symbol: service.symbol, tint: service.sensitive ? Theme.warn : Theme.accent, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.title).font(.ui(12.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(grants.map(\.name).joined(separator: ", "))
                        .font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.tail)
                }
                .frame(width: 330, alignment: .leading)
                HStack(spacing: 4) {
                    ForEach(grants.prefix(10)) { g in
                        Group {
                            if let p = g.path { FileIcon(path: p, size: 20) } else { IconBadge(symbol: "app.dashed", tint: Theme.text3, size: 20) }
                        }
                        .help(g.name + (g.lastModified.map { " · autorisée \(Fmt.relative($0))" } ?? ""))
                    }
                    if grants.count > 10 {
                        Text("+\(grants.count - 10)").font(.ui(11)).foregroundStyle(Theme.text3)
                    }
                }
                Spacer(minLength: 8)
                Button("Gérer") { Finder.open(SettingsPane.privacy(service.anchor)) }
                    .buttonStyle(SoftButtonStyle(small: true))
            }
        }
    }
}

// MARK: - Real time

struct RealtimeTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.protection
        VStack(alignment: .leading, spacing: 14) {
            if !model.realtime.anyOn {
                Card(padding: 18) {
                    HStack(alignment: .center, spacing: 14) {
                        IconBadge(symbol: "shield.lefthalf.filled.badge.checkmark", tint: Theme.good, size: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Une protection qui veille pendant que tu travailles").font(.serif(20)).foregroundStyle(Theme.text)
                            Text("Sans analyse permanente : ton Mac ne ralentit pas.")
                                .font(.ui(12.5)).foregroundStyle(Theme.text2)
                        }
                        Spacer()
                        Button("Tout activer") { model.enableRealtime() }.buttonStyle(SoftButtonStyle(prominent: true))
                    }
                }
            }
            Panel(title: "Surveillance", subtitle: "Chaque alerte arrive en notification.",
                  symbol: "dot.radiowaves.left.and.right", tint: model.realtime.anyOn ? Theme.good : Theme.text3) {
                VStack(spacing: 10) {
                    RealtimeToggle(title: "Nouveaux éléments de démarrage", symbol: "arrow.clockwise.circle",
                                   text: "Un agent ou un service qui s'installe, vérifié aussitôt.",
                                   isOn: $model.realtime.persistence)
                    RealtimeToggle(title: "Fichiers téléchargés", symbol: "arrow.down.circle",
                                   text: "Ce qui arrive dans Téléchargements passe aux signatures d'Apple.",
                                   isOn: $model.realtime.downloads)
                    RealtimeToggle(title: "Caméra et micro", symbol: "camera",
                                   text: "Dès que l'un d'eux s'allume.",
                                   isOn: $model.realtime.devices)
                    RealtimeToggle(title: "Réglages réseau", symbol: "network",
                                   text: "Un serveur DNS ou un proxy inconnu qui apparaît.",
                                   isOn: $model.realtime.network)
                }
                .switchToggles()
            }
            Panel(title: "Journal", subtitle: model.events.isEmpty ? "Rien à signaler pour l'instant." : "Les 200 derniers événements.",
                  symbol: "list.bullet.rectangle", tint: Theme.accent) {
                if !model.events.isEmpty {
                    Button("Effacer") { model.clearEvents() }.buttonStyle(SoftButtonStyle(small: true))
                }
            } content: {
                VStack(spacing: 2) {
                    ForEach(model.events.prefix(40)) { e in
                        HoverRow {
                            HStack(alignment: .top, spacing: 10) {
                                IconBadge(symbol: e.kind.symbol, tint: e.status.color, size: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.title).font(.ui(12.5, .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                    Text(e.detail).font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Text(Fmt.relative(e.date)).font(.ui(10.5)).foregroundStyle(Theme.text3)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct RealtimeToggle: View {
    var title: String
    var symbol: String
    var text: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 10) {
                IconBadge(symbol: symbol, tint: isOn ? Theme.good : Theme.text3, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                    Text(text).font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
            }
        }
    }
}
