import SwiftUI

/// The panel in the middle of the main window, the app dimmed behind it: until the user answers, nothing else in the
/// window answers clicks or the keyboard (Esc closes it, like "Plus tard").
struct UpdatesSelfModal: View {
    var body: some View {
        ZStack {
            // The only fixed color: a veil that darkens whatever theme is behind it.
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture {}
            UpdatesSelfPanel()
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .ignoresSafeArea()
    }
}

/// The panel that announces a new version of Clean My Claude, lists what changed,
/// and follows the download and installation when the user asks for it.
struct UpdatesSelfPanel: View {
    static let width: CGFloat = 440
    static let height: CGFloat = 600

    @Environment(AppModel.self) private var app
    /// The password of the signing keychain: kept only until "Signer".
    @State private var signingPassword = ""

    var body: some View {
        let m = app.updates.selfUpdate
        VStack(alignment: .leading, spacing: 0) {
            header(m)
            if let r = m.release {
                changes(r)
                footer(m, r)
            } else {
                upToDate(m)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .floatingSurface(radius: 18)
    }

    // MARK: Header

    private func header(_ m: UpdatesSelfModel) -> some View {
        ZStack(alignment: .topLeading) {
            DustBackdrop(seed: 61, opacity: 0.45)
                .frame(height: 120)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    BrandMark(size: 26)
                    Spacer(minLength: 8)
                    Button { m.closePanel() } label: {
                        Image(systemName: "xmark")
                            .font(.ui(10, .bold))
                            .foregroundStyle(Theme.text2)
                            .frame(width: 22, height: 22)
                            .background(PillShape().fill(Theme.track))
                            .contentShape(PillShape())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help(m.step.isBusy ? "Masquer : le téléchargement continue" : "Plus tard")
                }
                .frame(minHeight: 26)
                Text(m.release == nil ? "\(AppEdition.name) est à jour" : "Une nouvelle version est là")
                    .font(.serif(26))
                    .foregroundStyle(Theme.text)
                if let r = m.release {
                    Text("\(AppEdition.name) \(r.version)" + (r.published.map { " · publiée \(Fmt.relative($0))" } ?? ""))
                        .font(.ui(12.5))
                        .foregroundStyle(Theme.text2)
                    HStack(spacing: 6) {
                        Tag(text: "Tu as la \(m.build.version ?? "?")", symbol: "checkmark.circle", tint: Theme.text2)
                        if r.size > 0 { Tag(text: Fmt.bytes(r.size), symbol: "arrow.down.circle", tint: Theme.text2) }
                        if m.isSkipped { Tag(text: "Ignorée", symbol: "eye.slash", tint: Theme.warn, filled: true) }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
        }
    }

    // MARK: What changed

    private func changes(_ r: UpdatesSelfRelease) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Ce qui change")
                Text(Fmt.plural(r.changeCount, "changement", "changements"))
                    .font(.ui(11))
                    .foregroundStyle(Theme.text3)
                    .fixedSize()
            }
            ScrollArea {
                VStack(alignment: .leading, spacing: 14) {
                    if r.changes.isEmpty {
                        EmptyHint(text: "GitHub ne détaille pas ce qui change depuis ta version : la page de la version en dit plus.",
                                  symbol: Theme.icons == .hidden ? nil : "doc.text.magnifyingglass")
                    }
                    ForEach(r.changes) { UpdatesSelfChangeRow(change: $0) }
                    if r.moreChanges > 0 {
                        Text("Et \(Fmt.plural(r.moreChanges, "autre changement", "autres changements")), à lire sur GitHub.")
                            .font(.ui(11.5))
                            .foregroundStyle(Theme.text3)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The list takes what the header and the answer leave, and scrolls (it is cut in snapshots).
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous))
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Footer: the answer, then each step

    @ViewBuilder
    private func footer(_ m: UpdatesSelfModel, _ r: UpdatesSelfRelease) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let blocker = m.blocker, !m.step.isBusy, !m.step.awaitsUser {
                Callout(symbol: "hand.raised", title: "Mise à jour sur place impossible", text: blocker, tint: Theme.warn)
                HStack(spacing: 8) {
                    skipButton(m)
                    Spacer()
                    Button("Copier la commande") { m.copyInstallCommand() }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .help(UpdatesSelfGitHub.installCommand)
                    Button("Voir sur GitHub") { m.openReleasePage() }
                        .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                }
            } else {
                step(m, r)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill1)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder
    private func step(_ m: UpdatesSelfModel, _ r: UpdatesSelfRelease) -> some View {
        switch m.step {
        case .idle:
            if let note = m.placeNote {
                Text(note)
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Je télécharge la version publiée sur GitHub\(r.size > 0 ? " (\(Fmt.bytes(r.size)))" : ""), je vérifie son empreinte et sa signature, puis tu choisis quand relancer.\(m.placeNote == nil ? " L'ancienne version part à la Corbeille." : "")")
                .font(.ui(11.5))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                skipButton(m)
                Spacer()
                Button("Plus tard") { m.later() }
                    .buttonStyle(SoftButtonStyle())
                Button("Mettre à jour") { m.startUpdate() }
                    .buttonStyle(SoftButtonStyle(prominent: true))
            }
        case .downloading(let received, let expected):
            HStack(alignment: .center) {
                BusyMascot(.downloading, pixel: 1.5)
                Text("Téléchargement…").font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text(expected > 0 ? "\(Fmt.bytes(received)) sur \(Fmt.bytes(expected))" : Fmt.bytes(received))
                    .font(.mono(11))
                    .foregroundStyle(Theme.text2)
                    .monospacedDigit()
            }
            UsageBar(fraction: expected > 0 ? Double(received) / Double(expected) : 0, tint: Theme.accent, height: 6)
            HStack(spacing: 8) {
                Text("Tu peux fermer ce panneau : il revient quand tout est prêt.")
                    .font(.ui(11))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Button("Annuler") { m.cancelUpdate() }
                    .buttonStyle(SoftButtonStyle(small: true))
            }
        case .verifying:
            HStack(spacing: 8) {
                UpdatesSpinner(activity: m.signing ? .typing : .inspecting)
                Text(m.signing ? "Signature avec ton certificat local…" : "Vérification de l'empreinte et de la signature…")
                    .font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if !m.signing {
                    Button("Annuler") { m.cancelUpdate() }
                        .buttonStyle(SoftButtonStyle(small: true))
                }
            }
        case .password(let problem):
            HStack(spacing: 8) {
                if Theme.icons != .hidden {
                    Image(systemName: "key.fill").font(.ui(13, .semibold)).foregroundStyle(Theme.accent)
                }
                Text("Vérifiée : reste à la signer").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
            }
            Text("Pour que macOS garde tes autorisations, je la signe avec ton certificat local « \(UpdatesSelfSigning.name) ». Saisis le mot de passe de son trousseau, celui choisi avec setup_signing.sh : il est déverrouillé le temps de signer, puis reverrouillé.")
                .font(.ui(11.5))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if Snapshot.isActive {
                    Text(problem == nil ? "Mot de passe du trousseau de signature" : "••••••••")
                        .font(.ui(12.5)).foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(7)
                        .background(RoundedRectangle(cornerRadius: Theme.r(7), style: .continuous).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: Theme.r(7), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
                } else {
                    SecureField("Mot de passe du trousseau de signature", text: $signingPassword)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { sign(m) }
                }
                Button("Signer") { sign(m) }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .disabled(signingPassword.isEmpty && !Snapshot.isActive)
            }
            if let problem {
                Text(problem).font(.ui(11.5)).foregroundStyle(Theme.bad).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Installer sans re-signer") { m.skipSigning() }
                    .buttonStyle(SoftButtonStyle(small: true))
                    .help("Garde la signature publiée : macOS te redemandera l'Accessibilité et l'accès complet au disque.")
                Spacer()
                Button("Annuler") { m.cancelUpdate() }
                    .buttonStyle(SoftButtonStyle(small: true))
            }
        case .ready:
            HStack(spacing: 8) {
                if Theme.icons != .hidden {
                    Image(systemName: "checkmark.seal.fill").font(.ui(14, .semibold)).foregroundStyle(Theme.good)
                }
                Text("Prête à installer").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
            }
            Text(m.readyNote(r.version))
                .font(.ui(11.5))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            Text(continuityNote(m.continuity))
                .font(.ui(11))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Annuler") { m.cancelUpdate() }
                    .buttonStyle(SoftButtonStyle())
                Button("Installer et relancer") { m.installAndRelaunch() }
                    .buttonStyle(SoftButtonStyle(prominent: true))
            }
        case .installing:
            HStack(spacing: 8) {
                UpdatesSpinner(activity: .unpacking)
                Text("Installation, puis relance…").font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
            }
        case .failed(let message):
            Callout(symbol: "exclamationmark.triangle", title: "La mise à jour n'a pas abouti", text: message, tint: Theme.warn)
            HStack(spacing: 8) {
                if m.signingRefused {
                    Button("Installer sans re-signer") { m.startUpdate(resign: false) }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .help("Garde la signature publiée : macOS te redemandera l'Accessibilité et l'accès complet au disque.")
                } else {
                    Button("Voir sur GitHub") { m.openReleasePage() }
                        .buttonStyle(SoftButtonStyle(small: true))
                }
                Spacer()
                Button("Plus tard") { m.later() }
                    .buttonStyle(SoftButtonStyle())
                Button("Réessayer") { m.startUpdate() }
                    .buttonStyle(SoftButtonStyle(prominent: true))
            }
        }
    }

    private func continuityNote(_ c: UpdatesSelfSigning.Continuity) -> String {
        switch c {
        case .local: return "Signée avec ton certificat local : macOS garde les autorisations déjà accordées."
        case .kept: return "Signée par \(AppEdition.name), comme ta copie : macOS garde les autorisations et l'accès au trousseau déjà accordés."
        case .firstRelease: return "Elle est signée par \(AppEdition.name), ta copie ne l'était pas encore : macOS te redemandera une dernière fois certaines autorisations (Accessibilité, accès complet au disque) et l'accès au trousseau, puis les gardera aux mises à jour suivantes."
        case .adhoc: return "La version publiée n'est pas signée par un développeur reconnu d'Apple : macOS te redemandera peut-être certaines autorisations (Accessibilité, accès complet au disque)."
        }
    }

    private func sign(_ m: UpdatesSelfModel) {
        guard !signingPassword.isEmpty else { return }
        m.signStaged(password: signingPassword)
        signingPassword = ""
    }

    private func skipButton(_ m: UpdatesSelfModel) -> some View {
        Button(m.isSkipped ? "Ne plus ignorer" : "Ignorer cette version") {
            if m.isSkipped { m.unskip() } else { m.skip() }
        }
        .buttonStyle(.plain)
        .font(.ui(11.5))
        .foregroundStyle(Theme.text3)
        .help(m.isSkipped ? "Le panneau reviendra tout seul pour cette version." : "Le panneau ne reviendra tout seul qu'à la prochaine version.")
    }

    private func upToDate(_ m: UpdatesSelfModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tu as la dernière version publiée : \(m.build.label).")
                .font(.ui(12.5))
                .foregroundStyle(Theme.text2)
            if let d = m.lastCheck {
                Text("Vérifié \(Fmt.relative(d)).").font(.ui(11.5)).foregroundStyle(Theme.text3)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Fermer") { m.closePanel() }
                    .buttonStyle(SoftButtonStyle(prominent: true))
            }
        }
        .padding(22)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// One change: its topic as a tag ("Lanceur"), its title, then its points.
struct UpdatesSelfChangeRow: View {
    var change: UpdatesSelfChange

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let topic = change.title.topic {
                    Tag(text: topic, tint: Self.tint(topic), filled: true)
                }
                Text(change.title.text)
                    .font(.ui(12.5, .semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(change.details, id: \.self) { d in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").font(.ui(11.5)).foregroundStyle(Theme.text3)
                    (Text(d.topic.map { $0 + " : " } ?? "").font(.ui(11.5, .medium)).foregroundColor(Theme.text)
                     + Text(d.text).font(.ui(11.5)).foregroundColor(Theme.text2))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 2)
            }
        }
    }

    /// The same topic always gets the same color of the theme's palette (plain text in the themes without tinted icons,
    /// where some palette colors are too faint for a label).
    static func tint(_ topic: String) -> Color {
        guard Theme.icons == .tinted else { return Theme.text2 }
        return Theme.color(index: topic.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF })
    }
}

/// Clean My Claude's own version on the Mises à jour page.
struct UpdatesSelfCard: View {
    @Environment(AppModel.self) private var app
    @AppStorage(UpdatesSelfModel.autoKey) private var auto = true

    var body: some View {
        let m = app.updates.selfUpdate
        Panel(title: "\(AppEdition.name)", subtitle: subtitle(m), symbol: "sparkle", tint: Theme.brand) {
            HStack(spacing: 10) {
                Toggle(isOn: $auto) {
                    Text("Vérifier tout seul").font(.ui(11.5)).foregroundStyle(Theme.text2)
                }
                .switchToggles()
                .controlSize(.mini)
                .fixedSize()
                .disabled(DemoData.isEnabled || !m.canCheck)
                .help("Au lancement puis toutes les 6 h, l'app demande à GitHub le numéro de sa dernière version publiée : c'est la seule connexion qu'elle fait sans ton clic, et elle n'envoie rien d'autre.")
                UpdatesCheckButton(state: m.state) { Task { await m.check(announce: false) } }
                    .disabled(!m.canCheck || m.step.isBusy)
            }
        } content: {
            if let r = m.release {
                available(m, r)
            } else if case .failed(let message) = m.state {
                Text(message).font(.ui(12)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func subtitle(_ m: UpdatesSelfModel) -> String {
        if let r = m.release { return "La version \(r.version) est publiée sur GitHub. Tu as la \(m.build.label)." }
        guard m.canCheck else {
            return AppEdition.isLab ? "Version Labo \(m.build.label) : reconstruite à chaque essai, jamais remplacée par une version publiée."
                                    : "Version de développement : rien à comparer aux versions publiées."
        }
        if let d = m.state.date { return "Tu as la dernière version : \(m.build.label). Vérifié \(Fmt.relative(d))." }
        return "Ta version : \(m.build.label)."
    }

    @ViewBuilder
    private func available(_ m: UpdatesSelfModel, _ r: UpdatesSelfRelease) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Version \(r.version) disponible").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                    if m.isSkipped { Tag(text: "Ignorée", tint: Theme.warn, filled: true) }
                }
                Text([Fmt.plural(r.changeCount, "changement", "changements"),
                      r.published.map { "publiée \(Fmt.relative($0))" }, r.size > 0 ? Fmt.bytes(r.size) : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
            switch m.step {
            case .downloading(let received, let expected):
                UpdatesSpinner(activity: .downloading)
                UsageBar(fraction: expected > 0 ? Double(received) / Double(expected) : 0, tint: Theme.accent, height: 5)
                    .frame(width: 120)
                Button("Afficher") { m.showPanel() }.buttonStyle(SoftButtonStyle(small: true))
            case .verifying, .installing:
                UpdatesSpinner(activity: m.step == .installing ? .unpacking : .inspecting)
                Button("Afficher") { m.showPanel() }.buttonStyle(SoftButtonStyle(small: true))
            case .password:
                Button("Signer et installer") { m.showPanel() }.buttonStyle(SoftButtonStyle(prominent: true, small: true))
            case .ready:
                Button("Installer et relancer") { m.showPanel() }.buttonStyle(SoftButtonStyle(prominent: true, small: true))
            case .idle, .failed:
                Button("Voir les nouveautés") { m.showPanel() }.buttonStyle(SoftButtonStyle(prominent: true, small: true))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous).fill(Theme.brand.opacity(Theme.icons == .tinted ? 0.08 : 0)))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
    }
}
