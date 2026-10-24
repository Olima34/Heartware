import SwiftUI
import AppKit

/// The tabs of the settings window. The one shown is remembered, and `SettingsWindow.show` opens on any of them.
enum SettingsTab: String, CaseIterable {
    case general, appearance, shortcuts, network, permissions, cleanup, about

    static let key = "settings.tab"
}

struct SettingsView: View {
    @AppStorage(SettingsTab.key) private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().frame(width: 520, height: 520)
                .tabItem { Label("Général", systemImage: "gearshape") }.tag(SettingsTab.general)
            AppearanceSettings().frame(width: AppearanceSettings.width, height: 680)
                .tabItem { Label("Apparence", systemImage: "paintpalette") }.tag(SettingsTab.appearance)
            ShortcutSettings().frame(width: 520, height: 400)
                .tabItem { Label("Raccourcis", systemImage: "keyboard") }.tag(SettingsTab.shortcuts)
            NetworkSettings().frame(width: NetworkSettings.width, height: NetworkSettings.height)
                .tabItem { Label("Réseau", systemImage: "network") }.tag(SettingsTab.network)
            PermissionsSettings().frame(width: 520, height: 400)
                .tabItem { Label("Autorisations", systemImage: "lock.shield") }.tag(SettingsTab.permissions)
            CleanupSettings().frame(width: 520, height: 400)
                .tabItem { Label("Nettoyage", systemImage: "sparkles") }.tag(SettingsTab.cleanup)
            AboutSettings().frame(width: 520, height: 400)
                .tabItem { Label("À propos", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
    }
}

/// Opens the settings window on a tab from anywhere: the launcher (floating over another app), a page, a link, even with
/// the main window closed and no Dock icon.
@MainActor
enum SettingsWindow {
    /// SwiftUI's own identifier for the window of the `Settings` scene.
    static let identifier = "com_apple_SwiftUI_Settings_window"

    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == identifier && ($0.isVisible || $0.isMiniaturized) }
    }

    static func show(_ tab: SettingsTab) {
        // The tab view follows the remembered tab, open or not.
        UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.key)
        guard !Snapshot.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let w = window {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            return
        }
        // Since macOS 14 the `showSettingsWindow:` action is refused when sent by code; the app menu's own
        // « Réglages… » item (⌘,), performed as if clicked, opens the scene with or without a window of the app.
        if let menu = NSApp.mainMenu?.items.first?.submenu,
           let i = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) {
            menu.performActionForItem(at: i)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Preferences.menuMetricKey) private var metric: MenuMetric = .cpuMemory
    @AppStorage(Preferences.alertsKey) private var alerts = false
    @AppStorage(DockIconMode.key) private var dockIcon: DockIconMode = .never
    @AppStorage(UpdatesSelfModel.autoKey) private var autoUpdate = true

    var body: some View {
        Form {
            Section {
                LaunchAtLoginToggle()
                Picker("Icône dans le Dock", selection: $dockIcon) {
                    ForEach(DockIconMode.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: dockIcon) { _, _ in AppContext.applyDockIcon() }
                Picker("Barre des menus", selection: $metric) {
                    ForEach(MenuMetric.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Alertes disque plein et mémoire saturée", isOn: $alerts)
                    .onChange(of: alerts) { _, on in if on { Alerts.requestPermission() } }
                    .disabled(!Alerts.available)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Profil")
                        Text(app.profile.isChosen ? app.profile.summary : "Aucun : tous les outils sont dans la barre latérale")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Modifier") {
                        app.showProfilePanel = true
                        AppContext.showMainWindow()
                    }
                    .disabled(app.showOnboarding)
                }
                HStack {
                    Text("Présentation de l'app")
                    Spacer()
                    Button("Revoir") {
                        app.showOnboarding = true
                        AppContext.showMainWindow()
                    }
                    .disabled(app.showOnboarding)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Astuces")
                        Text("Elles s'ouvrent seules la première fois, puis par leur « ? »").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Tout revoir") {
                        HelpTips.resetAll()
                        HUD.show("Les astuces se rouvriront")
                    }
                }
            }
            Section {
                Toggle("Rechercher les nouvelles versions de \(AppEdition.name)", isOn: $autoUpdate)
                    .disabled(DemoData.isEnabled || !app.updates.selfUpdate.canCheck)
                HStack {
                    Text(selfUpdateStatus)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(app.updates.selfUpdate.release == nil ? "Rechercher maintenant" : "Voir les nouveautés") {
                        Task { await app.updates.selfUpdate.check() }
                    }
                    .disabled(app.updates.selfUpdate.state.isChecking || !app.updates.selfUpdate.canCheck)
                }
            } header: {
                Text("Mises à jour de \(AppEdition.name)")
            } footer: {
                Text("Au lancement puis toutes les 6 h, l'app demande à GitHub son dernier numéro de version. Rien d'autre ne part, et rien ne s'installe sans toi.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Autorisations") {
                HStack {
                    Label(app.fullDiskAccess ? "Accès complet au disque accordé" : "Accès complet au disque non accordé",
                          systemImage: app.fullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(app.fullDiskAccess ? Theme.good : Theme.warn)
                    Spacer()
                    Button("Ouvrir le réglage") { Finder.open(Permissions.fullDiskAccessURL) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var selfUpdateStatus: String {
        let m = app.updates.selfUpdate
        if m.state.isChecking { return "Vérification…" }
        if let r = m.release { return "Version \(r.version) disponible, tu as la \(m.build.label)" }
        guard m.canCheck else { return AppEdition.isLab ? "Version Labo \(m.build.label)" : "Version de développement" }
        if case .failed(let message) = m.state { return message }
        if let d = m.state.date { return "À jour : \(m.build.label), vérifié \(Fmt.relative(d))" }
        return "Version \(m.build.label)"
    }
}

struct ShortcutSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Ouvrir le lanceur")
                    Spacer()
                    ShortcutRecorder(combo: app.launcher.combo) { app.launcher.setCombo($0) }
                }
                if app.launcher.combo != nil && !app.launcher.hotKeyActive {
                    Text("macOS a refusé ce raccourci : choisis-en un avec ⌘ ou ⌃.").font(.caption).foregroundStyle(Theme.warn)
                }
            } footer: {
                Text("Clique, puis tape le nouveau raccourci. ⎋ annule, ⌫ l'efface. Ceux des fenêtres sont dans la page Raccourcis.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct CleanupSettings: View {
    @AppStorage(Preferences.alwaysTrashKey) private var alwaysTrash = false
    // The demo shows none of this Mac's folders and changes none of its settings.
    @State private var exclusions = DemoData.isEnabled ? [] : Preferences.exclusions

    var body: some View {
        Form {
            Section {
                Toggle("Toujours passer par la Corbeille", isOn: $alwaysTrash)
                    .disabled(DemoData.isEnabled)
                Text("Sinon, caches et journaux sont supprimés directement : les apps les recréent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ne jamais toucher à") {
                if exclusions.isEmpty {
                    Text("Aucune exclusion.").foregroundStyle(.secondary)
                }
                ForEach(exclusions, id: \.self) { p in
                    HStack {
                        Image(systemName: "folder")
                        Text(FS.pretty(p)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { remove(p) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
                Button("Ajouter un dossier…") { add() }
                    .disabled(DemoData.isEnabled)
            }
            Section {
                Button("Ouvrir le journal des suppressions") {
                    if FS.exists(ActionLog.file) { NSWorkspace.shared.open(URL(fileURLWithPath: ActionLog.file)) } else { Finder.reveal(ActionLog.folder) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            exclusions = Array(Set(exclusions + panel.urls.map(\.path))).sorted()
            Preferences.exclusions = exclusions
        }
    }

    private func remove(_ p: String) {
        guard !DemoData.isEnabled else { return }
        exclusions.removeAll { $0 == p }
        Preferences.exclusions = exclusions
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 14) {
            PixelMascot(pixel: 5)
            Text("Heartware").font(.serif(24))
            Text("Version \(UpdatesSelfBuild.current.label)")
                .font(.ui(12)).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Un utilitaire d'entretien pour macOS, construit avec Claude. Libre, gratuit, et tout se passe en local.")
                .font(.ui(12.5)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Link("Code source sur GitHub", destination: URL(string: "https://github.com/Olima34/Heartware")!)
                .font(.ui(12.5))
            Text("Projet personnel, sans lien avec Anthropic ni avec MacPaw. « Claude » est une marque d'Anthropic.")
                .font(.ui(10.5)).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
