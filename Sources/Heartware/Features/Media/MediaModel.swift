import SwiftUI
import Observation

/// The parts of the Multimédia page. The raw values are the `--tab` names of the snapshots.
enum MediaTab: String, CaseIterable, Identifiable {
    /// Films et séries: search, a title's card, where to watch it, the user's platforms (`CinemaModel`).
    case watch = "films"
    /// The ad-free player (YouTube, Twitch, the free platforms), Vidéo seule, the browser handoff, the accounts.
    case player = "lecteur"
    /// The DNS ad blocker of the whole Mac: state, level, counter, exceptions.
    case blocker = "bloqueur"
    /// Windscribe's free VPN: the country chosen here, the data of the month (`VPNModel`).
    case vpn = "vpn"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .watch: return "Films et séries"
        case .player: return "Lecteur sans pub"
        case .blocker: return "Bloqueur de pub"
        case .vpn: return "VPN"
        }
    }

    /// The tab a snapshot name belongs to (`--tab comptes` shows the player's tab…), nil when it is no name of this page.
    static func forSnapshot(_ name: String) -> MediaTab? {
        if let tab = MediaTab(rawValue: name) { return tab }
        // `vpn-absent`, `vpn-compte`, `vpn-connexion`…: the VPN's states (`VPNModel.applySnapshotTab`).
        if name.hasPrefix("vpn-") { return .vpn }
        switch name {
        case "cle", "clé", "vide", "recherche": return .watch
        case "comptes", "video", "lecteur-twitch", "safari", "sans-extension", "bascule": return .player
        case "intro", "installation", "reinstaller", "compteur-vide", "attente", "mesure": return .blocker
        default: return nil
        }
    }
}

/// The Multimédia page: Films et séries (`CinemaModel`), the ad-free player and the ad blocker (`AdBlockModel`), and the
/// VPN (`VPNModel`) under one roof, one tab each.
@Observable
@MainActor
final class MediaModel: AppModule {
    var tab: MediaTab = .watch

    /// The ad blocker's badge ("inactif" when its profile was turned off): this module is the page's first, it gives it.
    var sidebarBadge: String? { AppContext.model?.adblock.sidebarBadge }

    /// Opens the main window on this part of the page.
    func show(_ tab: MediaTab, app: AppModel) {
        self.tab = tab
        LauncherAppActions.openMain(app, .media)
    }

    func applySnapshotTab(_ tab: String) {
        if let t = MediaTab.forSnapshot(tab) { self.tab = t }
    }

    func selfTest() -> [String] {
        var f: [String] = []
        let expected: [(String, MediaTab)] = [("films", .watch), ("cle", .watch), ("lecteur", .player), ("comptes", .player),
                                              ("video", .player), ("safari", .player), ("bloqueur", .blocker), ("intro", .blocker),
                                              ("installation", .blocker), ("attente", .blocker), ("vpn", .vpn), ("vpn-compte", .vpn),
                                              ("vpn-installation", .vpn)]
        for (name, tab) in expected where MediaTab.forSnapshot(name) != tab {
            f.append("Multimédia : « --tab \(name) » n'ouvre pas l'onglet \(tab.title)")
        }
        if MediaTab.forSnapshot("autres") != nil { f.append("Multimédia : un nom d'onglet inconnu change d'onglet") }
        if Set(MediaTab.allCases.map(\.title)).count != MediaTab.allCases.count { f.append("Multimédia : deux onglets portent le même nom") }
        return f
    }

    func dump() -> [String] { ["Onglet : \(tab.title)"] }
}
