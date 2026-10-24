import Foundation
import Security
import SystemConfiguration

/// The families of the security review, in the order the page shows them.
enum SecurityCategory: String, CaseIterable, Identifiable {
    case defenses, updates, access, sharing, network, secrets, browsing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defenses: return "Défenses de macOS"
        case .updates: return "Mises à jour"
        case .access: return "Accès au Mac"
        case .sharing: return "Partage et accès à distance"
        case .network: return "Réseau et interception"
        case .secrets: return "Secrets et identifiants"
        case .browsing: return "Fichiers et navigation"
        }
    }

    var symbol: String {
        switch self {
        case .defenses: return "shield.lefthalf.filled"
        case .updates: return "arrow.triangle.2.circlepath"
        case .access: return "lock"
        case .sharing: return "person.2.wave.2"
        case .network: return "network.badge.shield.half.filled"
        case .secrets: return "key"
        case .browsing: return "safari"
        }
    }
}

/// "Essentiel": what every Mac should have. "Renforcé": stricter, for a laptop that travels or sensitive work
/// (in the spirit of the CIS Benchmark level 2 and the NIST macOS Security Compliance Project).
enum SecurityLevel {
    case essential, hardened
}

/// What the app can do itself about a point, after the user's confirmation.
struct SecurityFix {
    enum Action {
        /// Tools run as the user, one after the other (arguments, never a shell).
        case user([[String]])
        /// One fixed command line run as administrator (macOS asks for the password): never built from data.
        case admin(String)
    }

    var title: String
    /// What happens, in plain words, shown before anything runs.
    var explanation: String
    var action: Action
}

struct SecurityCheck: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var status: Status
    var detail: String
    var advice: String? = nil
    var settingsURL: String? = nil
    /// Counted in the security score.
    var scored = true
    var fix: SecurityFix? = nil

    var category: SecurityCategory { SecurityAudit.catalog[id]?.category ?? .defenses }
    /// 3: critical, 2: important, 1: recommended.
    var weight: Int { SecurityAudit.catalog[id]?.weight ?? 1 }
    var level: SecurityLevel { SecurityAudit.catalog[id]?.level ?? .essential }
    var passed: Bool { status == .ok || status == .info }
}

enum SettingsPane {
    static let fileVault = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault"
    static let security = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Security"
    static let firewall = "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall"
    static let updates = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
    static let lockScreen = "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"
    static let users = "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"
    static let sharing = "x-apple.systempreferences:com.apple.Sharing-Settings.extension"
    static let loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    static let network = "x-apple.systempreferences:com.apple.Network-Settings.extension"
    static let profiles = "x-apple.systempreferences:com.apple.Profiles-Settings.extension"
    static let airDrop = "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension"
    static let timeMachine = "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"
    static let extensions = "x-apple.systempreferences:com.apple.ExtensionsPreferences"
    static func privacy(_ anchor: String) -> String { "x-apple.systempreferences:com.apple.preference.security?\(anchor)" }
}

/// Reads the state of macOS' own protections and of what weakens them. Nothing here needs administrator rights,
/// nothing is changed: the fixes run only from the page, after a confirmation.
enum SecurityAudit {
    /// Family, weight and level of every point, by id (the demo shares it).
    static let catalog: [String: (category: SecurityCategory, weight: Int, level: SecurityLevel)] = [
        "filevault": (.defenses, 3, .essential), "sip": (.defenses, 3, .essential), "gatekeeper": (.defenses, 3, .essential),
        "ssv": (.defenses, 2, .essential), "firewall": (.defenses, 2, .essential), "stealth": (.defenses, 1, .hardened),
        "xprotect": (.defenses, 2, .essential), "backup": (.defenses, 1, .hardened), "lockdown": (.defenses, 1, .hardened),
        "updates": (.updates, 3, .essential), "autoinstall": (.updates, 1, .essential), "pending": (.updates, 2, .essential),
        "screenlock": (.access, 3, .essential), "idle": (.access, 1, .essential), "autologin": (.access, 3, .essential),
        "guest": (.access, 2, .essential), "root": (.access, 2, .essential), "hints": (.access, 1, .essential),
        "admin": (.access, 1, .hardened),
        "ssh": (.sharing, 2, .essential), "screensharing": (.sharing, 2, .essential), "ard": (.sharing, 2, .essential),
        "remoteevents": (.sharing, 2, .essential), "filesharing": (.sharing, 1, .essential), "printers": (.sharing, 1, .essential),
        "internetsharing": (.sharing, 2, .essential), "bluetooth": (.sharing, 1, .hardened), "airplay": (.sharing, 1, .hardened),
        "airdrop": (.sharing, 1, .essential), "media": (.sharing, 1, .hardened),
        "proxy": (.network, 2, .essential), "dns": (.network, 2, .essential), "certificates": (.network, 3, .essential),
        "hosts": (.network, 1, .essential), "profiles": (.network, 2, .essential), "policies": (.network, 2, .essential),
        "sshkeys": (.secrets, 1, .essential), "credentials": (.secrets, 2, .essential), "history": (.secrets, 1, .essential),
        "extensions": (.browsing, 1, .essential), "safaridownloads": (.browsing, 1, .essential), "fraud": (.browsing, 2, .essential)
    ]

    static func run() -> [SecurityCheck] {
        if DemoData.isEnabled { return DemoData.securityChecks() }
        let checks: [() -> [SecurityCheck]] = [
            { [fileVault()] }, { [sip()] }, { [gatekeeper()] }, { [sealedSystem()] }, firewall, { [xprotect()] },
            { [backup()] }, { [lockdown()] }, updates, { [screenLock()] }, { [idleLock()] }, { [autoLogin()] }, { [guest()] },
            { [rootAccount()] }, { [passwordHints()] }, { [adminAccount()] }, sharing, { [airDrop()] }, { [proxy()] }, { [dns()] },
            { [certificates()] }, { [hostsFile()] }, { [profiles()] }, { [browserPolicies()] }, { [sshKeys()] },
            { [credentialFiles()] }, { [shellHistory()] }, { [fileExtensions()] }, safari
        ]
        let slots = Slots<[SecurityCheck]>(count: checks.count)
        DispatchQueue.concurrentPerform(iterations: checks.count) { i in _ = slots.set(i, checks[i]()) }
        let all = slots.all.flatMap { $0 }
        // In the catalog's family order, then as listed.
        return SecurityCategory.allCases.flatMap { c in all.filter { $0.category == c } }
    }

    // MARK: Defenses

    static func fileVault() -> SecurityCheck {
        let out = Shell.run("/usr/bin/fdesetup", ["status"]).all
        var c = SecurityCheck(id: "filevault", title: "Chiffrement FileVault", symbol: "lock.doc", status: .unknown,
                              detail: "État inconnu", settingsURL: SettingsPane.fileVault)
        if out.contains("FileVault is On") {
            c.status = .ok
            c.detail = "Ton disque est chiffré : sans ton mot de passe, ses données sont illisibles."
        } else if out.contains("in progress") {
            c.status = .info
            c.detail = "Chiffrement en cours."
        } else if out.contains("FileVault is Off") {
            c.status = .bad
            c.detail = "Le disque n'est pas chiffré."
            c.advice = "Si ton Mac est perdu ou volé, n'importe qui peut lire tes fichiers. Active FileVault dans Confidentialité et sécurité."
        }
        return c
    }

    static func firewall() -> [SecurityCheck] {
        let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        let state = Shell.run(tool, ["--getglobalstate"]).all
        let stealthOut = Shell.run(tool, ["--getstealthmode"]).all
        var c = SecurityCheck(id: "firewall", title: "Coupe-feu", symbol: "flame", status: .unknown,
                              detail: "État inconnu", settingsURL: SettingsPane.firewall)
        let on = state.contains("enabled")
        if on {
            c.status = .ok
            c.detail = "Les connexions entrantes non autorisées sont bloquées."
        } else if state.contains("disabled") {
            c.status = .warn
            c.detail = "Le coupe-feu est désactivé."
            c.advice = "Sur un Wi-Fi public, il empêche les autres appareils de se connecter à tes services."
            c.fix = SecurityFix(title: "Activer le coupe-feu",
                                explanation: "Le coupe-feu de macOS sera activé. macOS te demande ton mot de passe d'administrateur.",
                                action: .admin("/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on"))
        }
        var s = SecurityCheck(id: "stealth", title: "Mode furtif", symbol: "eye.slash", status: .unknown,
                              detail: "État inconnu", settingsURL: SettingsPane.firewall)
        let stealth = stealthOut.lowercased()
        if stealth.contains("is on") || stealth.contains("enabled") {
            s.status = .ok
            s.detail = "Ton Mac ne répond pas aux sondes du réseau (ping, balayage de ports)."
        } else if stealth.contains("is off") || stealth.contains("disabled") {
            s.status = .warn
            s.detail = "Ton Mac se signale à qui le sonde sur le réseau."
            s.advice = "Le mode furtif le rend invisible aux balayages sur un Wi-Fi public." + (on ? "" : " Il demande le coupe-feu.")
            s.fix = SecurityFix(title: "Activer le mode furtif",
                                explanation: "Le coupe-feu passe en mode furtif (et s'active s'il était coupé). macOS te demande ton mot de passe d'administrateur.",
                                action: .admin("/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on; /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on"))
        }
        return [c, s]
    }

    static func gatekeeper() -> SecurityCheck {
        let out = Shell.run("/usr/sbin/spctl", ["--status"]).all
        var c = SecurityCheck(id: "gatekeeper", title: "Gatekeeper", symbol: "checkmark.shield", status: .unknown,
                              detail: "État inconnu", settingsURL: SettingsPane.security)
        if out.contains("assessments enabled") {
            c.status = .ok
            c.detail = "Seules les apps signées et vérifiées par Apple s'ouvrent sans avertissement."
        } else if out.contains("disabled") {
            c.status = .bad
            c.detail = "Les apps s'ouvrent sans aucune vérification."
            c.advice = "Réactive-le dans Confidentialité et sécurité : « Autoriser les applications téléchargées depuis : App Store et développeurs identifiés »."
        }
        return c
    }

    static func sip() -> SecurityCheck {
        let out = Shell.run("/usr/bin/csrutil", ["status"]).all
        var c = SecurityCheck(id: "sip", title: "Protection de l'intégrité du système", symbol: "cpu", status: .unknown,
                              detail: "État inconnu")
        if out.contains("enabled.") {
            c.status = .ok
            c.detail = "Les fichiers de macOS ne peuvent pas être modifiés, même par un administrateur."
        } else if out.contains("disabled") || out.contains("Custom Configuration") {
            c.status = .bad
            c.detail = "SIP est désactivée ou affaiblie : un logiciel malveillant pourrait modifier macOS."
            c.advice = "Réactive-la depuis le mode de récupération avec « csrutil enable »."
        }
        return c
    }

    static func sealedSystem() -> SecurityCheck {
        let out = Shell.run("/usr/bin/csrutil", ["authenticated-root", "status"]).all
        var c = SecurityCheck(id: "ssv", title: "Volume système scellé", symbol: "seal", status: .unknown, detail: "État inconnu")
        if out.contains("enabled") {
            c.status = .ok
            c.detail = "macOS vérifie à chaque démarrage que son volume système n'a pas été modifié d'un seul octet."
        } else if out.contains("disabled") {
            c.status = .bad
            c.detail = "Le sceau du volume système est désactivé : macOS ne vérifie plus son intégrité au démarrage."
            c.advice = "Réactive-le depuis le mode de récupération avec « csrutil authenticated-root enable »."
        }
        return c
    }

    static func xprotect() -> SecurityCheck {
        guard let best = ProtectionSignatures.newest() else {
            return SecurityCheck(id: "xprotect", title: "Antimalware intégré (XProtect)", symbol: "ant", status: .unknown,
                                 detail: "Version introuvable.", scored: false)
        }
        var c = SecurityCheck(id: "xprotect", title: "Antimalware intégré (XProtect)", symbol: "ant", status: .ok,
                              detail: "", settingsURL: SettingsPane.updates)
        let when = best.date.map { ", installées \(Fmt.relative($0))" } ?? ""
        c.detail = "Actif. Définitions version \(best.version)\(when)."
        if let d = best.date, Date().timeIntervalSince(d) > 90 * 86400 {
            c.status = .warn
            c.detail = "Définitions version \(best.version), installées \(Fmt.relative(d)) : elles ne se mettent plus à jour."
            c.advice = "Apple publie de nouvelles signatures plusieurs fois par mois. Vérifie que « Installer les réponses de sécurité et les fichiers système » est activé."
        }
        return c
    }

    static func backup() -> SecurityCheck {
        var c = SecurityCheck(id: "backup", title: "Sauvegarde Time Machine", symbol: "clock.arrow.circlepath", status: .unknown,
                              detail: "État inconnu", settingsURL: SettingsPane.timeMachine)
        let out = Shell.run("/usr/bin/tmutil", ["destinationinfo"]).all
        if out.contains("No destinations configured") {
            c.status = .warn
            c.detail = "Aucune sauvegarde Time Machine n'est configurée."
            c.advice = "Face à un rançongiciel, une panne ou une erreur, une sauvegarde est le seul vrai recours. Si tu sauvegardes autrement, ignore ce point."
            return c
        }
        guard out.contains("Name") else { return c }
        let destinations = defaultsExport("/Library/Preferences/com.apple.TimeMachine")["Destinations"] as? [[String: Any]] ?? []
        let unencrypted = destinations.contains { ($0["LastKnownEncryptionState"] as? String).map { $0 != "Encrypted" } ?? false }
        c.status = unencrypted ? .warn : .ok
        c.detail = unencrypted ? "Une sauvegarde n'est pas chiffrée : qui prend le disque lit tes fichiers."
                               : "Ton Mac est sauvegardé par Time Machine."
        if unencrypted { c.advice = "Choisis « Chiffrer la sauvegarde » pour ce disque dans Time Machine." }
        return c
    }

    static func lockdown() -> SecurityCheck {
        let on = defaultsExport(FS.home + "/Library/Preferences/.GlobalPreferences")["LDMGlobalEnabled"] as? Bool ?? false
        return SecurityCheck(id: "lockdown", title: "Mode Isolement", symbol: "lock.trianglebadge.exclamationmark",
                             status: .info,
                             detail: on ? "Activé : macOS restreint fortement ce qui peut l'attaquer (pièces jointes, liens, partages)."
                                        : "Désactivé. Il protège les personnes visées par des attaques ciblées (journalistes, militants…).",
                             advice: on ? nil : "La plupart des gens n'en ont pas besoin : il limite aussi certaines fonctions.",
                             settingsURL: SettingsPane.security, scored: false)
    }

    // MARK: Updates

    static func updates() -> [SecurityCheck] {
        let plist = defaultsExport("/Library/Preferences/com.apple.SoftwareUpdate")
        func flag(_ k: String) -> Bool { (plist[k] as? Bool) ?? ((plist[k] as? Int).map { $0 != 0 } ?? true) }
        var c = SecurityCheck(id: "updates", title: "Réponses de sécurité automatiques", symbol: "arrow.triangle.2.circlepath",
                              status: .ok, detail: "", settingsURL: SettingsPane.updates)
        if !(flag("CriticalUpdateInstall") && flag("ConfigDataInstall")) {
            c.status = .bad
            c.detail = "Les réponses de sécurité et les fichiers de données système (XProtect) ne s'installent pas seuls."
            c.advice = "Active « Installer les réponses de sécurité et les fichiers système » dans Mise à jour de logiciels › Options."
        } else if !flag("AutomaticCheckEnabled") {
            c.status = .warn
            c.detail = "macOS ne recherche pas les mises à jour tout seul."
            c.advice = "Active la recherche automatique dans Mise à jour de logiciels."
        } else {
            c.detail = "Les correctifs de sécurité et les signatures antimalware s'installent tout seuls."
        }
        var a = SecurityCheck(id: "autoinstall", title: "Mises à jour de macOS automatiques", symbol: "square.and.arrow.down.on.square",
                              status: .ok, detail: "", settingsURL: SettingsPane.updates)
        if !flag("AutomaticDownload") {
            a.status = .warn
            a.detail = "macOS ne télécharge pas ses mises à jour à l'avance."
            a.advice = "Active le téléchargement automatique : les correctifs arrivent plus vite."
        } else if !flag("AutomaticallyInstallMacOSUpdates") {
            a.status = .info
            a.detail = "Les mises à jour de macOS sont téléchargées et attendent ton feu vert."
        } else {
            a.detail = "macOS se met à jour tout seul."
        }
        return [c, a]
    }

    /// Slow (it asks Apple's servers), so it runs on its own.
    static func pendingUpdates() -> SecurityCheck {
        if DemoData.isEnabled { return DemoData.pendingUpdates() }
        let r = Shell.run("/usr/sbin/softwareupdate", ["-l"], timeout: 90)
        let text = r.all
        var c = SecurityCheck(id: "pending", title: "Mises à jour en attente", symbol: "square.and.arrow.down",
                              status: .unknown, detail: "Impossible de joindre le serveur de mises à jour.",
                              settingsURL: SettingsPane.updates)
        let labels = text.split(separator: "\n").filter { $0.contains("* Label:") }
            .map { $0.replacingOccurrences(of: "* Label:", with: "").trimmingCharacters(in: .whitespaces) }
        if !labels.isEmpty {
            c.status = .warn
            c.detail = labels.prefix(3).joined(separator: ", ")
            c.advice = "Installe-les : la plupart corrigent des failles de sécurité."
        } else if text.contains("No new software available") {
            c.status = .ok
            c.detail = "Ton Mac est à jour."
        }
        return c
    }

    // MARK: Access

    static func screenLock() -> SecurityCheck {
        let out = Shell.run("/usr/sbin/sysadminctl", ["-screenLock", "status"]).all
        var c = SecurityCheck(id: "screenlock", title: "Mot de passe au réveil", symbol: "lock.display", status: .unknown,
                              detail: "État inconnu", settingsURL: SettingsPane.lockScreen)
        if out.contains("is off") {
            c.status = .bad
            c.detail = "Ton Mac se réveille sans demander de mot de passe."
            c.advice = "Règle « Exiger le mot de passe » sur « Immédiatement » dans Écran verrouillé."
        } else if out.contains("immediate") {
            c.status = .ok
            c.detail = "Le mot de passe est demandé immédiatement après la veille."
        } else if let r = out.range(of: #"delay is (\d+) seconds"#, options: .regularExpression) {
            let n = Int(out[r].filter(\.isNumber)) ?? 0
            c.status = n <= 300 ? .ok : .warn
            c.detail = "Le mot de passe est demandé \(Fmt.duration(Double(n))) après la veille."
            if n > 300 { c.advice = "Raccourcis ce délai dans Écran verrouillé." }
        }
        return c
    }

    /// The screen locks when the screen saver starts or the display sleeps, whichever comes first.
    static func idleLock() -> SecurityCheck {
        var c = SecurityCheck(id: "idle", title: "Verrouillage après inactivité", symbol: "timer", status: .unknown,
                              detail: "État inconnu", settingsURL: SettingsPane.lockScreen)
        let saver = Shell.run("/usr/bin/defaults", ["-currentHost", "read", "com.apple.screensaver", "idleTime"])
        // Never set: macOS' default of twenty minutes.
        let saverSeconds = saver.ok ? Int(saver.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1200 : 1200
        var sleeps: [Int] = []
        for line in Shell.run("/usr/bin/pmset", ["-g", "custom"]).out.split(separator: "\n") where line.contains("displaysleep") {
            if let n = Int(line.split(separator: " ").last ?? "") { sleeps.append(n) }
        }
        let lockAfter = idleLockSeconds(screenSaver: saverSeconds, displaySleepMinutes: sleeps)
        if lockAfter == nil {
            c.status = .warn
            c.detail = "L'écran ne s'éteint jamais tout seul (au moins sur secteur) : ton Mac reste ouvert si tu t'absentes."
            c.advice = "Règle l'économiseur d'écran ou l'extinction de l'écran sur 20 minutes au plus dans Écran verrouillé."
        } else if let s = lockAfter, s > 20 * 60 {
            c.status = .warn
            c.detail = "Ton Mac se verrouille après \(Fmt.duration(Double(s))) d'inactivité."
            c.advice = "20 minutes au plus : réduis l'économiseur ou l'extinction de l'écran dans Écran verrouillé."
        } else if let s = lockAfter {
            c.status = .ok
            c.detail = "Ton Mac se verrouille après \(Fmt.duration(Double(s))) d'inactivité au plus."
        }
        return c
    }

    /// When the screen locks on the worst power source (battery or adapter), or nil for never. 0 means never for both.
    static func idleLockSeconds(screenSaver: Int, displaySleepMinutes: [Int]) -> Int? {
        let display = displaySleepMinutes.map { $0 == 0 ? Int.max : $0 * 60 }.max() ?? Int.max
        let saver = screenSaver == 0 ? Int.max : screenSaver
        let lock = min(saver, display)
        return lock == Int.max ? nil : lock
    }

    static func autoLogin() -> SecurityCheck {
        let r = Shell.run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"])
        if r.ok, !r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SecurityCheck(id: "autologin", title: "Ouverture de session automatique", symbol: "person.badge.key",
                                 status: .bad, detail: "Le Mac ouvre la session de \(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) sans mot de passe.",
                                 advice: "Désactive l'ouverture de session automatique dans Utilisateurs et groupes.",
                                 settingsURL: SettingsPane.users)
        }
        return SecurityCheck(id: "autologin", title: "Ouverture de session automatique", symbol: "person.badge.key",
                             status: .ok, detail: "Désactivée : il faut un mot de passe au démarrage.", settingsURL: SettingsPane.users)
    }

    static func guest() -> SecurityCheck {
        let r = Shell.run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.loginwindow", "GuestEnabled"])
        let on = r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        var c = SecurityCheck(id: "guest", title: "Compte invité", symbol: "person.crop.circle.badge.questionmark",
                              status: on ? .warn : .ok,
                              detail: on ? "N'importe qui peut ouvrir une session invité sur ce Mac." : "Désactivé.",
                              advice: on ? "Désactive-le si tu ne t'en sers pas." : nil,
                              settingsURL: SettingsPane.users)
        if on {
            c.fix = SecurityFix(title: "Désactiver le compte invité",
                                explanation: "Le compte invité et l'accès invité aux dossiers partagés seront désactivés. macOS te demande ton mot de passe d'administrateur.",
                                action: .admin("/usr/sbin/sysadminctl -guestAccount off; /usr/sbin/sysadminctl -smbGuestAccess off"))
        }
        return c
    }

    static func rootAccount() -> SecurityCheck {
        let r = Shell.run("/usr/bin/dscl", [".", "-read", "/Users/root", "AuthenticationAuthority"])
        let enabled = r.ok && r.out.contains("ShadowHash")
        return SecurityCheck(id: "root", title: "Compte root", symbol: "person.badge.shield.checkmark",
                             status: enabled ? .bad : .ok,
                             detail: enabled ? "Le super-utilisateur root est activé et peut ouvrir une session."
                                             : "Désactivé, comme il se doit.",
                             advice: enabled ? "Désactive-le avec « dsenableroot -d » dans le Terminal." : nil,
                             settingsURL: SettingsPane.users)
    }

    static func passwordHints() -> SecurityCheck {
        let r = Shell.run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.loginwindow", "RetriesUntilHint"])
        let n = r.ok ? Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        var c = SecurityCheck(id: "hints", title: "Indices de mot de passe", symbol: "questionmark.key.filled",
                              status: n > 0 ? .warn : .ok,
                              detail: n > 0 ? "L'écran de connexion montre l'indice de ton mot de passe après \(n) essais."
                                            : "L'écran de connexion ne donne aucun indice.",
                              settingsURL: SettingsPane.users)
        if n > 0 {
            c.advice = "Un indice aide surtout celui qui essaie de deviner ton mot de passe."
            c.fix = SecurityFix(title: "Masquer les indices",
                                explanation: "L'écran de connexion ne montrera plus l'indice du mot de passe. macOS te demande ton mot de passe d'administrateur.",
                                action: .admin("/usr/bin/defaults write /Library/Preferences/com.apple.loginwindow RetriesUntilHint -int 0"))
        }
        return c
    }

    static func adminAccount() -> SecurityCheck {
        let isAdmin = Shell.run("/usr/sbin/dseditgroup", ["-o", "checkmember", "-m", NSUserName(), "admin"]).out.hasPrefix("yes")
        return SecurityCheck(id: "admin", title: "Compte du quotidien", symbol: "person.fill.checkmark",
                             status: isAdmin ? .warn : .ok,
                             detail: isAdmin ? "Tu travailles avec un compte administrateur : un logiciel malveillant qui obtient ton mot de passe a les pleins pouvoirs."
                                             : "Tu travailles avec un compte standard : bien vu.",
                             advice: isAdmin ? "Pour une protection renforcée, crée un compte administrateur séparé et passe le tien en compte standard." : nil,
                             settingsURL: SettingsPane.users)
    }

    // MARK: Sharing

    static func sharing() -> [SecurityCheck] {
        let listing = Shell.run("/bin/launchctl", ["print-disabled", "system"])
        let disabled = LaunchItemScanner.parseDisabled(listing.out)
        // A service listed "enabled" (or "false") runs; one missing from the list keeps macOS' default: off.
        func on(_ label: String) -> Bool { disabled[label] == false }
        func check(_ id: String, _ title: String, _ symbol: String, _ active: Bool, _ what: String, advice: String,
                   fix: SecurityFix? = nil, url: String = SettingsPane.sharing) -> SecurityCheck {
            var c = SecurityCheck(id: id, title: title, symbol: symbol, status: active ? .warn : .ok,
                                  detail: active ? what : "Désactivé.", settingsURL: url)
            if active {
                c.advice = advice
                c.fix = fix
            }
            return c
        }
        let ardRunning = Shell.run("/usr/bin/pgrep", ["-x", "ARDAgent"]).ok
        let printers = Shell.run("/usr/sbin/cupsctl").out.contains("_share_printers=1")
        let nat = defaultsExport("/Library/Preferences/SystemConfiguration/com.apple.nat")
        let natOn = ((nat["NAT"] as? [String: Any])?["Enabled"] as? Int ?? 0) == 1
        let bluetooth = Shell.run("/usr/bin/defaults", ["-currentHost", "read", "com.apple.Bluetooth", "PrefKeyServicesEnabled"])
            .out.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        let airplayRead = Shell.run("/usr/bin/defaults", ["-currentHost", "read", "com.apple.controlcenter", "AirplayRecieverEnabled"])
        // Never set: macOS' default, on.
        let airplay = !airplayRead.ok || airplayRead.out.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        let media = defaultsExport(FS.home + "/Library/Preferences/com.apple.amp.mediasharingd")
        let mediaOn = (media["home-sharing-enabled"] as? Int ?? 0) == 1 || (media["public-sharing-enabled"] as? Int ?? 0) == 1

        return [
            check("ssh", "Connexion à distance (SSH)", "terminal", on("com.openssh.sshd"),
                  "N'importe qui sur le réseau peut tenter d'ouvrir une session sur ton Mac.",
                  advice: "Désactive « Session à distance » dans Partage si tu ne t'en sers pas.",
                  fix: SecurityFix(title: "Couper SSH", explanation: "La session à distance (SSH) sera désactivée. macOS te demande ton mot de passe d'administrateur.",
                                   action: .admin("/bin/launchctl disable system/com.openssh.sshd; /bin/launchctl bootout system/com.openssh.sshd 2>/dev/null; true"))),
            check("screensharing", "Partage d'écran", "rectangle.on.rectangle", on("com.apple.screensharing"),
                  "Ton écran peut être vu et contrôlé à distance.",
                  advice: "Désactive « Partage d'écran » dans Partage si tu ne t'en sers pas.",
                  fix: SecurityFix(title: "Couper le partage d'écran", explanation: "Le partage d'écran sera désactivé. macOS te demande ton mot de passe d'administrateur.",
                                   action: .admin("/bin/launchctl disable system/com.apple.screensharing; /bin/launchctl bootout system/com.apple.screensharing 2>/dev/null; true"))),
            check("ard", "Gestion à distance", "desktopcomputer.and.arrow.down", ardRunning,
                  "Apple Remote Desktop est actif : ton Mac peut être administré à distance.",
                  advice: "Si ce Mac n'est pas géré par ton entreprise, désactive « Gestion à distance » dans Partage."),
            check("remoteevents", "Événements Apple à distance", "applescript", on("com.apple.AEServer"),
                  "D'autres Mac peuvent piloter les apps de celui-ci.",
                  advice: "Désactive « Événements Apple à distance » dans Partage.",
                  fix: SecurityFix(title: "Couper les événements à distance", explanation: "Les événements Apple à distance seront désactivés. macOS te demande ton mot de passe d'administrateur.",
                                   action: .admin("/bin/launchctl disable system/com.apple.AEServer; /bin/launchctl bootout system/com.apple.AEServer 2>/dev/null; true"))),
            check("filesharing", "Partage de fichiers", "folder.badge.person.crop", on("com.apple.smbd"),
                  "Des dossiers de ton Mac sont partagés sur le réseau.",
                  advice: "Désactive « Partage de fichiers » si tu ne t'en sers pas."),
            check("printers", "Partage d'imprimantes", "printer", printers,
                  "Tes imprimantes sont proposées aux autres appareils du réseau.",
                  advice: "Désactive « Partage d'imprimantes » si tu ne t'en sers pas.",
                  fix: SecurityFix(title: "Couper le partage d'imprimantes", explanation: "Tes imprimantes ne seront plus partagées. macOS te demande ton mot de passe d'administrateur.",
                                   action: .admin("/usr/sbin/cupsctl --no-share-printers"))),
            check("internetsharing", "Partage de connexion", "wifi.router", natOn,
                  "Ton Mac partage sa connexion Internet avec d'autres appareils.",
                  advice: "Désactive « Partage Internet » si ce n'est pas voulu."),
            check("bluetooth", "Partage Bluetooth", "dot.radiowaves.left.and.right", bluetooth,
                  "Des appareils Bluetooth peuvent envoyer ou parcourir des fichiers.",
                  advice: "Désactive « Partage Bluetooth » si tu ne t'en sers pas.",
                  fix: SecurityFix(title: "Couper le partage Bluetooth", explanation: "Le partage de fichiers par Bluetooth sera désactivé.",
                                   action: .user([["/usr/bin/defaults", "-currentHost", "write", "com.apple.Bluetooth", "PrefKeyServicesEnabled", "-bool", "false"]]))),
            check("airplay", "Récepteur AirPlay", "airplayvideo", airplay,
                  "Ton Mac accepte les diffusions AirPlay et écoute sur le réseau (ports 5000 et 7000).",
                  advice: "Désactive « Récepteur AirPlay » dans AirDrop et Handoff si tu ne diffuses jamais vers ce Mac.",
                  url: SettingsPane.airDrop),
            check("media", "Partage de médias", "music.note.house", mediaOn,
                  "Ta bibliothèque de musique et de vidéos est partagée sur le réseau.",
                  advice: "Désactive « Partage de médias » dans Partage si tu ne t'en sers pas.")
        ].map { c in
            // Without launchd's list, "off" would be a guess: the services it decides are shown as unknown.
            guard !listing.ok, ["ssh", "screensharing", "remoteevents", "filesharing"].contains(c.id) else { return c }
            var u = c
            u.status = .unknown
            u.detail = "État illisible."
            u.fix = nil
            return u
        }
    }

    static func airDrop() -> SecurityCheck {
        let mode = Shell.run("/usr/bin/defaults", ["read", "com.apple.sharingd", "DiscoverableMode"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var c = SecurityCheck(id: "airdrop", title: "AirDrop", symbol: "airplayaudio", status: .ok,
                              detail: "", settingsURL: SettingsPane.airDrop)
        switch mode {
        case "Everyone":
            c.status = .warn
            c.detail = "Visible de tout le monde : n'importe qui à proximité peut t'envoyer des fichiers."
            c.fix = SecurityFix(title: "Contacts seulement", explanation: "AirDrop ne sera visible que de tes contacts.",
                                action: .user([["/usr/bin/defaults", "write", "com.apple.sharingd", "DiscoverableMode", "-string", "Contacts Only"],
                                               ["/usr/bin/killall", "sharingd"]]))
        case "Off": c.detail = "Désactivé."
        default: c.detail = "Visible de tes contacts seulement."
        }
        return c
    }

    // MARK: Network

    /// A proxy set in the network settings: every web request goes through it. Adware sets one to read and alter pages.
    static func proxy() -> SecurityCheck {
        var c = SecurityCheck(id: "proxy", title: "Proxy réseau", symbol: "arrow.triangle.branch", status: .ok,
                              detail: "Aucun proxy : ton trafic web va directement aux sites.", settingsURL: SettingsPane.network)
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            c.status = .unknown
            c.detail = "Réglages illisibles."
            return c
        }
        let found = proxies(settings)
        guard !found.isEmpty else { return c }
        let local = found.allSatisfy { $0.contains("127.0.0.1") || $0.contains("localhost") || $0.contains("::1") }
        c.status = local ? .info : .warn
        c.detail = "Ton trafic passe par : " + found.joined(separator: ", ") + "."
        c.advice = local ? "Un outil de ce Mac (débogueur réseau, VPN, filtre) intercepte ton trafic. Vérifie que tu le reconnais."
                         : "Si tu ne l'as pas configuré (entreprise, école), c'est la signature classique d'un logiciel publicitaire qui lit et modifie les pages."
        return c
    }

    static func proxies(_ s: [String: Any]) -> [String] {
        func on(_ k: String) -> Bool { (s[k] as? Int ?? 0) == 1 }
        var out: [String] = []
        for (enable, host, port, name) in [("HTTPEnable", "HTTPProxy", "HTTPPort", "HTTP"), ("HTTPSEnable", "HTTPSProxy", "HTTPSPort", "HTTPS"),
                                           ("SOCKSEnable", "SOCKSProxy", "SOCKSPort", "SOCKS")] where on(enable) {
            out.append("\(name) \(s[host] as? String ?? "?")\((s[port] as? Int).map { ":\($0)" } ?? "")")
        }
        if on("ProxyAutoConfigEnable") { out.append("configuration automatique \(s["ProxyAutoConfigURLString"] as? String ?? "")") }
        return out
    }

    /// Resolvers anyone may choose on purpose. Any other public address deserves a look: DNS changers (OSX.MaMi,
    /// DNSChanger) point Macs to servers that send them to fake sites.
    static let knownResolvers: [String: String] = [
        "1.1.1.1": "Cloudflare", "1.0.0.1": "Cloudflare", "1.1.1.2": "Cloudflare", "1.0.0.2": "Cloudflare", "1.1.1.3": "Cloudflare",
        "8.8.8.8": "Google", "8.8.4.4": "Google", "9.9.9.9": "Quad9", "149.112.112.112": "Quad9", "9.9.9.11": "Quad9",
        "208.67.222.222": "OpenDNS", "208.67.220.220": "OpenDNS", "94.140.14.14": "AdGuard", "94.140.15.15": "AdGuard",
        "76.76.2.0": "Control D", "76.76.10.0": "Control D", "194.242.2.2": "Mullvad", "185.228.168.9": "CleanBrowsing",
        "2606:4700:4700::1111": "Cloudflare", "2606:4700:4700::1001": "Cloudflare", "2001:4860:4860::8888": "Google",
        "2001:4860:4860::8844": "Google", "2620:fe::fe": "Quad9", "2620:fe::9": "Quad9"
    ]

    static func isPrivate(_ ip: String) -> Bool {
        if ip.contains(":") {
            let l = ip.lowercased()
            return l == "::1" || l.hasPrefix("fe80") || l.hasPrefix("fd") || l.hasPrefix("fc")
        }
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || p[0] == 127 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
            || (p[0] == 100 && (64...127).contains(p[1])) || (p[0] == 169 && p[1] == 254)
    }

    static func dns() -> SecurityCheck {
        var c = SecurityCheck(id: "dns", title: "Serveurs DNS", symbol: "point.3.connected.trianglepath.dotted", status: .unknown,
                              detail: "Réglages illisibles.", settingsURL: SettingsPane.network)
        guard let store = SCDynamicStoreCreate(nil, "Heartware" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] else { return c }
        let servers = dict["ServerAddresses"] as? [String] ?? []
        guard !servers.isEmpty else {
            c.status = .ok
            c.detail = "Aucun serveur DNS actif (pas de réseau)."
            return c
        }
        // Typed into the network settings (what a DNS changer does with networksetup), not given by the box, the
        // operator or a VPN: only those are judged.
        let keys = SCDynamicStoreCopyKeyList(store, "Setup:/Network/Service/[^/]+/DNS" as CFString) as? [String] ?? []
        let manual = Set(keys.flatMap { (SCDynamicStoreCopyValue(store, $0 as CFString) as? [String: Any])?["ServerAddresses"] as? [String] ?? [] })
        let named = servers.map { s in knownResolvers[s].map { "\(s) (\($0))" } ?? (isPrivate(s) ? "\(s) (local)" : s) }
        c.detail = "Ton Mac demande les adresses des sites à : " + named.joined(separator: ", ") + (manual.isEmpty ? ", fournis par le réseau." : ".")
        let unknown = manual.filter(isUnknownResolver).sorted()
        if unknown.isEmpty {
            c.status = .ok
        } else {
            c.status = .warn
            c.advice = "Réglé à la main : \(unknown.joined(separator: ", ")), un serveur inconnu. Si ni toi ni ton entreprise ne l'avez choisi, un logiciel malveillant peut t'envoyer vers de faux sites. Vérifie-le dans Réglages › Réseau › DNS."
        }
        return c
    }

    static func isUnknownResolver(_ ip: String) -> Bool {
        !isPrivate(ip) && knownResolvers[ip] == nil && !ip.hasPrefix("45.90.28.") && !ip.hasPrefix("45.90.30.")
    }

    /// Certificates trusted by hand (the user's or the administrator's trust settings): a root certificate trusted for
    /// websites lets whoever holds its key read and alter every HTTPS connection (OSX.MaMi, some adware, school proxies).
    static func certificates() -> SecurityCheck {
        var c = SecurityCheck(id: "certificates", title: "Certificats racine ajoutés", symbol: "checkmark.seal.text.page",
                              status: .ok, detail: "Aucun certificat ajouté n'est autorisé à signer des sites web.")
        var risky: [String] = []
        var benign = 0
        for domain in [SecTrustSettingsDomain.user, .admin] {
            var certs: CFArray?
            guard SecTrustSettingsCopyCertificates(domain, &certs) == errSecSuccess, let list = certs as? [SecCertificate] else { continue }
            for cert in list {
                var settings: CFArray?
                guard SecTrustSettingsCopyTrustSettings(cert, domain, &settings) == errSecSuccess else { continue }
                let name = SecCertificateCopySubjectSummary(cert) as String? ?? "?"
                if trustsWeb(settings as? [[String: Any]] ?? []) { risky.append(name) } else { benign += 1 }
            }
        }
        if !risky.isEmpty {
            c.status = .warn
            c.detail = "Certificats approuvés pour les sites web : " + risky.prefix(4).joined(separator: ", ") + (risky.count > 4 ? "…" : "") + "."
            c.advice = "Leur détenteur peut déchiffrer tout ce que tu échanges en HTTPS. Normal pour un outil de développement ou le réseau d'une entreprise ; sinon, supprime-les dans Trousseaux d'accès."
        } else if benign > 0 {
            c.detail = "\(Fmt.plural(benign, "certificat ajouté", "certificats ajoutés")), limité\(benign > 1 ? "s" : "") à d'autres usages (Wi-Fi d'entreprise…)."
        }
        return c
    }

    /// Empty trust settings mean "trusted for everything"; otherwise a setting for SSL (or for no policy) that trusts the root.
    static func trustsWeb(_ settings: [[String: Any]]) -> Bool {
        if settings.isEmpty { return true }
        for s in settings {
            let raw = (s[kSecTrustSettingsResult as String] as? NSNumber)?.uint32Value ?? SecTrustSettingsResult.trustRoot.rawValue
            guard raw == SecTrustSettingsResult.trustRoot.rawValue || raw == SecTrustSettingsResult.trustAsRoot.rawValue else { continue }
            guard let value = s[kSecTrustSettingsPolicy as String], CFGetTypeID(value as CFTypeRef) == SecPolicyGetTypeID() else { return true }
            let props = SecPolicyCopyProperties(value as! SecPolicy) as? [String: Any] ?? [:]
            if props[kSecPolicyOid as String] as? String == (kSecPolicyAppleSSL as String) { return true }
        }
        return false
    }

    /// /etc/hosts: an entry that sends Apple's, Google's or a security vendor's domains elsewhere blocks updates or fakes sites.
    static func hostsFile() -> SecurityCheck {
        var c = SecurityCheck(id: "hosts", title: "Fichier hosts", symbol: "doc.text.magnifyingglass", status: .ok,
                              detail: "D'origine : aucun site n'est détourné.")
        guard let text = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else {
            c.status = .unknown
            c.detail = "Illisible."
            return c
        }
        let entries = hostsEntries(text)
        guard !entries.isEmpty else { return c }
        let hijacked = suspiciousHosts(entries)
        if !hijacked.isEmpty {
            c.status = .warn
            c.detail = "Détournés : " + hijacked.prefix(4).map { "\($0.host) → \($0.ip)" }.joined(separator: ", ") + "."
            c.advice = "Un logiciel malveillant bloque ainsi les mises à jour de sécurité ou t'envoie vers un faux site. Si ce n'est pas toi, retire ces lignes de /etc/hosts."
        } else {
            c.status = .info
            c.detail = "\(Fmt.plural(entries.count, "entrée ajoutée", "entrées ajoutées")) (bloqueur de publicité, développement…), aucune ne détourne un site sensible."
        }
        return c
    }

    static let watchedDomains = ["apple.com", "icloud.com", "mzstatic.com", "google.com", "microsoft.com", "github.com", "anthropic.com",
                                 "claude.ai", "malwarebytes.com", "objective-see.org", "virustotal.com", "paypal.com"]
    /// Where macOS fetches its security updates and XProtect signatures: blocking them is never an ad blocker's job.
    static let updateHosts = ["swscan.apple.com", "swdist.apple.com", "swcdn.apple.com", "xp.apple.com", "mesu.apple.com",
                              "updates.cdn-apple.com", "gdmf.apple.com", "ocsp.apple.com", "ocsp2.apple.com", "api.apple-cloudkit.com"]

    /// A sensitive site sent to another address, or macOS' update servers cut off. Blocking a tracker
    /// (0.0.0.0 adservice.google.com, an ad blocker's list) is fine.
    static func suspiciousHosts(_ entries: [(ip: String, host: String)]) -> [(ip: String, host: String)] {
        entries.filter { e in
            if updateHosts.contains(e.host) { return true }
            let blocked = ["0.0.0.0", "127.0.0.1", "::1", "::", "0:0:0:0:0:0:0:0"].contains(e.ip)
            return !blocked && watchedDomains.contains { e.host == $0 || e.host.hasSuffix("." + $0) }
        }
    }

    static func hostsEntries(_ text: String) -> [(ip: String, host: String)] {
        var out: [(ip: String, host: String)] = []
        for raw in text.split(separator: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            for host in parts.dropFirst() {
                let h = host.lowercased()
                if ["localhost", "broadcasthost", "ip6-localhost", "ip6-loopback"].contains(h) { continue }
                out.append((parts[0], h))
            }
        }
        return out
    }

    /// Configuration profiles: adware installs some to impose a search engine, a homepage or a proxy.
    static func profiles() -> SecurityCheck {
        var c = SecurityCheck(id: "profiles", title: "Profils de configuration", symbol: "person.text.rectangle", status: .ok,
                              detail: "Aucun profil installé.", settingsURL: SettingsPane.profiles)
        let mdm = Shell.run("/usr/bin/profiles", ["status", "-type", "enrollment"]).out.contains("MDM enrollment: Yes")
        let listing = Shell.run("/usr/bin/profiles", ["show", "-type", "configuration"])
        // Some versions of macOS answer only to the administrator: no answer is not "no profile".
        guard listing.ok || listing.all.contains("There are no configuration profiles") else {
            c.status = .unknown
            c.detail = "Liste illisible sans droits d'administrateur."
            c.scored = false
            return c
        }
        let names = profileNames(listing.out)
        // Screen Time's own profile is Apple's.
        let others = names.filter { !$0.identifier.hasPrefix("com.apple.ManagedSettings") }
        if mdm {
            c.status = .info
            c.detail = "Ce Mac est géré par une organisation (MDM)" + (others.isEmpty ? "." : " : " + others.map(\.name).joined(separator: ", ") + ".")
            c.advice = "Normal pour un Mac d'entreprise ou d'école : l'organisation peut en régler la sécurité."
        } else if !others.isEmpty {
            c.status = .warn
            c.detail = "Installé\(others.count > 1 ? "s" : "") : " + others.map(\.name).joined(separator: ", ") + "."
            c.advice = "Si tu ne reconnais pas ce profil, supprime-le dans Réglages › Général › Gestion des appareils : les logiciels publicitaires s'en servent pour imposer leur moteur de recherche."
        } else if !names.isEmpty {
            c.detail = "Seulement celui de Temps d'écran (Apple)."
        }
        return c
    }

    static func profileNames(_ text: String) -> [(name: String, identifier: String)] {
        var out: [(name: String, identifier: String)] = []
        var name: String?
        for line in text.split(separator: "\n") {
            if let r = line.range(of: "attribute: name: ") { name = String(line[r.upperBound...]) }
            if let r = line.range(of: "attribute: profileIdentifier: ") {
                let id = String(line[r.upperBound...])
                out.append((name ?? id, id))
                name = nil
            }
        }
        return out
    }

    /// Browser settings imposed by policy (outside an MDM): forced extensions, search engine, homepage or proxy.
    static let browsers = ["com.google.Chrome": "Chrome", "com.microsoft.Edge": "Edge", "com.microsoft.edgemac": "Edge",
                           "com.brave.Browser": "Brave", "org.mozilla.firefox": "Firefox", "com.apple.Safari": "Safari",
                           "com.vivaldi.Vivaldi": "Vivaldi", "company.thebrowser.Browser": "Arc"]
    static let hijackKeys = ["ExtensionInstallForcelist", "ExtensionSettings", "DefaultSearchProviderSearchURL", "DefaultSearchProviderEnabled",
                             "HomepageLocation", "RestoreOnStartupURLs", "NewTabPageLocation", "ProxySettings", "ProxyServer", "ProxyPacUrl",
                             "HomePage", "NewWindowBehavior", "SearchEngine"]

    static func browserPolicies() -> SecurityCheck {
        var c = SecurityCheck(id: "policies", title: "Navigateurs détournés", symbol: "globe.badge.chevron.backward", status: .ok,
                              detail: "Aucun navigateur n'est réglé de force (moteur de recherche, page d'accueil, extensions).")
        var found: [String] = []
        for root in ["/Library/Managed Preferences", "/Library/Managed Preferences/" + NSUserName()] {
            for (id, name) in browsers.sorted(by: { $0.key < $1.key }) {
                guard let dict = NSDictionary(contentsOfFile: root + "/" + id + ".plist") as? [String: Any] else { continue }
                let keys = hijackKeys.filter { dict[$0] != nil }
                if !keys.isEmpty { found.append("\(name) (\(keys.prefix(2).joined(separator: ", ")))") }
            }
        }
        if !found.isEmpty {
            let mdm = Shell.run("/usr/bin/profiles", ["status", "-type", "enrollment"]).out.contains("MDM enrollment: Yes")
            c.status = mdm ? .info : .bad
            c.detail = "Réglé de force : " + found.joined(separator: ", ") + "."
            c.advice = mdm ? "Ce Mac est géré par une organisation : ces réglages viennent sans doute d'elle."
                           : "Hors entreprise, c'est la marque d'un logiciel publicitaire (Adload, Pirrit…). Supprime son profil dans Réglages › Général › Gestion des appareils, puis lance l'analyse des menaces."
            c.settingsURL = SettingsPane.profiles
        }
        return c
    }

    // MARK: Secrets

    /// Private SSH keys: readable by others, or without a passphrase (any program that copies the file can use it).
    static func sshKeys() -> SecurityCheck {
        var c = SecurityCheck(id: "sshkeys", title: "Clés SSH", symbol: "key.horizontal", status: .ok, detail: "Aucune clé privée SSH.")
        let dir = FS.home + "/.ssh"
        var open: [String] = []
        var plain: [String] = []
        var total = 0
        for name in FS.children(dir) where !name.hasSuffix(".pub") {
            let path = dir + "/" + name
            guard let kind = sshKeyKind(path) else { continue }
            total += 1
            // stat, not lstat: a key linked from a dotfiles folder is judged on the real file.
            var st = stat()
            if stat(path, &st) == 0, st.st_mode & 0o077 != 0 { open.append(path) }
            if kind == .unencrypted { plain.append(name) }
        }
        guard total > 0 else { return c }
        if !open.isEmpty {
            c.status = .bad
            c.detail = "Lisible\(open.count > 1 ? "s" : "") par les autres comptes : " + open.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") + "."
            c.fix = SecurityFix(title: "Rendre privées", explanation: "Ces clés ne seront plus lisibles que par toi (droits 600).",
                                action: .user(open.map { ["/bin/chmod", "600", $0] }))
        } else if !plain.isEmpty {
            c.status = .warn
            c.detail = "Sans phrase de passe : " + plain.joined(separator: ", ") + ". Un voleur de données qui copie le fichier peut s'en servir tel quel."
            c.advice = "Ajoute une phrase de passe avec « ssh-keygen -p -f ~/.ssh/\(plain[0]) », puis « ssh-add --apple-use-keychain » pour ne pas la retaper."
        } else {
            c.detail = "\(Fmt.plural(total, "clé privée protégée", "clés privées protégées")) par une phrase de passe."
        }
        return c
    }

    enum SSHKeyKind { case encrypted, unencrypted }

    /// Reads the header only: the PEM markers, or the cipher name of an OpenSSH key ("none" when unencrypted).
    static func sshKeyKind(_ path: String) -> SSHKeyKind? {
        guard let h = FileHandle(forReadingAtPath: path), let data = try? h.read(upToCount: 4096) else { return nil }
        try? h.close()
        return sshKeyKind(text: String(decoding: data, as: UTF8.self))
    }

    static func sshKeyKind(text: String) -> SSHKeyKind? {
        guard text.hasPrefix("-----BEGIN"), text.contains("PRIVATE KEY-----") else { return nil }
        if text.contains("ENCRYPTED") { return .encrypted }
        guard text.contains("OPENSSH PRIVATE KEY") else { return .unencrypted }
        let body = text.split(separator: "\n").dropFirst().prefix { !$0.hasPrefix("-----") }.joined()
        // The first 64 characters hold the magic and the cipher name ("aes256-gcm@openssh.com" included),
        // decoded on their own (a multiple of 4).
        guard let raw = Data(base64Encoded: String(body.prefix(64))) else { return nil }
        let magic = Array("openssh-key-v1".utf8) + [0]
        let bytes = [UInt8](raw)
        guard bytes.count > magic.count + 4, Array(bytes.prefix(magic.count)) == magic else { return nil }
        let n = Int(bytes[magic.count + 3])
        guard bytes.count >= magic.count + 4 + n else { return nil }
        let cipher = String(decoding: bytes[(magic.count + 4)..<(magic.count + 4 + n)], as: UTF8.self)
        return cipher == "none" ? .unencrypted : .encrypted
    }

    /// Files where tools keep passwords or tokens in clear: the first thing information stealers copy.
    static let credentialStores: [(path: String, marker: String, name: String, advice: String)] = [
        (".git-credentials", "@", "Git", "lance « git config --global credential.helper osxkeychain », puis supprime ~/.git-credentials"),
        (".netrc", "password", "netrc", "garde ces mots de passe dans le trousseau plutôt que dans ~/.netrc"),
        (".aws/credentials", "aws_secret_access_key", "AWS", "préfère « aws sso login » ou aws-vault, qui gardent les clés hors du disque"),
        (".docker/config.json", "\"auth\":", "Docker", "ajoute « \"credsStore\": \"osxkeychain\" » à ~/.docker/config.json puis reconnecte-toi"),
        (".npmrc", "_authToken", "npm", "garde le jeton dans une variable d'environnement plutôt que dans ~/.npmrc"),
        (".pypirc", "password", "PyPI", "utilise un jeton gardé dans le trousseau plutôt que ~/.pypirc"),
        (".config/gh/hosts.yml", "oauth_token", "GitHub CLI", "reconnecte-toi avec « gh auth login », qui range le jeton dans le trousseau"),
        (".kube/config", "token:", "Kubernetes", "préfère un plug-in d'authentification à un jeton écrit en clair")
    ]

    static func credentialFiles() -> SecurityCheck {
        var c = SecurityCheck(id: "credentials", title: "Identifiants en clair", symbol: "doc.badge.ellipsis", status: .ok,
                              detail: "Aucun mot de passe ni jeton écrit en clair dans les fichiers des outils courants.")
        var found: [(name: String, path: String, advice: String)] = []
        var openFiles: [String] = []
        for f in credentialStores {
            let path = FS.home + "/" + f.path
            guard let h = FileHandle(forReadingAtPath: path), let data = try? h.read(upToCount: 1 << 20) else { continue }
            try? h.close()
            let text = String(decoding: data, as: UTF8.self)
            guard holdsSecret(text, marker: f.marker) else { continue }
            // Docker: the registries are listed, the secrets themselves are in the keychain.
            if f.name == "Docker", text.contains("credsStore") { continue }
            found.append((f.name, path, f.advice))
            var st = stat()
            if stat(path, &st) == 0, st.st_mode & 0o044 != 0 { openFiles.append(path) }
        }
        guard !found.isEmpty else { return c }
        c.status = .warn
        c.detail = "En clair : " + found.map { "\($0.name) (\(FS.pretty($0.path)))" }.joined(separator: ", ") + "."
        c.advice = "N'importe quel programme lancé sous ton compte peut les lire. " + Fmt.cap(found[0].advice) + "."
        if !openFiles.isEmpty {
            c.fix = SecurityFix(title: "Rendre privés", explanation: "Ces fichiers ne seront plus lisibles que par toi (droits 600). Les secrets y restent : suis le conseil pour les sortir du disque.",
                                action: .user(openFiles.map { ["/bin/chmod", "600", $0] }))
        }
        return c
    }

    /// A line with the marker and a real value: `_authToken=${NPM_TOKEN}` reads a variable, nothing is written there.
    static func holdsSecret(_ text: String, marker: String) -> Bool {
        text.split(separator: "\n").contains { line in
            guard let r = line.range(of: marker) else { return false }
            let value = line[r.upperBound...].drop { $0 == " " || $0 == "=" || $0 == ":" || $0 == "\"" }
            return !value.isEmpty && !value.hasPrefix("$") && !value.hasPrefix("${")
        }
    }

    /// Tokens and keys pasted in a terminal stay in its history.
    static let secretPatterns = [#"sk-ant-[A-Za-z0-9_-]{20,}"#, #"\bsk-[A-Za-z0-9]{32,}"#, #"\bgh[pousr]_[A-Za-z0-9]{30,}"#,
                                 #"github_pat_[A-Za-z0-9_]{30,}"#, #"glpat-[A-Za-z0-9_-]{20,}"#, #"xox[abpr]-[A-Za-z0-9-]{20,}"#,
                                 #"\bAKIA[0-9A-Z]{16}\b"#, #"\bAIza[0-9A-Za-z_-]{35}\b"#, #"(?i)\b(password|passwd|api[_-]?key|secret)=[^\s$]{6,}"#]
    private static let secretRegexes = secretPatterns.compactMap { try? NSRegularExpression(pattern: $0) }

    static func countSecrets(_ text: String) -> Int {
        let range = NSRange(text.startIndex..., in: text)
        return secretRegexes.reduce(0) { $0 + $1.numberOfMatches(in: text, range: range) }
    }

    static func shellHistory() -> SecurityCheck {
        var c = SecurityCheck(id: "history", title: "Secrets dans l'historique du Terminal", symbol: "terminal", status: .ok,
                              detail: "Aucune clé d'API ni mot de passe repéré dans tes historiques.")
        var count = 0
        var files: [String] = []
        for name in [".zsh_history", ".bash_history", ".python_history", ".node_repl_history"] {
            guard let h = FileHandle(forReadingAtPath: FS.home + "/" + name), let data = try? h.read(upToCount: 8 << 20) else { continue }
            try? h.close()
            let n = countSecrets(String(decoding: data, as: UTF8.self))
            if n > 0 {
                count += n
                files.append(name)
            }
        }
        if count > 0 {
            c.status = .warn
            c.detail = "\(Fmt.plural(count, "secret probable", "secrets probables")) (clés d'API, jetons, mots de passe) dans " + files.joined(separator: ", ") + "."
            c.advice = "Révoque ces clés si elles sont encore valables, puis efface l'historique dans l'onglet Traces."
        }
        return c
    }

    // MARK: Browsing

    static func fileExtensions() -> SecurityCheck {
        let on = Shell.run("/usr/bin/defaults", ["read", "NSGlobalDomain", "AppleShowAllExtensions"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        var c = SecurityCheck(id: "extensions", title: "Extensions des fichiers", symbol: "doc.questionmark", status: on ? .ok : .warn,
                              detail: on ? "Le Finder montre toutes les extensions : « facture.pdf.app » ne passe pas pour un PDF."
                                         : "Le Finder masque des extensions : une app nommée « facture.pdf » peut passer pour un document.")
        if !on {
            c.fix = SecurityFix(title: "Montrer les extensions",
                                explanation: "Le Finder affichera l'extension de tous les fichiers. Il redémarre pour l'appliquer (ses fenêtres se rouvrent).",
                                action: .user([["/usr/bin/defaults", "write", "NSGlobalDomain", "AppleShowAllExtensions", "-bool", "true"],
                                               ["/usr/bin/killall", "Finder"]]))
        }
        return c
    }

    /// Safari keeps its settings in its container: readable with Full Disk Access only.
    static func safari() -> [SecurityCheck] {
        let plist = FS.home + "/Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist"
        var open = SecurityCheck(id: "safaridownloads", title: "Ouverture des fichiers téléchargés", symbol: "arrow.down.app",
                                 status: .unknown, detail: "Illisible sans l'accès complet au disque.", scored: false)
        var fraud = SecurityCheck(id: "fraud", title: "Alerte sites frauduleux (Safari)", symbol: "exclamationmark.shield",
                                  status: .unknown, detail: "Illisible sans l'accès complet au disque.", scored: false)
        guard let dict = NSDictionary(contentsOfFile: plist) as? [String: Any] else { return [open, fraud] }
        open.scored = true
        fraud.scored = true
        // Never set: Safari's default (on for both).
        let autoOpen = dict["AutoOpenSafeDownloads"] as? Bool ?? true
        open.status = autoOpen ? .warn : .ok
        open.detail = autoOpen ? "Safari ouvre tout seul les fichiers « fiables » téléchargés (PDF, images, archives décompressées)."
                               : "Safari n'ouvre rien tout seul après un téléchargement."
        if autoOpen { open.advice = "Décoche « Ouvrir les fichiers fiables après téléchargement » dans Safari › Réglages › Général : une archive piégée ne s'ouvrira plus d'elle-même." }
        let warn = dict["WarnAboutFraudulentWebsites"] as? Bool ?? true
        fraud.status = warn ? .ok : .bad
        fraud.detail = warn ? "Safari t'avertit avant d'ouvrir un site d'hameçonnage connu." : "Safari n'avertit plus des sites d'hameçonnage."
        if !warn { fraud.advice = "Coche « Avertir en cas de visite d'un site web frauduleux » dans Safari › Réglages › Sécurité." }
        return [open, fraud]
    }

    // MARK: Tools

    static func defaultsExport(_ domain: String) -> [String: Any] {
        let out = Shell.run("/usr/bin/defaults", ["export", domain, "-"]).out
        return (try? PropertyListSerialization.propertyList(from: Data(out.utf8), format: nil)) as? [String: Any] ?? [:]
    }

    /// Pure checks for `--selftest`.
    static func selfTest() -> [String] {
        var f: [String] = []
        for (ip, p) in [("192.168.1.1", true), ("10.2.0.1", true), ("172.20.0.1", true), ("100.64.0.1", true), ("82.163.143.135", false),
                        ("8.8.8.8", false), ("fd00::1", true), ("2001:4860:4860::8888", false)] where isPrivate(ip) != p {
            f.append("Adresse \(ip) \(p ? "prise pour publique" : "prise pour privée")")
        }
        let hosts = "127.0.0.1\tlocalhost\n::1 localhost # loopback\n0.0.0.0 ads.example.com tracker.example.com\n10.0.0.5 swscan.apple.com\n"
        let e = hostsEntries(hosts)
        if e.count != 3 || e.last?.host != "swscan.apple.com" { f.append("Lecture du fichier hosts : \(e)") }
        let profiles = "There are 1 configuration profiles installed\nx[1] attribute: name: Search Helper\nx[1] attribute: profileIdentifier: com.searchx.config\n"
        if profileNames(profiles).first?.name != "Search Helper" { f.append("Lecture des profils de configuration") }
        let proxied = proxies(["HTTPEnable": 1, "HTTPProxy": "proxy.example.net", "HTTPPort": 8080, "ProxyAutoConfigEnable": 1,
                               "ProxyAutoConfigURLString": "http://pac.example/x.pac"])
        if proxied != ["HTTP proxy.example.net:8080", "configuration automatique http://pac.example/x.pac"] { f.append("Lecture des proxys : \(proxied)") }
        if !trustsWeb([]) { f.append("Certificat approuvé pour tout non reconnu") }
        if countSecrets("export ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz\ngit push\nls -la\n") != 1 { f.append("Secrets de l'historique mal comptés") }
        if countSecrets("cd ~/Developer && swift build && open https://github.com/x\nexport TOKEN=$GITHUB_TOKEN\n") != 0 {
            f.append("Commande ordinaire prise pour un secret")
        }
        let plain = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n-----END OPENSSH PRIVATE KEY-----\n"
        let locked = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBhbGxv\n-----END OPENSSH PRIVATE KEY-----\n"
        if sshKeyKind(text: plain) != .unencrypted { f.append("Clé SSH sans phrase de passe non reconnue") }
        if sshKeyKind(text: locked) != .encrypted { f.append("Clé SSH chiffrée prise pour une clé en clair") }
        if sshKeyKind(text: "ssh-ed25519 AAAAC3Nz… moi@mac") != nil { f.append("Clé publique prise pour une clé privée") }
        for (saver, display, expected) in [(1200, [10, 0], Optional(1200)), (0, [10, 0], nil), (0, [10, 15], Optional(900)), (600, [], Optional(600))]
        where idleLockSeconds(screenSaver: saver, displaySleepMinutes: display) != expected {
            f.append("Délai de verrouillage mal calculé (\(saver), \(display))")
        }
        for id in catalog.keys where !(1...3).contains(catalog[id]!.weight) { f.append("Poids invalide pour \(id)") }
        let adBlock: [(ip: String, host: String)] = [("0.0.0.0", "adservice.google.com"), ("0.0.0.0", "watson.telemetry.microsoft.com"),
                                                     ("127.0.0.1", "ads.example.com")]
        if !suspiciousHosts(adBlock).isEmpty { f.append("Liste d'un bloqueur de publicité prise pour un détournement") }
        if suspiciousHosts([("0.0.0.0", "swscan.apple.com")]).isEmpty || suspiciousHosts([("185.1.2.3", "www.paypal.com")]).isEmpty {
            f.append("Détournement du fichier hosts non repéré")
        }
        if holdsSecret("registry=https://r.example\n//r.example/:_authToken=${NPM_TOKEN}\n", marker: "_authToken") {
            f.append("Jeton npm lu dans une variable pris pour un secret en clair")
        }
        if !holdsSecret("//registry.npmjs.org/:_authToken=npm_abcdefghijklmnop\n", marker: "_authToken") { f.append("Jeton npm en clair non repéré") }
        if isUnknownResolver("192.168.1.1") || isUnknownResolver("1.1.1.1") || !isUnknownResolver("82.163.143.135") {
            f.append("Classement des serveurs DNS")
        }
        return f
    }
}
