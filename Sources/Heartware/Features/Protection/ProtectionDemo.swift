import Foundation

/// The fictional Mac of `--demo` for the new Protection tabs: Camille picked up an adware with a fake video player.
/// Nothing here comes from this Mac (names, paths, apps and addresses are made up).
enum ProtectionDemo {
    static let home = DemoData.home
    private static let now = Date()
    private static func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    static func threatScan(deep: Bool) -> (threats: [ProtectionThreat], summary: ProtectionScanSummary) {
        let hidden = home + "/Library/Application Support/.a7f3c2e1/Services/com.SearchDaemon.service.app"
        let threats = [
            ProtectionThreat(kind: .signature, severity: Status.bad.rawValue, name: "MACOS.ADLOAD.SD",
                             detail: "Les signatures antimalware d'Apple (XProtect 5367) reconnaissent ce fichier.",
                             path: hidden + "/Contents/MacOS/com.SearchDaemon.service",
                             removable: [hidden, home + "/Library/LaunchAgents/com.SearchDaemon.plist"],
                             services: ["gui/501/com.SearchDaemon"]),
            ProtectionThreat(kind: .signature, severity: Status.bad.rawValue, name: "MACOS.9f3e6a2",
                             detail: "Arrivé dans Téléchargements, reconnu par les signatures antimalware d'Apple (XProtect 5367). Ne l'ouvre pas.",
                             path: home + "/Downloads/Lecteur Vidéo HD.app/Contents/MacOS/Lecteur Vidéo HD",
                             removable: [home + "/Downloads/Lecteur Vidéo HD.app"]),
            ProtectionThreat(kind: .persistence, severity: Status.bad.rawValue, name: "com.apple.updates.helper",
                             detail: "Se lance à chaque démarrage. Se fait passer pour Apple : /Users/Shared/.cache/updater --daemon",
                             path: home + "/Library/LaunchAgents/com.apple.updates.helper.plist",
                             removable: [home + "/Library/LaunchAgents/com.apple.updates.helper.plist", "/Users/Shared/.cache/updater"],
                             services: ["gui/501/com.apple.updates.helper"]),
            ProtectionThreat(kind: .tampered, severity: Status.warn.rawValue, name: "Rétro Arcade.app",
                             detail: "Son programme a été modifié après sa signature : version piratée, infectée ou abîmée. Réinstalle-la depuis la source officielle.",
                             path: "/Applications/Rétro Arcade.app", removable: ["/Applications/Rétro Arcade.app"])
        ]
        return (threats, ProtectionScanSummary(date: ago(4), deep: deep, files: deep ? 61_408 : 3_912, threats: 3,
                                               signaturesVersion: 5367, duration: deep ? 214 : 41))
    }

    static func keyboardTaps() -> [ProtectionKeyboardTap] {
        [ProtectionKeyboardTap(pid: 812, name: "Mosaïque", path: "/Applications/Mosaïque.app/Contents/MacOS/Mosaïque",
                               signature: .developerID("Mosaïque Labs"), canModify: true),
         ProtectionKeyboardTap(pid: 655, name: "Tisserand", path: "/Applications/Tisserand.app/Contents/MacOS/Tisserand",
                               signature: .developerID("Tisserand SARL"), canModify: false),
         ProtectionKeyboardTap(pid: 402, name: "universalaccessd", path: "/usr/libexec/universalaccessd", signature: .apple, canModify: false)]
    }

    static func browserExtensions() -> [ProtectionBrowserExtension] {
        let chrome = home + "/Library/Application Support/Google/Chrome/Default/Extensions/"
        return [
            ProtectionBrowserExtension(browser: "Chrome", identifier: "kpbhmnelfgdpaaoijcnclagkcnkcdmlo", name: "Recherche Plus",
                                       readsEverything: true, forced: true, enabled: true, container: chrome + "kpbhmnelfgdpaaoijcnclagkcnkcdmlo"),
            ProtectionBrowserExtension(browser: "Chrome", identifier: "cjpalhdlnbpafiamejdnhcphjbkeiagm", name: "Bloqueur de publicités",
                                       readsEverything: true, forced: false, enabled: true, container: chrome + "cjpalhdlnbpafiamejdnhcphjbkeiagm"),
            ProtectionBrowserExtension(browser: "Chrome", identifier: "aapbdbdomjkkjkaonfhkkikfgjllcleb", name: "Traducteur express",
                                       readsEverything: true, forced: false, enabled: false, container: chrome + "aapbdbdomjkkjkaonfhkkikfgjllcleb"),
            ProtectionBrowserExtension(browser: "Safari", identifier: "fr.ardoise.notes.clipper", name: "Ardoise : capture de page",
                                       readsEverything: false, forced: false, enabled: true, container: "/Applications/Ardoise.app")
        ]
    }

    static func exposedPorts() -> [NetworkPort] {
        [NetworkPort(port: 3000, pid: 9120, process: "node", user: "camille", addresses: ["*"], appPath: "/Applications/Hélios Code.app",
                     executable: "/Applications/Hélios Code.app/Contents/Resources/node"),
         NetworkPort(port: 5000, pid: 488, process: "ControlCenter", user: "camille", addresses: ["*"], appPath: nil,
                     executable: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"),
         NetworkPort(port: 7000, pid: 488, process: "ControlCenter", user: "camille", addresses: ["*"], appPath: nil,
                     executable: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter")]
    }

    static func anchors() -> [ProtectionAnchor] {
        [ProtectionAnchor(kind: .loginItem, name: "Nuage Drive", path: "/Applications/Nuage Drive.app", detail: "Par Nuage Drive SAS", risk: .info),
         ProtectionAnchor(kind: .loginItem, name: "Lanterne", path: "/Applications/Lanterne.app", detail: "Par Lanterne Software", risk: .info),
         ProtectionAnchor(kind: .loginItem, name: "Mosaïque", path: "/Applications/Mosaïque.app", detail: "Par Mosaïque Labs", risk: .info),
         ProtectionAnchor(kind: .systemExtension, name: "Boussole VPN", detail: "com.boussolevpn.client.tunnel · activated enabled", risk: .info)]
    }

    static func events() -> [ProtectionEvent] {
        [ProtectionEvent(date: ago(38), kind: .download, title: "Menace dans Téléchargements : Lecteur Vidéo HD.app",
                         detail: "MACOS.9f3e6a2 : ne l'ouvre pas, mets-le à la Corbeille depuis Protection › Menaces.", severity: Status.bad.rawValue,
                         path: home + "/Downloads/Lecteur Vidéo HD.app"),
         ProtectionEvent(date: ago(36), kind: .persistence, title: "Élément de démarrage suspect : com.apple.updates.helper",
                         detail: "Se lance à chaque démarrage. Se fait passer pour Apple : /Users/Shared/.cache/updater --daemon", severity: Status.bad.rawValue),
         ProtectionEvent(date: ago(130), kind: .camera, title: "La caméra s'est éteinte", detail: "Plus aucune app ne filme.", severity: Status.info.rawValue),
         ProtectionEvent(date: ago(175), kind: .camera, title: "La caméra s'est allumée", detail: "Une app filme. Le Centre de contrôle indique laquelle.",
                         severity: Status.warn.rawValue),
         ProtectionEvent(date: ago(2_900), kind: .persistence, title: "Nouvel élément de démarrage : com.helios.code.updater",
                         detail: "Helios Labs Inc. · se lancera à chaque démarrage.", severity: Status.info.rawValue),
         ProtectionEvent(date: ago(4_300), kind: .persistence, title: "Protection en temps réel activée",
                         detail: "Démarrage, Téléchargements, caméra, micro et réglages réseau sont surveillés.", severity: Status.ok.rawValue)]
    }
}
