import SwiftUI
import AppKit

enum AdBlockStyle {
    static var tint: Color { Theme.palette[6] }
}

/// What takes longer to explain than a line: each « ? » opens it by itself the first time, then on a click.
@MainActor
enum AdBlockTips {
    static let player = HelpTip(
        id: "media.player", title: "Le lecteur sans pub",
        text: "YouTube et Twitch : leurs pubs vidéo sont coupées (si YouTube retient la vidéo le temps d'une pub, la fenêtre le dit). France.tv et M6+ aussi, après connexion à ton compte gratuit. Arte n'a pas de pub ; celle de Pluto TV est cousue dans le flux et reste. TF1+ refuse de lire dès qu'une pub est bloquée : il n'est pas dans le lecteur.")

    static let videoOnly = HelpTip(
        id: "media.videoOnly", title: "Vidéo seule",
        text: "« Détacher la vidéo » reprend ici, sans pub, la vidéo YouTube ou le direct Twitch de ton navigateur : une petite fenêtre au-dessus des autres, sur tous tes bureaux. Tire ses bords pour la redimensionner, survole-la pour la déplacer ou revenir au lecteur complet. Netflix, Prime Video, Disney+, TF1+ et les autres vidéos protégées restent dans Safari, qui les passe dans son image dans l'image (pour un lecteur fermé comme celui de TF1+, Heartware ouvre le menu de la vidéo, avec l'autorisation d'Accessibilité). Pendant l'image dans l'image, la croix rouge de Safari le cache au lieu de le fermer. Pour que Safari écoute Heartware :",
        steps: safariSteps)

    /// Back as a warning, when Safari did not take the app's script (to pause, or for its picture in picture).
    static let safariPause = HelpTip(
        id: "media.videoOnly.safari", title: "Pour que Safari écoute Heartware",
        text: "Il se met alors en pause tout seul et la vidéo reprend ici à la même seconde ; Netflix, Prime Video ou Disney+ passent dans son image dans l'image. Dans Chrome, Brave ou Edge : Présentation › Options pour les développeurs › Autoriser JavaScript à partir des évènements Apple.",
        steps: safariSteps)

    static let safariSteps = [
        "Dans Safari, Réglages… › Avancées : coche « Afficher les fonctionnalités pour les développeurs web ».",
        "Onglet Développeur : coche « Autoriser JavaScript à partir des évènements Apple » (Safari demande ton mot de passe).",
        "Détache à nouveau la vidéo."
    ]

    static let handoff = HelpTip(
        id: "media.handoff", title: "YouTube et Twitch toujours sans pub",
        text: "Ton navigateur affiche YouTube ou Twitch : la page continue dans le lecteur, à la même seconde si possible, et son onglet se ferme. Pour la garder dans le navigateur, rouvre l'onglet (⌘⇧T) ou prends le bouton Safari du lecteur. YouTube Studio, YouTube Music et ton compte restent dans le navigateur. Heartware lit seulement l'adresse de l'onglet affiché, sans la garder. Plutôt d'un clic, avec un signet dans Safari :",
        steps: [
            "Clique sur « Copier le signet ».",
            "Dans Safari : Signets › Ajouter un signet, puis remplace son adresse par celle copiée.",
            "Sur une vidéo YouTube ou un direct Twitch, clique sur le signet : la page s'ouvre ici (Safari te demande une fois s'il peut ouvrir Heartware)."
        ])

    static let accounts = HelpTip(
        id: "media.accounts", title: "Tes comptes dans le lecteur",
        text: "Ta connexion reste dans Heartware, sur ce Mac : Heartware ne voit ni ton mot de passe ni ton compte. Google te propose une clé d'identification ? Choisis « Essayer une autre méthode », puis ton mot de passe.")

    static func blocker(_ m: AdBlockModel) -> HelpTip {
        let network = m.resolvers.first.map { ip in SecurityAudit.isPrivate(ip) ? "à ta box (\(ip))" : "à \(ip)" } ?? "au DNS de ton réseau"
        return HelpTip(
            id: "media.blocker", title: "Le bloqueur de pub",
            text: "Ton Mac demande l'adresse des sites à Control D, par un DNS chiffré qui applique les listes HaGeZi et dit ne garder aucun journal (sans le bloqueur : en clair, \(network)). Les pubs servies par le site lui-même passent : pour YouTube et Twitch, prends le lecteur sans pub. Un site ne marche plus ? Ajoute-le aux exceptions, ou passe en Équilibré.")
    }

    /// On hover over the counter: what it counts.
    static let counted = "Compté sur ce Mac, en direct dans le journal de macOS, pendant que Heartware tourne : les noms des sites y sont masqués. Les pubs vidéo coupées par le lecteur sans pub comptent aussi ; celles d'une extension de Safari, non."

    static func safariExtension(_ name: String) -> HelpTip {
        HelpTip(
            id: "media.safariExtension", title: "Pubs YouTube dans Safari",
            text: "Elles viennent des mêmes serveurs que les vidéos : aucun DNS ne peut les couper, une extension de Safari si. Vérifie ces trois réglages une fois :",
            steps: [
                "Safari › Réglages… › Extensions : coche « \(name) ».",
                "Toujours dans Extensions, « Modifier les sites web… » : choisis « Autoriser » pour youtube.com, ou pour tous les sites.",
                "Sur YouTube, clique sur son icône dans la barre d'outils et choisis « Complet ». Recharge la vidéo."
            ])
    }
}

// MARK: - The tabs

/// « Lecteur sans pub » : the player, what brings the browser's videos into it, its accounts, and Safari's own blocker.
struct AdBlockPlayerTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AdBlockPlayerPanel()
            TileRow(spacing: 16) {
                AdBlockVideoPanel()
                AdBlockHandoffPanel()
            }
            TileRow(spacing: 16) {
                AdBlockAccountsPanel()
                AdBlockYouTubePanel()
            }
        }
        .onAppear { app.adblock.refreshExtensions() }
    }
}

/// « Bloqueur de pub » : the DNS blocker of the whole Mac.
struct AdBlockBlockerTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.adblock
        VStack(alignment: .leading, spacing: 18) {
            if m.waitingForInstall, !m.state.isOn {
                AdBlockInstallSteps()
            } else {
                AdBlockStatusCard()
            }
            if m.installed || m.tally.total > 0 {
                AdBlockCounterPanel()
            }
            TileRow(spacing: 16) {
                AdBlockExceptionsPanel()
                AdBlockCheckPanel()
            }
        }
        .onAppear { m.refreshState() }
    }
}

// MARK: - The player

/// YouTube, Twitch and the free French platforms without their video ads, in a window of the app.
private struct AdBlockPlayerPanel: View {
    @Environment(AppModel.self) private var app
    @State private var link = ""

    var body: some View {
        let m = app.adblock
        // Every site of the player counts (YouTube, Twitch, France.tv…).
        let cut = m.tally.apps.filter { $0.key.hasPrefix("Lecteur sans pub · ") }.reduce(0) { $0 + $1.value }
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button { m.player.open(AdBlockPlayer.youtube) } label: { label("YouTube sans pub", "play.rectangle.fill") }
                        .buttonStyle(SoftButtonStyle(prominent: true))
                    Button { m.player.open(AdBlockPlayer.twitch) } label: { label("Twitch sans pub", "tv") }
                        .buttonStyle(SoftButtonStyle(prominent: true))
                    Text("Aussi").font(.ui(11.5)).foregroundStyle(Theme.text3).padding(.leading, 6)
                    ForEach(AdBlockPlayerSite.others) { site in
                        Button(site.name) { m.player.open(site.home) }
                            .buttonStyle(SoftButtonStyle(small: true))
                            .help(site.limit ?? "Sans compte ni pub")
                    }
                    Spacer(minLength: 0)
                    if cut > 0 { Tag(text: Fmt.plural(cut, "pub vidéo coupée", "pubs vidéo coupées"), symbol: "hand.raised.fill", tint: Theme.good, filled: true) }
                    HelpTipButton(tip: AdBlockTips.player)
                }
                HStack(spacing: 8) {
                    AdBlockField(placeholder: "Colle un lien YouTube, Twitch, France.tv, M6+, Arte ou Pluto TV", text: $link) { watch() }
                    Button("Regarder") { watch() }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .disabled(AdBlockPlayer.playable(link) == nil)
                }
            }
        }
    }

    private func watch() {
        guard let url = AdBlockPlayer.playable(link) else { return }
        app.adblock.player.open(url)
        link = ""
    }

    private func label(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            if Theme.icons != .hidden { Image(systemName: symbol).font(.ui(12, .semibold)) }
            Text(text)
        }
    }
}

/// Shown only when the profile's level or exceptions changed since it was installed.
struct AdBlockBottomBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.adblock
        if m.needsReinstall, !m.waitingForInstall {
            ActionBar {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Changements à appliquer").font(.serif(17)).foregroundStyle(Theme.text)
                    Text("Niveau \(m.settings.level.title) · \(Fmt.plural(m.settings.exceptions.count, "exception", "exceptions")) : réinstalle le profil, macOS remplace l'ancien.")
                        .font(.ui(11)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Button("Réinstaller le profil") { m.install() }
                    .buttonStyle(SoftButtonStyle(prominent: true))
            }
        }
    }
}

// MARK: - State, level and main actions

private struct AdBlockStatusCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.adblock
        Card(padding: 22) {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(headline(m)).font(.serif(24)).foregroundStyle(Theme.text)
                        HelpTipButton(tip: AdBlockTips.blocker(m), size: 15)
                    }
                    if let detail = detail(m) {
                        Text(detail).font(.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    AdBlockLevelChoice()
                        .padding(.top, 2)
                    HStack(spacing: 10) { buttons(m) }
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
                if m.measuring {
                    VStack(alignment: .trailing, spacing: 8) {
                        BusyMascot(.inspecting, pixel: 4)
                        Text(m.measuringLevel.map { "Je questionne le DNS du niveau \($0.title)…" } ?? "J'essaie \(AdBlockCanary.ads.count + AdBlockCanary.useful.count) domaines…")
                            .font(.ui(11.5)).foregroundStyle(Theme.text3)
                    }
                    .frame(width: 220, alignment: .trailing)
                } else if let measure = m.measure, !measure.offline {
                    AdBlockScore(measure: measure)
                }
            }
        }
    }

    private func headline(_ m: AdBlockModel) -> String {
        switch m.state {
        case .on: return "Les pubs sont bloquées sur tout le Mac"
        case .off: return m.installed && !m.waitingForInstall ? "Le bloqueur n'est plus actif" : "Les pubs passent encore"
        case .offline: return "Pas de réseau pour vérifier"
        case .checking, .unknown: return "Vérification du blocage…"
        }
    }

    /// One line, two when something needs doing.
    private func detail(_ m: AdBlockModel) -> String? {
        switch m.state {
        case .on:
            var text = "Navigateurs, apps et jeux en profitent, sans rien installer d'autre."
            if m.settings.installedLevel == nil { text = "Un autre outil que Heartware bloque déjà les pubs sur ce Mac." }
            // Measured: a browser left open keeps its connections to the ad servers for a few minutes.
            if let at = m.settings.installedAt, Date().timeIntervalSince(at) < 15 * 60 {
                text += " Recharge tes pages ouvertes : un navigateur garde ses connexions aux régies quelques minutes."
            }
            return text
        case .off:
            return m.installed && !m.waitingForInstall
                ? "Le profil a été retiré, ou désactivé dans Réglages Système › Réseau › Filtres."
                : "Un profil DNS pour tous tes navigateurs, apps et jeux, que tu approuves dans Réglages Système et retires quand tu veux."
        case .offline:
            return "Aucun site ne répond : reconnecte-toi, puis vérifie à nouveau."
        case .checking, .unknown:
            return nil
        }
    }

    @ViewBuilder
    private func buttons(_ m: AdBlockModel) -> some View {
        switch m.state {
        case .on:
            Button { m.runMeasure() } label: { label("Mesurer sur ce Mac", "gauge.with.needle") }
                .buttonStyle(SoftButtonStyle(prominent: true))
                .disabled(m.measuring)
            if m.installed {
                Button { m.remove() } label: { label(m.removing ? "Retrait…" : "Désactiver", "hand.raised.slash") }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(m.removing)
            }
        case .off:
            Button { m.install() } label: { label(m.installed ? "Réinstaller le bloqueur" : "Installer le bloqueur", "hand.raised") }
                .buttonStyle(SoftButtonStyle(prominent: true))
            Button { m.runMeasure(level: m.settings.level) } label: { label("Mesurer avant d'installer", "gauge.with.needle") }
                .buttonStyle(SoftButtonStyle())
                .disabled(m.measuring)
                .help("Pose les mêmes questions au DNS du niveau \(m.settings.level.title), sans rien changer sur ton Mac")
        case .offline, .unknown:
            Button { m.refreshState() } label: { label("Vérifier", "arrow.clockwise") }
                .buttonStyle(SoftButtonStyle())
        case .checking:
            BusyMascot(.inspecting, pixel: 1)
        }
    }

    private func label(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            if Theme.icons != .hidden { Image(systemName: symbol).font(.ui(11.5, .semibold)) }
            Text(text)
        }
    }
}

/// Équilibré or Maximal, in a line, with what the chosen one blocks.
private struct AdBlockLevelChoice: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.adblock
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Niveau").font(.ui(12, .medium)).foregroundStyle(Theme.text3)
                GlassGroup(selection: m.settings.level, axis: .horizontal, radius: 6, pick: { m.settings.level = $0 }) {
                    HStack(spacing: 0) {
                        ForEach(AdBlockLevel.allCases) { level in chip(level, m).glassItem(level) }
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous).fill(Theme.fill1))
                .overlay(RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
                if m.needsReinstall, let installed = m.settings.installedLevel, installed != m.settings.level {
                    Text("Le profil installé est en \(installed.title)").font(.ui(11.5, .medium)).foregroundStyle(Theme.warn)
                }
            }
            Text(m.settings.level.detail).font(.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(_ level: AdBlockLevel, _ m: AdBlockModel) -> some View {
        let on = m.settings.level == level
        var active = false
        if case .on(let l) = m.state, l == level { active = true }
        return Button { m.settings.level = level } label: {
            HStack(spacing: 5) {
                if active, Theme.icons != .hidden { Image(systemName: "checkmark").font(.ui(9.5, .bold)) }
                Text(level.title).font(.ui(12, .medium))
                if level == .maximal { Text("recommandé").font(.ui(10.5)).opacity(0.75) }
            }
            .foregroundStyle(on ? Theme.text : Theme.text2)
            .padding(.horizontal, 10).frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(level.list)\(active ? " · actif sur ce Mac" : "")")
    }
}

/// The share of ads blocked by the last measurement, big, and its detail on a click.
private struct AdBlockScore: View {
    var measure: AdBlockMeasure
    @State private var detail = false

    var body: some View {
        let broken = measure.useful.filter { $0.verdict != .open }.count
        VStack(alignment: .trailing, spacing: 6) {
            Text("\(Int((measure.share * 100).rounded())) %").font(.serif(40)).foregroundStyle(Theme.text).monospacedDigit()
            Text("des pubs et pisteurs testés bloqués").font(.ui(11.5)).foregroundStyle(Theme.text3)
            UsageBar(fraction: measure.share, tint: measure.share >= 0.8 ? Theme.good : (measure.share >= 0.4 ? Theme.warn : Theme.bad), height: 7)
                .frame(width: 200)
            if broken > 0 {
                Text(Fmt.plural(broken, "site utile sans réponse", "sites utiles sans réponse")).font(.ui(11, .medium)).foregroundStyle(Theme.warn)
            }
            HStack(spacing: 6) {
                Text(measure.level.map { "Aperçu du niveau \($0.title) · \(Fmt.relative(measure.date))" } ?? "Sur ce Mac · \(Fmt.relative(measure.date))")
                    .font(.ui(11)).foregroundStyle(Theme.text3)
                Button("Détail") { detail.toggle() }
                    .buttonStyle(.plain).font(.ui(11, .medium)).foregroundStyle(Theme.accent)
                    .popover(isPresented: $detail, arrowEdge: .bottom) { AdBlockMeasureDetail(measure: measure) }
            }
            .fixedSize()
        }
        .frame(minWidth: 240, alignment: .trailing)
    }
}

/// After the profile was opened: what to do in System Settings.
private struct AdBlockInstallSteps: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.adblock
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    BusyMascot(.checking, pixel: 2)
                    Text("Encore une étape dans Réglages Système").font(.ui(15, .semibold)).foregroundStyle(Theme.text)
                }
                step(1, "Général › Gestion des appareils (ou Profils) : double-clique « \(AdBlockProfile.displayName) ».")
                step(2, "Clique sur Installer, puis confirme avec ton mot de passe.")
                step(3, "Reviens ici : la vérification se lance toute seule.")
                HStack(spacing: 10) {
                    Button("Ouvrir les profils") { m.openProfiles() }
                        .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                    Button("Vérifier maintenant") { m.refreshState() }
                        .buttonStyle(SoftButtonStyle(small: true))
                    Button("Annuler") { m.waitingForInstall = false }
                        .buttonStyle(SoftButtonStyle(small: true))
                }
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.ui(11.5, .bold)).foregroundStyle(Theme.onAccent)
                .frame(width: 20, height: 20).background(Circle().fill(Theme.accent))
            Text(text).font(.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Exceptions

private struct AdBlockExceptionsPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var m = app.adblock
        Panel(title: "Exceptions", subtitle: "Ces sites passent sans filtre", symbol: "checkmark.shield", tint: AdBlockStyle.tint) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    AdBlockField(placeholder: "boutique.fr ou l'adresse d'une page", text: $m.exceptionDraft) { m.addException(m.exceptionDraft) }
                    Button("Ajouter") { m.addException(m.exceptionDraft) }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .disabled(m.exceptionDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error = m.exceptionError {
                    Text(error).font(.ui(11.5, .medium)).foregroundStyle(Theme.warn)
                }
                if m.settings.exceptions.isEmpty {
                    Text("Aucune. Les Wi-Fi publics et ton réseau local passent déjà sans filtre.")
                        .font(.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                } else {
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(m.settings.exceptions, id: \.self) { d in
                            HStack(spacing: 5) {
                                Text(d).font(.ui(11.5, .medium)).foregroundStyle(Theme.text)
                                Button { m.removeException(d) } label: {
                                    Image(systemName: "xmark").font(.ui(9, .bold)).foregroundStyle(Theme.text3)
                                }
                                .buttonStyle(.plain)
                                .help("Retirer l'exception")
                            }
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(PillShape().fill(Theme.track))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Checking a domain

private struct AdBlockCheckPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var m = app.adblock
        Panel(title: "Vérifier un domaine", subtitle: "Un site affiche une erreur ? Regarde s'il est bloqué", symbol: "magnifyingglass", tint: AdBlockStyle.tint) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    AdBlockField(placeholder: "pub.exemple.fr", text: $m.checkText) { m.checkDomain() }
                    Button("Vérifier") { m.checkDomain() }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .disabled(m.checking || m.checkText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if m.checking {
                    HStack(spacing: 10) {
                        BusyMascot(.searching, pixel: 1.5)
                        Text("Je regarde sur ce Mac et dans la liste \(m.settings.level.list)…").font(.ui(12)).foregroundStyle(Theme.text3)
                    }
                } else if let c = m.check {
                    VStack(alignment: .leading, spacing: 6) {
                        if c.onMac == .missing, c.inList == .missing {
                            line("Ce domaine n'existe pas : vérifie son orthographe", ok: false)
                        } else {
                            line(macText(c.onMac), ok: c.onMac.stopped)
                            line(listText(c), ok: c.inList == .blocked)
                        }
                        if c.excepted {
                            line("Dans tes exceptions : il passe toujours", ok: false)
                        }
                    }
                    HStack(spacing: 8) {
                        if c.excepted {
                            Button("Retirer des exceptions") {
                                for e in m.settings.exceptions where c.domain == e || c.domain.hasSuffix("." + e) { m.removeException(e) }
                            }
                            .buttonStyle(SoftButtonStyle(small: true))
                        } else if c.onMac.stopped || c.inList == .blocked {
                            Button("Ajouter aux exceptions") { m.addException(c.domain) }
                                .buttonStyle(SoftButtonStyle(small: true))
                        }
                    }
                }
            }
        }
    }

    private func macText(_ v: AdBlockVerdict) -> String {
        switch v {
        case .blocked: return "Bloqué sur ce Mac"
        case .missing: return "Introuvable sur ce Mac (bloqué par un autre outil ?)"
        case .open: return "Passe sur ce Mac"
        case .unknown: return "Pas de réponse sur ce Mac"
        }
    }

    private func listText(_ c: AdBlockCheck) -> String {
        switch c.inList {
        case .blocked: return "Dans la liste \(c.level.list)"
        case .open, .missing: return "Pas dans la liste \(c.level.list)"
        case .unknown: return "Liste \(c.level.list) injoignable"
        }
    }

    private func line(_ text: String, ok: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").font(.ui(12)).foregroundStyle(ok ? Theme.good : Theme.text3)
            Text(text).font(.ui(12.5)).foregroundStyle(Theme.text)
        }
    }
}

/// A plain text field (a drawn one in snapshots).
struct AdBlockField: View {
    var placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void

    var body: some View {
        Group {
            if Snapshot.isActive {
                Text(text.isEmpty ? placeholder : text).font(.ui(12.5)).foregroundStyle(text.isEmpty ? Theme.text3 : Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.ui(12.5))
                    .onSubmit(onSubmit)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(8)).strokeBorder(Theme.border, lineWidth: Theme.line))
    }
}

// MARK: - Measurement

/// Every domain the last measurement tried, in the score's bubble.
private struct AdBlockMeasureDetail: View {
    var measure: AdBlockMeasure

    var body: some View {
        let missed = measure.ads.filter { !$0.verdict.stopped }
        let broken = measure.useful.filter { $0.verdict != .open }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                figure("\(measure.blockedAds)/\(measure.ads.count)", "pubs et pisteurs bloqués")
                figure("\(measure.useful.count - broken.count)/\(measure.useful.count)", "sites utiles joignables")
            }
            if !missed.isEmpty {
                Text("Passent encore : " + missed.map(\.domain).joined(separator: ", "))
                    .font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            if !broken.isEmpty {
                Text("Sites utiles sans réponse : " + broken.map(\.domain).joined(separator: ", "))
                    .font(.ui(11.5, .medium)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            ScrollArea(showsIndicators: true) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 5) {
                    ForEach(measure.probes) { p in
                        HStack(spacing: 6) {
                            Image(systemName: p.good ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.ui(11)).foregroundStyle(p.good ? Theme.good : (p.shouldBlock ? Theme.warn : Theme.bad))
                            Text(p.domain).font(.mono(11)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(p.shouldBlock ? (p.verdict.stopped ? "bloqué" : "passe") : (p.verdict == .open ? "joignable" : "bloqué"))
                                .font(.ui(10.5)).foregroundStyle(Theme.text3)
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(16)
        .frame(width: 560, alignment: .leading)
        .presentationBackground(Theme.card)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.serif(22)).foregroundStyle(Theme.text).monospacedDigit()
            Text(label).font(.ui(11)).foregroundStyle(Theme.text3)
        }
    }
}
