import SwiftUI
import AppKit

/// The active theme and the user's own themes. Observable: every view that reads `Theme` redraws when it changes.
/// Saved in the preferences (nothing is read or written in demo mode, while rendering snapshots or during the self-test).
@Observable
final class ThemeStore: @unchecked Sendable {
    static let shared = ThemeStore()

    private(set) var resolved: ThemeResolved
    /// The themes the user made, after the six built-in ones.
    private(set) var customs: [ThemeSpec]

    var active: ThemeSpec { resolved.spec }
    var all: [ThemeSpec] { ThemeSpec.builtIns + customs }

    @ObservationIgnored private static let activeKey = "app.theme"
    @ObservationIgnored private static let customsKey = "app.customThemes"
    @ObservationIgnored private static let redesignKey = "app.theme.graphiteRedesign"
    @ObservationIgnored private let persists: Bool

    init() {
        persists = !DemoData.isEnabled && !Snapshot.isActive && !Entry.arguments.contains("--selftest")
        let defaults = UserDefaults.standard
        var saved: [ThemeSpec] = []
        if persists, let data = defaults.data(forKey: Self.customsKey),
           let list = try? JSONDecoder().decode([ThemeSpec].self, from: data) {
            saved = list.filter { !$0.isBuiltIn }
        }
        customs = saved
        var id = persists ? defaults.string(forKey: Self.activeKey) : nil
        // Before the redesign, « graphite » was the sober theme, now « Graphite pur »: whoever chose it keeps it.
        if persists, !defaults.bool(forKey: Self.redesignKey) {
            defaults.set(true, forKey: Self.redesignKey)
            if id == "graphite" {
                id = ThemeSpec.graphitePur.id
                defaults.set(id, forKey: Self.activeKey)
            }
        }
        resolved = ThemeResolved((ThemeSpec.builtIns + saved).first { $0.id == id } ?? .base)
    }

    // MARK: Choosing

    func select(_ id: String) {
        guard id != active.id, let spec = all.first(where: { $0.id == id }) else { return }
        apply(spec)
    }

    /// Makes an editable copy of a theme and switches to it.
    @discardableResult
    func duplicate(_ spec: ThemeSpec) -> ThemeSpec {
        var copy = spec
        copy.id = "custom-" + UUID().uuidString.prefix(8).lowercased()
        copy.name = uniqueName(spec.isBuiltIn ? "Mon \(spec.displayName)" : "\(spec.displayName) (copie)")
        copy.summary = "Créé à partir de \(spec.displayName)."
        customs.append(copy)
        apply(copy)
        return copy
    }

    /// Changes the active theme, when it is one of the user's (the built-in ones stay as they are).
    func edit(_ change: (inout ThemeSpec) -> Void) {
        guard let i = customs.firstIndex(where: { $0.id == active.id }) else { return }
        var spec = customs[i]
        change(&spec)
        spec.clamp()
        guard spec != customs[i] else { return }
        customs[i] = spec
        apply(spec)
    }

    func delete(_ id: String) {
        guard let i = customs.firstIndex(where: { $0.id == id }) else { return }
        customs.remove(at: i)
        if active.id == id { apply(.base) } else { save() }
    }

    // MARK: Sharing

    /// The theme as JSON, to paste in a message or a file.
    func exportJSON(_ spec: ThemeSpec) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(spec)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Adds a theme pasted as JSON (missing fields come from Graphite) and switches to it.
    func importJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              var spec = try? JSONDecoder().decode(ThemeSpec.self, from: data) else { return false }
        spec.id = "custom-" + UUID().uuidString.prefix(8).lowercased()
        spec.name = uniqueName(spec.displayName)
        customs.append(spec)
        apply(spec)
        return true
    }

    // MARK: Applying

    /// Forces the light or dark appearance of the theme on every window (native controls included).
    /// Called on the main thread (launch, settings).
    func applyAppearance() {
        guard !Snapshot.isActive else { return }
        let name: NSAppearance.Name? = active.appearance == .system ? nil : (active.appearance == .light ? .aqua : .darkAqua)
        MainActor.assumeIsolated { NSApp?.appearance = name.flatMap(NSAppearance.init(named:)) }
    }

    private func apply(_ spec: ThemeSpec) {
        let appearanceChanged = spec.appearance != active.appearance
        resolved = ThemeResolved(spec)
        if appearanceChanged { applyAppearance() }
        save()
    }

    private func save() {
        guard persists else { return }
        let defaults = UserDefaults.standard
        defaults.set(active.id, forKey: Self.activeKey)
        if let data = try? JSONEncoder().encode(customs) { defaults.set(data, forKey: Self.customsKey) }
    }

    private func uniqueName(_ name: String) -> String {
        let taken = Set(all.map(\.name))
        guard taken.contains(name) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }
}
