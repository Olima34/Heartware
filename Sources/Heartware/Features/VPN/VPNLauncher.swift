import SwiftUI

/// The VPN in the launcher: « vpn france », « vpn off », and « vpn <pays> » for each free country.
@MainActor
enum VPNLauncher {
    static func commands() -> [AppCommand] {
        let tint = VPNStyle.tint
        return [
            AppCommand(id: "vpn_france", title: "VPN : se connecter en France", subtitle: "Windscribe gratuit, sans pub",
                       keywords: ["vpn", "france", "windscribe", "paris", "replay", "géoblocage", "france.tv", "tf1", "m6"],
                       icon: .symbol("lock.shield", tint), group: .actions, assistantSafe: true, hint: "Connecter") { ctx in
                ctx.app.vpn.connectFromOutside(.fr, app: ctx.app)
            },
            AppCommand(id: "vpn_off", title: "VPN : déconnecter", subtitle: "Coupe le VPN de Windscribe",
                       keywords: ["vpn", "couper", "désactiver", "arrêter", "windscribe", "vpn off"],
                       icon: .symbol("lock.open", tint), group: .actions, assistantSafe: true, hint: "Couper") { ctx in
                guard !DemoData.isEnabled else { return .message(DemoData.refusal) }
                ctx.app.vpn.disconnect(announce: true)
                return .done
            },
            AppCommand(id: "vpn_open", title: "VPN", subtitle: "Ton pays avec Windscribe, sur la page Multimédia",
                       keywords: ["vpn", "windscribe", "pays", "géoblocage"],
                       icon: .symbol("globe.europe.africa", tint), group: .tools, assistantSafe: true, urlSafe: true, hint: "Ouvrir") { ctx in
                ctx.app.media.show(.vpn, app: ctx.app)
                return .done
            }
        ]
    }

    /// « vpn fra », « vpn usa », « vpn londres »…: the free countries that match, France first.
    static func results(_ query: String) -> [AppCommand] {
        let asked = countries(for: query)
        return asked.prefix(4).enumerated().map { i, country in
            AppCommand(id: "vpn_to_" + country.rawValue, title: "VPN : se connecter \(country.inName)", subtitle: "Windscribe gratuit",
                       icon: .emoji(country.flag), group: .actions, hint: "Connecter", boost: 1500 - Double(i)) { ctx in
                ctx.app.vpn.connectFromOutside(country, app: ctx.app)
            }
        }
    }

    /// The countries a « vpn … » query asks for; [] when it is no such query.
    nonisolated static func countries(for query: String) -> [VPNCountry] {
        let q = VPNStatusParser.fold(query)
        guard q.hasPrefix("vpn ") else { return [] }
        let asked = String(q.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        guard !asked.isEmpty else { return [] }
        return VPNCountry.allCases.filter { country in
            country.searchNames.contains { name in
                name.hasPrefix(asked) || name.split(whereSeparator: { $0 == " " || $0 == "-" }).contains { $0.hasPrefix(asked) }
            }
        }
    }
}
