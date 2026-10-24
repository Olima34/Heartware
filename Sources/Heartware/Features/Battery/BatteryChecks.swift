import Foundation

/// `--selftest` for the battery: alerts that fire once and come back, the state in words, the launcher and the settings.
@MainActor
enum BatteryChecks {
    static func run() -> [String] {
        var f: [String] = []
        func equal<T: Equatable>(_ got: T, _ want: T, _ label: String) {
            if got != want { f.append("\(label) : « \(got) », attendu « \(want) »") }
        }
        func reading(_ percent: Int, ac: Bool, charging: Bool = false) -> BatteryReading {
            BatteryReading(percent: percent, isCharging: charging, onAC: ac)
        }

        // Low battery: once when crossing the level, again only after coming back above it (or after plugging in).
        var s = BatterySettings()
        s.lowAlert = true
        s.lowLevel = 20
        var arming = BatteryAlertArming()
        equal(BatteryRules.evaluate(reading(25, ac: false), settings: s, arming: &arming), nil, "alerte basse au-dessus du seuil")
        equal(BatteryRules.evaluate(reading(20, ac: false), settings: s, arming: &arming), .low(20), "alerte basse au seuil")
        equal(BatteryRules.evaluate(reading(19, ac: false), settings: s, arming: &arming), nil, "alerte basse répétée")
        equal(BatteryRules.evaluate(reading(21, ac: false), settings: s, arming: &arming), nil, "alerte basse réarmée trop tôt")
        equal(BatteryRules.evaluate(reading(20, ac: false), settings: s, arming: &arming), nil, "alerte basse sans remonter")
        equal(BatteryRules.evaluate(reading(18, ac: true, charging: true), settings: s, arming: &arming), nil, "alerte basse sur secteur")
        equal(BatteryRules.evaluate(reading(18, ac: false), settings: s, arming: &arming), .low(18), "alerte basse après le chargeur")
        s.lowAlert = false
        arming = BatteryAlertArming()
        equal(BatteryRules.evaluate(reading(5, ac: false), settings: s, arming: &arming), nil, "alerte basse coupée")

        // Charging alert: only while it charges, once, again after unplugging.
        s.highAlert = true
        s.highLevel = 80
        arming = BatteryAlertArming()
        equal(BatteryRules.evaluate(reading(85, ac: true), settings: s, arming: &arming), nil, "alerte haute sans recharge")
        equal(BatteryRules.evaluate(reading(80, ac: true, charging: true), settings: s, arming: &arming), .high(80), "alerte haute")
        equal(BatteryRules.evaluate(reading(81, ac: true, charging: true), settings: s, arming: &arming), nil, "alerte haute répétée")
        equal(BatteryRules.evaluate(reading(81, ac: false), settings: s, arming: &arming), nil, "alerte haute débranché")
        equal(BatteryRules.evaluate(reading(82, ac: true, charging: true), settings: s, arming: &arming), .high(82), "alerte haute rebranché")

        // The state in words.
        equal(BatteryRules.headline(reading(80, ac: true), limit: 80), "En pause à la limite", "état à la limite")
        equal(BatteryRules.headline(reading(60, ac: true, charging: true), limit: 80), "En charge jusqu'à 80 %", "état en charge limitée")
        equal(BatteryRules.headline(reading(60, ac: true, charging: true), limit: 100), "En charge", "état en charge sans limite")
        equal(BatteryRules.headline(reading(100, ac: true), limit: nil), "Chargée", "état chargée")
        equal(BatteryRules.headline(reading(40, ac: false), limit: 80), "Sur batterie", "état sur batterie")
        equal(BatteryRules.headline(reading(60, ac: true), limit: 80), "Branchée, charge en pause", "état retenu sous la limite")

        // Health from the capacities, current from the controller.
        let r = BatteryReading(percent: 50, isCharging: false, onAC: false, designCapacity: 4000, maxCapacity: 3600, voltage: 12, amperage: -0.5)
        equal(r.health, 0.9, "santé")
        equal(r.batteryPower, -6, "puissance")
        equal(BatteryReading(percent: 50, isCharging: false, onAC: false, designCapacity: 4000, maxCapacity: 4200).health, 1, "santé plafonnée")

        // Launcher.
        let choices = BatteryRules.defaultChoices
        equal(BatteryRules.parseLimit("80", choices: choices), 80, "« limite 80 »")
        equal(BatteryRules.parseLimit(" 95 % ", choices: choices), 95, "« limite 95 % »")
        equal(BatteryRules.parseLimit("82", choices: choices), nil, "« limite 82 » hors des choix")
        equal(BatteryRules.parseLimit("abc", choices: choices), nil, "« limite abc »")

        // Settings: an older or damaged file keeps what it can, and levels out of range come back within bounds.
        let decoded = try? JSONDecoder.store.decode(BatterySettings.self, from: Data(#"{"lowAlert":true,"lowLevel":-2,"highLevel":400}"#.utf8))
        equal(decoded?.lowAlert, true, "réglage relu")
        equal(decoded?.lowLevel, 5, "seuil bas hors bornes")
        equal(decoded?.highLevel, 100, "seuil haut hors bornes")
        equal(decoded?.highAlert, false, "réglage absent")
        return f
    }
}
