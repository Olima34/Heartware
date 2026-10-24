import Foundation

/// `--selftest` for the signature engine: small rules for each construct of the language, then Apple's own rules
/// against samples built in memory from their strings (nothing is written to the disk).
enum ProtectionYaraChecks {
    static func run() -> [String] {
        var f: [String] = []
        let macho: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe] + [UInt8](repeating: 0, count: 28)
        func data(_ parts: [UInt8]...) -> Data { Data(parts.flatMap { $0 }) }
        func t(_ s: String) -> [UInt8] { Array(s.utf8) }

        let source = #"""
        import "hash"
        private rule Macho { condition: uint32(0) == 0xfeedfacf or uint32(0) == 0xcffaedfe }
        rule text_all { strings: $a = "curl -fsSL" $b = "osascript" condition: Macho and all of them }
        rule text_nocase { strings: $a = "EvilDomain" nocase condition: $a and filesize < 1KB }
        rule text_wide { strings: $a = "secret" wide condition: $a }
        rule text_fullword { strings: $a = "bin" fullword condition: #a == 1 }
        rule hex_jump { strings: $a = { 41 42 [2-4] 43 44 } condition: $a }
        rule hex_alt { strings: $a = { 90 ( 11 22 | 33 44 55 ) 66 } condition: $a }
        rule hex_mask { strings: $a = { 4? 8B ?5 C3 } condition: $a at 4 }
        rule hex_not { strings: $a = { 01 ~02 03 } condition: $a }
        rule xor_one { strings: $a = "payload" xor(1-255) condition: $a }
        rule b64 { strings: $a = "hello world" base64 condition: $a }
        rule count_offset { strings: $a = "XY" condition: #a == 3 and @a[2] == 10 and !a[1] == 2 }
        rule in_range { strings: $a = "ZZ" condition: $a in (0..5) and not $a in (6..100) }
        rule percent { strings: $a = "p1" $b = "p2" $c = "p3" $d = "p4" condition: 50% of them }
        rule for_of { strings: $h1 = "MZ" $h2 = "PK" condition: for any of ($h*) : ( $ at 0 ) }
        rule for_in { strings: $a = "ab" condition: for all i in (1..#a) : ( @a[i] % 2 == 0 ) }
        rule be_read { condition: uint32be(0) == 0x78617221 and uint16(filesize - 2) == 0x0a0d }
        rule hash_rule { condition: hash.md5(0, filesize) == "5d41402abc4b2a76b9719d911017c592" }
        rule regex_rule { strings: $a = /https:\/\/[a-z]{3,7}\.pages\.dev/ condition: $a }
        rule rule_ref { condition: text_all and not text_wide }
        rule arith { condition: (filesize \ 2) * 2 + filesize % 2 == filesize and (0xF0 & 0x3C) == 0x30 and (1 << 4) == 16 }
        """#
        let set = ProtectionYaraRuleset(source: source)
        if !set.skipped.isEmpty { f.append("Règles d'essai ignorées : \(set.skipped.joined(separator: ", "))") }
        func expect(_ rule: String, _ d: Data, _ match: Bool) {
            let hit = set.scan(d).contains { $0.name == rule }
            if hit != match { f.append("Signature « \(rule) » : \(match ? "non reconnue" : "reconnue à tort")") }
        }
        expect("text_all", data(macho, t("x curl -fsSL y osascript")), true)
        expect("text_all", data(t("abcd curl -fsSL osascript")), false)
        expect("text_nocase", data(t("..eViLdOmAiN..")), true)
        expect("text_nocase", data(t("..eViLdOmAiN.."), [UInt8](repeating: 0, count: 2000)), false)
        expect("text_wide", data(t("s\0e\0c\0r\0e\0t\0")), true)
        expect("text_wide", data(t("secret")), false)
        expect("text_fullword", data(t("/usr/bin/ls cabin binary")), true)
        expect("text_fullword", data(t("/usr/bin/ls /bin/sh")), false)
        expect("hex_jump", data([0x41, 0x42, 0, 0, 0, 0x43, 0x44]), true)
        expect("hex_jump", data([0x41, 0x42, 0, 0x43, 0x44]), false)
        expect("hex_alt", data([0x90, 0x33, 0x44, 0x55, 0x66]), true)
        expect("hex_alt", data([0x90, 0x11, 0x44, 0x55, 0x66]), false)
        expect("hex_mask", data([0, 0, 0, 0, 0x47, 0x8B, 0x15, 0xC3]), true)
        expect("hex_mask", data([0, 0, 0, 0x47, 0x8B, 0x15, 0xC3]), false)
        expect("hex_not", data([0x01, 0x07, 0x03]), true)
        expect("hex_not", data([0x01, 0x02, 0x03]), false)
        expect("xor_one", data(t("payload").map { $0 ^ 0x5A }), true)
        expect("xor_one", data(t("payload")), false)
        expect("b64", data(t("x" + Data("say hello world!".utf8).base64EncodedString())), true)
        expect("b64", data(t("hello world")), false)
        expect("count_offset", data(t("XY........XYXY")), true)
        expect("count_offset", data(t("XY.XY.XY")), false)
        expect("in_range", data(t("..ZZ....")), true)
        expect("in_range", data(t("..ZZ....ZZ")), false)
        expect("percent", data(t("p1 p3")), true)
        expect("percent", data(t("p1")), false)
        expect("for_of", data(t("PK\u{3}\u{4} MZ")), true)
        expect("for_of", data(t(" PK MZ")), false)
        expect("for_in", data(t("ab..ab")), true)
        expect("for_in", data(t(".ab")), false)
        expect("be_read", data(t("xar!...\r\n")), true)
        expect("be_read", data(t("xar!...\n")), false)
        expect("hash_rule", data(t("hello")), true)
        expect("hash_rule", data(t("hellO")), false)
        expect("regex_rule", data(t("get https://abcd.pages.dev/x")), true)
        expect("regex_rule", data(t("get https://abcdefghij.pages.dev/x")), false)
        expect("rule_ref", data(macho, t("curl -fsSL osascript")), true)
        expect("arith", data(t("odd")), true)
        if set.scan(Data()).count > 0 { f.append("Un fichier vide reconnu par une signature") }

        // A file the size of a big app, with no signature in it: scanned within the time budget, nothing found.
        var noise = [UInt8](repeating: 0, count: 8 << 20)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in noise.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            noise[i] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        // (Only the rules with long enough strings: three bytes show up by chance in 8 Mo.)
        let strong: Set<String> = ["text_all", "text_nocase", "text_wide", "xor_one", "b64", "regex_rule", "hash_rule", "rule_ref"]
        if let hit = set.scan(Data(noise)).first(where: { strong.contains($0.name) }) { f.append("Bruit aléatoire reconnu par « \(hit.name) »") }
        return f + apple()
    }

    /// Apple's rules on samples made from their own strings: a Mach-O header, then each string once.
    /// Only rules this recipe can satisfy count (no regex, no offsets, no file size floor); almost all of them must match.
    static func apple() -> [String] {
        guard !DemoData.isEnabled, let sig = ProtectionSignatures.load() else { return [] }
        let (tried, missed) = synthesize(sig.binary)
        guard tried > 50 else { return ["Signatures XProtect : trop peu de règles testables (\(tried))"] }
        if Double(missed.count) / Double(tried) > 0.05 {
            return ["Signatures XProtect : \(missed.count) sur \(tried) non reconnues sur leur propre échantillon (\(missed.prefix(6).joined(separator: ", ")))"]
        }
        return []
    }

    /// For each public rule: a buffer holding its strings; returns how many rules were tried and which did not match.
    static func synthesize(_ set: ProtectionYaraRuleset) -> (tried: Int, missed: [String]) {
        var tried = 0
        var missed: [String] = []
        for rule in set.rules where !rule.isPrivate && !rule.strings.isEmpty {
            guard simple(rule.condition, set.rules) == true else { continue }
            var buffer: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 0x01] + [UInt8](repeating: 0, count: 56)
            var ok = true
            for s in rule.strings {
                guard let bytes = s.variants.first.flatMap(concrete) else { ok = false; break }
                buffer += [0x0A] + bytes + [0x0A]
            }
            guard ok else { continue }
            tried += 1
            if !set.scan(Data(buffer)).contains(where: { $0.name == rule.name }) { missed.append(rule.name) }
        }
        return (tried, missed)
    }

    /// True for a condition a buffer of strings satisfies: Mach-O, file size ceilings, string presence and counts of them.
    private static func simple(_ e: ProtectionYaraExpr, _ rules: [ProtectionYaraRule]) -> Bool? {
        switch e {
        case .and(let t): return t.allSatisfy { simple($0, rules) == true } ? true : nil
        case .or(let t): return t.contains { simple($0, rules) == true } ? true : nil
        case .rule(let i): return rules[i].name == "Macho" ? true : nil
        case .found(let ref): return ref != nil ? true : nil
        case .of(let q, _):
            if case .none = q { return nil }
            return true
        case .binary(let op, .filesize, .const(.int(let n))): return (op == "<" || op == "<=") && n > 4096 ? true : nil
        default: return nil
        }
    }

    /// One concrete byte sequence the variant matches: masked nibbles from the pattern, jumps at their shortest,
    /// the first alternative.
    private static func concrete(_ v: ProtectionYaraVariant) -> [UInt8]? {
        switch v.body {
        case .bytes(let b, _): return b
        case .regex: return nil
        case .hex(let nodes):
            func flat(_ n: [ProtectionYaraHex]) -> [UInt8] {
                n.flatMap { node -> [UInt8] in
                    switch node {
                    case .byte(let b, let mask, let negated): return [negated ? (b & mask) ^ 0xFF : b & mask]
                    case .jump(let lo, _): return [UInt8](repeating: 0x41, count: lo)
                    case .alt(let alts): return flat(alts[0])
                    }
                }
            }
            return flat(nodes)
        }
    }
}
