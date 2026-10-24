import Foundation
import AppKit
import CoreWLAN
import SystemConfiguration
import Darwin

// What the Network module reads from macOS, and the parsers of the tools it runs.
// Reading local state (interfaces, Wi-Fi, ports) never touches the network.

// MARK: - Units

enum NetworkFormat {
    /// Bits per second, the unit of internet plans ("312 Mbit/s").
    /// The thresholds sit half a unit lower: 999,6 Mbit/s rounds to "1 Gbit/s", not "1 000 Mbit/s".
    static func bits(_ bps: Double) -> String {
        if bps >= 999_500_000 { return Fmt.dec(bps / 1e9) + " Gbit/s" }
        if bps >= 999_500 { return Fmt.int(bps / 1e6) + " Mbit/s" }
        if bps >= 999.5 { return Fmt.int(bps / 1e3) + " kbit/s" }
        return Fmt.int(bps) + " bit/s"
    }

    static func ms(_ v: Double) -> String {
        v < 10 ? Fmt.dec(v) + " ms" : Fmt.int(v) + " ms"
    }
}

// MARK: - Speed test (networkQuality)

struct NetworkSpeedResult: Codable, Identifiable, Equatable {
    var id: Date { date }
    var date: Date
    /// Bits per second.
    var download: Double
    var upload: Double
    /// Round trips per minute while the line is busy (higher is better).
    var responsiveness: Double?
    /// Idle latency, in milliseconds.
    var baseRTT: Double?
    var interface: String?
    var server: String?

    enum Rating { case low, medium, high }

    var rating: Rating? {
        guard let r = responsiveness else { return nil }
        return NetworkSpeed.rating(rpm: r)
    }
}

enum NetworkSpeed {
    /// About 20 s on a good line, more when the line is slow: the progress bar aims a bit long.
    static let duration: TimeInterval = 25

    /// `networkQuality -c` prints one JSON object; anything around it (warnings) is ignored.
    static func parse(_ text: String, date: Date = Date()) -> Result<NetworkSpeedResult, NetworkFailure> {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let root = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else {
            return .failure(NetworkFailure(message: "Réponse de networkQuality illisible."))
        }
        func number(_ key: String) -> Double? { (root[key] as? NSNumber)?.doubleValue }
        guard let dl = number("dl_throughput") else {
            if let code = root["error_code"] as? Int {
                let offline = [-1009, -1004, -1001, -1003].contains(code)
                return .failure(NetworkFailure(message: offline ? "Pas de connexion à Internet." : "Le test a échoué (erreur \(code))."))
            }
            return .failure(NetworkFailure(message: "Le test n'a pas mesuré de débit."))
        }
        return .success(NetworkSpeedResult(date: date, download: dl, upload: number("ul_throughput") ?? 0,
                                           responsiveness: number("responsiveness"), baseRTT: number("base_rtt"),
                                           interface: root["interface_name"] as? String, server: root["test_endpoint"] as? String))
    }

    /// The low / medium / high scale networkQuality prints (516 RPM is "Medium").
    static func rating(rpm: Double) -> NetworkSpeedResult.Rating {
        rpm < 200 ? .low : (rpm < 1000 ? .medium : .high)
    }

    /// What a download speed is enough for.
    static func uses(download bps: Double) -> [(String, String, Bool)] {
        let mbps = bps / 1e6
        return [("envelope", "Mails et web", mbps >= 1), ("video", "Visio HD", mbps >= 4),
                ("play.tv", "Streaming 4K", mbps >= 25), ("arrow.down.circle", "Gros téléchargements", mbps >= 100)]
    }
}

/// An error to show as is.
struct NetworkFailure: Error, Equatable {
    let message: String
}

// MARK: - Ping

struct NetworkPingStats: Equatable {
    var samples: [Double] = []
    var sent = 0
    var received = 0
    var average: Double?
    var jitter: Double?

    var loss: Double { sent > 0 ? Double(sent - received) / Double(sent) : 0 }
}

enum NetworkPing {
    /// "64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=12.345 ms" → 12.345
    static func sample(_ line: String) -> Double? {
        guard let r = line.range(of: #"time[=<]([0-9]+(?:[.,][0-9]+)?) ms"#, options: .regularExpression) else { return nil }
        let value = line[r].drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." || $0 == "," }
        return Double(value.replacingOccurrences(of: ",", with: "."))
    }

    /// The closing lines of `ping`: packets sent and received, and "min/avg/max/stddev".
    static func summary(_ text: String, into stats: inout NetworkPingStats) {
        for line in text.split(whereSeparator: \.isNewline) {
            let l = String(line)
            if l.contains("packets transmitted") {
                let numbers = l.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if numbers.count >= 2 {
                    stats.sent = numbers[0]
                    stats.received = numbers[1]
                }
            } else if l.contains("min/avg/max"), let eq = l.firstIndex(of: "=") {
                let values = l[l.index(after: eq)...].replacingOccurrences(of: "ms", with: "")
                    .split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }
                if values.count >= 4 {
                    stats.average = values[1]
                    stats.jitter = values[3]
                }
            }
        }
        if stats.average == nil, !stats.samples.isEmpty {
            stats.average = stats.samples.reduce(0, +) / Double(stats.samples.count)
        }
    }
}

// MARK: - Open ports (lsof)

struct NetworkPort: Identifiable, Equatable {
    var id: String { "\(pid)-\(port)" }
    let port: Int
    let pid: Int32
    let process: String
    var user: String?
    /// Addresses it listens on ("*", "127.0.0.1", "[::1]"…).
    var addresses: [String]
    /// The app bundle the process belongs to (helpers included).
    var appPath: String?
    var executable: String?

    /// Reachable from other devices of the network, not only from this Mac.
    var isExposed: Bool { addresses.contains { !NetworkPorts.isLoopback($0) } }
    var isMine: Bool { user == nil || user == NetworkPorts.currentUser }
    /// Part of macOS (AirPlay, Handoff…) or run by another user: nothing to stop from here.
    var isSystem: Bool {
        guard isMine else { return true }
        guard let e = executable, !e.hasPrefix("/usr/local/") else { return false }
        return ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"].contains { e.hasPrefix($0) }
    }
    var appName: String? { appPath.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") } }
    var displayName: String { appName ?? process }
}

enum NetworkPorts {
    static let arguments = ["-iTCP", "-sTCP:LISTEN", "-nP", "-F", "pcnL"]

    static var currentUser: String { DemoData.isEnabled ? (DemoData.home as NSString).lastPathComponent : NSUserName() }

    /// "*" means every interface of this Mac.
    static func describe(address: String) -> String {
        address == "*" ? "toutes les adresses" : address
    }

    /// `lsof -F pcnL` output: one field per line ("p123", "cname", "Luser", "f12", "n*:8080").
    /// IPv4 and IPv6 sockets of the same port are merged.
    static func parse(_ text: String) -> [NetworkPort] {
        var out: [String: NetworkPort] = [:]
        var order: [String] = []
        var pid: Int32 = 0
        var command = "", user: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            guard let tag = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value) ?? 0
                command = ""
                user = nil
            case "c": command = value
            case "L": user = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = String(value[..<colon])
                let key = "\(pid)-\(port)"
                if var p = out[key] {
                    if !p.addresses.contains(address) { p.addresses.append(address) }
                    out[key] = p
                } else {
                    out[key] = NetworkPort(port: port, pid: pid, process: command, user: user, addresses: [address])
                    order.append(key)
                }
            default: break
            }
        }
        return order.compactMap { out[$0] }.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    static func isLoopback(_ address: String) -> Bool {
        let a = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return a.hasPrefix("127.") || a == "::1" || a == "localhost" || a.hasPrefix("::ffff:127.")
    }

    /// The outermost app bundle in an executable path (".../Code.app/Contents/Frameworks/Code Helper.app/..." → Code.app).
    static func appBundle(inPath path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Lists listening TCP ports. `admin` asks macOS for the password to also see root services.
    static func scan(admin: Bool = false) -> Result<[NetworkPort], NetworkFailure> {
        let r: Shell.Output
        if admin {
            r = Shell.runAsAdmin("/usr/sbin/lsof " + arguments.joined(separator: " "))
        } else {
            r = Shell.run("/usr/sbin/lsof", arguments, timeout: 20)
        }
        // lsof answers 1 when nothing listens.
        guard r.ok || (r.status == 1 && r.err.isEmpty) else {
            return .failure(NetworkFailure(message: r.err.isEmpty ? "lsof a échoué." : r.err))
        }
        var ports = parse(r.out)
        for i in ports.indices {
            ports[i].executable = executablePath(ports[i].pid)
            ports[i].appPath = ports[i].executable.flatMap(appBundle(inPath:))
        }
        return .success(ports)
    }

    /// What a well-known process does, in plain words.
    static func describe(_ p: NetworkPort) -> String? {
        let known: [String: String] = [
            "rapportd": "Continuité et Handoff entre tes appareils Apple", "ControlCenter": "Récepteur AirPlay",
            "sharingd": "AirDrop et partage", "mDNSResponder": "Bonjour : découverte des appareils du réseau",
            "launchd": "Service système lancé à la demande", "screensharingd": "Partage d'écran", "sshd": "Connexion à distance (SSH)",
            "smbd": "Partage de fichiers", "cupsd": "Impression", "remoted": "Service système d'Apple", "netbiosd": "Partage Windows (NetBIOS)",
            "node": "Node.js (serveur de dév)", "Python": "Python", "python3": "Python", "java": "Java",
            "ruby": "Ruby", "php": "PHP", "mysqld": "Base de données MySQL", "postgres": "Base de données PostgreSQL",
            "redis-server": "Base Redis", "mongod": "Base MongoDB", "nginx": "Serveur web nginx", "httpd": "Serveur web Apache",
            "com.docker.backend": "Docker", "docker": "Docker", "mailpit": "Boîte mail de test", "ollama": "Ollama (modèles d'IA en local)"
        ]
        if let d = known[p.process] { return d }
        if p.process.lowercased().hasPrefix("python") { return "Python" }
        return nil
    }
}

// MARK: - Addresses

struct NetworkInterface: Identifiable, Equatable {
    var id: String { bsdName }
    let bsdName: String
    var displayName: String
    var ipv4: [String] = []
    var ipv6: [String] = []
    var isPrimary = false

    /// The address to show: IPv4 first, unless IPv6 is asked for.
    func address(preferringIPv6 v6: Bool = false) -> String? {
        v6 ? (ipv6.first ?? ipv4.first) : (ipv4.first ?? ipv6.first)
    }
}

struct NetworkAddresses: Equatable {
    var interfaces: [NetworkInterface] = []
    var router: String?
    var dns: [String] = []
    var searchDomains: [String] = []

    var primary: NetworkInterface? { interfaces.first(where: \.isPrimary) ?? interfaces.first }
    var localIP: String? { primary?.ipv4.first ?? primary?.ipv6.first }
}

enum NetworkLocal {
    /// IP addresses per interface (getifaddrs), default router and DNS (System Configuration). Fast: no process, no network.
    static func read() -> NetworkAddresses {
        if DemoData.isEnabled { return NetworkDemo.addresses }
        var result = NetworkAddresses()
        var global: [String: Any] = [:]
        if let store = SCDynamicStoreCreate(nil, "Heartware" as CFString, nil, nil) {
            global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] ?? [:]
            let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] ?? [:]
            result.router = global["Router"] as? String
            result.dns = dns["ServerAddresses"] as? [String] ?? []
            result.searchDomains = dns["SearchDomains"] as? [String] ?? []
        }
        let primary = global["PrimaryInterface"] as? String
        var names: [String: String] = [:]
        for i in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            if let bsd = SCNetworkInterfaceGetBSDName(i) as String?, let name = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? {
                names[bsd] = name
            }
        }
        var byName: [String: NetworkInterface] = [:]
        var order: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = p.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let bsd = String(cString: p.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            if byName[bsd] == nil {
                byName[bsd] = NetworkInterface(bsdName: bsd, displayName: names[bsd] ?? friendlyName(bsd), isPrimary: bsd == primary)
                order.append(bsd)
            }
            if family == AF_INET {
                byName[bsd]?.ipv4.append(address)
            } else if !address.lowercased().hasPrefix("fe80") {
                // Link-local addresses are the same kind on every Mac: only routable ones are shown.
                byName[bsd]?.ipv6.append(address)
            }
        }
        // Tunnels and Apple's private links (awdl, llw…) only matter when they carry IPv4 (a VPN).
        result.interfaces = order.compactMap { byName[$0] }.filter { i in
            if i.ipv4.isEmpty && i.ipv6.isEmpty { return false }
            let system = ["utun", "awdl", "llw", "anpi", "ipsec", "gif", "stf", "ap"].contains { i.bsdName.hasPrefix($0) }
            return !system || !i.ipv4.isEmpty
        }
        .sorted { ($0.isPrimary ? 0 : 1, $0.bsdName) < ($1.isPrimary ? 0 : 1, $1.bsdName) }
        return result
    }

    static func friendlyName(_ bsd: String) -> String {
        if bsd.hasPrefix("utun") || bsd.hasPrefix("ipsec") { return "VPN" }
        if bsd.hasPrefix("bridge") { return "Pont réseau" }
        if bsd.hasPrefix("en") { return "Ethernet" }
        return bsd
    }
}

// MARK: - Wi-Fi

struct NetworkWiFi: Equatable {
    var interface: String
    var powerOn: Bool
    /// nil when macOS hides it (location not allowed) or when not connected.
    var ssid: String?
    var connected: Bool
    var rssi: Int
    var noise: Int
    var channel: Int?
    /// 2.4, 5 or 6 (GHz).
    var band: String?
    /// MHz.
    var width: Int?
    /// Mbit/s.
    var txRate: Double
    var security: String
    var phy: String
    var country: String?

    var snr: Int { rssi - noise }

    /// 0…1, for the signal gauge (-90 dBm → 0, -40 dBm → 1).
    var signalFraction: Double { min(1, max(0, Double(rssi + 90) / 50)) }

    var signalLabel: String { NetworkWiFi.label(rssi: rssi) }

    static func label(rssi: Int) -> String {
        switch rssi {
        case (-50)...: return "Excellent"
        case (-60)...: return "Très bon"
        case (-67)...: return "Bon"
        case (-75)...: return "Moyen"
        default: return "Faible"
        }
    }

    static func read() -> NetworkWiFi? {
        if DemoData.isEnabled { return NetworkDemo.wifi }
        guard let i = CWWiFiClient.shared().interface() else { return nil }
        let ch = i.wlanChannel()
        let band: String? = switch ch?.channelBand.rawValue ?? 0 {
        case 1: "2,4"
        case 2: "5"
        case 3: "6"
        default: nil
        }
        let width: Int? = switch ch?.channelWidth.rawValue ?? 0 {
        case 1: 20
        case 2: 40
        case 3: 80
        case 4: 160
        case 5: 320
        default: nil
        }
        let rssi = i.rssiValue()
        return NetworkWiFi(interface: i.interfaceName ?? "en0", powerOn: i.powerOn(), ssid: i.ssid(),
                           connected: i.powerOn() && rssi != 0, rssi: rssi, noise: i.noiseMeasurement(),
                           channel: ch.map { $0.channelNumber }, band: band, width: width, txRate: i.transmitRate(),
                           security: security(i.security().rawValue), phy: phy(i.activePHYMode().rawValue), country: i.countryCode())
    }

    /// CWSecurity raw values (stable across SDKs).
    static func security(_ raw: Int) -> String {
        switch raw {
        case 0: return "Ouvert (aucun chiffrement)"
        case 1, 6: return "WEP (obsolète)"
        case 2, 3: return "WPA Personnel"
        case 4: return "WPA2 Personnel"
        case 5: return "WPA/WPA2 Personnel"
        case 7, 8: return "WPA Entreprise"
        case 9, 10: return "WPA2 Entreprise"
        case 11: return "WPA3 Personnel"
        case 12: return "WPA3 Entreprise"
        case 13: return "WPA2/WPA3 Personnel"
        case 14, 15: return "Wi-Fi amélioré (OWE)"
        default: return "Inconnue"
        }
    }

    /// CWPHYMode raw values.
    static func phy(_ raw: Int) -> String {
        switch raw {
        case 1: return "802.11a"
        case 2: return "802.11b"
        case 3: return "802.11g"
        case 4: return "Wi-Fi 4 (802.11n)"
        case 5: return "Wi-Fi 5 (802.11ac)"
        case 6: return "Wi-Fi 6 (802.11ax)"
        case 7: return "Wi-Fi 7 (802.11be)"
        default: return "—"
        }
    }
}

// MARK: - Live output

/// Collects lines written by a background process and hands them to the main thread at most 4 times a second.
final class NetworkLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var scheduled = false
    private let deliver: @MainActor ([String]) -> Void

    init(deliver: @escaping @MainActor ([String]) -> Void) {
        self.deliver = deliver
    }

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
                MainActor.assumeIsolated { flush() }
            }
        }
    }

    @MainActor
    func flush() {
        lock.lock()
        let out = lines
        lines = []
        scheduled = false
        lock.unlock()
        if !out.isEmpty { deliver(out) }
    }
}
