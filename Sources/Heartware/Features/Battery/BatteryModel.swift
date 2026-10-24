import SwiftUI
import AppKit
import IOKit.ps

/// The battery: macOS' charge limit, alerts when it runs low (or charges past a level), and its health.
/// It follows the battery through macOS' power source notifications: nothing runs between two changes.
@Observable
@MainActor
final class BatteryModel: AppModule {
    var reading: BatteryReading?
    /// macOS' charge limit, read in the background (nil until then).
    var limit: BatteryLimitState?
    /// The limit being applied right now.
    var applying: Int?
    /// macOS kept the last change for System Settings: the limit the user asked for.
    var limitRefused: Int?
    var settings = BatterySettings() {
        didSet { store.value = settings }
    }
    /// The page is on screen: the limit is read again at each change of the battery.
    @ObservationIgnored var pageVisible = false

    @ObservationIgnored private let store = JSONStore<BatterySettings>("battery", default: BatterySettings())
    @ObservationIgnored private var arming = BatteryAlertArming()
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var limitTask: Task<Void, Never>?

    init() {
        settings = store.value
    }

    /// The limit macOS applies, when it has the setting.
    var activeLimit: Int? { limit?.supported == true ? limit?.limit : nil }

    // MARK: Module

    func start(app: AppModel) {
        started = true
        refresh()
        guard reading != nil else { return }
        refreshLimit()
        // Called by macOS when the level, the charger or the charging state changes (a few times an hour at rest).
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let s = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let model = Unmanaged<BatteryModel>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { model.powerChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
            source = s
        }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        limitTask?.cancel()
        store.flush()
    }

    private func powerChanged() {
        refresh()
        if pageVisible { refreshLimit() }
    }

    /// Reads the battery again (a few IOKit properties) and posts the alert it calls for.
    func refresh() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        let r = BatteryReader.read()
        if r != reading { reading = r }
        guard started, let r, let alert = BatteryRules.evaluate(r, settings: settings, arming: &arming) else { return }
        let id: String
        if case .low = alert { id = "battery-low" } else { id = "battery-high" }
        Notifier.post(id: id, title: alert.title, body: alert.body(settings), throttle: 600)
    }

    func refreshLimit() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        limitTask?.cancel()
        limitTask = Task {
            let state = await Task.detached(priority: .utility) { BatteryChargeLimit.read() }.value
            guard !Task.isCancelled else { return }
            if state != limit { limit = state }
            if limitRefused == state.limit { limitRefused = nil }
        }
    }

    // MARK: Actions

    /// Asks macOS for a new charge limit. When macOS keeps the setting for itself, System Settings opens on it.
    @discardableResult
    func setLimit(_ percent: Int) async -> CommandOutcome {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return .message(DemoData.refusal) }
        guard applying == nil else { return .done }
        applying = percent
        let error = await Task.detached(priority: .userInitiated) { BatteryChargeLimit.set(percent) }.value
        let state = await Task.detached(priority: .userInitiated) { BatteryChargeLimit.read() }.value
        applying = nil
        limit = state
        guard state.supported else {
            return .failed("Ton Mac n'a pas de limite de recharge : active plutôt l'alerte de charge.")
        }
        if error == nil, state.limit == percent {
            limitRefused = nil
            return .message(percent >= 100 ? "Plus de limite : ton Mac se rechargera jusqu'à 100 %" : "macOS arrêtera la recharge à \(percent) %")
        }
        limitRefused = percent
        openSettings()
        return .message("Choisis \(percent) % dans « Limite de recharge »")
    }

    func openSettings() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        Finder.open(BatteryChargeLimit.settingsURL)
    }

    /// Switching an alert on asks for notifications (after a click, never on its own) and looks at the battery at once.
    func setLowAlert(_ on: Bool) {
        settings.lowAlert = on
        alertChanged(on)
    }

    func setHighAlert(_ on: Bool) {
        settings.highAlert = on
        alertChanged(on)
    }

    func setLowLevel(_ v: Int) {
        settings.lowLevel = BatteryRules.clampLow(v)
        if !settings.lowAlert { setLowAlert(true) } else { alertChanged(true) }
    }

    func setHighLevel(_ v: Int) {
        settings.highLevel = BatteryRules.clampHigh(v)
        if !settings.highAlert { setHighAlert(true) } else { alertChanged(true) }
    }

    private func alertChanged(_ on: Bool) {
        guard on, !DemoData.isEnabled, !Snapshot.isActive else { return }
        Notifier.requestPermission()
        arming = BatteryAlertArming()
        refresh()
    }

    // MARK: Launcher

    private func open(_ app: AppModel) {
        app.page = .battery
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
    }

    private func limitCommand(_ v: Int, id: String, boost: Double = 0) -> AppCommand {
        let current = activeLimit == v
        return AppCommand(id: id, title: v >= 100 ? "Recharger la batterie jusqu'à 100 %" : "Limiter la recharge de la batterie à \(v) %",
                          subtitle: current ? "C'est déjà la limite de macOS" : (v >= 100 ? "Sans limite, avant un voyage par exemple" : "macOS s'arrête là tant que le chargeur reste branché"),
                          keywords: ["batterie", "limite", "recharge", "charge", "aldente", "\(v) %", "\(v)"],
                          icon: .symbol(v >= 100 ? "battery.100percent.bolt" : "battery.75percent", BatteryPage.tint), group: .system,
                          assistantSafe: true, boost: boost) { [weak self] _ in
            guard let self else { return .done }
            return await self.setLimit(v)
        }
    }

    func commands(app: AppModel) -> [AppCommand] {
        var list = [AppCommand(id: "battery_open", title: "Batterie : charge, limite et santé",
                               subtitle: reading.map { "\($0.percent) % · \(BatteryRules.headline($0, limit: activeLimit))" },
                               keywords: ["batterie", "battery", "charge", "chargeur", "limite", "aldente", "santé", "cycles", "autonomie"],
                               icon: .symbol("battery.75percent", BatteryPage.tint), group: .actions,
                               assistantSafe: true, urlSafe: true) { ctx in
            ctx.app.battery.open(ctx.app)
            return .done
        }]
        guard reading != nil else { return list }
        if limit?.supported != false {
            for v in limit?.choices ?? BatteryRules.defaultChoices { list.append(limitCommand(v, id: "battery_limit_\(v)")) }
        }
        let on = settings.lowAlert
        list.append(AppCommand(id: "battery_low_alert", title: on ? "Ne plus me prévenir quand la batterie est faible" : "Me prévenir quand la batterie passe sous \(settings.lowLevel) %",
                               keywords: ["batterie", "alerte", "faible", "notification", "prévenir", "seuil"],
                               icon: .symbol(on ? "bell.slash" : "bell.badge", BatteryPage.tint), group: .system, assistantSafe: true) { [weak self] _ in
            guard let self else { return .done }
            self.setLowAlert(!on)
            return .message(on ? "Alerte de batterie faible coupée" : "Je te préviendrai sous \(self.settings.lowLevel) %")
        })
        return list
    }

    /// « limite 85 », « batterie 90 %».
    func results(for query: String, app: AppModel) -> [AppCommand] {
        guard reading != nil, limit?.supported != false, query.count <= 40,
              let space = query.firstIndex(of: " ") else { return [] }
        let head = Fuzzy.fold(String(query[..<space]))
        guard ["limite", "limiter", "batterie", "recharge", "charge"].contains(head),
              let v = BatteryRules.parseLimit(String(query[query.index(after: space)...]), choices: limit?.choices ?? BatteryRules.defaultChoices)
        else { return [] }
        return [limitCommand(v, id: "battery_r_limit", boost: 1800)]
    }

    // MARK: Demo

    func loadDemo() {
        reading = BatteryReading(percent: 80, isCharging: false, onAC: true, cycleCount: 187, designCycles: 1000,
                                 designCapacity: 4382, maxCapacity: 3986, temperature: 30.4, voltage: 12.71, amperage: -0.02,
                                 adapterWatts: 61, adapterName: "Adaptateur secteur USB-C")
        limit = BatteryLimitState(supported: true, limit: 80, choices: BatteryRules.defaultChoices)
        var s = BatterySettings()
        s.lowAlert = true
        s.lowLevel = 20
        s.highAlert = false
        settings = s
    }

    func applySnapshotTab(_ tab: String) {
        // The page while macOS' charge limit is being read.
        if tab == "attente" { limit = nil }
    }

    // MARK: Checks

    func selfTest() -> [String] { BatteryChecks.run() }

    func dump() -> [String] {
        let r = DemoData.isEnabled ? reading : BatteryReader.read()
        guard let r else { return ["Batterie : aucune sur ce Mac"] }
        let l = DemoData.isEnabled ? limit : BatteryChargeLimit.read()
        let limitText = l.map { s -> String in
            guard s.supported else { return "absente de ce Mac ou de ce macOS" }
            return (s.limit.map { "\($0) %" } ?? "illisible") + " (choix : " + s.choices.map(String.init).joined(separator: ", ") + ")"
        } ?? "pas encore lue"
        return [
            "Batterie : \(r.percent) % · \(BatteryRules.headline(r, limit: l?.supported == true ? l?.limit : nil)) · secteur \(r.onAC ? "oui" : "non") · en charge \(r.isCharging ? "oui" : "non")",
            "Santé : \(r.health.map(Fmt.pct) ?? "?") (\(r.maxCapacity.map(Fmt.int) ?? "?") mAh sur \(r.designCapacity.map(Fmt.int) ?? "?")) · \(r.cycleCount.map { Fmt.plural($0, "cycle", "cycles") } ?? "cycles ?") sur \(r.designCycles.map(Fmt.int) ?? "?")",
            "Courant : \(r.voltage.map(Fmt.dec) ?? "?") V · \(r.amperage.map { Fmt.int($0 * 1000) } ?? "?") mA · chargeur \(r.adapterWatts.map { "\($0) W" } ?? "—")\(r.adapterName.map { " (\($0))" } ?? "") · température \(r.temperature.map { Fmt.dec($0) + " °C" } ?? "illisible")",
            "Limite de recharge de macOS : \(limitText)",
            "Alertes : sous \(settings.lowLevel) % \(settings.lowAlert ? "activée" : "coupée") · en charge à \(settings.highLevel) % \(settings.highAlert ? "activée" : "coupée")"
        ]
    }
}
