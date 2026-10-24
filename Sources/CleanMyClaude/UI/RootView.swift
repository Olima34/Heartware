import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            // A closed window would keep redrawing its pages and running their timers (processes, network):
            // they go away with it, so their onDisappear runs, and come back when it reopens.
            if app.mainWindowOpen {
                WindowShell()
            } else {
                Color.clear
            }
        }
        // The first-launch cards, or a new version of the app: a panel in the middle, nothing behind it answers
        // until the user does. The cards come first; a new version waits for them.
        .disabled(app.showOnboarding || app.updates.selfUpdate.panelVisible || app.showProfilePanel || app.refuge.showsOverlay)
        .allowsHitTesting(!app.showOnboarding && !app.updates.selfUpdate.panelVisible && !app.showProfilePanel && !app.refuge.showsOverlay)
        .overlay {
            if app.mainWindowOpen && app.showOnboarding {
                OnboardingModal()
            } else if app.mainWindowOpen && app.updates.selfUpdate.panelVisible {
                UpdatesSelfModal()
            } else if app.mainWindowOpen && app.showProfilePanel {
                ProfileModal()
            } else if app.mainWindowOpen && app.refuge.showsOverlay {
                // Its birth or its mue, once the cards and the other panels are done.
                RefugeCeremonyModal()
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.showOnboarding)
        .animation(.easeOut(duration: 0.2), value: app.updates.selfUpdate.panelVisible)
        .animation(.easeOut(duration: 0.2), value: app.showProfilePanel)
        .animation(.easeOut(duration: 0.25), value: app.refuge.showsOverlay)
        .ignoresSafeArea()
        .tint(Theme.accent)
        .environment(\.mainWindowOnScreen, app.mainWindowOnScreen)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshPermissions()
            app.refuge.arrived()
        }
        .onAppear { AppContext.openWindow = openWindow }
    }
}

/// True while the main window is really on screen (`AppModel.mainWindowOnScreen`): a small animation of its pages
/// (a blink, a clock ticking every second) stops while it is false. Other windows keep the default, true.
struct MainWindowOnScreenKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var mainWindowOnScreen: Bool {
        get { self[MainWindowOnScreenKey.self] }
        set { self[MainWindowOnScreenKey.self] = newValue }
    }
}

/// The window, Arc-style: glass everywhere, the sidebar laid on it, and the page on a stage set back from the edges,
/// its corners concentric with the window's.
struct WindowShell: View {
    static let sidebarWidth: CGFloat = 240
    /// The margin of the stage, and the radius of its corners (the window's, minus the margin).
    static let inset: CGFloat = 8
    static let stageRadius: CGFloat = 14

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: Self.sidebarWidth)
            Stage { PageContainer() }
                .padding(.vertical, Self.inset)
                .padding(.trailing, Self.inset)
        }
        .background {
            ZStack {
                // Snapshots cannot draw the desktop behind the window: its plain color stands in.
                if Snapshot.isActive { Theme.window } else { WindowGlass() }
                Theme.glass
            }
            .ignoresSafeArea()
        }
    }
}

/// The calm working area: nearly opaque, lit from above, set back from the window.
struct Stage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.r(WindowShell.stageRadius), style: .continuous)
        content
            .background(Theme.bg)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Theme.border, lineWidth: Theme.line) }
            .overlay { SpecularRim(shape: shape) }
            .background { shape.fill(Theme.bg).shadow(color: Theme.shadowDeep, radius: 20, y: 12) }
    }
}

/// How far the page has scrolled under the toolbar (only the marker at its top sets it).
struct StageScrollKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = value ?? nextValue() }
}

struct PageContainer: View {
    @Environment(AppModel.self) private var app
    /// Where the top of the page sits at rest, then whether it went under the toolbar, and its title too.
    @State private var restY: CGFloat?
    @State private var scrolled = false
    @State private var titleShown = false

    var body: some View {
        Group {
            if Snapshot.isActive {
                // A scroll view comes out empty in snapshots: the page alone, cut at the bottom of the stage.
                VStack(spacing: 0) {
                    StageToolbar(scrolled: false, titleShown: false)
                    // Laid over an empty area, the page never pushes the stage taller than the window.
                    Color.clear
                        .overlay(alignment: .top) { page.fixedSize(horizontal: false, vertical: true) }
                        .clipped()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            GeometryReader { g in
                                Color.clear.preference(key: StageScrollKey.self, value: g.frame(in: .named("stage")).minY)
                            }
                            .frame(height: 0)
                            .id("top")
                            page
                        }
                    }
                    .coordinateSpace(name: "stage")
                    .scrollIndicators(.automatic)
                    .onPreferenceChange(StageScrollKey.self) { y in if let y { follow(y) } }
                    .onChange(of: app.page) { _, _ in proxy.scrollTo("top", anchor: .top) }
                    .safeAreaInset(edge: .top, spacing: 0) { StageToolbar(scrolled: scrolled, titleShown: titleShown) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { BottomBar() }
                }
            }
        }
    }

    private var page: some View {
        PageView(page: app.page)
            .frame(maxWidth: 1180)
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity)
    }

    /// Only crossing a threshold redraws anything: scrolling itself stays free.
    private func follow(_ y: CGFloat) {
        guard let rest = restY else {
            restY = y
            return
        }
        let s = y < rest - 2, t = y < rest - 64
        if s != scrolled { withAnimation(.easeOut(duration: 0.16)) { scrolled = s } }
        if t != titleShown { withAnimation(.easeOut(duration: 0.16)) { titleShown = t } }
    }
}

/// The toolbar of the stage: back and forward, the page's title once its header has scrolled away, the command bar
/// in the middle (the launcher) and the settings.
struct StageToolbar: View {
    @Environment(AppModel.self) private var app
    var scrolled: Bool
    var titleShown: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 4) {
                StageToolbarButton(symbol: "chevron.left", help: "Page précédente (⌘[)", enabled: !app.backPages.isEmpty) { app.goBack() }
                StageToolbarButton(symbol: "chevron.right", help: "Page suivante (⌘])", enabled: !app.forwardPages.isEmpty) { app.goForward() }
                Text(app.page.title)
                    .font(.ui(15, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .padding(.leading, 6)
                    .opacity(titleShown ? 1 : 0)
                Spacer(minLength: 0)
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.ui(13))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Réglages (⌘,)")
            }
            CommandBar()
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .barGlass()
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1).opacity(scrolled ? 1 : 0)
        }
    }
}

struct StageToolbarButton: View {
    var symbol: String
    var help: String
    var enabled = true
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ui(12.5, .semibold))
                .foregroundStyle(enabled ? Theme.text2 : Theme.text3.opacity(0.6))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous).fill(hovering && enabled ? Theme.fill1 : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The ⌘K bar: it opens the launcher, where everything the app does can be typed.
struct CommandBar: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        Button { app.launcher.show() } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.ui(12, .medium))
                    .foregroundStyle(Theme.text3)
                Text("Chercher, lancer, calculer…")
                    .font(.ui(13))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                KeyCap(text: "⌘K")
            }
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .frame(width: 320, height: 30)
            .background(PillShape().fill(hovering ? Theme.fill2 : Theme.fill1))
            .overlay(PillShape().strokeBorder(Theme.border, lineWidth: Theme.line))
            .contentShape(PillShape())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .onHover { hovering = $0 }
        .help("Le lanceur : une page, une action, un fichier, un calcul (\(app.launcher.combo?.display ?? "⌥Espace") partout)")
    }
}

/// A key of the keyboard, as shown next to what it does.
struct KeyCap: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.ui(11, .medium))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: Theme.r(5), style: .continuous).fill(Theme.fill2))
    }
}

struct PageView: View {
    var page: Page

    var body: some View {
        switch page {
        case .dashboard: DashboardPage()
        case .refuge: RefugePage()
        case .cleanup: CleanupPage()
        case .protection: ProtectionPage()
        case .performance: PerformancePage()
        case .battery: BatteryPage()
        case .apps: AppsPage()
        case .storage: StoragePage()
        case .phone: PhonePage()
        case .menubar: MenuBarPage()
        case .wheel: WheelPage()
        case .media: MediaPage()
        case .hotkeys: HotkeysPage()
        case .toolbox: ToolboxPage()
        case .updates: UpdatesPage()
        case .automation: AutomationPage()
        case .assistant: AssistantPage()
        }
    }
}

/// The action bar of the current page, when it has something selected.
struct BottomBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.page {
        case .cleanup where app.cleanup.hasResults && !app.cleanup.isScanning:
            CleanupActionBar()
        case .protection where app.protection.tab == .privacy && !app.protection.traces.isEmpty:
            PrivacyActionBar()
        case .protection where app.protection.tab == .threats && !app.protection.selectedThreats.isEmpty:
            ThreatActionBar()
        case .storage where (app.storage.tab == .bigFiles && !app.storage.bigSelection.isEmpty)
            || (app.storage.tab == .duplicates && !app.storage.dupSelection.isEmpty):
            StorageActionBar()
        case .performance: PerformanceBottomBar()
        case .battery: BatteryBottomBar()
        case .phone where !app.phone.selection.isEmpty: PhoneBottomBar()
        case .wheel: WheelBottomBar()
        case .media: MediaBottomBar()
        case .hotkeys: HotkeysBottomBar()
        case .toolbox: ToolboxBottomBar()
        case .updates: UpdatesBottomBar()
        case .automation: AutomationBottomBar()
        case .assistant: AssistantBottomBar()
        default:
            EmptyView()
        }
    }
}

// MARK: - Sidebar

/// The glass column: the app, the pages of the profile, then what is going on.
struct Sidebar: View {
    @Environment(AppModel.self) private var app
    /// « Autres outils » unfolded.
    @AppStorage("sidebar.othersOpen") private var othersOpen = false
    /// Snapshots unfold it without touching the saved choice.
    var unfoldOthers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights.
            Color.clear.frame(height: 40)

            HStack(spacing: 8) {
                BrandMark(size: 20)
                Text("Chamois")
                    .font(.ui(15, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            if DemoData.isEnabled {
                Tag(text: "Démo · données fictives", symbol: "theatermasks", tint: Theme.text2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            SidebarProfileButton()
                .padding(.horizontal, 10)

            ScrollArea(showsIndicators: false) {
                // One glass bubble for the whole list: it slides from the page left to the page opened.
                GlassGroup(selection: app.page, axis: .vertical, radius: 8, pick: { app.page = $0 }) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(app.profile.sections, id: \.0) { group in
                            header(group.0)
                            ForEach(group.1) { item($0) }
                        }
                        others
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }

            Spacer(minLength: 0)
            // The YouTube downloads (they have no page: pasted in the launcher), from every page: the one under way,
            // or what ended; a click shows the list.
            if !app.youtube.jobs.isEmpty {
                YouTubeActivityCard()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            if !app.fullDiskAccess {
                Button { Finder.open(Permissions.fullDiskAccessURL) } label: {
                    SidebarModule(dot: Theme.warn, title: "Accès complet au disque", detail: "Corbeille, Mail, autorisations")
                }
                .buttonStyle(.plain)
                .help("Pour voir la Corbeille, Mail et les autorisations : un clic ouvre le réglage de macOS.")
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            SidebarStatus()
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.ui(11, .semibold))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func item(_ p: Page) -> some View {
        SidebarItem(symbol: p.symbol, title: p.title, badge: badge(for: p), selected: app.page == p) {
            app.page = p
        }
        .glassItem(p)
        .contextMenu {
            if p != .dashboard {
                if app.profile.isFeatured(p) {
                    Button("Ranger dans Autres outils") { app.profile.setFeatured(p, false) }
                } else {
                    Button("Garder dans la barre latérale") { app.profile.setFeatured(p, true) }
                }
                Divider()
            }
            Button("Personnaliser la barre latérale…") { app.showProfilePanel = true }
        }
    }

    /// The tools outside the profile, folded at the bottom. Folded, the page open among them still shows.
    @ViewBuilder
    private var others: some View {
        let list = app.profile.others
        if !list.isEmpty {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { othersOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Autres outils")
                        .font(.ui(11, .semibold))
                        .foregroundStyle(Theme.text3)
                    Text("\(list.count)")
                        .font(.ui(10, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: Theme.r(5), style: .continuous).fill(Theme.fill2))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.ui(9, .semibold))
                        .foregroundStyle(Theme.text3)
                        .rotationEffect(.degrees(othersOpen || unfoldOthers ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(othersOpen ? "Replier" : "Les outils hors de ton profil, toujours à un clic (et dans la barre \(app.launcher.combo?.display ?? "⌥Espace"))")
            if othersOpen || unfoldOthers {
                ForEach(list) { item($0) }
            } else if list.contains(app.page) {
                item(app.page)
            }
        }
    }

    private func badge(for p: Page) -> String? {
        switch p {
        case .cleanup: return app.cleanup.hasResults && app.cleanup.recommendedSize > 0 ? Fmt.bytes(app.cleanup.recommendedSize) : nil
        case .apps: return app.apps.unused.isEmpty ? nil : "\(app.apps.unused.count)"
        case .hotkeys: return app.hotkeys.sidebarBadge
        default: return ModuleRegistry.module(for: p, app: app)?.sidebarBadge
        }
    }
}

/// A small floating module at the bottom of the sidebar: a state dot, two short lines and, on its right, whatever acts
/// on it.
struct SidebarModule<Trailing: View>: View {
    var dot: Color
    var title: String
    var detail: String
    /// A slow pulse of the dot, only while something is really going on.
    var busy = false
    @ViewBuilder var trailing: Trailing
    @Environment(\.mainWindowOnScreen) private var onScreen

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if busy && onScreen && !Snapshot.isActive {
                    // A few frames a second, and only while busy and on screen.
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        Circle().fill(dot).opacity(0.55 + 0.45 * (0.5 + 0.5 * cos(t * 2.4)))
                    }
                } else {
                    Circle().fill(dot)
                }
            }
            .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(detail).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .floatingSurface(radius: 12, shadow: false)
        .contentShape(Rectangle())
    }
}

extension SidebarModule where Trailing == EmptyView {
    init(dot: Color, title: String, detail: String, busy: Bool = false) {
        self.init(dot: dot, title: title, detail: detail, busy: busy) { EmptyView() }
    }
}

/// What Chamois is doing: an analysis under way, or the health of the Mac and what was freed so far. Its « … » holds
/// the actions, the settings first.
struct SidebarStatus: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let busy = app.smartScanRunning || app.cleanup.isScanning || app.protection.isScanning || app.storage.isScanning
        SidebarModule(dot: busy ? Theme.accent : app.healthColor,
                      title: busy ? "Analyse en cours…" : app.healthLabel,
                      detail: busy ? "Je fais le tour du Mac" : detail,
                      busy: busy) {
            BorderlessMenu(indicator: false) {
                Button("Analyse intelligente") {
                    app.page = .dashboard
                    Task { await app.smartScan() }
                }
                .disabled(busy)
                Button("Personnaliser la barre latérale…") { app.showProfilePanel = true }
                Divider()
                SettingsLink { Text("Réglages…") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.ui(12, .semibold))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            // A menu takes the accent by default: here it is a quiet neutral control.
            .tint(Theme.text2)
            .help("Analyser, personnaliser, réglages")
        }
        .help("Score de santé : \(app.healthScore) sur 100")
    }

    private var detail: String {
        let score = "\(app.healthScore)/100"
        return app.history.totalFreed > 0 ? "\(score) · \(Fmt.bytes(app.history.totalFreed)) libérés" : "\(score) · prêt à nettoyer"
    }
}

/// The profile under the app's name: what the sidebar is tailored for, and the way to change it.
struct SidebarProfileButton: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let profile = app.profile
        Button { app.showProfilePanel = true } label: {
            HStack(spacing: 8) {
                if Theme.icons != .hidden {
                    Image(systemName: profile.symbol)
                        .font(.ui(12))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 16)
                }
                Text(profile.summary)
                    .font(.ui(12))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(profile.isChosen ? "Modifier" : "Personnaliser")
                    .font(.ui(11, .medium))
                    .foregroundStyle(hovering ? Theme.text : Theme.text3)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous).fill(hovering ? Theme.fill2 : Theme.fill1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Ton profil décide des outils mis en avant ; les autres sont rangés dans « Autres outils ».")
    }
}

/// A page of the sidebar. The selected one carries no background of its own: the group's glass bubble rests under it,
/// and its icon takes the accent.
struct SidebarItem: View {
    var symbol: String
    var title: String
    var badge: String? = nil
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if Theme.icons != .hidden {
                    Image(systemName: symbol)
                        .font(.ui(13.5))
                        .foregroundStyle(selected ? Theme.accent : Theme.text2)
                        .frame(width: 18)
                }
                Text(title)
                    .font(.ui(13, selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.text2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.ui(10.5, .medium))
                        .foregroundStyle(Theme.text2)
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .frame(minHeight: 18)
                        .background(RoundedRectangle(cornerRadius: Theme.r(5), style: .continuous).fill(Theme.fill2))
                }
            }
            .animation(.easeOut(duration: 0.2), value: selected)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous).fill(hovering && !selected ? Theme.fill1 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
