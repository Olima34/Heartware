import Foundation
import AppKit
import CoreGraphics
import Observation

// MARK: - Preference values

/// A value of a macOS preference, as `defaults` would write it.
enum PerformanceTweakValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case double(Double)
    case string(String)

    var plist: CFPropertyList {
        switch self {
        case .bool(let b): return (b ? kCFBooleanTrue : kCFBooleanFalse) as CFPropertyList
        case .double(let d): return d as NSNumber
        case .string(let s): return s as CFString
        }
    }

    /// Reads back what CFPreferences returned (booleans are their own type).
    init?(_ value: Any?) {
        guard let value else { return nil }
        if let s = value as? String {
            self = .string(s)
        } else if let n = value as? NSNumber {
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .double(n.doubleValue)
        } else {
            return nil
        }
    }

    /// Same meaning: `1` and `true` are the same switch, 0.001 and 0.0010000001 the same delay.
    func matches(_ other: PerformanceTweakValue?) -> Bool {
        guard let other else { return false }
        switch (self, other) {
        case (.bool(let a), .bool(let b)): return a == b
        case (.bool(let a), .double(let b)), (.double(let b), .bool(let a)): return (b != 0) == a
        case (.double(let a), .double(let b)): return abs(a - b) < 0.0005
        case (.string(let a), .string(let b)): return a == b
        default: return false
        }
    }
}

struct PerformanceTweakSetting: Sendable {
    /// nil: the global domain (every app).
    let domain: String?
    let key: String
    let value: PerformanceTweakValue
}

enum PerformanceTweakSection: String, CaseIterable, Identifiable, Sendable {
    case windows, dock, finder, games

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windows: return "Fenêtres et apps"
        case .dock: return "Dock et Mission Control"
        case .finder: return "Finder"
        case .games: return "Jeux"
        }
    }

    var symbol: String {
        switch self {
        case .windows: return "macwindow.on.rectangle"
        case .dock: return "dock.rectangle"
        case .finder: return "folder"
        case .games: return "gamecontroller"
        }
    }
}

/// What has to restart for a change to show.
enum PerformanceTweakRestart: Sendable {
    case none, dock, finder, apps

    var note: String? {
        switch self {
        case .none: return nil
        case .dock: return "Le Dock se relance tout seul (une seconde)."
        case .finder: return "Effectif après une relance du Finder."
        case .apps: return "Effectif dans les apps ouvertes ensuite."
        }
    }
}

/// A reversible macOS setting that makes the Mac feel faster. The value it replaces is kept, and put back as it was
/// (or removed if it did not exist) by "Rétablir".
struct PerformanceTweak: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let section: PerformanceTweakSection
    let settings: [PerformanceTweakSetting]
    var restart: PerformanceTweakRestart = .none
    var symbol: String

    static let all: [PerformanceTweak] = [
        PerformanceTweak(id: "window_open", title: "Fenêtres sans animation d'ouverture",
                         detail: "Les nouvelles fenêtres apparaissent d'un coup au lieu de s'agrandir depuis le centre.",
                         section: .windows, settings: [.init(domain: nil, key: "NSAutomaticWindowAnimationsEnabled", value: .bool(false))],
                         restart: .apps, symbol: "macwindow"),
        PerformanceTweak(id: "window_resize", title: "Feuilles et redimensionnements instantanés",
                         detail: "Les boîtes « Enregistrer », « Imprimer » et les changements de taille s'affichent sans glisser.",
                         section: .windows, settings: [.init(domain: nil, key: "NSWindowResizeTime", value: .double(0.001))],
                         restart: .apps, symbol: "arrow.up.left.and.arrow.down.right"),
        PerformanceTweak(id: "quicklook", title: "Coup d'œil instantané",
                         detail: "La barre d'espace ouvre l'aperçu sans zoom d'ouverture.",
                         section: .windows, settings: [.init(domain: nil, key: "QLPanelAnimationDuration", value: .double(0))],
                         restart: .apps, symbol: "eye"),
        PerformanceTweak(id: "dock_autohide", title: "Dock masqué qui apparaît sans attendre",
                         detail: "Supprime la demi-seconde d'attente avant que le Dock ne surgisse, et l'accélère (si tu le masques automatiquement).",
                         section: .dock, settings: [.init(domain: "com.apple.dock", key: "autohide-delay", value: .double(0)),
                                                    .init(domain: "com.apple.dock", key: "autohide-time-modifier", value: .double(0.25))],
                         restart: .dock, symbol: "dock.arrow.up.rectangle"),
        PerformanceTweak(id: "dock_bounce", title: "Apps qui s'ouvrent sans rebondir",
                         detail: "Plus de rebond d'icône dans le Dock au lancement d'une app.",
                         section: .dock, settings: [.init(domain: "com.apple.dock", key: "launchanim", value: .bool(false))],
                         restart: .dock, symbol: "arrow.up.and.down"),
        PerformanceTweak(id: "mission_control", title: "Mission Control plus rapide",
                         detail: "L'animation de Mission Control et d'App Exposé dure 0,12 s au lieu d'environ une demi-seconde.",
                         section: .dock, settings: [.init(domain: "com.apple.dock", key: "expose-animation-duration", value: .double(0.12))],
                         restart: .dock, symbol: "rectangle.3.group"),
        PerformanceTweak(id: "minimize_scale", title: "Réduction en effet « Échelle »",
                         detail: "Plus léger que l'effet « Génie » pour réduire une fenêtre dans le Dock.",
                         section: .dock, settings: [.init(domain: "com.apple.dock", key: "mineffect", value: .string("scale"))],
                         restart: .dock, symbol: "arrow.down.right.and.arrow.up.left"),
        PerformanceTweak(id: "finder_animations", title: "Finder sans animations",
                         detail: "Fenêtres d'informations et ouvertures de dossiers sans effet dans le Finder.",
                         section: .finder, settings: [.init(domain: "com.apple.finder", key: "DisableAllAnimations", value: .bool(true))],
                         restart: .finder, symbol: "folder"),
        PerformanceTweak(id: "metal_hud", title: "Compteur d'images (FPS) dans les jeux",
                         detail: "Le compteur d'Apple (Metal Performance HUD) s'affiche dans les jeux et apps 3D : images par seconde, temps par image, mémoire graphique.",
                         section: .games, settings: [.init(domain: nil, key: "MetalForceHudEnabled", value: .bool(true))],
                         restart: .apps, symbol: "speedometer")
    ]
}

/// What a tweak replaced, to put it back.
struct PerformanceTweakOriginal: Codable, Equatable, Sendable {
    var domain: String?
    var key: String
    var value: PerformanceTweakValue?
}

enum PerformanceDefaults {
    private static func app(_ domain: String?) -> CFString {
        (domain as CFString?) ?? kCFPreferencesAnyApplication
    }

    static func read(domain: String?, key: String) -> PerformanceTweakValue? {
        if DemoData.isEnabled { return PerformanceDemo.preference(domain: domain, key: key) }
        CFPreferencesAppSynchronize(app(domain))
        return PerformanceTweakValue(CFPreferencesCopyAppValue(key as CFString, app(domain)))
    }

    /// Writes (or removes, for nil) one value for the current user, like `defaults write`.
    @discardableResult
    static func write(domain: String?, key: String, value: PerformanceTweakValue?) -> Bool {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return false }
        CFPreferencesSetValue(key as CFString, value?.plist, app(domain), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesSynchronize(app(domain), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

// MARK: - Displays

/// A screen and the best refresh rate it offers at its current resolution.
struct PerformanceDisplay: Identifiable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let resolution: String
    /// Hz (0: the screen does not say, a built-in panel at 60 Hz).
    let current: Double
    let best: Double
    let builtIn: Bool

    var canGoFaster: Bool { best > max(current, 60) + 1 }
}

enum PerformanceDisplays {
    @MainActor
    static func list() -> [PerformanceDisplay] {
        if DemoData.isEnabled { return PerformanceDemo.displays() }
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[n.uint32Value] = screen.localizedName
            }
        }
        return ids.prefix(Int(count)).compactMap { id in
            guard let cur = CGDisplayCopyDisplayMode(id) else { return nil }
            let best = bestMode(id, like: cur)
            return PerformanceDisplay(id: id, name: names[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Écran intégré" : "Écran externe"),
                                      resolution: "\(cur.width) × \(cur.height)", current: cur.refreshRate,
                                      best: max(best?.refreshRate ?? 0, cur.refreshRate), builtIn: CGDisplayIsBuiltin(id) != 0)
        }
    }

    /// The fastest mode with exactly the same size on screen and in pixels.
    private static func bestMode(_ id: CGDirectDisplayID, like cur: CGDisplayMode) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        return modes
            .filter { $0.width == cur.width && $0.height == cur.height && $0.pixelWidth == cur.pixelWidth
                && $0.pixelHeight == cur.pixelHeight && $0.isUsableForDesktopGUI() }
            .max { $0.refreshRate < $1.refreshRate }
    }

    /// Switches a screen to its best refresh rate, for good (like System Settings › Displays).
    @MainActor
    static func setBest(_ id: UInt32) -> Bool {
        guard !DemoData.isEnabled, !Snapshot.isActive, let cur = CGDisplayCopyDisplayMode(id), let best = bestMode(id, like: cur),
              best.refreshRate > cur.refreshRate else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, id, best, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        let ok = CGCompleteDisplayConfiguration(config, .permanently) == .success
        if ok { ActionLog.write("ÉCRAN \(id) → \(Int(best.refreshRate)) Hz") }
        return ok
    }
}

// MARK: - Model

@Observable
@MainActor
final class PerformanceTweaks {
    static let accessibilitySettings = "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display"

    /// Current value of each setting, by "domain|key".
    var values: [String: PerformanceTweakValue] = [:]
    var originals: [String: [PerformanceTweakOriginal]] {
        didSet { store.value = originals }
    }
    var displays: [PerformanceDisplay] = []
    var reduceTransparency = false
    var reduceMotion = false
    var message: (text: String, ok: Bool)?

    @ObservationIgnored private let store: JSONStore<[String: [PerformanceTweakOriginal]]>

    init() {
        let s = JSONStore<[String: [PerformanceTweakOriginal]]>("performance-tweaks", default: [:])
        store = s
        originals = s.value
    }

    static func slot(_ domain: String?, _ key: String) -> String { (domain ?? "global") + "|" + key }

    func refresh() {
        var v: [String: PerformanceTweakValue] = [:]
        for t in PerformanceTweak.all {
            for s in t.settings {
                if let value = PerformanceDefaults.read(domain: s.domain, key: s.key) { v[Self.slot(s.domain, s.key)] = value }
            }
        }
        values = v
        displays = PerformanceDisplays.list()
        if DemoData.isEnabled {
            reduceTransparency = false
            reduceMotion = false
        } else {
            reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    func isApplied(_ t: PerformanceTweak) -> Bool {
        t.settings.allSatisfy { $0.value.matches(values[Self.slot($0.domain, $0.key)]) }
    }

    var appliedCount: Int { PerformanceTweak.all.filter(isApplied).count }

    /// Applies a tweak, keeping the values it replaces. Restarts the Dock when needed.
    func apply(_ t: PerformanceTweak) {
        apply([t])
    }

    func apply(_ list: [PerformanceTweak]) {
        guard !DemoData.isEnabled else {
            message = (DemoData.refusal, false)
            return
        }
        var restarts = Set<String>()
        for t in list where !isApplied(t) {
            if originals[t.id] == nil {
                originals[t.id] = t.settings.map { PerformanceTweakOriginal(domain: $0.domain, key: $0.key, value: values[Self.slot($0.domain, $0.key)]) }
            }
            for s in t.settings { PerformanceDefaults.write(domain: s.domain, key: s.key, value: s.value) }
            ActionLog.write("RÉGLAGE \(t.title)")
            if t.restart == .dock { restarts.insert("Dock") }
        }
        refresh()
        relaunch(restarts)
        let applied = list.filter(isApplied).count
        message = (applied == list.count ? (list.count == 1 ? "Réglage appliqué." : "\(list.count) réglages appliqués.")
                   : "Certains réglages n'ont pas pu être écrits.", applied == list.count)
    }

    /// Puts back exactly what was there before (or removes the value if there was none).
    func restore(_ t: PerformanceTweak) {
        restore([t])
    }

    func restore(_ list: [PerformanceTweak]) {
        guard !DemoData.isEnabled else {
            message = (DemoData.refusal, false)
            return
        }
        var restarts = Set<String>()
        for t in list {
            guard isApplied(t) || originals[t.id] != nil else { continue }
            let saved = originals[t.id] ?? t.settings.map { PerformanceTweakOriginal(domain: $0.domain, key: $0.key, value: nil) }
            for o in saved { PerformanceDefaults.write(domain: o.domain, key: o.key, value: o.value) }
            originals[t.id] = nil
            ActionLog.write("RÉGLAGE RÉTABLI \(t.title)")
            if t.restart == .dock { restarts.insert("Dock") }
        }
        refresh()
        relaunch(restarts)
        message = ("Réglages d'origine remis.", true)
    }

    var everyday: [PerformanceTweak] { PerformanceTweak.all.filter { $0.section != .games } }

    private func relaunch(_ names: Set<String>) {
        for n in names { _ = Shell.run("/usr/bin/killall", [n], timeout: 5) }
    }

    /// The Finder restarts on request only: a copy in progress would stop.
    func relaunchFinder() {
        guard !DemoData.isEnabled else {
            message = (DemoData.refusal, false)
            return
        }
        guard CommandRunner.confirm("Relancer le Finder ?", "Les fenêtres du Finder se ferment et se rouvrent ; une copie en cours serait interrompue.",
                                    button: "Relancer") else { return }
        _ = Shell.run("/usr/bin/killall", ["Finder"], timeout: 5)
    }

    func setBestRefresh(_ d: PerformanceDisplay) {
        guard !DemoData.isEnabled else {
            message = (DemoData.refusal, false)
            return
        }
        let ok = PerformanceDisplays.setBest(d.id)
        displays = PerformanceDisplays.list()
        message = ok ? ("\(d.name) affiche maintenant \(Int(d.best)) images par seconde.", true)
            : ("\(d.name) n'a pas accepté le changement de fréquence.", false)
    }
}
