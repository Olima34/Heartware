import SwiftUI
import AppKit
import ApplicationServices

/// What the user chose, saved in `windows.json`.
struct WindowsSettings: Codable, Equatable {
    var enabled = true
    var gap: Double = 0
    var cycles = true
    /// Actions whose shortcut the user removed (`HotKeyCenter` would bring the default back otherwise).
    var cleared: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WindowsSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? d.gap
        cycles = try c.decodeIfPresent(Bool.self, forKey: .cycles) ?? d.cycles
        cleared = try c.decodeIfPresent([String].self, forKey: .cleared) ?? d.cleared
    }
}

/// The margin choices of the page.
enum WindowsGap: Int, CaseIterable, Identifiable {
    case none = 0, small = 4, medium = 8, large = 12, wide = 16

    var id: Int { rawValue }
    var title: String { self == .none ? "Aucune" : "\(rawValue) pt" }
}

/// Why an action did nothing.
enum WindowsOutcome: Equatable {
    case done
    case needsPermission
    case noWindow
    case fullScreen
    case nothingToRestore
    case singleScreen
    case demo

    var message: String? {
        switch self {
        case .done: return nil
        case .needsPermission: return "Autorise d'abord l'Accessibilité (Raccourcis › Fenêtres)."
        case .noWindow: return "Aucune fenêtre à ranger au premier plan."
        case .fullScreen: return "Cette fenêtre est en mode plein écran : quitte-le d'abord."
        case .nothingToRestore: return "Rien à restaurer pour cette fenêtre."
        case .singleScreen: return "Un seul écran est branché."
        case .demo: return DemoData.refusal
        }
    }
}

/// A window the module moved: its frame before, to restore it, and what was done last, to cycle ½ → ⅔ → ⅓.
private struct WindowsMemory {
    let window: AXUIElement
    var original: CGRect
    var lastSet: CGRect
    var lastAction: WindowsAction?
    var step: Int
}

@Observable
@MainActor
final class WindowsModel: AppModule {
    var enabled: Bool
    var gap: WindowsGap
    var cycles: Bool
    var trusted = false
    var combos: [WindowsAction: KeyCombo] = [:]
    /// Shortcuts macOS accepted.
    var active: Set<WindowsAction> = []
    /// A remark after a change ("⌃⌥C servait à…").
    var note: String?
    /// Why the last shortcut typed was refused (already used elsewhere in Heartware).
    var refusal: String?

    @ObservationIgnored private let store = JSONStore<WindowsSettings>("windows", default: WindowsSettings())
    @ObservationIgnored private var memory: [WindowsMemory] = []
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let s = store.value
        enabled = s.enabled
        gap = WindowsGap(rawValue: Int(s.gap)) ?? .none
        cycles = s.cycles
        combos = Self.savedCombos(cleared: Set(s.cleared))
        trusted = !DemoData.isEnabled && AXIsProcessTrusted()
    }

    private static func savedCombos(cleared: Set<String>) -> [WindowsAction: KeyCombo] {
        var out: [WindowsAction: KeyCombo] = [:]
        for a in WindowsAction.allCases where !cleared.contains(a.rawValue) {
            if let c = HotKeyCenter.shared.combo(for: a.commandID, fallback: a.defaultCombo) { out[a] = c }
        }
        return out
    }

    /// Registered, refused by macOS, or waiting for the permission / the main switch.
    func isRefused(_ a: WindowsAction) -> Bool {
        enabled && trusted && combos[a] != nil && !active.contains(a)
    }

    var sidebarBadge: String? {
        if !enabled { return "Inactif" }
        return trusted ? nil : "À autoriser"
    }

    // MARK: Module

    func start(app: AppModel) {
        trusted = AXIsProcessTrusted()
        registerAll()
        // macOS posts this when an app is added to (or removed from) the Accessibility list;
        // the new state is readable a moment later.
        let dnc = DistributedNotificationCenter.default()
        let axToken = dnc.addObserver(forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { self?.refreshTrust() }
            }
        }
        let activeToken = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTrust() }
        }
        observers = [(dnc, axToken), (NotificationCenter.default, activeToken)]
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        for a in WindowsAction.allCases { HotKeyCenter.shared.unregister(a.commandID) }
        active = []
    }

    func loadDemo() {
        trusted = true
        enabled = true
        gap = .none
        cycles = true
        combos = Dictionary(uniqueKeysWithValues: WindowsAction.allCases.compactMap { a in a.defaultCombo.map { (a, $0) } })
        active = Set(combos.keys)
    }

    var quickToggles: [QuickToggle] {
        [QuickToggle(id: "windows", title: "Raccourcis de fenêtres", symbol: "rectangle.split.2x1", isOn: enabled && trusted) { [weak self] in
            guard let self else { return }
            if !self.trusted {
                // The permission is asked from the page, where its line says what it is for.
                if let app = AppContext.model { app.hotkeys.show(.windows, app: app) }
            } else {
                self.setEnabled(!self.enabled)
            }
        }]
    }

    /// `--tab autoriser`: the Fenêtres part as it looks before the Accessibility permission.
    func applySnapshotTab(_ tab: String) {
        if tab == "autoriser" {
            trusted = false
            active = []
        }
    }

    func commands(app: AppModel) -> [AppCommand] {
        let open = AppCommand(id: "win_settings", title: "Raccourcis des fenêtres", subtitle: "Moitiés, tiers, quarts : choisis tes touches",
                              keywords: ["fenêtre", "fenêtres", "window", "ranger", "raccourci", "rectangle", "magnet"],
                              icon: .symbol("rectangle.split.2x1", Theme.palette[6]), group: .tools, assistantSafe: true, urlSafe: true,
                              hint: "Ouvrir") { ctx in
            ctx.app.hotkeys.show(.windows, app: ctx.app)
            return .done
        }
        return [open] + WindowsAction.allCases.map { a in
            AppCommand(id: a.commandID, title: "Fenêtre : \(a.title.prefix(1).lowercased() + a.title.dropFirst())",
                       subtitle: a.detail ?? "La fenêtre au premier plan", keywords: a.keywords,
                       icon: .symbol(a.symbol, Theme.palette[6]), group: .system, assistantSafe: true,
                       hint: combos[a]?.display) { ctx in
                let outcome = ctx.app.windows.perform(a)
                return outcome.message.map { .failed($0) } ?? .done
            }
        }
    }

    func selfTest() -> [String] {
        var failures = WindowsGeometry.selfTest()
        var seen: [KeyCombo: WindowsAction] = [:]
        for a in WindowsAction.allCases {
            if !AppCommand.isValidID(a.commandID) { failures.append("identifiant invalide \(a.commandID)") }
            guard let c = a.defaultCombo else { continue }
            if !c.hasModifier { failures.append("raccourci sans modificateur pour \(a.title)") }
            if let other = seen[c] { failures.append("\(a.title) et \(other.title) ont le même raccourci") }
            seen[c] = a
        }
        let decoded = try? JSONDecoder.store.decode(WindowsSettings.self, from: Data("{\"gap\": 8}".utf8))
        if decoded?.gap != 8 || decoded?.enabled != true { failures.append("réglages partiels mal relus") }
        // "Raccourcis par défaut" brings every default back, even after one was removed (only in demo: nothing is saved).
        if DemoData.isEnabled {
            let (keptCombos, keptActive, keptCleared) = (combos, active, store.value.cleared)
            setCombo(nil, for: .leftHalf)
            resetShortcuts()
            let defaults = Dictionary(uniqueKeysWithValues: WindowsAction.allCases.compactMap { a in a.defaultCombo.map { (a, $0) } })
            if combos != defaults { failures.append("« Raccourcis par défaut » ne remet pas les raccourcis d'origine") }
            (combos, active, store.value.cleared, note, refusal) = (keptCombos, keptActive, keptCleared, nil, nil)
        }
        return failures
    }

    func dump() -> [String] {
        var lines = ["Accessibilité : \(AXIsProcessTrusted() ? "accordée" : "non accordée") · raccourcis \(enabled ? "activés" : "coupés")"]
        let all = NSScreen.screens
        let maxY = all.first?.frame.maxY ?? 0
        for (i, s) in all.enumerated() {
            let ax = WindowsGeometry.flip(s.visibleFrame, primaryMaxY: maxY)
            lines.append("Écran \(i + 1)\(i == 0 ? " (principal)" : "") : AppKit \(Self.text(s.visibleFrame)) → AX \(Self.text(ax))")
        }
        for a in WindowsAction.allCases {
            lines.append("\(a.commandID.padding(toLength: 24, withPad: " ", startingAt: 0)) \(combos[a]?.display ?? "—")")
        }
        if let screen = WindowsAX.screens().first {
            let sample = CGRect(x: screen.visible.minX + 100, y: screen.visible.minY + 100, width: 800, height: 500)
            for a in [WindowsAction.leftHalf, .topRight, .centerThird, .almostMaximize] {
                if let r = WindowsGeometry.target(for: a, window: sample, screens: WindowsAX.screens(), gap: CGFloat(gap.rawValue)) {
                    lines.append("\(a.title) sur l'écran principal : \(Self.text(r))")
                }
            }
        }
        return lines
    }

    private static func text(_ r: CGRect) -> String {
        "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width))×\(Int(r.height)))"
    }

    // MARK: Settings

    func setEnabled(_ on: Bool) {
        enabled = on
        store.value.enabled = on
        registerAll()
    }

    func setGap(_ g: WindowsGap) {
        gap = g
        store.value.gap = Double(g.rawValue)
    }

    func setCycles(_ on: Bool) {
        cycles = on
        store.value.cycles = on
    }

    /// Saves a new shortcut. A shortcut already used by another action is taken from it; one used elsewhere
    /// in Heartware (launcher, clipboard, Raccourcis) is refused.
    func setCombo(_ combo: KeyCombo?, for a: WindowsAction) {
        note = nil
        refusal = nil
        if let combo, let owner = AppContext.model?.hotkeys.owner(of: combo, except: .windows) {
            refusal = "\(combo.display) est déjà utilisé par \(owner) : choisis-en un autre pour « \(a.title) »."
            return
        }
        if let combo, let other = combos.first(where: { $0.key != a && $0.value == combo })?.key {
            save(nil, for: other)
            note = "\(combo.display) servait à « \(other.title) » : ce raccourci lui a été retiré."
        }
        save(combo, for: a)
    }

    func resetShortcuts() {
        note = nil
        refusal = nil
        store.value.cleared = []
        for a in WindowsAction.allCases {
            // `change(…, to: nil)` would save "no shortcut": each action gets its default saved again instead.
            HotKeyCenter.shared.change(a.commandID, to: a.defaultCombo) {}
        }
        combos = Self.savedCombos(cleared: [])
        if DemoData.isEnabled { active = Set(combos.keys) } else { registerAll() }
    }

    private func save(_ combo: KeyCombo?, for a: WindowsAction) {
        combos[a] = combo
        var cleared = Set(store.value.cleared)
        if combo == nil { cleared.insert(a.rawValue) } else { cleared.remove(a.rawValue) }
        store.value.cleared = cleared.sorted()
        var ok = HotKeyCenter.shared.change(a.commandID, to: combo) { [weak self] in self?.hotKey(a) }
        if DemoData.isEnabled { ok = combo != nil }
        if ok && !(enabled && trusted) { HotKeyCenter.shared.unregister(a.commandID) }
        if ok && enabled && trusted { active.insert(a) } else { active.remove(a) }
    }

    // MARK: Registration

    func refreshTrust() {
        guard !DemoData.isEnabled else { return }
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        trusted = now
        registerAll()
    }

    /// Nothing is registered without the permission or with the main switch off.
    private func registerAll() {
        guard !DemoData.isEnabled else { return }
        var ok: Set<WindowsAction> = []
        for a in WindowsAction.allCases {
            guard enabled, trusted, let c = combos[a] else {
                HotKeyCenter.shared.unregister(a.commandID)
                continue
            }
            if HotKeyCenter.shared.register(a.commandID, combo: c, action: { [weak self] in self?.hotKey(a) }) { ok.insert(a) }
        }
        active = ok
    }

    private func hotKey(_ a: WindowsAction) {
        if let m = perform(a).message { HUD.show(m, symbol: "exclamationmark.triangle.fill") }
    }

    // MARK: Moving windows

    /// Applies `action` to the focused window of the frontmost app (or of `pid`).
    @discardableResult
    func perform(_ action: WindowsAction, pid: pid_t? = nil) -> WindowsOutcome {
        guard !DemoData.isEnabled else { return .demo }
        guard AXIsProcessTrusted() else {
            trusted = false
            return .needsPermission
        }
        guard let target = WindowsAX.focusedWindow(pid: pid), let current = WindowsAX.frame(of: target.window) else { return .noWindow }
        if WindowsAX.isFullScreen(target.window) { return .fullScreen }
        let index = memory.firstIndex { CFEqual($0.window, target.window) }
        let screens = WindowsAX.screens()

        if action == .restore {
            guard let index else { return .nothingToRestore }
            WindowsAX.setFrame(memory[index].original, of: target, resize: WindowsAX.isResizable(target.window))
            memory.remove(at: index)
            return .done
        }

        // The frame before the first move is kept until the user moves the window by hand.
        var entry = WindowsMemory(window: target.window, original: current, lastSet: current, lastAction: nil, step: 0)
        if let index, WindowsGeometry.approxEqual(memory[index].lastSet, current) { entry = memory[index] }
        let step = cycles && entry.lastAction == action ? entry.step + 1 : 0
        let g = CGFloat(gap.rawValue)
        guard let frame = WindowsGeometry.target(for: action, window: current, screens: screens, gap: g, step: step) else {
            return action == .nextDisplay || action == .previousDisplay ? .singleScreen : .noWindow
        }
        let resizable = WindowsAX.isResizable(target.window)
        WindowsAX.setFrame(frame, of: target, resize: resizable)

        var actual = WindowsAX.frame(of: target.window) ?? frame
        if !WindowsGeometry.approxEqual(actual, frame), let i = WindowsGeometry.screenIndex(for: frame, in: screens) {
            // The app kept its own size (minimum width…): keep it against the same edges, inside the screen.
            let origin = WindowsGeometry.anchored(actual: actual.size, target: frame, in: screens[i].visible, gap: g)
            WindowsAX.setPosition(origin, target.window)
            actual = WindowsAX.frame(of: target.window) ?? CGRect(origin: origin, size: actual.size)
        }
        entry.lastSet = actual
        entry.lastAction = action
        entry.step = step
        if let index { memory.remove(at: index) }
        memory.append(entry)
        if memory.count > 40 { memory.removeFirst(memory.count - 40) }
        return .done
    }
}
