import Foundation

/// `--selftest`: the reading of `windscribe-cli`'s outputs (built from its sources: the lines of
/// BackendCommander::onStateResponse, the words of strings.cpp and of its French translation), the locations it may be
/// given, the phases and the sizes.
enum VPNChecks {
    static let gib: Int64 = 1 << 30

    /// English, connected (`Connected: <city - nickname>`, a WireGuard tunnel, the free 10 GB).
    static let connectedEN = """
    Internet connectivity: available
    Login state: Logged in
    Firewall state: On
    Connect state: Connected: Paris - Seine
    Protocol: WireGuard:443
    VPN IP: 203.0.113.24
    Data usage: 3.20 GB / 10.00 GB
    """

    /// French, the tunnel still tested ("*"), the non-breaking space of "Protocole : %1\u{a0}:%2".
    static let testingFR = """
    Connectivité Internet : disponible
    État de connexion : Connecté
    État du pare-feu : Sur
    *État de connexion : Connecté : Paris - Seine
    Protocole : WireGuard\u{00A0}:443
    IP publique : 203.0.113.24
    Utilisation des données : 3,20 Go / 10,00 Go
    """

    static let loggedOutEN = """
    Internet connectivity: available
    Login state: Logged out
    Firewall state: Off
    Public IP: 198.51.100.7
    """

    static let readyUnlimitedEN = """
    Internet connectivity: available
    Login state: Logged in
    Firewall state: Off
    Connect state: Disconnected
    Public IP: 198.51.100.7
    Data usage: 512 bytes / Unlimited
    Update available: 2.25.1
    """

    static let outOfDataFR = """
    Connectivité Internet : disponible
    État de connexion : Connecté
    État du pare-feu : De
    État de connexion : Erreur : Vous n’avez plus de données ou votre compte a été désactivé. Passez à Pro pour continuer à utiliser Windscribe
    IP publique : 198.51.100.7
    Utilisation des données : 10,00 Go / 10,00 Go
    """

    static let unavailableEN = """
    Internet connectivity: available
    Login state: Logged in
    Firewall state: Off
    Connect state: Error: Location does not exist or is disabled
    Data usage: 1.10 GB / 10.00 GB
    """

    static let connectingES = """
    Conectividad a Internet: disponible
    Estado de inicio de sesión: Conectado
    Estado del cortafuegos: Desactivado
    Estado de conexión: Conectando: Paris - Seine
    Protocolo: WireGuard:443
    Uso de datos: 1.10 GB / 10.00 GB
    """

    /// Windscribe just started: still signing in with its saved session (no data line yet).
    static let loggingInFR = """
    Connectivité Internet : disponible
    État de connexion : Connexion
    État du pare-feu : De
    État de connexion : Coupé
    """

    static let interferenceEN = """
    Internet connectivity: available
    Login state: Logged in
    Firewall state: On
    Connect state: Connected: London - Crown [Network interference]
    Protocol: Stealth:443
    Public IP: 198.51.100.7
    Data usage: 700.50 MB / 2.00 GB
    """

    static func run() -> [String] {
        var f: [String] = []
        f += statusChecks()
        f += sizeAndFailureChecks()
        f += countryChecks()
        f += phaseChecks()
        f += windscribeSettingsChecks()
        f += outOfSightChecks()
        f += disconnectChecks()
        return f
    }

    /// The menu switch and the wait after « Déconnecter » (the user saw a reconnection right after cutting).
    static func disconnectChecks() -> [String] {
        var f: [String] = []
        let expected: [(VPNPhase, VPNPhase.MenuAction)] = [
            (.connecting(.fr), .disconnect), (.disconnecting, .wait), (.starting, .wait),
            (.ready, .connect), (.closed, .connect), (.failed("x"), .connect)
        ]
        for (phase, action) in expected where phase.menuAction != action {
            f.append("VPN : la bascule du menu fait \(phase.menuAction) au lieu de \(action) (\(phase))")
        }
        if VPNPhase.stillDisconnecting(.disconnected) || !VPNPhase.stillDisconnecting(.disconnecting)
            || !VPNPhase.stillDisconnecting(.connecting(city: nil)) {
            f.append("VPN : l'attente après « Déconnecter » s'arrête au mauvais moment")
        }
        return f
    }

    // MARK: Windscribe's « Hide from Dock » and « Start minimized »

    /// `types::GuiSettings` as Windscribe's `Preferences::saveGuiSettings` streams it (behind its magic and version), with
    /// an app and a route out of the tunnel, a background image and a hotspot name with accents.
    static func guiSettingsBlob(gui: UInt32 = 8, hide: Bool = false, minimized: Bool = false) -> Data {
        var w = VPNQtWriter()
        w.u32(VPNWindscribeSettings.magic)
        w.u32(1)
        w.u32(gui)
        // isLaunchOnStartup, isAutoConnect, isHideFromDock, isShowNotifications, orderLocation (+ latencyDisplay before 6)
        w.bool(true); w.bool(false); w.bool(hide); w.bool(false); w.u32(0)
        if gui < 6 { w.u32(1) }
        // ShareSecureHotspot 2: isEnabled, password, ssid
        w.u32(2); w.bool(false); w.string(nil); w.string("Café")
        // ShareProxyGateway 4: isEnabled, mode, port, whileConnected, requireAuth, username, password
        w.u32(4); w.bool(false); w.u32(0); w.u32(0); w.bool(false); w.bool(true); w.string(""); w.string(nil)
        // SplitTunneling 1: settings 1 (active, mode), one app 2 (type, name, fullName, active, icon), one route 2
        w.u32(1); w.u32(1); w.bool(true); w.u32(0)
        w.u32(1); w.u32(2); w.u32(0); w.string("Safari"); w.string("/Applications/Safari.app"); w.bool(true); w.string("")
        w.u32(1); w.u32(2); w.u32(1); w.string("exemple.fr"); w.bool(true)
        // isDockedToTray, isMinimizeAndCloseToTray, BackgroundSettings 2 (two types, two images, aspect ratio)
        w.bool(false); w.bool(false)
        w.u32(2); w.u32(1); w.u32(1); w.string(nil); w.string("/Users/démo/fond.png"); w.u32(1)
        // isStartMinimized, isShowLocationHealth, isAutoSecureNetworks, appSkin, trayIconColor, multiDesktopBehavior
        w.bool(minimized); w.bool(false); w.bool(true)
        if gui >= 2 { w.u32(0) }
        if gui >= 3 { w.u32(2) }
        if gui >= 4 { w.u32(0) }
        // SoundSettings 1
        if gui >= 5 { w.u32(1); w.u32(0); w.string(nil); w.u32(0); w.string(nil) }
        return Data(w.bytes)
    }

    /// `guiSettingsBlob()` as Windscribe stores it when compressing pays (flags 3: zlib by `qCompress`, then the
    /// checksum), made outside Heartware with Python's zlib.
    static let compressedFixture = "AwN5XtUmii9xTCx47V/5n63kG9XbP73Fv4A9W5dPa4hqMSvCcYpwn/hJjwOUwLyPzOGKoopGcyulxMmBpMJ6bq3VERI1/6WoV1g3fIb66LWDs4NLcI8xDIXTBGYRS6kKmkqCHtFQcxNa4fQlZrJDL1GtXH255eGkmo5D3o1M8T/gi8koDHPQwvAA+vBI0mPtKQRW8Lko2VausHq0APjLsj8N+zIqHl/Uuw=="

    private static func windscribeSettingsChecks() -> [String] {
        var f: [String] = []
        let key = VPNWindscribeSettings.cryptKey
        if VPNSimpleCrypt.checksum(Array("123456789".utf8)) != 0x906E { f.append("somme de contrôle de Qt (CRC-16 X.25) fausse") }
        if VPNSimpleCrypt.adler32(Array("Wikipedia".utf8)) != 0x11E6_0398 { f.append("Adler-32 faux") }
        let plain = guiSettingsBlob()
        let stored = VPNSimpleCrypt.encrypt(plain, key: key, random: 0x5A)
        if VPNSimpleCrypt.decrypt(stored, key: key) != plain { f.append("SimpleCrypt : l'aller-retour ne rend pas les mêmes octets") }
        if VPNSimpleCrypt.decrypt(compressedFixture, key: key) != plain { f.append("SimpleCrypt : réglages compressés par Qt mal lus") }
        if VPNWindscribeSettings.flags(in: compressedFixture) != .visible { f.append("réglages compressés : drapeaux mal lus") }
        if VPNWindscribeSettings.flags(in: stored) != .visible { f.append("réglages par défaut de Windscribe mal lus") }
        let onlyDock = VPNSimpleCrypt.encrypt(guiSettingsBlob(hide: true), key: key, random: 1)
        let onlyMinimized = VPNSimpleCrypt.encrypt(guiSettingsBlob(minimized: true), key: key, random: 2)
        if VPNWindscribeSettings.flags(in: onlyDock) != VPNWindscribeFlags(hideFromDock: true, startMinimized: false)
            || VPNWindscribeSettings.flags(in: onlyMinimized) != VPNWindscribeFlags(hideFromDock: false, startMinimized: true) {
            f.append("« Masquer du Dock » et « Démarrer réduit » confondus")
        }
        if let hidden = VPNWindscribeSettings.setting(.invisible, in: compressedFixture, random: 7),
           let clear = VPNSimpleCrypt.decrypt(hidden, key: key), clear.count == plain.count {
            if VPNWindscribeSettings.flags(in: hidden) != .invisible { f.append("réglage invisible non relu") }
            let changed = (0..<plain.count).filter { plain[$0] != clear[$0] }
            if changed.count != 2 { f.append("écrire les deux réglages change \(changed.count) octets") }
            if let back = VPNWindscribeSettings.setting(.visible, in: hidden), VPNSimpleCrypt.decrypt(back, key: key) != plain {
                f.append("revenir aux réglages d'avant ne rend pas les mêmes octets")
            }
        } else {
            f.append("réglage invisible impossible à écrire")
        }
        // Older settings (version 5: latencyDisplay still there) are read as Windscribe reads them.
        let old = VPNSimpleCrypt.encrypt(guiSettingsBlob(gui: 5, hide: true, minimized: true), key: key, random: 3)
        if VPNWindscribeSettings.flags(in: old) != .invisible { f.append("réglages de la version 5 mal lus") }
        // Anything else is left alone.
        var refused: [(String, Data)] = [("version 9", guiSettingsBlob(gui: 9)), ("un octet de trop", plain + Data([0])),
                                         ("un octet de moins", plain.dropLast())]
        var notBool = plain
        notBool[14] = 2
        refused.append(("un booléen à 2", notBool))
        var wrongMagic = plain
        wrongMagic[0] ^= 1
        refused.append(("une autre signature", wrongMagic))
        for (name, data) in refused where VPNWindscribeSettings.setting(.invisible, in: VPNSimpleCrypt.encrypt(data, key: key, random: 9)) != nil {
            f.append("réglages avec \(name) modifiés quand même")
        }
        if var bytes = Data(base64Encoded: stored) {
            bytes[bytes.count - 3] ^= 0x10
            if VPNSimpleCrypt.decrypt(bytes.base64EncodedString(), key: key) != nil { f.append("réglages abîmés acceptés") }
            bytes = Data(base64Encoded: stored)!
            bytes[1] = VPNSimpleCrypt.flagHash
            if VPNSimpleCrypt.decrypt(bytes.base64EncodedString(), key: key) != nil { f.append("réglages protégés par SHA-1 acceptés sans contrôle") }
        }
        if VPNSimpleCrypt.decrypt(stored, key: key ^ 0xFF) != nil { f.append("SimpleCrypt : une autre clé passe la somme de contrôle") }
        return f
    }

    private static func outOfSightChecks() -> [String] {
        var f: [String] = []
        let config = VPNWindscribe.hiddenLaunchConfiguration()
        if config.activates || !config.hides || config.addsToRecentItems || config.createsNewApplicationInstance {
            f.append("Windscribe démarré au premier plan, visible ou dans les éléments récents")
        }
        let titles: [(VPNPhase, String)] = [(.connecting(.fr), "VPN · connexion…"), (.connecting(nil), "VPN · connexion…"),
                                            (.disconnecting, "VPN · coupure…"), (.ready, "VPN · France"),
                                            (.connected(VPNConnection(country: .de)), "VPN · Allemagne")]
        for (phase, title) in titles where VPNText.menuTitle(phase) != title {
            f.append("menu d'état : « \(VPNText.menuTitle(phase)) » au lieu de « \(title) »")
        }
        return f
    }

    private static func statusChecks() -> [String] {
        var f: [String] = []
        if let s = VPNStatusParser.parse(connectedEN) {
            if s.login != .loggedIn || s.link != .connected(city: "Paris - Seine") { f.append("statut anglais connecté mal lu : \(s)") }
            if s.proto != "WireGuard:443" || s.ip != "203.0.113.24" || !s.ipIsVPN { f.append("protocole ou IP du VPN mal lus : \(s)") }
            if s.used != 3_435_973_837 || s.limit != 10 * gib { f.append("données mal lues : \(String(describing: s.used)) / \(String(describing: s.limit))") }
            if s.testing || s.interference { f.append("tunnel testé ou perturbé à tort") }
        } else {
            f.append("statut anglais connecté illisible")
        }
        if let s = VPNStatusParser.parse(testingFR) {
            if s.login != .loggedIn || s.link != .connected(city: "Paris - Seine") || !s.testing { f.append("statut français en test mal lu : \(s)") }
            if s.proto != "WireGuard:443" || s.ipIsVPN { f.append("protocole français mal lu : \(String(describing: s.proto))") }
            if s.used != 3_435_973_837 || s.limit != 10 * gib { f.append("données françaises mal lues") }
        } else {
            f.append("statut français illisible")
        }
        if let s = VPNStatusParser.parse(loggedOutEN) {
            if s.login != .loggedOut || s.link != .disconnected || s.used != nil || s.ip != "198.51.100.7" { f.append("statut déconnecté du compte mal lu : \(s)") }
        } else {
            f.append("statut déconnecté du compte illisible")
        }
        if let s = VPNStatusParser.parse(readyUnlimitedEN) {
            if s.login != .loggedIn || s.link != .disconnected || s.used != 512 || s.limit != nil { f.append("statut illimité mal lu : \(s)") }
        } else {
            f.append("statut illimité illisible")
        }
        if VPNStatusParser.parse(outOfDataFR)?.link != .failed(.outOfData) { f.append("données épuisées (français) non reconnues") }
        if VPNStatusParser.parse(unavailableEN)?.link != .failed(.locationUnavailable) { f.append("lieu refusé non reconnu") }
        if let s = VPNStatusParser.parse(connectingES) {
            if s.login != .loggedIn || s.link != .connecting(city: "Paris - Seine") { f.append("connexion en cours (espagnol) mal lue : \(s)") }
        } else {
            f.append("statut espagnol illisible")
        }
        if let s = VPNStatusParser.parse(loggingInFR) {
            if s.login != .loggingIn || s.link != .disconnected { f.append("ouverture de session (français) mal lue : \(s)") }
        } else {
            f.append("statut d'ouverture de session illisible")
        }
        if let s = VPNStatusParser.parse(interferenceEN) {
            if s.link != .connected(city: "London - Crown") || !s.interference || s.proto != "Stealth:443" { f.append("interférence mal lue : \(s)") }
            if s.used != 734_527_488 || s.limit != 2 * gib || s.usage?.unconfirmedEmail != true { f.append("2 Go sans e-mail mal lus") }
        } else {
            f.append("statut avec interférence illisible")
        }
        for notStatus in ["Not logged in", "Windscribe CLI is already running", "", "Connection is in progress.  Use 'windscribe-cli status' to check for connection status."]
        where VPNStatusParser.parse(notStatus) != nil {
            f.append("« \(notStatus) » pris pour un statut")
        }
        return f
    }

    private static func sizeAndFailureChecks() -> [String] {
        var f: [String] = []
        let sizes: [(String, Int64?)] = [("3.20 GB", 3_435_973_837), ("3,20 Go", 3_435_973_837), ("10.00 GB", 10 * gib), ("1.2 GiB", 1_288_490_189),
                                         ("512 bytes", 512), ("0 octets", 0), ("1\u{00A0}023 octets", 1023), ("700,50 Mo", 734_527_488),
                                         ("12.00 kB", 12_288), ("Unlimited", nil), ("Illimité", nil), ("3.20 GB extra", nil)]
        for (text, expected) in sizes where VPNStatusParser.size(text) != expected {
            f.append("taille « \(text) » lue \(String(describing: VPNStatusParser.size(text))) au lieu de \(String(describing: expected))")
        }
        let failures: [(String, VPNStatusParser.Failure)] = [
            ("Windscribe CLI is already running", .busy), ("Not logged in", .notSignedIn), ("Non connecté", .notSignedIn),
            ("Aborting: app did not start in time", .notStarted), ("Abandon : l’application n’a pas démarré à temps", .notStarted),
            ("Aborting: IPC communication error", .noAnswer)
        ]
        for (text, expected) in failures where VPNStatusParser.failure(text) != expected {
            f.append("échec « \(text) » mal compris : \(VPNStatusParser.failure(text))")
        }
        for (bytes, text) in [(3_435_973_837 as Int64, "3,2 Go"), (10 * gib, "10 Go"), (512 * 1_048_576, "512 Mo"), (0, "0 o")]
        where VPNFormat.size(bytes) != text {
            f.append("taille \(bytes) affichée « \(VPNFormat.size(bytes)) » au lieu de « \(text) »")
        }
        return f
    }

    private static func countryChecks() -> [String] {
        var f: [String] = []
        if VPNCountry.allCases.first != .fr { f.append("la France n'est pas le premier pays") }
        if VPNCountry.allCases.count != 10 { f.append("\(VPNCountry.allCases.count) pays gratuits au lieu de 10") }
        if Set(VPNCountry.allCases.map(\.name)).count != VPNCountry.allCases.count { f.append("deux pays portent le même nom") }
        for country in VPNCountry.allCases {
            if country.cliNames.first != country.rawValue.uppercased() { f.append("\(country.name) : le code ISO n'est pas essayé en premier") }
            for name in country.cliNames where VPNCountry.validated(name, for: country) == nil {
                f.append("\(country.name) : « \(name) » refusé pour la CLI")
            }
            if country.flag.unicodeScalars.count != 2 { f.append("\(country.name) : drapeau mal formé") }
        }
        for unsafe in ["-n", "best", "static", "WireGuard", "fr; rm -rf ~", "FR\nUS", "", "Paris-1", "é"] where VPNCountry.isSafeCLIName(unsafe) {
            f.append("« \(unsafe) » accepté comme lieu pour la CLI")
        }
        if VPNCountry.validated("US", for: .fr) != nil { f.append("un lieu d'un autre pays accepté") }
        let cities: [(String, VPNCountry?)] = [("Paris", .fr), ("Toronto", .ca), ("London", .gb), ("Zurich", .ch), ("Madrid", nil)]
        for (city, expected) in cities where VPNCountry.forCity(city) != expected { f.append("ville \(city) rattachée à \(String(describing: VPNCountry.forCity(city)))") }
        if VPNStatusParser.cityName("Paris - Seine") != "Paris" { f.append("nom de ville mal extrait") }
        let queries: [(String, VPNCountry?)] = [("vpn fra", .fr), ("VPN France", .fr), ("vpn royaume", .gb), ("vpn usa", .us), ("vpn etats", .us),
                                               ("vpn Norvège", .no), ("vpn", nil), ("vpnx fr", nil), ("france", nil)]
        for (q, expected) in queries where VPNLauncher.countries(for: q).first != expected {
            f.append("lanceur « \(q) » → \(String(describing: VPNLauncher.countries(for: q).first))")
        }
        return f
    }

    private static func phaseChecks() -> [String] {
        var f: [String] = []
        func phase(_ text: String, target: VPNCountry? = nil, own: Bool = false) -> VPNPhase? {
            VPNStatusParser.parse(text).map { VPNPhase.from($0, target: target, ownAttempt: own) }
        }
        if case .connected(let c)? = phase(connectedEN) {
            if c.country != .fr || c.city != "Paris" { f.append("connexion à Paris non rattachée à la France") }
        } else {
            f.append("statut connecté sans phase connectée")
        }
        if phase(loggedOutEN) != .loggedOut { f.append("compte déconnecté sans sa phase") }
        if phase(loggingInFR) != .starting { f.append("ouverture de session sans sa phase") }
        if phase(readyUnlimitedEN) != .ready { f.append("prêt sans sa phase") }
        if phase(outOfDataFR) != .outOfData { f.append("données épuisées sans leur phase") }
        if phase(unavailableEN) != .ready { f.append("une vieille erreur de lieu bloque la page") }
        if phase(unavailableEN, target: .fr, own: true) != .failed(VPNText.unavailable(.fr)) { f.append("lieu refusé sans message") }
        if phase(connectingES, target: .fr) != .connecting(.fr) { f.append("connexion en cours sans son pays") }
        let exhausted = VPNStatus(login: .loggedIn, link: .disconnected, used: 10 * gib, limit: 10 * gib)
        if VPNPhase.from(exhausted, target: nil, ownAttempt: false) != .outOfData { f.append("10 Go sur 10 Go sans la phase des données épuisées") }
        if VPNText.headline(.connected(VPNConnection(country: .us)), usage: nil) != "Connecté aux États-Unis" { f.append("titre « aux États-Unis » mal accordé") }
        if VPNText.headline(.outOfData, usage: VPNUsage(used: 10 * gib, limit: 10 * gib)) != "Tes 10 Go du mois sont épuisés" { f.append("titre des données épuisées") }
        if !VPNInstaller.isWindscribeSignature("Authority=Developer ID Application: Windscribe Limited (TEAM123456)\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA") {
            f.append("signature de Windscribe refusée")
        }
        if VPNInstaller.isWindscribeSignature("Authority=Developer ID Application: Quelqu'un d'autre (X)\nAuthority=Apple Root CA")
            || VPNInstaller.isWindscribeSignature("Authority=Apple Development: Windscribe (X)\nAuthority=Apple Root CA") {
            f.append("installateur d'un autre signataire accepté")
        }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>system-entities</key><array>
        <dict><key>dev-entry</key><string>/dev/disk9</string></dict>
        <dict><key>dev-entry</key><string>/dev/disk9s1</string><key>mount-point</key><string>/Volumes/Windscribe</string></dict>
        </array></dict></plist>
        """
        if VPNInstaller.mountPoint(plist: plist) != "/Volumes/Windscribe" { f.append("point de montage de l'image disque mal lu") }
        return f
    }
}
