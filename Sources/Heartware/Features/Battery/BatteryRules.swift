import Foundation

/// What the battery module keeps between launches ("battery").
struct BatterySettings: Codable, Equatable {
    /// Warn when the battery runs down to `lowLevel` (on battery).
    var lowAlert = false
    var lowLevel = 20
    /// Warn when charging reaches `highLevel`: time to unplug (for a Mac without a charge limit, or to aim lower).
    var highAlert = false
    var highLevel = 80

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BatterySettings()
        lowAlert = (try? c.decodeIfPresent(Bool.self, forKey: .lowAlert)) ?? d.lowAlert
        lowLevel = BatteryRules.clampLow((try? c.decodeIfPresent(Int.self, forKey: .lowLevel)) ?? d.lowLevel)
        highAlert = (try? c.decodeIfPresent(Bool.self, forKey: .highAlert)) ?? d.highAlert
        highLevel = BatteryRules.clampHigh((try? c.decodeIfPresent(Int.self, forKey: .highLevel)) ?? d.highLevel)
    }
}

/// Which alerts may fire: each one fires once, then waits until the battery is clearly back on the right side.
struct BatteryAlertArming: Equatable {
    var low = true
    var high = true
}

enum BatteryAlert: Equatable {
    case low(Int)
    case high(Int)

    var title: String {
        switch self {
        case .low(let p): return "Batterie à \(p) %"
        case .high(let p): return "Batterie à \(p) %"
        }
    }

    func body(_ s: BatterySettings) -> String {
        switch self {
        case .low: return "Branche ton chargeur : elle vient de passer sous ton seuil d'alerte de \(s.lowLevel) %."
        case .high: return "Tu peux débrancher le chargeur : au-delà de \(s.highLevel) %, la batterie s'use plus vite."
        }
    }
}

/// The rules of the module, apart from IOKit (checked by `--selftest`).
enum BatteryRules {
    static let defaultChoices = [80, 85, 90, 95, 100]
    static let lowChoices = [10, 15, 20, 25, 30, 40]
    static let highChoices = [50, 60, 70, 75, 80, 90]
    /// Points the level must come back past before the same alert may fire again.
    static let rearm = 3

    static func clampLow(_ v: Int) -> Int { min(50, max(5, v)) }
    static func clampHigh(_ v: Int) -> Int { min(100, max(40, v)) }

    /// The alert to post for this reading, if any; updates which alerts may fire next.
    static func evaluate(_ r: BatteryReading, settings s: BatterySettings, arming: inout BatteryAlertArming) -> BatteryAlert? {
        // Back on the right side: the alert may fire again next time.
        if r.onAC || r.percent >= s.lowLevel + rearm { arming.low = true }
        if !r.onAC || r.percent <= s.highLevel - rearm { arming.high = true }
        if s.lowAlert, arming.low, !r.onAC, r.percent <= s.lowLevel {
            arming.low = false
            return .low(r.percent)
        }
        // Only while it charges: plugging in a Mac already above the level says nothing.
        if s.highAlert, arming.high, r.onAC, r.isCharging, r.percent >= s.highLevel {
            arming.high = false
            return .high(r.percent)
        }
        return nil
    }

    /// The state in a few words, for the page and the launcher.
    static func headline(_ r: BatteryReading, limit: Int?) -> String {
        let capped = limit.map { $0 < 100 } ?? false
        if r.isCharging { return capped ? "En charge jusqu'à \(limit ?? 100) %" : "En charge" }
        if r.onAC {
            if r.fullyCharged || r.percent >= 100 { return "Chargée" }
            if let limit, capped, r.percent >= limit - 1 { return "En pause à la limite" }
            return "Branchée, charge en pause"
        }
        return "Sur batterie"
    }

    static func detail(_ r: BatteryReading, limit: Int?) -> String {
        if r.isCharging {
            if let m = r.minutesToFull { return "Encore \(Fmt.duration(Double(m) * 60)) avant \(limit.map { $0 < 100 ? "la limite" : "d'être pleine" } ?? "d'être pleine")." }
            return "La batterie se recharge."
        }
        if r.onAC {
            if let limit, limit < 100, r.percent >= limit - 1 {
                return "macOS garde la batterie à \(limit) % tant que le chargeur reste branché : ton Mac tourne sur le secteur."
            }
            if r.isHeld { return "macOS retient la charge (recharge optimisée ou température) : elle reprendra d'elle-même." }
            return "Ton Mac tourne sur le secteur."
        }
        if let m = r.minutesToEmpty { return "Environ \(Fmt.duration(Double(m) * 60)) d'autonomie à ce rythme." }
        return "macOS calcule l'autonomie restante."
    }

    /// What follows « limite » in the launcher: a percentage among `choices` ("80", "80 %").
    static func parseLimit(_ text: String, choices: [Int]) -> Int? {
        let t = text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        guard let v = Int(t), choices.contains(v) else { return nil }
        return v
    }

    static func label(_ limit: Int) -> String { limit >= 100 ? "100 % (sans limite)" : "\(limit) %" }
}
