import Foundation

// Pure parts of the ad blocker: the levels, the macOS profile that turns the filtering DNS on, the DNS messages
// used to measure it, and what counts as "blocked".
//
// Why a DNS profile and not /etc/hosts: the best lists (HaGeZi) block a domain with all its subdomains, which a hosts
// file cannot do. Measured on the traffic of six news and entertainment sites, hosts files stopped 41 to 51 % of the ad
// and tracker domains, the same lists applied by a filtering DNS 82 to 87 %, with nothing useful broken.

enum AdBlockLevel: String, Codable, CaseIterable, Identifiable {
    case balanced, maximal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: return "Équilibré"
        case .maximal: return "Maximal"
        }
    }

    /// The list applied by the resolver.
    var list: String {
        switch self {
        case .balanced: return "HaGeZi Pro"
        case .maximal: return "HaGeZi Pro++"
        }
    }

    var detail: String {
        switch self {
        case .balanced:
            return "Pubs, pisteurs, télémétrie et sites piégés. Laisse passer les quelques services de Google et Meta dont certains sites ont besoin."
        case .maximal:
            return "Tout ce qu'Équilibré bloque, plus les pisteurs de Google, Meta, Amazon… Un lien sponsorisé peut ne plus s'ouvrir : ajoute alors une exception."
        }
    }

    /// Control D's public resolver for this list (free, no account; it applies HaGeZi's lists as they are published).
    var serverURL: String { "https://freedns.controld.com/" + (self == .balanced ? "x-hagezi-pro" : "x-hagezi-proplus") }
}

/// The configuration profile macOS installs from System Settings: an encrypted DNS (DNS-over-HTTPS) setting for the
/// whole Mac, with the exceptions resolved by the network's own DNS instead.
enum AdBlockProfile {
    static let identifier = "fr.cleanmyclaude.adblock"
    static let payloadIdentifier = "fr.cleanmyclaude.adblock.dns"
    static let displayName = "Heartware · Bloqueur de pub"
    static let fileName = "Heartware - Bloqueur de pub.mobileconfig"
    /// Control D's addresses: the Mac reaches the resolver without asking another DNS first.
    static let serverAddresses = ["76.76.2.11", "2606:1a40::11"]

    /// Wi-Fi login pages (hotels, trains, planes) and the names of the local network (the box, a printer): always
    /// through the network's DNS, the only one that knows them.
    static let alwaysLocal = [
        "captive.apple.com", "detectportal.firefox.com", "neverssl.com", "wifi.sncf", "wifi.tgv-lyria.com", "wifi.tgvlyria.com",
        "freewlan.sbb.ch", "register.onboard.eurostar.com", "iceportal.de", "*.network-auth.com", "secure.datavalet.io",
        "login.cloud5.com", "guestinternet.com", "portal.mist.com", "wifi.inflightinternet.com", "inflight-wifi.com",
        "local", "home", "lan", "box", "internal", "home.arpa", "localdomain"
    ]

    /// Each exception with its subdomains ("exemple.fr" and "*.exemple.fr").
    static func neverConnect(exceptions: [String]) -> [String] {
        var out: [String] = []
        for d in alwaysLocal + exceptions {
            for v in d.hasPrefix("*.") ? [d] : [d, "*." + d] where !out.contains(v) { out.append(v) }
        }
        return out
    }

    static func dictionary(level: AdBlockLevel, exceptions: [String], uuid: UUID = UUID(), payloadUUID: UUID = UUID()) -> [String: Any] {
        let dns: [String: Any] = [
            "DNSSettings": [
                "DNSProtocol": "HTTPS",
                "ServerURL": level.serverURL,
                "ServerAddresses": serverAddresses
            ] as [String: Any],
            "OnDemandEnabled": 1,
            "OnDemandRules": [
                ["Action": "EvaluateConnection",
                 "ActionParameters": [["DomainAction": "NeverConnect", "Domains": neverConnect(exceptions: exceptions)] as [String: Any]]
                ] as [String: Any],
                ["Action": "Connect"]
            ],
            "PayloadDisplayName": "\(displayName) (\(level.title))",
            "PayloadDescription": "DNS chiffré qui applique la liste \(level.list).",
            "PayloadIdentifier": payloadIdentifier,
            "PayloadOrganization": "Heartware",
            "PayloadType": "com.apple.dnsSettings.managed",
            "PayloadUUID": payloadUUID.uuidString,
            "PayloadVersion": 1,
            "ProhibitDisablement": false
        ]
        return [
            "PayloadContent": [dns],
            "PayloadDescription": "Bloque les pubs, les pisteurs et les sites piégés pour tout le Mac, avec la liste \(level.list) appliquée par le DNS chiffré de Control D. Retire ce profil pour tout remettre comme avant.",
            "PayloadDisplayName": displayName,
            "PayloadIdentifier": identifier,
            "PayloadOrganization": "Heartware",
            "PayloadRemovalDisallowed": false,
            "PayloadScope": "System",
            "PayloadType": "Configuration",
            "PayloadUUID": uuid.uuidString,
            "PayloadVersion": 1
        ]
    }

    /// The .mobileconfig file itself (an XML property list).
    static func data(level: AdBlockLevel, exceptions: [String]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: dictionary(level: level, exceptions: exceptions), format: .xml, options: 0)
    }
}

enum AdBlockDomain {
    /// "https://www.Exemple.fr/page" → "exemple.fr" (the whole site, for an exception; `keepWWW` to check that very name);
    /// nil for anything that is not a domain name (an address, a word).
    static func normalize(_ raw: String, keepWWW: Bool = false) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let cut = s.firstIndex(where: { "/?#".contains($0) }) { s = String(s[..<cut]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.lastIndex(of: ":") { s = String(s[..<colon]) }
        while s.hasPrefix("*.") { s.removeFirst(2) }
        if s.hasSuffix(".") { s.removeLast() }
        if !keepWWW, s.hasPrefix("www."), s.dropFirst(4).contains(".") { s.removeFirst(4) }
        return isValid(s) ? s : nil
    }

    static func isValid(_ s: String) -> Bool {
        guard s.count <= 253, s.contains("."), !s.hasPrefix("."), !s.contains("..") else { return false }
        let labels = s.split(separator: ".")
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return false }
        guard s.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "." || $0 == "_" }) else { return false }
        // An IP address is not a domain.
        return !labels.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}

/// Blocked, reachable, no such name (NXDOMAIN: a dead domain, or a blocker that answers that way), or no answer.
enum AdBlockVerdict: String, Codable {
    case blocked, open, missing, unknown

    /// Unreachable all the same (the canary domains all exist: "missing" is a block there).
    var stopped: Bool { self == .blocked || self == .missing }
}

/// The domains a measurement looks at: ad and tracker domains seen on real sites, and sites that must keep working.
enum AdBlockCanary {
    static let ads = [
        "securepubads.g.doubleclick.net", "pagead2.googlesyndication.com", "googleads.g.doubleclick.net", "tpc.googlesyndication.com",
        "doubleclick.net", "www.googletagmanager.com", "www.google-analytics.com", "app-measurement.com", "c.amazon-adsystem.com",
        "aax.amazon-adsystem.com", "ib.adnxs.com", "static.criteo.net", "cdn.taboola.com", "trc.taboola.com", "widgets.outbrain.com",
        "sb.scorecardresearch.com", "analytics.tiktok.com", "ads.linkedin.com", "static.ads-twitter.com", "bat.bing.com",
        "match.adsrvr.org", "ads.pubmatic.com", "fastlane.rubiconproject.com", "cdn.id5-sync.com", "tags.crwdcntrl.net",
        "pixel.quantserve.com", "g2.gumgum.com", "api2.amplitude.com", "api-js.mixpanel.com", "boot.pbstck.com"
    ]
    static let useful = [
        "www.apple.com", "www.google.com", "www.youtube.com", "github.com", "www.wikipedia.org", "www.lemonde.fr",
        "www.leboncoin.fr", "www.amazon.fr", "claude.ai", "www.netflix.com"
    ]
    /// Blocked by both levels: shows the filter is on.
    static let both = "pagead2.googlesyndication.com"
    /// Blocked by Maximal only: tells the two levels apart.
    static let maximalOnly = "doubleclick.net"
    /// Always reachable: tells "blocked" from "no network".
    static let reachable = "www.apple.com"
}

/// The DNS messages of a measurement through the resolver itself (RFC 1035, sent over HTTPS as in RFC 8484).
enum AdBlockDNS {
    /// A query for the A (1) or AAAA (28) records of `name`.
    static func query(_ name: String, type: UInt16 = 1, id: UInt16 = 0) -> Data? {
        var d = Data()
        func u16(_ v: UInt16) { d.append(UInt8(v >> 8)); d.append(UInt8(v & 0xFF)) }
        u16(id); u16(0x0100); u16(1); u16(0); u16(0); u16(0)
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else { return nil }
            d.append(UInt8(bytes.count))
            d.append(contentsOf: bytes)
        }
        d.append(0)
        u16(type); u16(1)
        return d
    }

    /// The `dns` parameter of a DNS-over-HTTPS GET.
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The answer code and the A / AAAA addresses of a response; nil when it cannot be read.
    static func parse(_ data: Data) -> (rcode: Int, addresses: [String])? {
        let b = [UInt8](data)
        guard b.count >= 12 else { return nil }
        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        let rcode = Int(b[3] & 0x0F)
        let questions = u16(4), answers = u16(6)
        var i = 12
        func skipName() -> Bool {
            while i < b.count {
                let len = Int(b[i])
                if len == 0 { i += 1; return true }
                if len & 0xC0 == 0xC0 { i += 2; return i <= b.count }
                i += len + 1
            }
            return false
        }
        for _ in 0..<questions {
            guard skipName(), i + 4 <= b.count else { return nil }
            i += 4
        }
        var addresses: [String] = []
        for _ in 0..<answers {
            guard skipName(), i + 10 <= b.count else { break }
            let type = u16(i), length = u16(i + 8)
            i += 10
            guard i + length <= b.count else { break }
            if type == 1, length == 4 {
                addresses.append(b[i..<i + 4].map(String.init).joined(separator: "."))
            } else if type == 28, length == 16 {
                addresses.append(stride(from: i, to: i + 16, by: 2).map { String(u16($0), radix: 16) }.joined(separator: ":"))
            }
            i += length
        }
        return (rcode, addresses)
    }

    /// What a resolver's answer means: REFUSED, no address or only a "sinkhole" address is a block.
    static func verdict(rcode: Int, addresses: [String]) -> AdBlockVerdict {
        if rcode == 2 { return .unknown } // SERVFAIL: the resolver could not answer
        if rcode == 3 { return .missing }
        if rcode != 0 || addresses.isEmpty { return .blocked }
        return addresses.allSatisfy(isSinkhole) ? .blocked : .open
    }

    static func isSinkhole(_ ip: String) -> Bool {
        ["0.0.0.0", "127.0.0.1", "::", "::1", "0:0:0:0:0:0:0:0", "0:0:0:0:0:0:0:1"].contains(ip)
    }
}

/// One line of a measurement.
struct AdBlockProbe: Codable, Identifiable, Hashable {
    var domain: String
    var shouldBlock: Bool
    var verdict: AdBlockVerdict

    var id: String { domain }
    /// What was expected: an ad blocked, a useful site reachable.
    var good: Bool { shouldBlock ? verdict.stopped : verdict == .open }
}

/// A whole measurement: on this Mac, or through a level's resolver before installing it.
struct AdBlockMeasure: Codable, Equatable {
    var date: Date
    /// nil: through this Mac's resolver; a level: through that level's resolver.
    var level: AdBlockLevel?
    var probes: [AdBlockProbe]

    var ads: [AdBlockProbe] { probes.filter(\.shouldBlock) }
    var useful: [AdBlockProbe] { probes.filter { !$0.shouldBlock } }
    var blockedAds: Int { ads.filter(\.verdict.stopped).count }
    var brokenUseful: Int { useful.filter(\.verdict.stopped).count }
    /// No network: the useful sites did not answer either.
    var offline: Bool { !useful.isEmpty && useful.allSatisfy { $0.verdict != .open } }
    var share: Double { ads.isEmpty ? 0 : Double(blockedAds) / Double(ads.count) }
}

/// What this Mac's resolver does now.
enum AdBlockState: Equatable {
    case unknown, checking, off, offline
    /// Filtering: at the level the canaries point to (nil when they point to no level of ours).
    case on(AdBlockLevel?)

    var isOn: Bool { if case .on = self { return true } else { return false } }

    /// From the three canaries' verdicts: nothing can be said while a useful site does not answer.
    static func from(both: AdBlockVerdict, maximalOnly: AdBlockVerdict, reachable: AdBlockVerdict) -> AdBlockState {
        guard reachable == .open else { return .offline }
        guard both != .open else { return .off }
        return .on(maximalOnly == .open ? .balanced : .maximal)
    }
}

struct AdBlockSettings: Codable, Equatable {
    var level: AdBlockLevel = .maximal
    var exceptions: [String] = []
    /// What the profile last opened for installation holds (to tell when it must be installed again).
    var installedLevel: AdBlockLevel?
    var installedExceptions: [String]?
    var installedAt: Date?
    var lastMeasure: AdBlockMeasure?
}
