import SwiftUI

/// The translator inside the launcher panel (⌥Espace › Traducteur, "trad …", a translation of the results, or its own
/// shortcut): the whole text, its whole translation; ↩ or the button copies it, ⇥ changes the language, ⌘↩ asks Claude.
/// The gear (⌘,) turns the panel to its settings: engine, languages to download, history.
struct TranslatorPanelView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if app.translator.showSettings {
                TranslatorSettingsView()
            } else {
                translation
            }
        }
        // In both views: a translation asked just before the gear still arrives.
        .background(TranslatorHost(channel: .panel))
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: app.translator.showSettings) { _, settings in
            if !settings { DispatchQueue.main.async { focused = true } }
        }
    }

    private var translation: some View {
        @Bindable var model = app.translator
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "character.bubble").font(.ui(19, .medium))
                    .foregroundStyle(Theme.palette[1]).frame(width: 24).padding(.top, 2)
                if Snapshot.isActive {
                    Text(model.sourceText.isEmpty ? "Texte à traduire…" : model.sourceText)
                        .font(.ui(17)).foregroundStyle(model.sourceText.isEmpty ? Theme.text3 : Theme.text)
                        .lineLimit(6).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // The whole sentence, not one line of it.
                    TextField("Texte à traduire…", text: $model.sourceText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.ui(17))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1...6)
                        .focused($focused)
                }
                TranslatorPanelButton(symbol: "gearshape.fill", help: "Réglages de la traduction (⌘,)") { model.showSettings = true }
                TranslatorPanelButton(symbol: "chevron.backward.circle.fill", help: "Revenir à la recherche (⎋)") { app.launcher.backToSearch() }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Rectangle().fill(Theme.border).frame(height: 1)

            HStack(spacing: 8) {
                sourceMenu
                Button { model.swapLanguages() } label: {
                    Image(systemName: "arrow.left.arrow.right").font(.ui(10.5, .semibold)).foregroundStyle(Theme.text3)
                        .frame(width: 22, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Inverser les langues")
                ForEach(model.panelTargets.filter { $0 != model.effectiveSource }, id: \.self) { code in
                    chip(code)
                }
                otherMenu
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            result
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            status
                .padding(.horizontal, 18)
                .padding(.bottom, 10)

            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 14) {
                LauncherKeyHint(key: "↩", label: "Copier la traduction")
                LauncherKeyHint(key: "⌘↩", label: "Claude")
                LauncherKeyHint(key: "⇥", label: "Langue")
                LauncherKeyHint(key: "⌘,", label: "Réglages")
                LauncherKeyHint(key: "⎋", label: "Retour")
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Theme.fill1)
        }
    }

    /// The text's language: detected, or picked when it is not recognized.
    private var sourceMenu: some View {
        let m = app.translator
        let label = m.sourceCode.map { TranslatorLanguage.named($0) } ?? m.detectedCode.map { TranslatorLanguage.named($0) } ?? "Langue détectée"
        return BorderlessMenu {
            Button("Détection automatique") { m.sourceCode = nil }
            Divider()
            ForEach(TranslatorLanguage.all) { l in
                Button(l.name + (m.languageStatus[l.code] == .installed ? "  ✓" : "")) { m.sourceCode = l.code }
            }
        } label: {
            Text(label).font(.ui(12, .medium)).foregroundStyle(Theme.text2).lineLimit(1)
        }
        .fixedSize()
        .help(m.sourceCode == nil ? "Détectée en tapant : clique pour la choisir" : "Choisie à la main")
    }

    /// Every language, for one that is not among the chips.
    private var otherMenu: some View {
        let m = app.translator
        return BorderlessMenu {
            ForEach(TranslatorLanguage.all.filter { $0.code != m.effectiveSource }) { l in
                Button(l.name + (l.code == "fr" || m.languageStatus[l.code] == .installed ? "  ✓" : "")) { m.targetCode = l.code }
            }
        } label: {
            Text("Autre").font(.ui(11.5)).foregroundStyle(Theme.text3)
        }
        .fixedSize()
        .help("Toutes les langues")
    }

    private func chip(_ code: String) -> some View {
        let m = app.translator
        let selected = m.effectiveTarget == code
        let installed = m.languageStatus[code] == .installed || code == "fr"
        return Button { m.targetCode = code } label: {
            HStack(spacing: 4) {
                Text(TranslatorLanguage.named(code)).font(.ui(11.5, selected ? .semibold : .regular))
                if !installed, m.engine == .apple { Image(systemName: "arrow.down.circle").font(.ui(9)) }
            }
            .foregroundStyle(selected ? Theme.text : Theme.text2)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(PillShape().fill(selected ? Theme.accent.opacity(0.22) : Theme.track.opacity(0.6)))
            .overlay(PillShape().strokeBorder(selected ? Theme.accent.opacity(0.7) : .clear, lineWidth: Theme.line))
        }
        .buttonStyle(.plain)
        .help(installed ? "Sur ton Mac" : "Pas encore sur ton Mac : à télécharger, ou ⌘↩ pour Claude")
    }

    @ViewBuilder
    private var result: some View {
        let m = app.translator
        let text = Text(m.resultText.isEmpty ? placeholder : m.resultText)
            .font(.ui(21))
            .foregroundStyle(m.resultText.isEmpty ? Theme.text3 : Theme.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        ScrollArea { text }
    }

    private var placeholder: String {
        let m = app.translator
        if m.isTranslating { return "Traduction…" }
        if m.sourceText.isEmpty { return "Tape ou colle un texte : la traduction s'affiche ici." }
        if m.engine == .claude { return "↩ pour traduire avec Claude." }
        return ""
    }

    @ViewBuilder
    private var status: some View {
        let m = app.translator
        HStack(spacing: 8) {
            if m.isTranslating {
                BusyMascot(.reading, pixel: 1.5)
            }
            if let code = m.downloading {
                BusyMascot(.downloading, pixel: 1.5)
                Text("Téléchargement de \(TranslatorLanguage.withArticle(code))…").font(.ui(11.5)).foregroundStyle(Theme.text2)
            } else if let error = m.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.ui(11.5)).foregroundStyle(Theme.warn).lineLimit(2)
            } else if m.engine == .apple, m.pairStatus == .downloadable, m.resultText.isEmpty, !m.sourceText.isEmpty {
                Text(missingText).font(.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(1)
                Button("Télécharger") { m.downloadCurrentPair() }
                    .buttonStyle(SoftButtonStyle(small: true))
                    .help("macOS le télécharge une fois, puis traduit sans connexion")
            } else if let by = m.resultEngine, !m.resultText.isEmpty {
                HStack(spacing: 5) {
                    if by == .claude { Image(systemName: "sparkles").font(.ui(10)) } else { Image(systemName: "lock.laptopcomputer").font(.ui(10)) }
                    Text(by == .claude ? "Claude · \(m.claudeModel.familyTitle)" : "Sur ton Mac, hors ligne").font(.ui(11))
                }
                .foregroundStyle(Theme.text3)
            }
            Spacer()
            if !m.resultText.isEmpty, !m.isTranslating {
                Button { app.launcher.copyTranslation() } label: {
                    HStack(spacing: 6) {
                        if Theme.icons != .hidden { Image(systemName: "doc.on.doc").font(.ui(11, .semibold)) }
                        Text("Copier la traduction")
                    }
                }
                .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                .help("Copie la traduction (↩) : il ne reste qu'à la coller")
            }
        }
        .frame(height: 28)
    }

    /// "L'espagnol n'est pas encore sur ton Mac." (the language of the pair that is missing).
    private var missingText: String {
        let m = app.translator
        let missing = [m.effectiveTarget, m.effectiveSource].compactMap { $0 }.first { $0 != "fr" && m.languageStatus[$0] != .installed }
            ?? m.effectiveTarget
        return "\(Fmt.cap(TranslatorLanguage.withArticle(missing))) n'est pas encore sur ton Mac."
    }
}

/// A round icon button of the panel's top bar (the gear, back).
private struct TranslatorPanelButton: View {
    var symbol: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.ui(15)).foregroundStyle(Theme.text3)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Settings

/// The translator's settings, in the same panel: the engine and Claude's manner on the left with the languages to
/// download, the history on the right (it scrolls, the panel keeps its size). ⎋ or the arrow goes back.
struct TranslatorSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "gearshape").font(.ui(18, .medium))
                    .foregroundStyle(Theme.palette[1]).frame(width: 24)
                Text("Réglages de la traduction").font(.ui(17)).foregroundStyle(Theme.text)
                Spacer()
                TranslatorPanelButton(symbol: "chevron.backward.circle.fill", help: "Revenir à la traduction (⎋)") {
                    app.translator.showSettings = false
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Rectangle().fill(Theme.border).frame(height: 1)

            HStack(alignment: .top, spacing: 0) {
                ScrollArea { options.padding(18) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Theme.border).frame(width: 1)
                TranslatorHistoryColumn()
                    .frame(width: 300)
            }
            .frame(maxHeight: .infinity)

            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 14) {
                LauncherKeyHint(key: "⎋", label: "Retour à la traduction")
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Theme.fill1)
        }
        .task { await app.translator.refreshLanguageStatuses() }
    }

    private var options: some View {
        @Bindable var model = app.translator
        return VStack(alignment: .leading, spacing: 18) {
            section("Moteur") {
                PillPicker(options: TranslatorEngine.allCases, selection: $model.engine, label: \.title)
            }
            section("Avec Claude · ⌘↩") {
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Text("Ton").font(.ui(11.5)).foregroundStyle(Theme.text3)
                        PillPicker(options: TranslatorTone.allCases, selection: $model.tone, label: \.title)
                    }
                    HStack(spacing: 6) {
                        Text("Modèle").font(.ui(11.5)).foregroundStyle(Theme.text3)
                        PillPicker(options: [AssistantModelChoice.haiku, .sonnet, .opus], selection: $model.claudeModel, label: \.familyTitle)
                    }
                    if !app.assistant.isReady {
                        Button("Connecter Claude") {
                            app.launcher.hide()
                            app.page = .assistant
                            NotificationCenter.default.post(name: .openMainWindow, object: nil)
                        }
                        .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                    }
                }
            }
            languages
        }
    }

    /// French ↔ each language Apple offers: on the Mac, or a button that downloads it (in its own small window).
    private var languages: some View {
        let m = app.translator
        let list = TranslatorLanguage.all.filter { $0.code != "fr" && (m.languageStatus[$0.code] ?? .unknown) != .unsupported }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                title("Langues sur ton Mac")
                Spacer()
                Button("Réglages Système") { Finder.open("x-apple.systempreferences:com.apple.Localization-Settings.extension") }
                    .buttonStyle(.plain)
                    .font(.ui(11)).foregroundStyle(Theme.accent)
                    .help("Retirer une langue, ou voir toutes celles de macOS")
            }
            if let note = m.downloadError {
                Text(note).font(.ui(11)).foregroundStyle(Theme.warn)
            }
            if !TranslatorAvailability.isAvailable {
                Text("Traduire sur ton Mac demande macOS 15 : Claude traduit en attendant.").font(.ui(11.5)).foregroundStyle(Theme.text3)
            } else if list.isEmpty || m.languageStatus.isEmpty {
                Text("Lecture des langues…").font(.ui(11.5)).foregroundStyle(Theme.text3)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3), alignment: .leading, spacing: 2) {
                    ForEach(list) { l in
                        HStack(spacing: 6) {
                            Text(l.name).font(.ui(11.5)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.85)
                            Spacer(minLength: 4)
                            state(l.code)
                        }
                        .frame(height: 22)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func state(_ code: String) -> some View {
        let m = app.translator
        if m.downloading == code {
            BusyMascot(.downloading, pixel: 1)
                .help("Téléchargement en cours")
        } else {
            switch m.languageStatus[code] ?? .unknown {
            case .installed:
                Text("Installée").font(.ui(11)).foregroundStyle(Theme.good)
            case .downloadable:
                Button("Télécharger") { m.download(code) }
                    .buttonStyle(.plain)
                    .font(.ui(11, .medium))
                    .foregroundStyle(m.downloading == nil ? Theme.accent : Theme.text3)
                    .disabled(m.downloading != nil)
                    .help("Avec le français, une fois pour toutes : elle traduit ensuite sans connexion")
            default: Text("…").font(.ui(11)).foregroundStyle(Theme.text3)
            }
        }
    }

    private func section<Content: View>(_ name: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title(name)
            content()
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
    }
}

/// The translations kept on the Mac: a click takes one back into the translator.
private struct TranslatorHistoryColumn: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.translator
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Historique").font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if !model.history.isEmpty {
                    Button("Effacer") { model.clearHistory() }.buttonStyle(SoftButtonStyle(small: true))
                }
            }
            Toggle("Garder l'historique", isOn: $model.keepHistory).switchToggles().font(.ui(11.5))
            if model.history.isEmpty {
                Text(model.keepHistory ? "Tes traductions s'afficheront ici." : "Rien n'est gardé.")
                    .font(.ui(11.5)).foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
            } else {
                ScrollArea {
                    VStack(spacing: 6) {
                        ForEach(model.history) { entry($0) }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(18)
    }

    private func entry(_ e: TranslatorEntry) -> some View {
        Button { app.translator.restore(e) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(TranslatorLanguage.named(e.from)) → \(TranslatorLanguage.named(e.to))")
                        .font(.ui(10.5, .semibold)).foregroundStyle(Theme.text3).lineLimit(1)
                    if e.engine == .claude { Image(systemName: "sparkles").font(.ui(9)).foregroundStyle(Theme.text3) }
                    Spacer(minLength: 4)
                    Text(Fmt.relative(e.date)).font(.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Text(e.source).font(.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(1)
                Text(e.result).font(.ui(11.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(Theme.cardRaised.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Reprendre cette traduction")
    }
}
