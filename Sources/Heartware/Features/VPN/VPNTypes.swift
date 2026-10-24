import SwiftUI

enum VPNStyle {
    static var tint: Color { Theme.palette[1] }
}

/// The ten countries of Windscribe's free plan (windscribe.com/features/use-for-free, October 2026), France first.
/// Windscribe picks a free city in the country by itself; the Pro ones stay out of reach of a free account.
enum VPNCountry: String, CaseIterable, Identifiable, Codable {
    case fr, us, ca, gb, hk, de, nl, ch, no, ro

    var id: String { rawValue }

    var name: String {
        switch self {
        case .fr: return "France"
        case .us: return "États-Unis"
        case .ca: return "Canada"
        case .gb: return "Royaume-Uni"
        case .hk: return "Hong Kong"
        case .de: return "Allemagne"
        case .nl: return "Pays-Bas"
        case .ch: return "Suisse"
        case .no: return "Norvège"
        case .ro: return "Roumanie"
        }
    }

    /// "en France", "aux États-Unis", "à Hong Kong"…
    var inName: String {
        switch self {
        case .us: return "aux États-Unis"
        case .nl: return "aux Pays-Bas"
        case .ca: return "au Canada"
        case .gb: return "au Royaume-Uni"
        case .hk: return "à Hong Kong"
        default: return "en " + name
        }
    }

    /// The flag, made of the two regional indicator letters of the ISO code.
    var flag: String {
        var s = ""
        for scalar in rawValue.uppercased().unicodeScalars {
            if let flagScalar = Unicode.Scalar(0x1F1E6 + scalar.value - 65) { s.unicodeScalars.append(flagScalar) }
        }
        return s
    }

    /// What `windscribe-cli connect -n` is given, in turn: the ISO code (Windscribe matches it against the country code
    /// of its regions and draws one of their free cities), then the English name of the region if the code was refused.
    var cliNames: [String] {
        switch self {
        case .fr: return ["FR", "France"]
        case .us: return ["US"]
        case .ca: return ["CA"]
        case .gb: return ["GB", "United Kingdom"]
        case .hk: return ["HK", "Hong Kong"]
        case .de: return ["DE", "Germany"]
        case .nl: return ["NL", "Netherlands"]
        case .ch: return ["CH", "Switzerland"]
        case .no: return ["NO", "Norway"]
        case .ro: return ["RO", "Romania"]
        }
    }

    /// Windscribe's cities in this country, as its locations name them: the country of a connection made in Windscribe itself.
    var cities: [String] {
        switch self {
        case .fr: return ["Paris", "Marseille"]
        case .us: return ["New York", "Atlanta", "Dallas", "Denver", "Los Angeles", "Chicago", "Seattle", "Miami", "Washington DC",
                          "Boston", "Charlotte", "Phoenix", "San Francisco", "Silicon Valley", "Las Vegas", "Salt Lake City",
                          "Kansas City", "Houston", "Orlando", "Tampa", "Philadelphia", "Portland", "San Jose", "Buffalo"]
        case .ca: return ["Toronto", "Montreal", "Vancouver"]
        case .gb: return ["London", "Manchester", "Edinburgh"]
        case .hk: return ["Hong Kong"]
        case .de: return ["Frankfurt", "Berlin", "Munich"]
        case .nl: return ["Amsterdam", "Rotterdam"]
        case .ch: return ["Zurich"]
        case .no: return ["Oslo"]
        case .ro: return ["Bucharest"]
        }
    }

    /// What the launcher recognises after « vpn » (folded: lower case, no accents).
    var searchNames: [String] {
        let extra: [String]
        switch self {
        case .fr: extra = ["paris"]
        case .us: extra = ["usa", "amerique", "etats unis", "united states"]
        case .ca: extra = ["toronto", "montreal"]
        case .gb: extra = ["uk", "angleterre", "united kingdom", "londres", "grande-bretagne"]
        case .hk: extra = ["chine"]
        case .de: extra = ["germany", "deutschland", "berlin"]
        case .nl: extra = ["hollande", "netherlands", "amsterdam"]
        case .ch: extra = ["switzerland", "zurich"]
        case .no: extra = ["norway", "oslo"]
        case .ro: extra = ["romania", "bucarest"]
        }
        return [Fuzzy.fold(name), rawValue] + extra
    }

    static func forCity(_ city: String) -> VPNCountry? {
        let c = Fuzzy.fold(city)
        return allCases.first { country in country.cities.contains { Fuzzy.fold($0) == c } }
    }

    /// A name `windscribe-cli` may receive: letters and spaces only, starting with a letter (never an option such as
    /// `-n`), and none of the words the CLI reads otherwise (`best`, `static`, a protocol).
    static func isSafeCLIName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 32, let first = s.first, first.isASCII, first.isLetter else { return false }
        guard s.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == " ") }) else { return false }
        let reserved: Set<String> = ["best", "static", "wireguard", "ikev2", "udp", "tcp", "stealth", "wstunnel"]
        return !reserved.contains(s.lowercased())
    }

    /// The location really passed to the CLI: one of this country's known names, checked again.
    static func validated(_ name: String, for country: VPNCountry) -> String? {
        country.cliNames.contains(name) && isSafeCLIName(name) ? name : nil
    }
}

/// What `windscribe-cli status` told, read by `VPNStatusParser`.
struct VPNStatus: Equatable {
    enum Login: Equatable {
        case loggedIn, loggedOut, loggingIn
        case failed(String)
    }

    enum Link: Equatable {
        case connected(city: String?)
        case connecting(city: String?)
        case disconnecting
        case disconnected
        case failed(VPNLinkError)
    }

    var internet = true
    var login: Login = .loggedOut
    var link: Link = .disconnected
    /// "*" before the line: Windscribe is still testing the tunnel.
    var testing = false
    /// "[Network interference]" after it: the tunnel test failed.
    var interference = false
    /// "WireGuard:443".
    var proto: String?
    var ip: String?
    var ipIsVPN = false
    var used: Int64?
    /// nil with `used` set: unlimited.
    var limit: Int64?

    var usage: VPNUsage? { used.map { VPNUsage(used: $0, limit: limit) } }
}

enum VPNLinkError: Equatable {
    case locationUnavailable
    case outOfData
    case other(String)
}

/// The data of the month: used, and the plan's allowance (nil: unlimited).
struct VPNUsage: Equatable {
    var used: Int64
    var limit: Int64?

    var remaining: Int64? { limit.map { max(0, $0 - used) } }

    var fraction: Double {
        guard let limit, limit > 0 else { return 0 }
        let u = Double(used)
        let l = Double(limit)
        return min(1, u / l)
    }

    var exhausted: Bool {
        guard let limit, limit > 0 else { return false }
        return used >= limit
    }

    /// 2 GB: the plan of an account whose e-mail address is not confirmed (10 GB once it is).
    var unconfirmedEmail: Bool {
        guard let limit else { return false }
        let gib: Int64 = 1 << 30
        return limit > 0 && limit <= 2 * gib
    }
}

/// A connection, as the page shows it.
struct VPNConnection: Equatable {
    var country: VPNCountry?
    var city: String?
    var proto: String?
    var ip: String?
    var testing = false
    var interference = false

    var place: String { country?.inName ?? city.map { "à " + $0 } ?? "" }
}

/// Where Heartware is with Windscribe.
enum VPNPhase: Equatable {
    /// Not read yet.
    case unknown
    case notInstalled
    /// Installed, not running: the VPN is off (the CLI would start it).
    case closed
    /// Starting, or signing in to the account with its saved session.
    case starting
    case loggedOut
    /// Signed in, no tunnel.
    case ready
    case connecting(VPNCountry?)
    case connected(VPNConnection)
    case disconnecting
    /// The month's data is used up (or the account was disabled).
    case outOfData
    case failed(String)

    var isOn: Bool {
        if case .connected = self { return true }
        return false
    }

    enum MenuAction: Equatable { case connect, disconnect, wait }

    /// What the menu bar switch does: off while on or connecting, nothing while Windscribe is starting or cutting (a
    /// second click there used to start a new connection).
    var menuAction: MenuAction {
        switch self {
        case .connected, .connecting: return .disconnect
        case .disconnecting, .starting: return .wait
        default: return .connect
        }
    }

    /// Windscribe still on its way down after « disconnect »: the states worth waiting out.
    static func stillDisconnecting(_ link: VPNStatus.Link) -> Bool {
        switch link {
        case .disconnecting, .connecting, .connected: return true
        case .disconnected, .failed: return false
        }
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .disconnecting, .starting: return true
        default: return false
        }
    }

    /// The phase a status read gives. `target`: the country being connected (its name wins over the city's);
    /// `ownAttempt`: an error of the tunnel belongs to what Heartware just asked (otherwise it is an old one, the
    /// tunnel simply being off, except the data used up).
    static func from(_ s: VPNStatus, target: VPNCountry?, ownAttempt: Bool) -> VPNPhase {
        switch s.login {
        case .loggedOut, .failed: return .loggedOut
        case .loggingIn: return .starting
        case .loggedIn: break
        }
        switch s.link {
        case .connected(let city):
            let country = city.flatMap { VPNCountry.forCity(VPNStatusParser.cityName($0)) } ?? target
            return .connected(VPNConnection(country: country, city: city.map(VPNStatusParser.cityName), proto: s.proto,
                                            ip: s.ip, testing: s.testing, interference: s.interference))
        case .connecting(let city):
            return .connecting(target ?? city.flatMap { VPNCountry.forCity(VPNStatusParser.cityName($0)) })
        case .disconnecting:
            return .disconnecting
        case .failed(.outOfData):
            return .outOfData
        case .failed(.locationUnavailable):
            if ownAttempt { return .failed(VPNText.unavailable(target)) }
        case .failed(.other(let message)):
            if ownAttempt { return .failed(VPNText.windscribeSaid(message)) }
        case .disconnected:
            break
        }
        return s.usage?.exhausted == true ? .outOfData : .ready
    }
}

/// Where the installation stands.
enum VPNInstallStep: Equatable {
    /// Homebrew at work: its last line.
    case brew(String)
    case downloading(received: Int64, expected: Int64)
    /// The installer's signature being checked.
    case checking
    /// The installer is open: the rest happens in its window.
    case opened
    case failed(String)

    var running: Bool {
        switch self {
        case .brew, .downloading, .checking: return true
        default: return false
        }
    }
}

/// Sizes as Windscribe counts them (1 Go = 1 024³ octets: its 10 Go are 10 Go here too), in French.
enum VPNFormat {
    static func size(_ bytes: Int64) -> String {
        let v = Double(max(0, bytes))
        let gib = 1_073_741_824.0
        let mib = 1_048_576.0
        if v >= gib * 0.95 { return Fmt.dec(v / gib) + " Go" }
        if v >= mib { return Fmt.int(v / mib) + " Mo" }
        if v >= 1024 { return Fmt.int(v / 1024) + " Ko" }
        return Fmt.int(Int(v)) + " o"
    }
}

/// The sentences more than one place says.
enum VPNText {
    static func unavailable(_ country: VPNCountry?) -> String {
        guard let country else { return "Ce pays n'est pas disponible pour l'instant : choisis-en un autre." }
        return "Windscribe n'a pas de serveur gratuit libre \(country.inName) pour l'instant : réessaie, ou choisis un autre pays."
    }

    static func windscribeSaid(_ message: String) -> String {
        "Windscribe a répondu : « \(message.trimmingCharacters(in: .whitespacesAndNewlines)) »"
    }

    static let buildAPlan = "Ils reviennent le mois prochain. Sans attendre : le Build-A-Plan de Windscribe, 2 pays et données illimitées dès 3 $ par mois."

    /// The page's title line for a phase (and `--dump`).
    static func headline(_ phase: VPNPhase, usage: VPNUsage?) -> String {
        switch phase {
        case .unknown: return "VPN"
        case .notInstalled: return "Windscribe n'est pas installé"
        case .closed, .ready: return "VPN coupé"
        case .starting: return "Windscribe démarre…"
        case .loggedOut: return "Connecte-toi à ton compte Windscribe"
        case .connecting(let country): return "Connexion" + (country.map { " " + $0.inName } ?? "") + "…"
        case .connected(let c): return c.place.isEmpty ? "Connecté" : "Connecté " + c.place
        case .disconnecting: return "Déconnexion…"
        case .outOfData: return "Tes " + (usage?.limit.map(VPNFormat.size) ?? "données") + " du mois sont épuisés"
        case .failed: return "La connexion n'a pas abouti"
        }
    }

    static func installHeadline(_ step: VPNInstallStep) -> String {
        switch step {
        case .brew, .downloading, .checking: return "Installation de Windscribe…"
        case .opened: return "Encore une étape dans l'installateur"
        case .failed: return "L'installation n'a pas abouti"
        }
    }

    /// One line under the title, or nil.
    static func detail(_ phase: VPNPhase, publicIP: String?) -> String? {
        switch phase {
        case .unknown, .starting, .disconnecting: return nil
        case .notInstalled: return "Le VPN gratuit et sans pub de Windscribe : 10 pays, dont la France."
        case .closed: return "Choisis un pays : Windscribe démarre en coulisses et te connecte."
        case .loggedOut: return "C'est gratuit : avec ton adresse e-mail confirmée, tu as 10 Go par mois."
        case .ready: return publicIP.map { "Ton adresse visible : " + $0 } ?? "Choisis un pays."
        case .connecting: return "Windscribe cherche un serveur gratuit."
        case .connected(let c):
            var parts = [c.city, c.proto, c.ip.map { "IP " + $0 }].compactMap { $0 }
            if c.testing { parts.append("tunnel en test") }
            if c.interference { parts.append("réseau perturbé") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .outOfData: return buildAPlan
        case .failed(let message): return message
        }
    }

    /// The switch of the menu bar panel.
    static func menuTitle(_ phase: VPNPhase) -> String {
        switch phase {
        case .connected(let c): return "VPN · " + (c.country?.name ?? c.city ?? "actif")
        case .connecting: return "VPN · connexion…"
        case .starting: return "VPN · démarrage…"
        case .disconnecting: return "VPN · coupure…"
        default: return "VPN · France"
        }
    }

    static func usageLine(_ u: VPNUsage) -> String {
        guard let limit = u.limit else { return VPNFormat.size(u.used) + " · illimité" }
        return VPNFormat.size(u.used) + " sur " + VPNFormat.size(limit)
    }
}
