import AppKit
import SwiftUI

// MARK: - Installed apps

struct LauncherApp: Sendable {
    let name: String
    let path: String
    let keywords: [String]
}

enum LauncherAppIndex {
    static let roots = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        FS.home + "/Applications", "/System/Library/CoreServices/Applications"
    ]

    /// Every .app in the usual folders (one level of sub-folders), by display name.
    static func scan() -> [LauncherApp] {
        var seen = Set<String>()
        var out: [LauncherApp] = []
        func add(_ path: String) {
            let real = (path as NSString).resolvingSymlinksInPath
            guard seen.insert(real).inserted else { return }
            let display = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            var keywords = [file]
            if let id = Bundle(path: path)?.bundleIdentifier, let last = id.split(separator: ".").last { keywords.append(String(last)) }
            out.append(LauncherApp(name: display, path: path, keywords: keywords))
        }
        for root in roots {
            for name in FS.children(root) {
                let p = root + "/" + name
                if name.hasSuffix(".app") {
                    add(p)
                } else if FS.isDirectory(p), !name.hasSuffix(".localized") || root.hasPrefix(FS.home) {
                    for sub in FS.children(p) where sub.hasSuffix(".app") { add(p + "/" + sub) }
                }
            }
        }
        add("/System/Library/CoreServices/Finder.app")
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func commandID(for path: String) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let clean = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_" }
        return "app_" + String(String(clean).prefix(58))
    }

    static func commands(_ apps: [LauncherApp]) -> [AppCommand] {
        apps.map { a in
            AppCommand(id: commandID(for: a.path), title: a.name, subtitle: nil, keywords: a.keywords, icon: .file(a.path),
                       group: .apps, hint: "Ouvrir") { ctx in
                if ctx.alternate {
                    Finder.reveal(a.path)
                } else {
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: a.path), configuration: .init())
                }
                return .done
            }
        }
    }
}

// MARK: - System commands

enum LauncherSystem {
    /// Runs a tool off the main thread.
    private static func tool(_ path: String, _ args: [String]) async -> Shell.Output {
        await Task.detached { Shell.run(path, args) }.value
    }

    private static func script(_ source: String) async -> Shell.Output {
        await Task.detached { Shell.appleScript(source) }.value
    }

    private static func outcome(_ r: Shell.Output, _ success: String? = nil) -> CommandOutcome {
        if r.ok { return success.map { .message($0) } ?? .done }
        return r.err == "Opération annulée." ? .done : .failed(r.err.isEmpty ? "Échec de la commande." : r.err)
    }

    static func commands() -> [AppCommand] {
        var list: [AppCommand] = [
            AppCommand(id: "sys_sleep", title: "Mettre en veille", keywords: ["veille", "sleep", "dormir"],
                       icon: .symbol("moon.zzz"), group: .system) { _ in outcome(await tool("/usr/bin/pmset", ["sleepnow"])) },
            AppCommand(id: "sys_lock", title: "Verrouiller l'écran", subtitle: "Éteint l'écran ; le mot de passe est demandé si c'est réglé ainsi",
                       keywords: ["verrouiller", "lock", "écran"], icon: .symbol("lock"), group: .system) { _ in
                outcome(await tool("/usr/bin/pmset", ["displaysleepnow"]))
            },
            AppCommand(id: "sys_restart", title: "Redémarrer", keywords: ["restart", "reboot", "redémarrer"],
                       icon: .symbol("arrow.clockwise.circle"), group: .system,
                       risk: .confirm("Les apps ouvertes vont se fermer. Enregistre ton travail avant.")) { _ in
                outcome(await script("tell application \"System Events\" to restart"))
            },
            AppCommand(id: "sys_shutdown", title: "Éteindre", keywords: ["shutdown", "éteindre", "arrêter"],
                       icon: .symbol("power"), group: .system,
                       risk: .confirm("Les apps ouvertes vont se fermer. Enregistre ton travail avant.")) { _ in
                outcome(await script("tell application \"System Events\" to shut down"))
            },
            AppCommand(id: "sys_logout", title: "Fermer la session", keywords: ["logout", "déconnexion", "session"],
                       icon: .symbol("rectangle.portrait.and.arrow.right"), group: .system,
                       risk: .confirm("Les apps ouvertes vont se fermer.")) { _ in
                outcome(await script("tell application \"System Events\" to log out"))
            },
            AppCommand(id: "sys_darkmode", title: "Basculer le mode sombre", keywords: ["sombre", "clair", "dark", "light", "apparence"],
                       icon: .symbol("circle.lefthalf.filled"), group: .system) { _ in
                outcome(await script("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"))
            },
            AppCommand(id: "sys_mute", title: "Couper ou rétablir le son", keywords: ["muet", "mute", "son", "volume"],
                       icon: .symbol("speaker.slash"), group: .system) { _ in
                outcome(await script("set volume output muted not (output muted of (get volume settings))"))
            },
            AppCommand(id: "sys_eject", title: "Éjecter tous les disques", keywords: ["éjecter", "eject", "clé usb", "disque"],
                       icon: .symbol("eject"), group: .system) { _ in
                guard !DemoData.isEnabled else { return .message(DemoData.refusal) }
                let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey]
                let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
                let ejectable = volumes.filter { url in
                    let v = try? url.resourceValues(forKeys: Set(keys))
                    return (v?.volumeIsEjectable ?? false) || (v?.volumeIsRemovable ?? false)
                }
                guard !ejectable.isEmpty else { return .message("Aucun disque à éjecter.") }
                var failed = 0
                for v in ejectable {
                    do { try NSWorkspace.shared.unmountAndEjectDevice(at: v) } catch { failed += 1 }
                }
                return failed == 0 ? .message("\(Fmt.plural(ejectable.count, "disque éjecté", "disques éjectés"))")
                                   : .failed("\(failed) disque(s) en cours d'utilisation.")
            },
            AppCommand(id: "sys_hide_others", title: "Masquer les autres apps", keywords: ["masquer", "hide", "cacher"],
                       icon: .symbol("eye.slash"), group: .system) { _ in
                guard !DemoData.isEnabled else { return .message(DemoData.refusal) }
                let front = NSWorkspace.shared.frontmostApplication
                for app in NSWorkspace.shared.runningApplications
                where app.activationPolicy == .regular && app != front && app != NSRunningApplication.current {
                    app.hide()
                }
                return .done
            },
            AppCommand(id: "sys_hidden_files", title: "Afficher ou masquer les fichiers cachés", subtitle: "Dans le Finder",
                       keywords: ["fichiers cachés", "hidden", "invisibles", "finder"], icon: .symbol("eye"), group: .system,
                       // The Finder relaunches, like `maint_finder`.
                       risk: .confirm("Le Finder va redémarrer : ses fenêtres se ferment, et une copie en cours serait interrompue.")) { _ in
                guard !DemoData.isEnabled else { return .message(DemoData.refusal) }
                let current = await tool("/usr/bin/defaults", ["read", "com.apple.finder", "AppleShowAllFiles"])
                let on = ["1", "true", "yes"].contains(current.out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                _ = await tool("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", on ? "false" : "true"])
                _ = await tool("/usr/bin/killall", ["Finder"])
                return .message(on ? "Fichiers cachés masqués." : "Fichiers cachés affichés.")
            },
            AppCommand(id: "sys_empty_trash", title: "Vider la Corbeille", keywords: ["corbeille", "trash", "vider"],
                       icon: .symbol("trash"), group: .system) { _ in
                // QuickActions asks for confirmation itself.
                let message = await Task.detached { QuickActions.emptyTrash() }.value
                return message.map { .message($0) } ?? .done
            },
            AppCommand(id: "sys_screensaver", title: "Lancer l'économiseur d'écran", keywords: ["économiseur", "screensaver"],
                       icon: .symbol("sparkles.tv"), group: .system) { _ in
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
                return .done
            },
            AppCommand(id: "sys_screenshot", title: "Capture d'écran", keywords: ["capture", "screenshot", "copie d'écran"],
                       icon: .symbol("camera.viewfinder"), group: .system) { _ in
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"))
                return .done
            }
        ]
        let folders: [(String, String, String, String)] = [
            ("folder_downloads", "Téléchargements", "Downloads", "arrow.down.circle"),
            ("folder_documents", "Documents", "Documents", "doc"),
            ("folder_desktop", "Bureau", "Desktop", "menubar.dock.rectangle"),
            ("folder_home", "Dossier personnel", "", "house"),
            ("folder_trash", "Ouvrir la Corbeille", ".Trash", "trash")
        ]
        for (id, title, sub, symbol) in folders {
            list.append(AppCommand(id: id, title: title, subtitle: "Dossier", keywords: ["dossier", "folder", sub],
                                   icon: .symbol(symbol, Theme.palette[1]), group: .system, assistantSafe: true, hint: "Ouvrir") { _ in
                NSWorkspace.shared.open(URL(fileURLWithPath: sub.isEmpty ? FS.home : FS.home + "/" + sub))
                return .done
            })
        }
        return list
    }
}

// MARK: - System Settings panes

enum LauncherSettings {
    static let panes: [(String, String, String, [String])] = [
        ("Wi-Fi", "com.apple.wifi-settings-extension", "wifi", ["wifi", "réseau sans fil"]),
        ("Bluetooth", "com.apple.BluetoothSettings", "dot.radiowaves.left.and.right", []),
        ("Réseau", "com.apple.Network-Settings.extension", "network", ["network", "vpn"]),
        ("Notifications", "com.apple.Notifications-Settings.extension", "bell.badge", []),
        ("Son", "com.apple.Sound-Settings.extension", "speaker.wave.2", ["audio", "volume"]),
        ("Concentration", "com.apple.Focus-Settings.extension", "moon", ["ne pas déranger", "focus"]),
        ("Temps d'écran", "com.apple.Screen-Time-Settings.extension", "hourglass", ["screen time"]),
        ("Général", "com.apple.systempreferences.GeneralSettings", "gearshape", ["general"]),
        ("Apparence", "com.apple.Appearance-Settings.extension", "circle.lefthalf.filled", ["thème", "sombre"]),
        ("Accessibilité", "com.apple.Accessibility-Settings.extension", "accessibility", []),
        ("Centre de contrôle", "com.apple.ControlCenter-Settings.extension", "switch.2", ["barre des menus"]),
        ("Siri", "com.apple.Siri-Settings.extension", "mic", ["apple intelligence"]),
        ("Confidentialité et sécurité", "com.apple.settings.PrivacySecurity.extension", "hand.raised", ["sécurité", "privacy"]),
        ("Bureau et Dock", "com.apple.Desktop-Settings.extension", "dock.rectangle", ["dock", "mission control"]),
        ("Moniteurs", "com.apple.Displays-Settings.extension", "display", ["écran", "résolution", "displays"]),
        ("Fond d'écran", "com.apple.Wallpaper-Settings.extension", "photo", ["wallpaper"]),
        ("Économiseur d'écran", "com.apple.ScreenSaver-Settings.extension", "sparkles.tv", []),
        ("Batterie", "com.apple.Battery-Settings.extension", "battery.75", ["énergie", "battery"]),
        ("Écran verrouillé", "com.apple.Lock-Screen-Settings.extension", "lock.display", []),
        ("Touch ID et mot de passe", "com.apple.Touch-ID-Settings.extension", "touchid", ["empreinte"]),
        ("Utilisateurs et groupes", "com.apple.Users-Groups-Settings.extension", "person.2", ["comptes"]),
        ("Mots de passe", "com.apple.Passwords-Settings.extension", "key", ["passwords"]),
        ("Comptes Internet", "com.apple.Internet-Accounts-Settings.extension", "at", ["mail", "comptes"]),
        ("Clavier", "com.apple.Keyboard-Settings.extension", "keyboard", ["raccourcis", "keyboard"]),
        ("Souris", "com.apple.Mouse-Settings.extension", "computermouse", []),
        ("Trackpad", "com.apple.Trackpad-Settings.extension", "rectangle.and.hand.point.up.left", []),
        ("Imprimantes et scanners", "com.apple.Print-Scan-Settings.extension", "printer", ["imprimante"]),
        ("Mise à jour de logiciels", "com.apple.Software-Update-Settings.extension", "arrow.down.circle", ["update", "maj"]),
        ("Stockage", "com.apple.settings.Storage", "internaldrive", ["disque"]),
        ("Partage", "com.apple.Sharing-Settings.extension", "person.2.wave.2", ["airdrop", "partage d'écran"]),
        ("Time Machine", "com.apple.Time-Machine-Settings.extension", "clock.arrow.circlepath", ["sauvegarde", "backup"]),
        ("Date et heure", "com.apple.Date-Time-Settings.extension", "clock", []),
        ("Ouverture (éléments de connexion)", "com.apple.LoginItems-Settings.extension", "power", ["démarrage", "login items"])
    ]

    static func commands() -> [AppCommand] {
        panes.map { title, ext, symbol, keywords in
            let id = "set_" + ext.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "-", with: "_").suffix(56)
            return AppCommand(id: String(id), title: title, subtitle: "Réglages Système", keywords: keywords + ["réglages", "settings", "préférences"],
                              icon: .symbol(symbol, Theme.text2), group: .settings, hint: "Ouvrir") { _ in
                Finder.open("x-apple.systempreferences:\(ext)")
                return .done
            }
        }
    }
}

// MARK: - Heartware itself

@MainActor
enum LauncherAppActions {
    static func openMain(_ app: AppModel, _ page: Page) {
        app.page = page
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
    }

    static func commands(_ app: AppModel) -> [AppCommand] {
        var list: [AppCommand] = Page.allCases.map { p in
            AppCommand(id: "open_\(p.rawValue)", title: p.title, subtitle: "Ouvrir dans Heartware",
                              keywords: ["heartware", "ouvrir"], icon: .symbol(p.symbol), group: .actions,
                              assistantSafe: true, urlSafe: true, hint: "Ouvrir") { ctx in
                openMain(ctx.app, p)
                return .done
            }
        }
        list += [
            // The translator has no page: it translates right in the launcher panel.
            AppCommand(id: "open_translator", title: "Traducteur", subtitle: "Traduire ici, sans ouvrir la fenêtre",
                       keywords: ["traduire", "traduction", "translate", "langue"], icon: .symbol("character.bubble", Theme.palette[1]),
                       group: .actions, assistantSafe: true, urlSafe: true, hint: "Traduire", staysInLauncher: true) { ctx in
                ctx.app.launcher.showTranslator()
                return .done
            },
            // Opens the profile panel over the page already open: it only changes what the sidebar shows.
            AppCommand(id: "act_profile", title: "Choisir mon profil", subtitle: "Les outils mis en avant dans la barre latérale",
                       keywords: ["profil", "personnaliser", "barre latérale", "outils", "autres outils"],
                       icon: .symbol("person.crop.rectangle.stack"), group: .actions, assistantSafe: true, urlSafe: true, hint: "Ouvrir") { ctx in
                openMain(ctx.app, ctx.app.page)
                ctx.app.showProfilePanel = true
                return .done
            },
            AppCommand(id: "act_smart_scan", title: "Analyse intelligente", subtitle: "Fichiers inutiles, sécurité, apps, démarrage",
                       keywords: ["analyser", "scan", "bilan", "santé"], icon: .symbol("wand.and.stars"), group: .actions,
                       assistantSafe: true, urlSafe: true) { ctx in
                openMain(ctx.app, .dashboard)
                Task { await ctx.app.smartScan() }
                return .done
            },
            AppCommand(id: "act_scan_junk", title: "Chercher les fichiers inutiles", keywords: ["nettoyer", "nettoyage", "caches", "place"],
                       icon: .symbol("sparkles"), group: .actions, assistantSafe: true, urlSafe: true) { ctx in
                openMain(ctx.app, .cleanup)
                Task { await ctx.app.cleanup.scan() }
                return .done
            },
            AppCommand(id: "act_security", title: "Faire le bilan de sécurité", keywords: ["sécurité", "protection", "malware"],
                       icon: .symbol("lock.shield"), group: .actions, assistantSafe: true, urlSafe: true) { ctx in
                openMain(ctx.app, .protection)
                Task { await ctx.app.protection.audit() }
                return .done
            },
            AppCommand(id: "act_storage", title: "Explorer le dossier personnel", keywords: ["stockage", "espace disque", "gros fichiers"],
                       icon: .symbol("chart.pie"), group: .actions, assistantSafe: true, urlSafe: true) { ctx in
                openMain(ctx.app, .storage)
                Task { await ctx.app.storage.scan(FS.home) }
                return .done
            },
            // Never run without a word, even when Claude proposes it: macOS empties its disk caches and every app reads
            // its code again, which can freeze the Mac for a few seconds.
            AppCommand(id: "act_free_ram", title: "Libérer la mémoire vive", subtitle: "Demande ton mot de passe",
                       keywords: ["ram", "mémoire", "purge"], icon: .symbol("memorychip"), group: .actions,
                       risk: .confirm("macOS vide ses caches de disque : le Mac peut se figer quelques secondes, le temps que les apps relisent ce dont elles ont besoin. C'est rarement utile, macOS gère très bien sa mémoire seul."),
                       assistantSafe: true) { _ in
                let message = await Task.detached { QuickActions.freeMemory() }.value
                return message.map { .message($0) } ?? .done
            },
            AppCommand(id: "act_flush_dns", title: "Vider le cache DNS", subtitle: "Demande ton mot de passe",
                       keywords: ["dns", "réseau", "internet"], icon: .symbol("network"), group: .actions, assistantSafe: true) { _ in
                let message = await Task.detached { QuickActions.flushDNS() }.value
                return message.map { .message($0) } ?? .done
            },
            AppCommand(id: "act_log", title: "Journal des suppressions", keywords: ["journal", "log", "historique"],
                       icon: .symbol("doc.text"), group: .actions, assistantSafe: true) { _ in
                if FS.exists(ActionLog.file) { NSWorkspace.shared.open(URL(fileURLWithPath: ActionLog.file)) } else { Finder.reveal(ActionLog.folder) }
                return .done
            }
        ]
        for t in MaintenanceTask.all where t.available && !["ram", "dns"].contains(t.id) {
            list.append(AppCommand(id: "maint_\(t.id)", title: t.title, subtitle: "Maintenance" + (t.needsAdmin ? " · mot de passe" : ""),
                                   keywords: ["maintenance", "réparer"], icon: .symbol(t.symbol, Theme.warn), group: .actions,
                                   risk: maintenanceRisk(t), assistantSafe: assistantMaintenance.contains(t.id)) { ctx in
                await ctx.app.performance.run(t)
                let r = ctx.app.performance.results[t.id]
                return r?.ok == true ? .message("\(t.title) : terminé.") : .failed(r?.message ?? "Échec")
            })
        }
        return list
    }

    /// The maintenance Claude may suggest: nothing deleted, nothing interrupted (Spotlight still asks first, it keeps the Mac busy).
    static let assistantMaintenance: Set<String> = ["dock", "quicklook", "launchservices", "spotlight"]

    /// Relaunching the Dock or Quick Look loses nothing; the other tasks delete (simulators, snapshots), keep the Mac
    /// busy (Spotlight, Launch Services) or interrupt something (a copy in the Finder): they ask first.
    static func maintenanceRisk(_ t: MaintenanceTask) -> CommandRisk {
        if ["dock", "quicklook"].contains(t.id) { return .safe }
        if t.id == "finder" { return .confirm("Les fenêtres du Finder vont se fermer, et une copie en cours serait interrompue.") }
        return .confirm(t.warning ?? t.detail)
    }
}

// MARK: - Results computed from the query

enum LauncherDynamic {
    static func results(_ query: String) -> [AppCommand] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out: [AppCommand] = []

        if let v = LauncherCalculator.evaluate(q) {
            let text = LauncherCalculator.format(v)
            out.append(AppCommand(id: "calc_result", title: "= \(text)", subtitle: q, icon: .symbol("function", Theme.brand),
                                  group: .calculator, hint: "Copier", boost: 2000) { _ in CommandRunner.copy(text) })
        }
        if let c = LauncherUnits.convert(q) {
            let text = LauncherCalculator.format(c.value)
            out.append(AppCommand(id: "unit_result", title: "\(c.from) = \(c.to)", subtitle: "Conversion", icon: .symbol("ruler", Theme.brand),
                                  group: .calculator, hint: "Copier", boost: 2000) { _ in CommandRunner.copy(text) })
        }
        if let t = LauncherWorldClock.answer(q) {
            out.append(AppCommand(id: "clock_result", title: "\(t.city) : \(t.time)", subtitle: "Heure locale", icon: .symbol("globe.europe.africa", Theme.brand),
                                  group: .calculator, hint: "Copier", boost: 2000) { _ in CommandRunner.copy(t.time) })
        }
        out += volume(q)
        out += processes(q)
        out += emoji(q)
        out += web(q)
        return out
    }

    /// "volume 40", "volume 40 %" → 40.
    static func volumeLevel(_ q: String) -> Int? {
        let lower = q.lowercased()
        guard lower.hasPrefix("volume "), let n = Int(lower.dropFirst(7).replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)),
              (0...100).contains(n) else { return nil }
        return n
    }

    private static func volume(_ q: String) -> [AppCommand] {
        guard let n = volumeLevel(q) else { return [] }
        return [AppCommand(id: "volume_set", title: "Régler le volume à \(n) %", icon: .symbol("speaker.wave.2"), group: .system, boost: 1500) { _ in
            let r = await Task.detached { Shell.appleScript("set volume output volume \(n)") }.value
            return r.ok ? .message("Volume : \(n) %") : .failed(r.err)
        }]
    }

    /// "quitter Slack", "forcer Chrome"
    private static func processes(_ q: String) -> [AppCommand] {
        let lower = q.lowercased()
        let verbs: [(String, Bool)] = [("quitter ", false), ("quit ", false), ("fermer ", false), ("forcer ", true), ("kill ", true)]
        // The demo never lists (nor closes) the apps really open on this Mac.
        guard !DemoData.isEnabled, let (verb, force) = verbs.first(where: { lower.hasPrefix($0.0) }) else { return [] }
        let name = String(q.dropFirst(verb.count))
        guard !name.isEmpty else { return [] }
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
            .compactMap { app -> AppCommand? in
                guard let title = app.localizedName, let score = Fuzzy.score(name, in: title) else { return nil }
                // Stable per app (not the pid), so the usage memory keeps one line per app.
                return AppCommand(id: processID(app.bundleIdentifier ?? title, force: force), title: "\(force ? "Forcer à quitter" : "Quitter") \(title)",
                                  icon: app.bundleURL.map { .file($0.path) } ?? .symbol("xmark.app"), group: .system,
                                  risk: force ? .confirm("Les documents non enregistrés de \(title) seront perdus.") : .safe,
                                  boost: 1200 + score / 10) { _ in
                    let ok = force ? app.forceTerminate() : app.terminate()
                    return ok ? .message("\(title) \(force ? "arrêtée" : "fermée").") : .failed("\(title) n'a pas voulu se fermer.")
                }
            }
    }

    /// "quit_com_tinyspeck_slackmacgap", "kill_slack": letters, digits and "_" only, at most 64 characters.
    static func processID(_ key: String, force: Bool) -> String {
        let clean = Fuzzy.fold(key).unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return (force ? "kill_" : "quit_") + String(String(clean).prefix(59))
    }

    /// ":smile" or "emoji cœur"
    private static func emoji(_ q: String) -> [AppCommand] {
        let lower = q.lowercased()
        let term: String
        if lower.hasPrefix(":") { term = String(lower.dropFirst()) } else if lower.hasPrefix("emoji ") { term = String(lower.dropFirst(6)) } else { return [] }
        guard term.count >= 2 else { return [] }
        return LauncherEmoji.search(term).prefix(24).enumerated().map { i, e in
            AppCommand(id: LauncherEmoji.commandID(e.char), title: e.char, subtitle: e.name.lowercased(), icon: .emoji(e.char), group: .emoji,
                       hint: "Copier", boost: 1000 - Double(i)) { _ in CommandRunner.copy(e.char) }
        }
    }

    /// Prefixes ("g ", "yt "…) or a fallback web search at the end of the list.
    private static func web(_ q: String) -> [AppCommand] {
        let engines: [(prefix: String, name: String, url: String, symbol: String)] = [
            ("g ", "Google", "https://www.google.com/search?q=", "magnifyingglass"),
            ("ddg ", "DuckDuckGo", "https://duckduckgo.com/?q=", "magnifyingglass"),
            ("yt ", "YouTube", "https://www.youtube.com/results?search_query=", "play.rectangle"),
            ("gh ", "GitHub", "https://github.com/search?q=", "chevron.left.forwardslash.chevron.right"),
            ("wiki ", "Wikipédia", "https://fr.wikipedia.org/w/index.php?search=", "book"),
            ("maps ", "Plans", "maps://?q=", "map"),
            ("gtrad ", "Google Traduction", "https://translate.google.com/?sl=auto&tl=fr&text=", "character.bubble")
        ]
        let lower = q.lowercased()
        func command(_ name: String, _ base: String, _ term: String, _ symbol: String, boost: Double) -> AppCommand {
            let encoded = term.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? term
            return AppCommand(id: "web_\(Fuzzy.fold(name).filter { $0.isASCII && $0.isLetter })", title: "Rechercher « \(term) » sur \(name)",
                              icon: .symbol(symbol, Theme.palette[1]), group: .web, hint: "Ouvrir", boost: boost) { _ in
                if let url = URL(string: base + encoded) { NSWorkspace.shared.open(url) }
                return .done
            }
        }
        if let e = engines.first(where: { lower.hasPrefix($0.prefix) }) {
            let term = String(q.dropFirst(e.prefix.count))
            return term.isEmpty ? [] : [command(e.name, e.url, term, e.symbol, boost: 1500)]
        }
        return q.count >= 2 ? [command("Google", engines[0].url, q, "magnifyingglass", boost: -400)] : []
    }

    /// What may stay as is in the value of a query parameter: not "&", "+", "=", "?" or "#",
    /// which would cut the search ("g AT&T" would look for "AT").
    static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()
}

// MARK: - Emoji

enum LauncherEmoji {
    struct Item { let char: String; let name: String }

    /// Built once from the Unicode tables (English names).
    static let all: [Item] = {
        var out: [Item] = []
        let ranges: [ClosedRange<UInt32>] = [0x1F300...0x1F5FF, 0x1F600...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF,
                                             0x1FA70...0x1FAFF, 0x2600...0x26FF, 0x2700...0x27BF]
        for r in ranges {
            for v in r {
                guard let s = Unicode.Scalar(v), s.properties.isEmojiPresentation, let name = s.properties.name else { continue }
                out.append(Item(char: String(Character(s)), name: name))
            }
        }
        return out
    }()

    /// A few French words mapped to the English names Unicode uses.
    private static let french: [String: String] = [
        "coeur": "heart", "cœur": "heart", "rire": "laugh", "sourire": "smil", "pleure": "cry", "feu": "fire", "chat": "cat",
        "chien": "dog", "soleil": "sun", "lune": "moon", "étoile": "star", "etoile": "star", "pouce": "thumbs", "fête": "party",
        "fete": "party", "cadeau": "gift", "fleur": "flower", "arbre": "tree", "voiture": "car", "avion": "airplane",
        "maison": "house", "ordinateur": "computer", "café": "coffee", "cafe": "coffee", "bière": "beer", "biere": "beer",
        "gâteau": "cake", "gateau": "cake", "argent": "money", "fusée": "rocket", "fusee": "rocket", "check": "check",
        "ok": "ok", "triste": "sad", "colère": "angry", "colere": "angry", "clin": "wink", "bisou": "kiss", "mains": "hands",
        "pluie": "rain", "neige": "snow", "balai": "broom", "poubelle": "wastebasket", "cerveau": "brain", "robot": "robot"
    ]

    /// A whole word of the name first ("ok" → OK HAND SIGN), then a word that starts with it, then the rest
    /// (COOKED RICE only contains "OK").
    static func search(_ term: String) -> [Item] {
        let t = (french[term] ?? term).uppercased()
        var tiers: [[Item]] = [[], [], []]
        for e in all where e.name.contains(t) {
            let words = e.name.split(whereSeparator: { $0 == " " || $0 == "-" })
            tiers[words.contains { $0 == t } ? 0 : (words.contains { $0.hasPrefix(t) } ? 1 : 2)].append(e)
        }
        return tiers.flatMap { $0 }
    }

    /// "emoji_1f600": the code points, stable whatever the rank in the results.
    static func commandID(_ char: String) -> String {
        "emoji_" + char.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "_")
    }
}
