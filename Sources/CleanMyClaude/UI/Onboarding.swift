import SwiftUI
import AppKit
import Combine

/// The cards that introduce the app the first time it opens (Réglages › Général brings them back), in the middle of
/// the main window like the update panel: nothing behind them answers until the user is done.
struct OnboardingModal: View {
    var body: some View {
        ZStack {
            // The only fixed color: a veil that darkens whatever theme is behind it.
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture {}
            OnboardingPanel()
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .ignoresSafeArea()
    }
}

enum OnboardingSlide: Int, CaseIterable, Identifiable {
    case welcome, profile, launcher, control, permissions

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Bienvenue"
        case .profile: return "Ton profil"
        case .launcher: return "La barre"
        case .control: return "Tu gardes la main"
        case .permissions: return "Autorisations"
        }
    }

    /// `--snapshot --page dashboard` writes one picture per card, named after it.
    var snapshotName: String {
        switch self {
        case .welcome: return "bienvenue"
        case .profile: return "profil"
        case .launcher: return "barre"
        case .control: return "controle"
        case .permissions: return "autorisations"
        }
    }
}

/// The cards side by side: the current one in the middle, its neighbours peeking at the edges.
/// They turn with the buttons, ← and →, a click on a neighbour, a drag, two fingers on the trackpad or the mouse wheel.
struct OnboardingPanel: View {
    static let width: CGFloat = 660
    static let height: CGFloat = 598
    static let cardSize = CGSize(width: 500, height: 492)
    static let gap: CGFloat = 18
    private static let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)

    @Environment(AppModel.self) private var app
    @State private var index: Int
    /// How far the cards follow the pointer or the fingers, before they settle on one.
    @State private var drag: CGFloat = 0
    @State private var swipe = OnboardingSwipe()

    init(start: OnboardingSlide = .welcome) {
        _index = State(initialValue: start.rawValue)
    }

    private var last: Int { OnboardingSlide.allCases.count - 1 }
    private var step: CGFloat { Self.cardSize.width + Self.gap }
    /// Where the cards stand, counted in cards (1.5: halfway between the second and the third).
    private var position: CGFloat { CGFloat(index) - drag / step }

    var body: some View {
        VStack(spacing: 0) {
            cards
                .padding(.top, 22)
            Spacer(minLength: 0)
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .floatingSurface(radius: 20)
        .onAppear {
            swipe.start(follow: { follow($0) }, settle: { settle($0) }, turn: { go(to: index + $0) })
        }
        .onDisappear { swipe.stop() }
    }

    // MARK: Cards

    private var cards: some View {
        HStack(spacing: Self.gap) {
            ForEach(OnboardingSlide.allCases) { slide in
                let i = slide.rawValue
                // 0 in the middle, 1 at the edge (typed apart: Xcode 16 finds `1 - 0.5 * d` ambiguous).
                let d: CGFloat = min(1, abs(CGFloat(i) - position))
                let scale: CGFloat = 1 - 0.08 * d
                let fade: Double = 1 - 0.5 * Double(d)
                card(slide)
                    .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                    .allowsHitTesting(i == index)
                    .scaleEffect(scale)
                    .opacity(fade)
                    .overlay {
                        // A card at the edge comes to the middle when clicked.
                        if i != index {
                            Color.clear.contentShape(Rectangle()).onTapGesture { go(to: i) }
                        }
                    }
                    .accessibilityHidden(i != index)
            }
        }
        .fixedSize()
        .offset(x: (Self.width - Self.cardSize.width) / 2 - CGFloat(index) * step + drag)
        .frame(width: Self.width, height: Self.cardSize.height, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { follow($0.translation.width) }
                .onEnded { settle($0.predictedEndTranslation.width) }
        )
    }

    @ViewBuilder
    private func card(_ slide: OnboardingSlide) -> some View {
        switch slide {
        case .welcome: OnboardingWelcomeCard()
        case .profile: OnboardingProfileCard()
        case .launcher: OnboardingLauncherCard()
        case .control: OnboardingControlCard()
        case .permissions: OnboardingPermissionsCard(active: index == slide.rawValue)
        }
    }

    // MARK: Footer

    private var footer: some View {
        ZStack {
            dots
            HStack(spacing: 8) {
                if index < last {
                    Button("Passer") { app.finishOnboarding() }
                        .buttonStyle(.plain)
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.text3)
                        .help("Fermer la présentation : Réglages › Général la remontre quand tu veux.")
                }
                Spacer()
                if index > 0 {
                    Button("Précédent") { go(to: index - 1) }
                        .buttonStyle(SoftButtonStyle())
                }
                Button(index == last ? "C'est parti" : "Suivant") {
                    if index == last { app.finishOnboarding() } else { go(to: index + 1) }
                }
                .buttonStyle(SoftButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .background(keys)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingSlide.allCases) { slide in
                let on = slide.rawValue == index
                PillShape()
                    .fill(on ? Theme.accent : Theme.borderStrong)
                    .frame(width: on ? 20 : 7, height: 7)
                    .padding(4)
                    .contentShape(Rectangle())
                    .onTapGesture { go(to: slide.rawValue) }
                    .help(slide.title)
            }
        }
    }

    /// ← and → turn the cards, Esc closes them like « Passer ».
    private var keys: some View {
        ZStack {
            Button("") { go(to: index - 1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { go(to: index + 1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { app.finishOnboarding() }.keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.plain)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Moving

    private func go(to i: Int) {
        let target = max(0, min(last, i))
        withAnimation(Self.spring) {
            index = target
            drag = 0
        }
    }

    /// The cards follow the pointer, and resist past the first and the last one.
    private func follow(_ dx: CGFloat) {
        let pastEdge = (index == 0 && dx > 0) || (index == last && dx < 0)
        drag = pastEdge ? dx / 3 : max(-step, min(step, dx))
    }

    /// Lands on the next card once the gesture went (or was thrown) a quarter of a card, else back in place.
    private func settle(_ projected: CGFloat) {
        var target = index
        if projected < -step / 4 { target += 1 } else if projected > step / 4 { target -= 1 }
        go(to: target)
    }
}

/// Two fingers on the trackpad turn the cards: SwiftUI has no swipe gesture on the Mac outside a scroll view, so the
/// main window's scroll events are read while the cards are on screen. A mouse wheel turns one card per notch.
@MainActor
final class OnboardingSwipe {
    private var monitor: Any?
    /// The gesture in progress: nil until it shows a direction, true when it goes sideways (the cards then take it).
    private var sideways: Bool?
    private var total: CGFloat = 0
    private var lastDelta: CGFloat = 0
    private var lastNotch = Date.distantPast

    func start(follow: @escaping (CGFloat) -> Void, settle: @escaping (CGFloat) -> Void, turn: @escaping (Int) -> Void) {
        guard monitor == nil, !Snapshot.isActive else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window?.identifier?.rawValue.hasPrefix("main") == true else { return event }
            let taken = MainActor.assumeIsolated { self.handle(event, follow: follow, settle: settle, turn: turn) }
            return taken ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ e: NSEvent, follow: (CGFloat) -> Void, settle: (CGFloat) -> Void, turn: (Int) -> Void) -> Bool {
        // The glide after the fingers leave belongs to the gesture that came before it.
        if !e.momentumPhase.isEmpty { return sideways == true }
        if e.phase.isEmpty {
            // A mouse wheel: one card per notch, no faster than the cards move.
            guard !e.hasPreciseScrollingDeltas else { return false }
            let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
            if abs(d) > 0.1, Date().timeIntervalSince(lastNotch) > 0.35 {
                lastNotch = Date()
                turn(d < 0 ? 1 : -1)
            }
            return true
        }
        if e.phase.contains(.mayBegin) || e.phase.contains(.began) {
            sideways = nil
            total = 0
            lastDelta = 0
        }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            // A quick flick goes on as far as its last movements would have carried it.
            if sideways == true { settle(total + lastDelta * 10) }
            return sideways == true
        }
        let dx = e.scrollingDeltaX
        if sideways == nil, abs(dx) + abs(e.scrollingDeltaY) > 1.5 { sideways = abs(dx) > abs(e.scrollingDeltaY) }
        guard sideways == true else { return false }
        total += dx
        lastDelta = dx
        follow(total)
        return true
    }
}

// MARK: - The card frame

/// A card: its picture on the faint backdrop, a kicker, a serif title and a few words, then its own content.
struct OnboardingCardFrame<Art: View, Content: View>: View {
    var kicker: String
    var title: String
    var text: String
    /// The picture's height; small when the theme hides the pictures (Graphite).
    var artHeight: CGFloat = 112
    var seed: UInt64 = 5
    @ViewBuilder var art: Art
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                DustBackdrop(seed: seed, opacity: 0.4)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                art
            }
            .frame(maxWidth: .infinity)
            .frame(height: artHeight)
            .clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text(kicker.uppercased())
                    .font(.ui(10.5, .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.text3)
                Text(title)
                    .font(.serif(25))
                    .foregroundStyle(Theme.text)
                Text(text)
                    .font(.ui(12.5))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 26)
            content
                .padding(.horizontal, 26)
                .padding(.top, 16)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.r(16), style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(16), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: Theme.r(16), style: .continuous))
    }
}

// MARK: - 1. Welcome

struct OnboardingWelcomeCard: View {
    @Environment(AppModel.self) private var app

    private let tiles: [(symbol: String, title: String, text: String)] = [
        ("sparkles", "Nettoyer", "Caches, gros fichiers, doublons et apps oubliées."),
        ("lock.shield", "Protéger", "Réglages de sécurité, traces et logiciels malveillants."),
        ("bolt", "Accélérer", "Mémoire, démarrage et apps trop gourmandes."),
        ("wrench.and.screwdriver", "Simplifier", "Convertir, traduire, presse-papiers, fenêtres.")
    ]

    var body: some View {
        OnboardingCardFrame(
            kicker: "Bienvenue",
            title: "Bienvenue dans Chamois",
            text: "Je prends soin de ton Mac : je fais le ménage, je veille sur lui et je t'évite les petites corvées du quotidien.",
            artHeight: Theme.current.spec.mascot ? 112 : 26,
            seed: 41
        ) {
            PixelMascot(pixel: 7)
                .padding(.top, 4)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow { tile(0); tile(1) }
                    GridRow { tile(2); tile(3) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Je reste discret, sans icône dans le Dock : ma silhouette dans la barre des menus me rouvre.")
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    if !Snapshot.isActive { LaunchAtLoginToggle().font(.ui(12)) }
                }
            }
        }
    }

    private func tile(_ i: Int) -> some View {
        let t = tiles[i]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                IconBadge(symbol: t.symbol, tint: Theme.color(index: i), size: 24)
                Text(t.title).font(.ui(13, .semibold)).foregroundStyle(Theme.text)
            }
            Text(t.text)
                .font(.ui(11.5))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
    }
}

// MARK: - 2. Profile

/// What the user does with their Mac: the sidebar and the dashboard put its tools forward. Nothing ticked, everything shows.
struct OnboardingProfileCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        OnboardingCardFrame(
            kicker: "Ton profil",
            title: "Qu'est-ce que tu fais avec ton Mac ?",
            text: "Coche ce qui te ressemble, même plusieurs : je mets tes outils en avant et je range les autres, toujours à un clic.",
            artHeight: 26,
            seed: 63
        ) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                ProfileKindGrid(columns: 2)
                Text(app.profile.isChosen
                     ? "Tu pourras changer d'avis à tout moment, sous mon nom dans la barre latérale."
                     : "Sans choix, je te montre tous les outils. Tu pourras choisir plus tard.")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 3. The bar

struct OnboardingLauncherCard: View {
    @Environment(AppModel.self) private var app

    private let examples: [(symbol: String, typed: String, result: String)] = [
        ("app.badge", "slack", "ouvre l'app"),
        ("doc.text.magnifyingglass", "facture edf", "le cherche dans la fenêtre Fichiers"),
        ("function", "1250*1,2", "1 500"),
        ("character.bubble", "trad merci en anglais", "thank you"),
        ("sparkles", "analyse", "lance une analyse du Mac")
    ]

    /// "⌥Espace" → ["⌥", "Espace"]: one key cap each.
    private var keys: [String] {
        let display = (app.launcher.combo ?? LauncherModel.defaultCombo).display
        let modifiers = display.prefix { "⌃⌥⇧⌘".contains($0) }
        return modifiers.map(String.init) + [String(display.dropFirst(modifiers.count))]
    }

    var body: some View {
        let combo = keys.joined()
        OnboardingCardFrame(
            kicker: "Le raccourci à retenir",
            title: "Une barre pour tout faire",
            text: "Depuis n'importe quelle app, \(combo) ouvre une barre au milieu de l'écran. Tape ce que tu veux, Entrée, c'est fait.",
            seed: 93
        ) {
            HStack(spacing: 8) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in OnboardingKeycap(label: key) }
            }
            .padding(.top, 10)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    ForEach(examples, id: \.typed) { e in
                        HStack(spacing: 10) {
                            IconBadge(symbol: e.symbol, tint: Theme.brand, size: 22)
                            Text(e.typed).font(.mono(12, .medium)).foregroundStyle(Theme.text)
                            Spacer(minLength: 8)
                            Text(e.result).font(.ui(11.5)).foregroundStyle(Theme.text3)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                    }
                }
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
                HStack(alignment: .center, spacing: 10) {
                    Text("⌘K sur un résultat ouvre ses actions : convertir, partager, quitter…")
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Essayer") { app.launcher.show() }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .help("Ouvre la barre, comme \(combo)")
                }
            }
        }
    }
}

/// A key of the keyboard, drawn with the theme's colors.
struct OnboardingKeycap: View {
    var label: String

    var body: some View {
        let word = label.count > 1
        Text(label)
            .font(.ui(word ? 17 : 22, .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, word ? 18 : 0)
            .frame(minWidth: 52, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: Theme.r(11), style: .continuous).fill(Theme.cardRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(11), style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: max(1, Theme.line)))
            .themedShadow(color: .black.opacity(0.2), radius: 0, y: 2)
    }
}

// MARK: - 4. Control

struct OnboardingControlCard: View {
    var body: some View {
        OnboardingCardFrame(
            kicker: "Tu gardes la main",
            title: "Rien ne se fait sans toi",
            text: "J'analyse, je t'explique ce que j'ai trouvé, puis c'est toi qui décides.",
            artHeight: Theme.icons == .hidden ? 26 : 112,
            seed: 17
        ) {
            IconBadge(symbol: "hand.raised", tint: Theme.good, size: 62)
                .padding(.top, 8)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                promise("checklist", "Rien sans ton accord",
                        "J'analyse en lecture seule. Je ne supprime que ce que tu coches, après confirmation.")
                promise("trash", "La Corbeille plutôt que l'oubli",
                        "Les caches se suppriment (tes apps les recréent), tout le reste passe par la Corbeille. Un journal note chaque action.")
                promise("lock", "Tes données restent sur ton Mac",
                        "Rien ne sort sans ton clic. Seule exception, que tu peux couper : je demande à GitHub si une nouvelle version de moi existe. Mon code est ouvert, sur GitHub.")
            }
        }
    }

    private func promise(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: symbol, tint: Theme.good, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                Text(text).font(.ui(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 5. Permissions

/// Every macOS permission in one place, asked only when the user clicks: each one is ticked, and unticking it
/// leaves it for later (Réglages › Autorisations, or the page that needs it).
struct OnboardingPermissionsCard: View {
    /// In the middle: its states are read again now and then (not while it waits at the edge).
    var active = true
    @Environment(AppModel.self) private var app
    @State private var center = PermissionCenter.shared
    /// What the user leaves for later.
    @State private var later: Set<PermissionKind> = []

    /// The two System Settings switches first, Full Disk Access leading: once it is on, macOS no longer asks for
    /// the three folders. Every permission of `PermissionCenter` is here.
    static let order: [PermissionKind] = [.fullDiskAccess, .accessibility] + PermissionKind.allCases.filter { !$0.needsSettings }

    var body: some View {
        OnboardingCardFrame(
            kicker: "Autorisations",
            title: "Tes autorisations, en une fois",
            text: "macOS veut ton accord pour certaines choses. Décoche ce que tu préfères garder pour plus tard : tout se retrouve dans Réglages › Autorisations.",
            artHeight: 26
        ) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    ForEach(Self.order) { row($0) }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
                actions
            }
        }
        .task(id: active) { if active { await center.refresh() } }
        // Read again quickly only while a switch of System Settings is awaited; otherwise when the app comes back to
        // the front (from System Settings, typically). Never while macOS shows its own question.
        .task(id: active && center.waitingForSettings) {
            guard active, center.waitingForSettings else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5), tolerance: .seconds(0.5))
                guard !Task.isCancelled else { return }
                await center.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard active, !center.isRunning || center.waitingForSettings else { return }
            Task { await center.refresh() }
        }
    }

    private func state(_ kind: PermissionKind) -> PermissionState { center.states[kind] ?? .notAsked }

    /// Still to ask, in order, without what is left for later.
    private var pending: [PermissionKind] {
        Self.order.filter { state($0) != .granted && !later.contains($0) }
    }

    private func row(_ kind: PermissionKind) -> some View {
        let s = state(kind)
        let skipped = later.contains(kind) && s != .granted
        return HStack(spacing: 10) {
            CheckBox(state: skipped ? .off : .on) {
                if later.contains(kind) { later.remove(kind) } else { later.insert(kind) }
            }
            .allowsHitTesting(s != .granted && !center.isRunning)
            .help(s == .granted ? "Déjà accordée" : (skipped ? "Je la demanderai" : "La garder pour plus tard"))
            IconBadge(symbol: kind.symbol, tint: Theme.accent, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(Self.use(kind)).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            .help(kind.purpose)
            Spacer(minLength: 6)
            trailing(kind, s, skipped)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3.5)
        .opacity(skipped ? 0.55 : 1)
    }

    @ViewBuilder
    private func trailing(_ kind: PermissionKind, _ s: PermissionState, _ skipped: Bool) -> some View {
        if center.isRunning && center.current == kind {
            if center.waitingForSettings {
                Button("Passer") { center.skip() }
                    .buttonStyle(SoftButtonStyle(small: true))
                    .help("Continuer sans attendre l'interrupteur de Réglages Système.")
            } else {
                Tag(text: "macOS demande…", tint: Theme.accent, filled: true)
            }
        } else {
            switch s {
            case .granted:
                Tag(text: "Accordée", symbol: "checkmark", tint: Theme.good, filled: true)
            case .denied:
                Button("Refusée · Réglages") { Finder.open(kind.settingsURL) }
                    .buttonStyle(SoftButtonStyle(small: true))
                    .help("macOS ne la redemande plus : active-la dans Réglages Système.")
            case .asked:
                Tag(text: "Demandée", tint: Theme.text3)
            case .notAsked:
                if skipped {
                    Tag(text: "Plus tard", tint: Theme.text3)
                } else if kind.needsSettings {
                    Tag(text: "Réglages Système", tint: Theme.text3)
                        .help("Elle se donne dans Réglages Système : la fenêtre s'ouvre au bon endroit, active \(AppEdition.name) puis reviens ici.")
                }
            }
        }
    }

    private var actions: some View {
        let count = pending.count
        return HStack(alignment: .center, spacing: 12) {
            Text(status)
                .font(.ui(11.5))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(center.isRunning ? "En cours…" : (count == 0 ? "Rien à demander" : "Autoriser (\(count))")) { ask() }
                .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                .disabled(center.isRunning || count == 0)
                .opacity(center.isRunning || count == 0 ? 0.5 : 1)
                .fixedSize()
        }
    }

    private var status: String {
        if center.isRunning, let k = center.current {
            return center.waitingForSettings
                ? "Active \(AppEdition.name) dans Réglages Système (\(k.title)), puis reviens ici."
                : "macOS te pose sa question : \(k.title). Tu peux refuser."
        }
        let granted = Self.order.filter { state($0) == .granted }.count
        if granted == Self.order.count { return "Tout est accordé, merci !" }
        return "\(granted) sur \(Self.order.count) accordées. macOS pose ses questions l'une après l'autre."
    }

    private func ask() {
        let kinds = pending
        Task {
            await center.requestAll(kinds)
            // The folders are readable now: the launcher can index them.
            if center.states[.folders] == .granted { app.launcher.enableIndex() }
            app.refreshPermissions()
        }
    }

    /// What each one is for, short enough for one line (the full text is in the tooltip).
    static func use(_ kind: PermissionKind) -> String {
        switch kind {
        case .fullDiskAccess: return "Voir la Corbeille, Mail et Safari"
        case .accessibility: return "Ranger les fenêtres au clavier"
        case .folders: return "Chercher tes fichiers en un instant"
        case .notifications: return "Te prévenir si le disque ou la mémoire sature, ou si la batterie faiblit"
        case .location: return "Afficher le nom du Wi-Fi (jamais ta position)"
        case .finder: return "Mettre certaines apps à la Corbeille"
        case .systemEvents: return "Mode sombre, redémarrer… depuis la barre"
        case .safari: return "Passer YouTube et Twitch au lecteur sans pub"
        case .localNetwork: return "Mesurer la latence de ta box"
        case .photos: return "Supprimer les photos de l'iPhone triées, avec Photos iCloud"
        }
    }
}
