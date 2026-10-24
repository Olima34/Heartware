import Foundation

// A YARA interpreter limited to what Apple's own malware signatures use (XProtect.yara, XPScripts.yr, shipped and updated
// by macOS in the XProtect bundle). A rule using anything else (other modules, regex in conditions…) is skipped: it can
// never match, so an unsupported construct costs a missed detection, never a false alarm.

/// A value in a condition: an integer (booleans are 0 and 1), a string (a hash) or undefined
/// (a read past the end of the file, the offset of a match that does not exist…).
enum ProtectionYaraValue: Equatable {
    case int(Int64)
    case str(String)
    case undef

    var truthy: Bool {
        switch self {
        case .int(let v): return v != 0
        case .str(let s): return !s.isEmpty
        case .undef: return false
        }
    }

    var int: Int64? {
        if case .int(let v) = self { return v }
        return nil
    }
}

enum ProtectionYaraQuantifier {
    case any, all, none
    case count(ProtectionYaraExpr)
    case percent(ProtectionYaraExpr)
}

enum ProtectionYaraIterable {
    case range(ProtectionYaraExpr, ProtectionYaraExpr)
    case list([ProtectionYaraExpr])
}

/// A condition. String references are indices in the rule's strings; nil is `$` inside `for … of`.
indirect enum ProtectionYaraExpr {
    case const(ProtectionYaraValue)
    case filesize
    case and([ProtectionYaraExpr])
    case or([ProtectionYaraExpr])
    case not(ProtectionYaraExpr)
    case binary(String, ProtectionYaraExpr, ProtectionYaraExpr)
    case unary(String, ProtectionYaraExpr)
    case read(bytes: Int, signed: Bool, bigEndian: Bool, ProtectionYaraExpr)
    case found(Int?)
    case foundAt(Int?, ProtectionYaraExpr)
    case foundIn(Int?, ProtectionYaraExpr, ProtectionYaraExpr)
    case count(Int?)
    case countIn(Int?, ProtectionYaraExpr, ProtectionYaraExpr)
    case offset(Int?, ProtectionYaraExpr)
    case length(Int?, ProtectionYaraExpr)
    case of(ProtectionYaraQuantifier, [Int])
    case forOf(ProtectionYaraQuantifier, [Int], ProtectionYaraExpr)
    case forIn(ProtectionYaraQuantifier, slot: Int, ProtectionYaraIterable, ProtectionYaraExpr)
    case variable(Int)
    case rule(Int)
    case hash(String, ProtectionYaraExpr, ProtectionYaraExpr)
}

/// One element of a hex string: a byte (with a mask for `?` nibbles, or negated with `~`), a jump `[n-m]`
/// or alternatives `( … | … )`.
indirect enum ProtectionYaraHex {
    case byte(UInt8, mask: UInt8, negated: Bool)
    case jump(Int, Int)
    case alt([[ProtectionYaraHex]])

    var minLength: Int {
        switch self {
        case .byte: return 1
        case .jump(let lo, _): return lo
        case .alt(let alts): return alts.map { $0.reduce(0) { $0 + $1.minLength } }.min() ?? 0
        }
    }

    var maxLength: Int {
        switch self {
        case .byte: return 1
        case .jump(_, let hi): return hi
        case .alt(let alts): return alts.map { $0.reduce(0) { $0 + $1.maxLength } }.max() ?? 0
        }
    }

    var isFixedByte: Bool {
        if case .byte(_, let mask, let negated) = self { return mask == 0xFF && !negated }
        return false
    }
}

/// One way a string may appear in a file (ascii and wide, each xor key, each base64 alignment are separate variants).
struct ProtectionYaraVariant {
    enum Body {
        case bytes([UInt8], nocase: Bool)
        case hex([ProtectionYaraHex])
        case regex(NSRegularExpression)
    }

    var body: Body
    var wide: Bool
    /// Runs of bytes every match holds at a fixed distance from its start: the ruleset picks in them the "atom"
    /// the file is searched for, all strings in one pass.
    var runs: [(bytes: [UInt8], offset: Int)] = []
    /// Single fixed bytes at a fixed distance from the start: without a run, the rarest one is looked for with memchr.
    var singles: [(byte: UInt8, offset: Int)] = []
}

struct ProtectionYaraString {
    var name: String
    var variants: [ProtectionYaraVariant]
    var fullword: Bool
}

struct ProtectionYaraRule {
    var name: String
    var isPrivate: Bool
    var isGlobal: Bool
    var meta: [String: String]
    var strings: [ProtectionYaraString]
    var condition: ProtectionYaraExpr
    /// Number of loop variables the condition uses.
    var slots: Int

    /// What XProtect calls the detection ("MACOS.644e18d", "OSX.Bundlore.D"…).
    var detection: String { meta["description"].flatMap { $0.isEmpty ? nil : $0 } ?? name }
}

// MARK: - Parser

/// Reads YARA source. `parse` returns the rules it understood and the names of the ones it skipped.
struct ProtectionYaraParser {
    enum Failure: Error { case syntax(String) }

    private enum Tok: Equatable {
        case ident(String)
        case sid(String)
        case cnt(String)
        case off(String)
        case len(String)
        case num(Int64)
        case text([UInt8])
        case sym(String)
        case eof
    }

    private let src: [UInt8]
    private var pos = 0
    private var peeked: [(Tok, Int)] = []

    // Per rule.
    private var ruleIndex: [String: Int] = [:]
    private var stringNames: [String] = []
    private var scopes: [String: Int] = [:]
    private var slotCount = 0
    private var inForOf = false

    init(_ source: String) {
        src = Array(source.utf8)
    }

    static func parse(_ source: String) -> (rules: [ProtectionYaraRule], skipped: [String]) {
        var p = ProtectionYaraParser(source)
        return p.parseFile()
    }

    private mutating func parseFile() -> (rules: [ProtectionYaraRule], skipped: [String]) {
        var rules: [ProtectionYaraRule] = []
        var skipped: [String] = []
        while true {
            peeked = []
            skipSpace()
            guard pos < src.count else { break }
            let start = pos
            do {
                guard let rule = try parseTopLevel() else { continue }
                ruleIndex[rule.name] = rules.count
                rules.append(rule)
            } catch {
                // Skip to the end of this rule: the next line that starts a rule.
                pos = start
                let name = ruleName(at: start)
                skipped.append(name)
                // A global rule restricts every other one: without it they could all match too much.
                if String(decoding: src[start..<min(src.count, start + 200)], as: UTF8.self)
                    .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).prefix(3).contains("global") {
                    return ([], skipped + rules.map(\.name))
                }
                skipRule()
            }
        }
        return (rules, skipped)
    }

    private func ruleName(at start: Int) -> String {
        var p = ProtectionYaraParser(String(decoding: src[start..<min(src.count, start + 300)], as: UTF8.self))
        while case .ident(let w) = (try? p.next()) ?? .eof {
            if w == "rule", case .ident(let n) = (try? p.next()) ?? .eof { return n }
        }
        return "?"
    }

    /// Moves past the rule starting at `pos`: to its closing brace, counting the braces of hex strings.
    private mutating func skipRule() {
        var depth = 0
        var opened = false
        while pos < src.count {
            let c = src[pos]
            if c == UInt8(ascii: "\"") {
                pos += 1
                while pos < src.count, src[pos] != UInt8(ascii: "\"") {
                    if src[pos] == UInt8(ascii: "\\") { pos += 1 }
                    pos += 1
                }
            } else if c == UInt8(ascii: "/"), pos + 1 < src.count, src[pos + 1] == UInt8(ascii: "/") {
                while pos < src.count, src[pos] != 0x0A { pos += 1 }
            } else if c == UInt8(ascii: "/"), pos + 1 < src.count, src[pos + 1] == UInt8(ascii: "*") {
                pos += 2
                while pos + 1 < src.count, !(src[pos] == UInt8(ascii: "*") && src[pos + 1] == UInt8(ascii: "/")) { pos += 1 }
                pos += 1
            } else if c == UInt8(ascii: "{") {
                depth += 1
                opened = true
            } else if c == UInt8(ascii: "}") {
                depth -= 1
                if opened, depth == 0 {
                    pos += 1
                    return
                }
            }
            pos += 1
        }
    }

    // MARK: Top level

    private mutating func parseTopLevel() throws -> ProtectionYaraRule? {
        var isPrivate = false, isGlobal = false
        while true {
            let t = try next()
            switch t {
            case .ident("import"), .ident("include"):
                guard case .text = try next() else { throw Failure.syntax("import") }
                return nil
            case .ident("private"): isPrivate = true
            case .ident("global"): isGlobal = true
            case .ident("rule"): return try parseRule(isPrivate: isPrivate, isGlobal: isGlobal)
            case .eof: return nil
            default: throw Failure.syntax("début de règle")
            }
        }
    }

    private mutating func parseRule(isPrivate: Bool, isGlobal: Bool) throws -> ProtectionYaraRule {
        guard case .ident(let name) = try next() else { throw Failure.syntax("nom") }
        if try peek() == .sym(":") {
            _ = try next()
            while case .ident = try peek() { _ = try next() }
        }
        try expect(.sym("{"))
        stringNames = []
        scopes = [:]
        slotCount = 0
        inForOf = false
        var meta: [String: String] = [:]
        var strings: [ProtectionYaraString] = []
        var condition: ProtectionYaraExpr?
        while true {
            let t = try next()
            switch t {
            case .ident("meta"):
                try expect(.sym(":"))
                while case .ident(let key) = try peek(), try peek(1) == .sym("=") {
                    _ = try next()
                    _ = try next()
                    switch try next() {
                    case .text(let v): meta[key] = String(decoding: v, as: UTF8.self)
                    case .num(let n): meta[key] = String(n)
                    case .ident(let w) where w == "true" || w == "false": meta[key] = w
                    case .sym("-"):
                        guard case .num(let n) = try next() else { throw Failure.syntax("meta") }
                        meta[key] = String(-n)
                    default: throw Failure.syntax("meta")
                    }
                }
            case .ident("strings"):
                try expect(.sym(":"))
                while case .sid(let sname) = try peek() {
                    _ = try next()
                    try expect(.sym("="))
                    let s = try parseStringDefinition(name: sname.isEmpty ? "$#\(strings.count)" : sname)
                    stringNames.append(s.name)
                    strings.append(s)
                }
            case .ident("condition"):
                try expect(.sym(":"))
                condition = try parseExpr()
                try expect(.sym("}"))
                guard let condition else { throw Failure.syntax("condition") }
                return ProtectionYaraRule(name: name, isPrivate: isPrivate, isGlobal: isGlobal, meta: meta, strings: strings,
                                          condition: condition, slots: slotCount)
            default:
                throw Failure.syntax("section")
            }
        }
    }

    // MARK: Strings

    private mutating func parseStringDefinition(name: String) throws -> ProtectionYaraString {
        peeked = []
        skipSpace()
        guard pos < src.count else { throw Failure.syntax("chaîne") }
        let c = src[pos]
        var variants: [ProtectionYaraVariant] = []
        var fullword = false
        if c == UInt8(ascii: "{") {
            pos += 1
            var raw: [UInt8] = []
            while pos < src.count, src[pos] != UInt8(ascii: "}") {
                if src[pos] == UInt8(ascii: "/"), pos + 1 < src.count, src[pos + 1] == UInt8(ascii: "/") {
                    while pos < src.count, src[pos] != 0x0A { pos += 1 }
                    continue
                }
                if src[pos] == UInt8(ascii: "/"), pos + 1 < src.count, src[pos + 1] == UInt8(ascii: "*") {
                    pos += 2
                    while pos + 1 < src.count, !(src[pos] == UInt8(ascii: "*") && src[pos + 1] == UInt8(ascii: "/")) { pos += 1 }
                    pos += 2
                    continue
                }
                raw.append(src[pos])
                pos += 1
            }
            guard pos < src.count else { throw Failure.syntax("hex") }
            pos += 1
            let nodes = try ProtectionYaraParser.parseHex(raw)
            // Modifiers on hex strings: only `private` exists.
            while case .ident("private") = try peek() { _ = try next() }
            for expanded in ProtectionYaraAtoms.expandLeading(nodes) {
                let parts = ProtectionYaraAtoms.fixedParts(expanded)
                variants.append(ProtectionYaraVariant(body: .hex(expanded), wide: false, runs: parts.runs, singles: parts.singles))
            }
        } else if c == UInt8(ascii: "/") {
            pos += 1
            var pattern = ""
            var bytes: [UInt8] = []
            while pos < src.count, src[pos] != UInt8(ascii: "/") {
                if src[pos] == UInt8(ascii: "\\"), pos + 1 < src.count {
                    bytes.append(src[pos])
                    pos += 1
                }
                bytes.append(src[pos])
                pos += 1
            }
            guard pos < src.count else { throw Failure.syntax("regex") }
            pos += 1
            pattern = String(decoding: bytes, as: UTF8.self)
            var options: NSRegularExpression.Options = []
            while pos < src.count, src[pos] == UInt8(ascii: "i") || src[pos] == UInt8(ascii: "s") {
                options.insert(src[pos] == UInt8(ascii: "i") ? .caseInsensitive : .dotMatchesLineSeparators)
                pos += 1
            }
            var wide = false, ascii = false, nocase = false
            while case .ident(let m) = try peek(), ["ascii", "wide", "nocase", "fullword", "private"].contains(m) {
                _ = try next()
                switch m {
                case "wide": wide = true
                case "ascii": ascii = true
                case "nocase": nocase = true
                case "fullword": fullword = true
                default: break
                }
            }
            if nocase { options.insert(.caseInsensitive) }
            // YARA reads "{,n}" as "{0,n}"; ICU wants the lower bound.
            pattern = pattern.replacingOccurrences(of: "{,", with: "{0,")
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { throw Failure.syntax("regex") }
            if ascii || !wide { variants.append(ProtectionYaraVariant(body: .regex(re), wide: false)) }
            if wide { variants.append(ProtectionYaraVariant(body: .regex(re), wide: true)) }
        } else if c == UInt8(ascii: "\"") {
            guard case .text(let text) = try next() else { throw Failure.syntax("texte") }
            var ascii = false, wide = false, nocase = false, xor: ClosedRange<Int>?, base64 = false, base64wide = false
            while case .ident(let m) = try peek() {
                guard ["ascii", "wide", "nocase", "fullword", "private", "xor", "base64", "base64wide"].contains(m) else { break }
                _ = try next()
                switch m {
                case "ascii": ascii = true
                case "wide": wide = true
                case "nocase": nocase = true
                case "fullword": fullword = true
                case "xor":
                    xor = 0...255
                    if try peek() == .sym("(") {
                        _ = try next()
                        guard case .num(let lo) = try next() else { throw Failure.syntax("xor") }
                        var hi = lo
                        if try peek() == .sym("-") {
                            _ = try next()
                            guard case .num(let h) = try next() else { throw Failure.syntax("xor") }
                            hi = h
                        }
                        try expect(.sym(")"))
                        guard (0...255).contains(lo), (lo...255).contains(hi) else { throw Failure.syntax("xor") }
                        xor = Int(lo)...Int(hi)
                    }
                case "base64", "base64wide":
                    // A custom alphabet is not supported.
                    if try peek() == .sym("(") { throw Failure.syntax("base64") }
                    if m == "base64" { base64 = true } else { base64wide = true }
                default: break
                }
            }
            guard !text.isEmpty else { throw Failure.syntax("texte vide") }
            if base64 || base64wide {
                guard !nocase, xor == nil else { throw Failure.syntax("base64") }
                for b in ProtectionYaraAtoms.base64Forms(text) {
                    if base64 { variants.append(.literal(b, nocase: false, wide: false)) }
                    if base64wide { variants.append(.literal(ProtectionYaraAtoms.widen(b), nocase: false, wide: true)) }
                }
            } else {
                var forms: [([UInt8], Bool)] = []
                if ascii || !wide { forms.append((text, false)) }
                if wide { forms.append((ProtectionYaraAtoms.widen(text), true)) }
                for (bytes, isWide) in forms {
                    if let xor {
                        guard !nocase else { throw Failure.syntax("xor nocase") }
                        for k in xor {
                            variants.append(.literal(bytes.map { $0 ^ UInt8(k) }, nocase: false, wide: isWide))
                        }
                    } else {
                        variants.append(.literal(bytes, nocase: nocase, wide: isWide))
                    }
                }
            }
        } else {
            throw Failure.syntax("chaîne")
        }
        return ProtectionYaraString(name: name, variants: variants, fullword: fullword)
    }

    static func parseHex(_ raw: [UInt8]) throws -> [ProtectionYaraHex] {
        var i = 0
        func space() { while i < raw.count, raw[i] == 0x20 || raw[i] == 0x09 || raw[i] == 0x0A || raw[i] == 0x0D { i += 1 } }
        func nibble(_ c: UInt8) -> (UInt8, UInt8)? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return (c - UInt8(ascii: "0"), 0xF)
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return (c - UInt8(ascii: "a") + 10, 0xF)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return (c - UInt8(ascii: "A") + 10, 0xF)
            case UInt8(ascii: "?"): return (0, 0)
            default: return nil
            }
        }
        func number() throws -> Int {
            var n = 0, digits = 0
            while i < raw.count, raw[i] >= UInt8(ascii: "0"), raw[i] <= UInt8(ascii: "9") {
                n = min(n * 10 + Int(raw[i] - UInt8(ascii: "0")), 1 << 30)
                digits += 1
                i += 1
            }
            guard digits > 0 else { throw Failure.syntax("saut") }
            return n
        }
        func sequence(inAlt: Bool) throws -> [ProtectionYaraHex] {
            var out: [ProtectionYaraHex] = []
            while true {
                space()
                guard i < raw.count else {
                    if inAlt { throw Failure.syntax("alternative") }
                    return out
                }
                let c = raw[i]
                if c == UInt8(ascii: "|") || c == UInt8(ascii: ")") {
                    guard inAlt else { throw Failure.syntax("hex") }
                    return out
                }
                if c == UInt8(ascii: "(") {
                    i += 1
                    var alts: [[ProtectionYaraHex]] = []
                    while true {
                        alts.append(try sequence(inAlt: true))
                        guard i < raw.count else { throw Failure.syntax("alternative") }
                        if raw[i] == UInt8(ascii: "|") { i += 1; continue }
                        i += 1 // ")"
                        break
                    }
                    out.append(.alt(alts))
                } else if c == UInt8(ascii: "[") {
                    i += 1
                    space()
                    var lo = 0, hi = 0
                    if i < raw.count, raw[i] == UInt8(ascii: "-") {
                        i += 1
                        lo = 0
                        hi = ProtectionYaraAtoms.unboundedJump
                    } else {
                        lo = try number()
                        space()
                        if i < raw.count, raw[i] == UInt8(ascii: "-") {
                            i += 1
                            space()
                            if i < raw.count, raw[i] == UInt8(ascii: "]") { hi = lo + ProtectionYaraAtoms.unboundedJump } else { hi = try number() }
                        } else {
                            hi = lo
                        }
                    }
                    space()
                    guard i < raw.count, raw[i] == UInt8(ascii: "]"), lo <= hi else { throw Failure.syntax("saut") }
                    i += 1
                    out.append(.jump(lo, hi))
                } else {
                    var negated = false
                    if c == UInt8(ascii: "~") {
                        negated = true
                        i += 1
                    }
                    guard i + 1 < raw.count, let hiN = nibble(raw[i]), let loN = nibble(raw[i + 1]) else { throw Failure.syntax("octet") }
                    i += 2
                    out.append(.byte(hiN.0 << 4 | loN.0, mask: hiN.1 << 4 | loN.1, negated: negated))
                }
            }
        }
        let nodes = try sequence(inAlt: false)
        guard !nodes.isEmpty, nodes.contains(where: { if case .jump = $0 { return false }; return true }) else {
            throw Failure.syntax("hex vide")
        }
        return nodes
    }

    // MARK: Conditions

    private mutating func parseExpr() throws -> ProtectionYaraExpr {
        var terms = [try parseAnd()]
        while try peek() == .ident("or") {
            _ = try next()
            terms.append(try parseAnd())
        }
        return terms.count == 1 ? terms[0] : .or(terms)
    }

    private mutating func parseAnd() throws -> ProtectionYaraExpr {
        var terms = [try parseNot()]
        while try peek() == .ident("and") {
            _ = try next()
            terms.append(try parseNot())
        }
        return terms.count == 1 ? terms[0] : .and(terms)
    }

    private mutating func parseNot() throws -> ProtectionYaraExpr {
        if try peek() == .ident("not") {
            _ = try next()
            return .not(try parseNot())
        }
        return try parseQuantified()
    }

    private mutating func parseQuantified() throws -> ProtectionYaraExpr {
        let t = try peek()
        if t == .ident("for") {
            _ = try next()
            return try parseFor()
        }
        if case .ident(let w) = t, ["any", "all", "none"].contains(w), try peek(1) == .ident("of") {
            _ = try next()
            _ = try next()
            let q: ProtectionYaraQuantifier = w == "any" ? .any : (w == "all" ? .all : .none)
            return .of(q, try parseStringSet())
        }
        if case .num(let n) = t {
            if try peek(1) == .ident("of") {
                _ = try next()
                _ = try next()
                return .of(.count(.const(.int(n))), try parseStringSet())
            }
            if try peek(1) == .sym("%"), try peek(2) == .ident("of") {
                _ = try next()
                _ = try next()
                _ = try next()
                return .of(.percent(.const(.int(n))), try parseStringSet())
            }
        }
        return try parseEquality()
    }

    private mutating func parseQuantifier() throws -> ProtectionYaraQuantifier {
        switch try next() {
        case .ident("any"): return .any
        case .ident("all"): return .all
        case .ident("none"): return .none
        case .num(let n):
            if try peek() == .sym("%") {
                _ = try next()
                return .percent(.const(.int(n)))
            }
            return .count(.const(.int(n)))
        case .sym("("):
            let e = try parseArith()
            try expect(.sym(")"))
            return .count(e)
        default: throw Failure.syntax("quantificateur")
        }
    }

    private mutating func parseFor() throws -> ProtectionYaraExpr {
        let q = try parseQuantifier()
        if try peek() == .ident("of") {
            _ = try next()
            let set = try parseStringSet()
            try expect(.sym(":"))
            try expect(.sym("("))
            let saved = inForOf
            inForOf = true
            let body = try parseExpr()
            inForOf = saved
            try expect(.sym(")"))
            return .forOf(q, set, body)
        }
        guard case .ident(let v) = try next(), !["in", "of"].contains(v) else { throw Failure.syntax("for") }
        // Several variables are for dictionaries and arrays of modules: not supported.
        try expect(.ident("in"))
        let iterable: ProtectionYaraIterable
        try expect(.sym("("))
        let first = try parseArith()
        if try peek() == .sym("..") {
            _ = try next()
            let last = try parseArith()
            try expect(.sym(")"))
            iterable = .range(first, last)
        } else {
            var items = [first]
            while try peek() == .sym(",") {
                _ = try next()
                items.append(try parseArith())
            }
            try expect(.sym(")"))
            iterable = .list(items)
        }
        try expect(.sym(":"))
        try expect(.sym("("))
        let slot = slotCount
        slotCount += 1
        let shadowed = scopes[v]
        scopes[v] = slot
        let body = try parseExpr()
        scopes[v] = shadowed
        try expect(.sym(")"))
        return .forIn(q, slot: slot, iterable, body)
    }

    /// `them` or `($a, $b*, …)`.
    private mutating func parseStringSet() throws -> [Int] {
        if try peek() == .ident("them") {
            _ = try next()
            guard !stringNames.isEmpty else { throw Failure.syntax("them") }
            return Array(stringNames.indices)
        }
        try expect(.sym("("))
        var set: [Int] = []
        repeat {
            if try peek() == .sym(",") { _ = try next() }
            guard case .sid(let name) = try next() else { throw Failure.syntax("ensemble") }
            if name.hasSuffix("*") {
                let prefix = String(name.dropLast())
                let found = stringNames.indices.filter { stringNames[$0].hasPrefix(prefix) }
                guard !found.isEmpty else { throw Failure.syntax("ensemble vide") }
                set += found
            } else {
                guard let i = stringNames.firstIndex(of: name) else { throw Failure.syntax("chaîne inconnue") }
                set.append(i)
            }
        } while try peek() == .sym(",")
        try expect(.sym(")"))
        return set
    }

    private mutating func parseEquality() throws -> ProtectionYaraExpr {
        var l = try parseRelational()
        while case .sym(let op) = try peek(), op == "==" || op == "!=" {
            _ = try next()
            l = .binary(op, l, try parseRelational())
        }
        return l
    }

    private mutating func parseRelational() throws -> ProtectionYaraExpr {
        var l = try parseArith()
        while case .sym(let op) = try peek(), ["<", "<=", ">", ">="].contains(op) {
            _ = try next()
            l = .binary(op, l, try parseArith())
        }
        return l
    }

    private mutating func parseArith() throws -> ProtectionYaraExpr { try parseBinary(level: 0) }

    private static let levels: [[String]] = [["|"], ["^"], ["&"], ["<<", ">>"], ["+", "-"], ["*", "\\", "%"]]

    private mutating func parseBinary(level: Int) throws -> ProtectionYaraExpr {
        guard level < Self.levels.count else { return try parseUnary() }
        var l = try parseBinary(level: level + 1)
        while case .sym(let op) = try peek(), Self.levels[level].contains(op) {
            _ = try next()
            l = .binary(op, l, try parseBinary(level: level + 1))
        }
        return l
    }

    private mutating func parseUnary() throws -> ProtectionYaraExpr {
        if try peek() == .sym("-") {
            _ = try next()
            return .unary("-", try parseUnary())
        }
        if try peek() == .sym("~") {
            _ = try next()
            return .unary("~", try parseUnary())
        }
        return try parsePrimary()
    }

    private mutating func stringRef(_ name: String) throws -> Int? {
        if name.isEmpty {
            guard inForOf else { throw Failure.syntax("$ hors boucle") }
            return nil
        }
        guard let i = stringNames.firstIndex(of: "$" + name) ?? stringNames.firstIndex(of: name) else {
            throw Failure.syntax("chaîne inconnue")
        }
        return i
    }

    private mutating func parseRange() throws -> (ProtectionYaraExpr, ProtectionYaraExpr) {
        try expect(.sym("("))
        let lo = try parseArith()
        try expect(.sym(".."))
        let hi = try parseArith()
        try expect(.sym(")"))
        return (lo, hi)
    }

    private mutating func parseIndex() throws -> ProtectionYaraExpr {
        if try peek() == .sym("[") {
            _ = try next()
            let e = try parseArith()
            try expect(.sym("]"))
            return e
        }
        return .const(.int(1))
    }

    private mutating func parsePrimary() throws -> ProtectionYaraExpr {
        let t = try next()
        switch t {
        case .num(let n): return .const(.int(n))
        case .text(let s): return .const(.str(String(decoding: s, as: UTF8.self)))
        case .sym("("):
            let e = try parseExpr()
            try expect(.sym(")"))
            return e
        case .sid(let name):
            let ref: Int?
            if name.hasPrefix("$") { ref = try stringRef(String(name.dropFirst())) } else { ref = try stringRef(name) }
            if try peek() == .ident("at") {
                _ = try next()
                return .foundAt(ref, try parseArith())
            }
            if try peek() == .ident("in") {
                _ = try next()
                let (lo, hi) = try parseRange()
                return .foundIn(ref, lo, hi)
            }
            return .found(ref)
        case .cnt(let name):
            let ref = try stringRef(name)
            if try peek() == .ident("in") {
                _ = try next()
                let (lo, hi) = try parseRange()
                return .countIn(ref, lo, hi)
            }
            return .count(ref)
        case .off(let name):
            let ref = try stringRef(name)
            return .offset(ref, try parseIndex())
        case .len(let name):
            let ref = try stringRef(name)
            return .length(ref, try parseIndex())
        case .ident(let w):
            switch w {
            case "true": return .const(.int(1))
            case "false": return .const(.int(0))
            case "filesize": return .filesize
            case "hash":
                try expect(.sym("."))
                guard case .ident(let algo) = try next(), ["md5", "sha1", "sha256"].contains(algo) else {
                    throw Failure.syntax("hash")
                }
                try expect(.sym("("))
                let off = try parseArith()
                try expect(.sym(","))
                let size = try parseArith()
                try expect(.sym(")"))
                return .hash(algo, off, size)
            default:
                if let read = Self.readFunction(w) {
                    try expect(.sym("("))
                    let e = try parseArith()
                    try expect(.sym(")"))
                    return .read(bytes: read.bytes, signed: read.signed, bigEndian: read.bigEndian, e)
                }
                if let slot = scopes[w] { return .variable(slot) }
                if let r = ruleIndex[w] { return .rule(r) }
                throw Failure.syntax("identifiant inconnu \(w)")
            }
        default:
            throw Failure.syntax("expression")
        }
    }

    private static func readFunction(_ w: String) -> (bytes: Int, signed: Bool, bigEndian: Bool)? {
        let table: [String: (Int, Bool, Bool)] = [
            "uint8": (1, false, false), "uint16": (2, false, false), "uint32": (4, false, false),
            "uint8be": (1, false, true), "uint16be": (2, false, true), "uint32be": (4, false, true),
            "int8": (1, true, false), "int16": (2, true, false), "int32": (4, true, false),
            "int8be": (1, true, true), "int16be": (2, true, true), "int32be": (4, true, true)
        ]
        return table[w].map { (bytes: $0.0, signed: $0.1, bigEndian: $0.2) }
    }

    // MARK: Tokens

    private mutating func expect(_ t: Tok) throws {
        guard try next() == t else { throw Failure.syntax("attendu \(t)") }
    }

    private mutating func peek(_ ahead: Int = 0) throws -> Tok {
        while peeked.count <= ahead {
            let start = pos
            let t = try lex()
            peeked.append((t, start))
        }
        return peeked[ahead].0
    }

    private mutating func next() throws -> Tok {
        if !peeked.isEmpty { return peeked.removeFirst().0 }
        return try lex()
    }

    private mutating func skipSpace() {
        while pos < src.count {
            let c = src[pos]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                pos += 1
            } else if c == UInt8(ascii: "/"), pos + 1 < src.count, src[pos + 1] == UInt8(ascii: "/") {
                while pos < src.count, src[pos] != 0x0A { pos += 1 }
            } else if c == UInt8(ascii: "/"), pos + 1 < src.count, src[pos + 1] == UInt8(ascii: "*") {
                pos += 2
                while pos + 1 < src.count, !(src[pos] == UInt8(ascii: "*") && src[pos + 1] == UInt8(ascii: "/")) { pos += 1 }
                pos = min(src.count, pos + 2)
            } else {
                return
            }
        }
    }

    private static func isIdent(_ c: UInt8, first: Bool) -> Bool {
        (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z")) || c == UInt8(ascii: "_")
            || (!first && c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
    }

    private mutating func identifier() -> String {
        let start = pos
        while pos < src.count, Self.isIdent(src[pos], first: false) { pos += 1 }
        return String(decoding: src[start..<pos], as: UTF8.self)
    }

    private mutating func lex() throws -> Tok {
        skipSpace()
        guard pos < src.count else { return .eof }
        let c = src[pos]
        if Self.isIdent(c, first: true) { return .ident(identifier()) }
        if c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") {
            var value: Int64 = 0
            if c == UInt8(ascii: "0"), pos + 1 < src.count, src[pos + 1] == UInt8(ascii: "x") || src[pos + 1] == UInt8(ascii: "X") {
                pos += 2
                var digits = 0
                while pos < src.count, let d = Self.hexDigit(src[pos]) {
                    value = value &* 16 &+ Int64(d)
                    pos += 1
                    digits += 1
                }
                guard digits > 0 else { throw Failure.syntax("nombre") }
            } else {
                while pos < src.count, src[pos] >= UInt8(ascii: "0"), src[pos] <= UInt8(ascii: "9") {
                    value = value &* 10 &+ Int64(src[pos] - UInt8(ascii: "0"))
                    pos += 1
                }
                // "1.5" is a float: not supported (".." is a range and stays).
                if pos + 1 < src.count, src[pos] == UInt8(ascii: "."), src[pos + 1] != UInt8(ascii: ".") { throw Failure.syntax("réel") }
            }
            if pos + 1 < src.count, src[pos + 1] == UInt8(ascii: "B") {
                if src[pos] == UInt8(ascii: "K") { value *= 1024; pos += 2 } else if src[pos] == UInt8(ascii: "M") { value *= 1024 * 1024; pos += 2 }
            }
            return .num(value)
        }
        switch c {
        case UInt8(ascii: "\""):
            pos += 1
            var out: [UInt8] = []
            while pos < src.count, src[pos] != UInt8(ascii: "\"") {
                if src[pos] == UInt8(ascii: "\\"), pos + 1 < src.count {
                    pos += 1
                    switch src[pos] {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                    case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                    case UInt8(ascii: "x"):
                        guard pos + 2 < src.count, let h = Self.hexDigit(src[pos + 1]), let l = Self.hexDigit(src[pos + 2]) else {
                            throw Failure.syntax("échappement")
                        }
                        out.append(h << 4 | l)
                        pos += 2
                    default: throw Failure.syntax("échappement")
                    }
                    pos += 1
                } else {
                    out.append(src[pos])
                    pos += 1
                }
            }
            guard pos < src.count else { throw Failure.syntax("texte") }
            pos += 1
            return .text(out)
        case UInt8(ascii: "$"), UInt8(ascii: "#"), UInt8(ascii: "@"):
            pos += 1
            var name = identifier()
            if c == UInt8(ascii: "$"), pos < src.count, src[pos] == UInt8(ascii: "*") {
                name += "*"
                pos += 1
            }
            if c == UInt8(ascii: "$") { return .sid(name.isEmpty ? "" : "$" + name) }
            return c == UInt8(ascii: "#") ? .cnt(name) : .off(name)
        case UInt8(ascii: "!"):
            if pos + 1 < src.count, src[pos + 1] == UInt8(ascii: "=") {
                pos += 2
                return .sym("!=")
            }
            pos += 1
            return .len(identifier())
        default:
            break
        }
        let two = pos + 1 < src.count ? String(decoding: src[pos...pos + 1], as: UTF8.self) : ""
        if ["==", "<=", ">=", "<<", ">>", ".."].contains(two) {
            pos += 2
            return .sym(two)
        }
        let one = String(UnicodeScalar(c))
        if "()[]{},:=<>+-*\\%&|^~.".contains(one) {
            pos += 1
            return .sym(one)
        }
        throw Failure.syntax("caractère \(one)")
    }

    private static func hexDigit(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

private extension ProtectionYaraVariant {
    static func literal(_ bytes: [UInt8], nocase: Bool, wide: Bool) -> ProtectionYaraVariant {
        let singles = bytes.enumerated().filter { !nocase || !ProtectionYaraAtoms.isLetter($0.element) }.map { (byte: $0.element, offset: $0.offset) }
        return ProtectionYaraVariant(body: .bytes(bytes, nocase: nocase), wide: wide,
                                     runs: bytes.count >= 2 ? [(bytes, 0)] : [], singles: singles)
    }
}

// MARK: - Atoms

/// Finds in each string what the file can be searched for quickly.
enum ProtectionYaraAtoms {
    /// `[n-]` jumps are capped: a match never spans more than this many bytes of jump.
    static let unboundedJump = 0x10000

    static func widen(_ b: [UInt8]) -> [UInt8] { b.flatMap { [$0, 0] } }

    static func isLetter(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
    }

    /// The runs of fully known bytes (and the known bytes one by one) found at a fixed distance from the start of the match:
    /// past a jump or alternatives of different lengths, that distance is not known any more.
    static func fixedParts(_ nodes: [ProtectionYaraHex]) -> (runs: [(bytes: [UInt8], offset: Int)], singles: [(byte: UInt8, offset: Int)]) {
        var runs: [(bytes: [UInt8], offset: Int)] = []
        var singles: [(byte: UInt8, offset: Int)] = []
        var offset = 0
        var run: [UInt8] = []
        var runStart = 0
        func close() {
            if run.count >= 2 { runs.append((run, runStart)) }
            run = []
        }
        for node in nodes {
            if node.isFixedByte, case .byte(let b, _, _) = node {
                if run.isEmpty { runStart = offset }
                run.append(b)
                singles.append((b, offset))
                offset += 1
                continue
            }
            close()
            guard node.minLength == node.maxLength else { return (runs, singles) }
            offset += node.minLength
        }
        close()
        return (runs, singles)
    }

    /// A hex string that starts with alternatives and has no good atom becomes one string per alternative.
    static func expandLeading(_ nodes: [ProtectionYaraHex]) -> [[ProtectionYaraHex]] {
        var out: [[ProtectionYaraHex]] = []
        func expand(_ n: [ProtectionYaraHex], depth: Int) {
            if !fixedParts(n).runs.isEmpty || depth > 2 || out.count > 32 {
                out.append(n)
                return
            }
            // The first element that is not a single fixed byte, when it is a group of alternatives.
            guard let i = n.firstIndex(where: { !$0.isFixedByte }), case .alt(let alts) = n[i], alts.count <= 16 else {
                out.append(n)
                return
            }
            for a in alts { expand(Array(n[..<i]) + a + Array(n[(i + 1)...]), depth: depth + 1) }
        }
        expand(nodes, depth: 0)
        return out
    }

    /// The three base64 forms of `s` (one per alignment), without the characters that depend on the bytes around it.
    static func base64Forms(_ s: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for k in 0..<3 {
            let padded = Data(Array(repeating: UInt8(ascii: "A"), count: k) + s)
            var enc = Array(padded.base64EncodedString().utf8)
            while enc.last == UInt8(ascii: "=") { enc.removeLast() }
            let lead = [0, 2, 3][k]
            let total = k + s.count
            let trail = total % 3 == 0 ? 0 : 1
            guard enc.count > lead + trail + 1 else { continue }
            out.append(Array(enc[lead..<(enc.count - trail)]))
        }
        return out
    }
}
