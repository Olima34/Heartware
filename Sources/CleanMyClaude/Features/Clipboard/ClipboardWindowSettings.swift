import SwiftUI
import AppKit

// MARK: - Settings

/// The history's settings, in its own window at the same size: what is kept and how it is pasted on the left,
/// the ignored apps and the history itself (pause, clearing) on the right. ⎋ or the arrow goes back to the list.
struct ClipboardWindowSettings: View {
    @Environment(AppModel.self) private var app
    /// Re-reads Accessibility when the user comes back from System Settings.
    @State private var refresh = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                ScrollArea { options.padding(18) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Theme.border).frame(width: 1)
                side
                    .padding(18)
                    .frame(width: 320)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh += 1 }
    }

    private var header: some View {
        let w = app.clipboard.window
        return HStack(spacing: 12) {
            CommandIconView(icon: .symbol("gearshape", Theme.palette[4]), size: 26)
            Text("Réglages de l'historique").font(.ui(17)).foregroundStyle(Theme.text)
            Spacer()
            ClipboardStatePill()
            ClipboardWindowButton(symbol: "chevron.backward.circle.fill", help: "Revenir à l'historique (⎋)") { w.showSettings = false }
        }
        .frame(height: 26)
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    // MARK: Left: what is kept, pasting

    private var options: some View {
        @Bindable var m = app.clipboard
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                title("Ce qui est gardé")
                // "Au plus 200 éléments · jusqu'à 200 Mo · pendant 30 jours": the three caps in one sentence.
                HStack(spacing: 6) {
                    word("Au plus")
                    choice("Garder au plus", [50, 100, 200, 500, 1000], m.settings.maxItems, { Fmt.plural($0, "élément", "éléments") }) {
                        m.settings.maxItems = $0
                    }
                    word("· jusqu'à")
                    choice("Jusqu'à", [50, 200, 500, 1000], m.settings.maxStorageMB, { $0 >= 1000 ? "1 Go" : "\($0) Mo" }) {
                        m.settings.maxStorageMB = $0
                    }
                    word("· pendant")
                    choice("Pendant", [1, 7, 30, 0], m.settings.retentionDays, { $0 == 0 ? "toujours" : ($0 == 1 ? "1 jour" : "\($0) jours") }) {
                        m.settings.retentionDays = $0
                    }
                }
                .help("Au-delà, les plus anciens s'en vont. Les épingles ne sont jamais effacées automatiquement.")
                row("Garder les images", help: "Captures et photos copiées, enregistrées en PNG dans le dossier de l'app.", isOn: $m.settings.keepImages)
                row("Garder les fichiers", help: "Seul le chemin est gardé, pas une copie du fichier.", isOn: $m.settings.keepFiles)
                row("Ignorer les secrets probables",
                    help: "Clés d'API, jetons, clés privées, codes à usage unique, mots de passe copiés depuis un navigateur ou un terminal : reconnus à leur forme, ils ne sont pas enregistrés. Ce qu'un gestionnaire marque comme confidentiel ne l'est jamais.",
                    isOn: $m.settings.skipSecrets)
            }
            VStack(alignment: .leading, spacing: 10) {
                title("Coller")
                row("Coller directement", help: "↩ colle l'élément dans l'app où tu étais. Sinon, il est copié et tu colles avec ⌘V.",
                    isOn: $m.settings.pasteDirectly) {
                    if m.settings.pasteDirectly && !accessibilityGranted {
                        Button("Autoriser") { AppPermission.accessibility.request() }
                            .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                            .help("Pour coller à ta place, macOS demande l'accès Accessibilité. Sans lui, l'élément est seulement copié.")
                    }
                }
                accessRow
            }
        }
    }

    private var accessibilityGranted: Bool {
        let _ = refresh
        // The demo shows the button: it cannot paste anyway.
        return !DemoData.isEnabled && AppPermission.accessibility.isGranted
    }

    /// What macOS says about reading the clipboard (15.4 and later), in one line.
    private var accessRow: some View {
        let access = ClipboardAccess.current
        return HStack(spacing: 8) {
            Text("Accès macOS au presse-papiers").font(.ui(12.5)).foregroundStyle(Theme.text)
            Spacer(minLength: 6)
            if access == .denied || access == .ask {
                Button("Réglages") { ClipboardAccess.openPrivacySettings() }
                    .buttonStyle(SoftButtonStyle(small: true))
            }
            StatusBadge(status: access.status, text: access.label)
        }
        .help(access.explanation)
    }

    // MARK: Right: ignored apps, the history itself

    private var side: some View {
        let m = app.clipboard
        let w = m.window
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                title("Apps ignorées")
                Text(Fmt.int(m.settings.excluded.count)).font(.ui(11, .semibold)).foregroundStyle(Theme.text3).monospacedDigit()
                Spacer()
                if !m.settings.excluded.isEmpty {
                    Button(w.showExcluded ? "Masquer" : "Voir") { w.showExcluded.toggle() }
                        .buttonStyle(.plain)
                        .font(.ui(11.5)).foregroundStyle(Theme.accent)
                }
            }
            .help("Ce que tu copies dans ces apps n'est jamais enregistré.")
            if w.showExcluded {
                ScrollArea {
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(m.settings.excluded) { excludedChip($0) }
                    }
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                addMenu
                if m.settings.excluded != ClipboardFilter.passwordManagers {
                    Button("Liste par défaut") { m.settings.excluded = ClipboardFilter.passwordManagers }
                        .buttonStyle(.plain)
                        .font(.ui(11.5)).foregroundStyle(Theme.text3)
                        .help("Les gestionnaires de mots de passe, et rien d'autre")
                }
            }
            Spacer(minLength: 12)
            Rectangle().fill(Theme.border).frame(height: 1)
            historyBlock
                .padding(.top, 4)
        }
    }

    private func excludedChip(_ a: ClipboardExcludedApp) -> some View {
        HStack(spacing: 4) {
            Text(a.name).font(.ui(11.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
            Button { app.clipboard.removeExclusion(a.bundleID) } label: {
                Image(systemName: "xmark").font(.ui(8.5, .bold)).foregroundStyle(Theme.text3).frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("Ne plus ignorer \(a.name)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(PillShape().fill(Theme.card))
        .overlay(PillShape().strokeBorder(Theme.border, lineWidth: Theme.line))
        .help(a.bundleID)
    }

    /// The apps open now and those of the history, in one click; any other one through the Finder.
    private var addMenu: some View {
        let m = app.clipboard
        return BorderlessMenu {
            let candidates = m.excludeCandidates
            ForEach(candidates) { a in
                Button(a.name) { m.exclude(bundleID: a.bundleID, name: a.name) }
            }
            if !candidates.isEmpty { Divider() }
            Button("Autre app…") { m.window.chooseOtherApp() }
        } label: {
            Text("Ajouter une app").font(.ui(11.5, .medium)).foregroundStyle(Theme.accent)
        }
        .help("Ne plus rien garder de ce que tu copies dans une app")
    }

    @ViewBuilder
    private var historyBlock: some View {
        let m = app.clipboard
        let w = m.window
        let unpinned = m.items.filter { !$0.pinned }.count
        VStack(alignment: .leading, spacing: 8) {
            title("Historique")
            if w.confirmClear {
                Text(ClipboardWindowSettings.clearQuestion(unpinned: unpinned)).font(.ui(12, .medium)).foregroundStyle(Theme.text)
                Text("Images comprises. Les épingles restent.").font(.ui(11)).foregroundStyle(Theme.text3)
                HStack(spacing: 8) {
                    Button("Annuler") { w.confirmClear = false }
                        .buttonStyle(SoftButtonStyle(small: true))
                    Button("Effacer") {
                        m.clear()
                        w.confirmClear = false
                        HUD.show("Historique effacé", symbol: "trash.fill")
                    }
                    .buttonStyle(SoftButtonStyle(destructive: true, small: true))
                }
            } else {
                Text(summary(m)).font(.ui(11.5)).foregroundStyle(Theme.text3).monospacedDigit()
                HStack(spacing: 8) {
                    Button(m.settings.enabled ? "Mettre en pause" : "Reprendre") { m.setEnabled(!m.settings.enabled) }
                        .buttonStyle(SoftButtonStyle(prominent: !m.settings.enabled, small: true))
                    // Pinned items are never cleared: with only those, there is nothing to clear.
                    if unpinned > 0 {
                        Button("Tout effacer…") { w.confirmClear = true }
                            .buttonStyle(SoftButtonStyle(small: true))
                    }
                }
            }
        }
    }

    private func summary(_ m: ClipboardModel) -> String {
        var parts = [Fmt.plural(m.items.count, "élément", "éléments")]
        if !m.items.isEmpty { parts.append(Fmt.bytes(m.totalBytes)) }
        let pins = m.items.filter(\.pinned).count
        if pins > 0 { parts.append(Fmt.plural(pins, "épingle", "épingles")) }
        return parts.joined(separator: " · ")
    }

    static func clearQuestion(unpinned: Int) -> String {
        unpinned == 1 ? "Effacer l'élément non épinglé ?" : "Effacer les \(Fmt.int(unpinned)) éléments non épinglés ?"
    }

    private var footer: some View {
        let m = app.clipboard
        return HStack(spacing: 14) {
            LauncherKeyHint(key: "⎋", label: "Retour à l'historique")
            Spacer()
            if m.skipped > 0 {
                Text(Fmt.plural(m.skipped, "copie ignorée", "copies ignorées") + " depuis le lancement")
                    .font(.ui(11)).foregroundStyle(Theme.text3).monospacedDigit()
                    .help("Mots de passe, secrets probables, données temporaires, apps ignorées : rien n'en a été gardé.")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(height: 38)
        .background(Theme.fill1)
    }

    // MARK: Pieces

    private func title(_ text: String) -> some View {
        Text(text).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
    }

    private func word(_ text: String) -> some View {
        Text(text).font(.ui(12.5)).foregroundStyle(Theme.text2)
    }

    /// A value chosen from a short menu, inside the sentence of the caps. The caps apply at once.
    private func choice(_ name: String, _ values: [Int], _ current: Int, _ label: @escaping (Int) -> String,
                        _ pick: @escaping (Int) -> Void) -> some View {
        let m = app.clipboard
        return BorderlessMenu {
            Picker(name, selection: Binding(get: { current }, set: {
                pick($0)
                m.prune()
            })) {
                ForEach(values, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(label(current)).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
        }
    }

    /// "Garder les images ………… ◯": a switch at the end of its line, with what it does on hover.
    private func row<Extra: View>(_ name: String, help: String, isOn: Binding<Bool>, @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.ui(12.5)).foregroundStyle(Theme.text)
            Spacer(minLength: 6)
            extra()
            // The name is already on the left (the drawn switch of the snapshots would show a label again).
            Toggle(isOn: isOn) { EmptyView() }
                .labelsHidden()
                .switchToggles()
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel(name)
        }
        .help(help)
    }
}

// MARK: - Activation

/// Before the history was ever turned on: what is recorded (three points), and the button that turns it on.
struct ClipboardWindowActivation: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.clipboard
        // The demo shows the window of someone who has never been asked.
        let access = DemoData.isEnabled ? ClipboardAccess.notAsked : ClipboardAccess.current
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CommandIconView(icon: .symbol("doc.on.clipboard", Theme.palette[4]), size: 26)
                Text("Historique du presse-papiers").font(.ui(17)).foregroundStyle(Theme.text)
                Spacer()
            }
            .frame(height: 26)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            Rectangle().fill(Theme.border).frame(height: 1)

            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Retrouve tout ce que tu as copié").font(.serif(26)).foregroundStyle(Theme.text)
                    VStack(alignment: .leading, spacing: 10) {
                        point("tray.full", "Le texte, les liens, les images et les fichiers que tu copies, avec leur app.")
                        point("lock.shield", "Jamais les mots de passe, ni ce qui ressemble à un secret.")
                            .help("Ce qu'un gestionnaire marque comme confidentiel, ce qui est copié pendant que 1Password, Bitwarden, Mots de passe ou une autre app de ta liste est au premier plan, et ce qui ressemble à un secret : clé d'API, jeton, clé privée, code à usage unique.")
                        point("internaldrive", "Tout reste sur ce Mac : 200 éléments et 30 jours par défaut.")
                    }
                    Button { m.window.activate() } label: {
                        HStack(spacing: 6) {
                            if Theme.icons != .hidden { Image(systemName: "doc.on.clipboard.fill").font(.ui(11.5, .semibold)) }
                            Text("Activer l'historique")
                        }
                    }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .disabled(DemoData.isEnabled && !Snapshot.isActive)
                    .padding(.top, 6)
                    if let line = access.firstStep {
                        HStack(spacing: 8) {
                            Text(line).font(.ui(11.5)).foregroundStyle(access == .denied ? Theme.bad : Theme.text3)
                                .fixedSize(horizontal: false, vertical: true)
                            if access == .denied || access == .ask {
                                Button("Réglages") { ClipboardAccess.openPrivacySettings() }
                                    .buttonStyle(SoftButtonStyle(small: true))
                            }
                        }
                        .help(access.explanation)
                    }
                }
                .frame(maxWidth: 490, alignment: .leading)
                Spacer(minLength: 0)
                ClipboardIllustration()
            }
            .padding(.horizontal, 32)
            .frame(maxHeight: .infinity)

            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 14) {
                LauncherKeyHint(key: "⎋", label: "Fermer")
                Spacer()
                if let combo = m.combo {
                    LauncherKeyHint(key: combo.display, label: "Rouvre cette fenêtre")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(height: 38)
            .background(Theme.fill1)
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if Theme.icons != .hidden {
                Image(systemName: symbol).font(.ui(12, .medium))
                    .foregroundStyle(Theme.icons == .tinted ? Theme.palette[4] : Theme.text2).frame(width: 18).padding(.top, 1)
            }
            Text(text).font(.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Three little cards in a stack: a text, a picture, a link.
struct ClipboardIllustration: View {
    var body: some View {
        ZStack {
            card(symbol: "link", lines: [0.8, 0.5], tint: Theme.palette[1]).rotationEffect(.degrees(-9)).offset(x: -50, y: 62)
            card(symbol: "text.alignleft", lines: [0.9, 0.7, 0.45], tint: Theme.palette[4]).offset(x: -30, y: -46)
            card(symbol: "photo", lines: [0.6], tint: Theme.palette[5]).rotationEffect(.degrees(7)).offset(x: 66, y: 34)
        }
        .frame(width: 280, height: 250)
    }

    private func card(symbol: String, lines: [CGFloat], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.ui(15, .semibold)).foregroundStyle(tint)
                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(tint.opacity(0.15)))
            ForEach(Array(lines.enumerated()), id: \.offset) { _, w in
                PillShape().fill(Theme.borderStrong).frame(width: 120 * w, height: 6)
            }
        }
        .padding(14)
        .frame(width: 150, height: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous).fill(Theme.cardRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
        .themedShadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }
}
