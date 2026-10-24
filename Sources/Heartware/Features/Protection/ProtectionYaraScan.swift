import Foundation
import CryptoKit

/// How often each byte and each pair of bytes shows up in real executables, measured once on a few of this Mac's own
/// (code and text of both architectures): the rarest parts of each string are what the file is searched for.
enum ProtectionYaraFrequency {
    static let samples = [Bundle.main.executablePath ?? "", "/usr/bin/ssh", "/usr/bin/curl", "/usr/bin/vim", "/usr/bin/zip",
                          "/usr/bin/sqlite3", "/usr/bin/perl5.34", "/usr/sbin/sshd"]

    static let tables: (pairs: [UInt32], bytes: [UInt32]) = {
        var pairs = [UInt32](repeating: 1, count: 65536)
        var bytes = [UInt32](repeating: 1, count: 256)
        var total = 0
        for path in samples where total < 16 << 20 {
            guard let h = FileHandle(forReadingAtPath: path), let d = try? h.read(upToCount: 4 << 20) else { continue }
            try? h.close()
            total += d.count
            d.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                guard p.count > 1 else { return }
                for i in 0..<(p.count - 1) {
                    pairs[Int(p[i]) | Int(p[i + 1]) << 8] &+= 1
                    bytes[Int(p[i])] &+= 1
                }
            }
        }
        return (pairs, bytes)
    }()

    static func pair(_ a: UInt8, _ b: UInt8) -> UInt64 { UInt64(tables.pairs[Int(a) | Int(b) << 8]) }
    static func byte(_ b: UInt8) -> UInt64 { UInt64(tables.bytes[Int(b)]) }
}

/// Rules ready to scan files: one atom per string variant sits in a table looked up by two bytes,
/// so a file is read once whatever the number of rules.
final class ProtectionYaraRuleset: @unchecked Sendable {
    let rules: [ProtectionYaraRule]
    let skipped: [String]

    /// Strings of all rules, flattened: rule `r`'s string `s` is `strings[stringBase[r] + s]`.
    fileprivate let strings: [ProtectionYaraString]
    fileprivate let stringBase: [Int]
    /// Variants of all strings, flattened: string `g`'s variant `v` is `variantBase[g] + v`.
    fileprivate let variantBase: [Int]
    fileprivate let variantCount: Int
    /// Variants with an atom in the table (the others are searched on their own).
    fileprivate let indexed: [Bool]
    /// For a variant without atom: its rarest known byte and where it sits in the match, found with memchr.
    fileprivate let anchors: [Int: (byte: UInt8, offset: Int)]

    fileprivate struct Entry {
        /// The atom, little endian, and its length (2 to 8).
        var atom: UInt64
        var length: Int8
        /// Where the two bytes of the key sit in the atom.
        var keyOffset: Int8
        /// Where the atom sits in the match.
        var offset: Int32
        var variant: Int32
    }
    /// Entries keyed by the two bytes `k` are `entries[bucket[k]..<bucket[k + 1]]`.
    fileprivate let bucket: [Int32]
    fileprivate let entries: [Entry]

    var publicRuleCount: Int { rules.filter { !$0.isPrivate }.count }

    init(source: String) {
        let parsed = ProtectionYaraParser.parse(source)
        var rules = parsed.rules
        skipped = parsed.skipped
        // Cheap tests first: `Macho and filesize < 1MB and $a` reads no string in a big file.
        var costs: [Int] = []
        for i in rules.indices {
            rules[i].condition = Self.cheapFirst(rules[i].condition, ruleCosts: costs)
            costs.append(Self.cost(rules[i].condition, ruleCosts: costs))
        }
        self.rules = rules
        var strings: [ProtectionYaraString] = []
        var stringBase: [Int] = []
        var variantBase: [Int] = []
        var indexed: [Bool] = []
        var anchors: [Int: (byte: UInt8, offset: Int)] = [:]
        var pending: [(key: Int, entry: Entry)] = []
        for r in rules {
            stringBase.append(strings.count)
            for s in r.strings {
                variantBase.append(indexed.count)
                for v in s.variants {
                    let id = indexed.count
                    let nocase: Bool
                    if case .bytes(_, let nc) = v.body { nocase = nc } else { nocase = false }
                    if let atom = Self.bestAtom(v.runs, nocase: nocase) {
                        for form in atom.forms {
                            var packed: UInt64 = 0
                            for (k, b) in form.enumerated() { packed |= UInt64(b) << (8 * UInt64(k)) }
                            let key = Int(form[atom.key]) | Int(form[atom.key + 1]) << 8
                            pending.append((key, Entry(atom: packed, length: Int8(form.count), keyOffset: Int8(atom.key),
                                                       offset: Int32(atom.offset), variant: Int32(id))))
                        }
                        indexed.append(true)
                    } else {
                        indexed.append(false)
                        if let rare = v.singles.min(by: { ProtectionYaraFrequency.byte($0.byte) < ProtectionYaraFrequency.byte($1.byte) }) {
                            anchors[id] = rare
                        }
                    }
                }
                strings.append(s)
            }
        }
        pending.sort { $0.key < $1.key }
        var bucket = [Int32](repeating: 0, count: 65537)
        for p in pending { bucket[p.key + 1] += 1 }
        for k in 0..<65536 { bucket[k + 1] += bucket[k] }
        self.strings = strings
        self.stringBase = stringBase
        self.variantBase = variantBase
        self.variantCount = indexed.count
        self.indexed = indexed
        self.anchors = anchors
        self.bucket = bucket
        self.entries = pending.map(\.entry)
    }

    /// The rarest pair of known bytes of a variant, widened to at most 8 bytes around it (and to at most four letters
    /// for a case-insensitive string, each upper/lower case combination being an atom of its own).
    private static func bestAtom(_ runs: [(bytes: [UInt8], offset: Int)], nocase: Bool) -> (forms: [[UInt8]], offset: Int, key: Int)? {
        var best: (cost: UInt64, run: Int, at: Int)?
        for (r, run) in runs.enumerated() where run.bytes.count >= 2 {
            for j in 0..<(run.bytes.count - 1) {
                let a = run.bytes[j], b = run.bytes[j + 1]
                var cost: UInt64
                if nocase {
                    cost = 0
                    for x in ProtectionYaraAtoms.isLetter(a) ? [a | 0x20, a & ~0x20] : [a] {
                        for y in ProtectionYaraAtoms.isLetter(b) ? [b | 0x20, b & ~0x20] : [b] { cost += ProtectionYaraFrequency.pair(x, y) }
                    }
                } else {
                    cost = ProtectionYaraFrequency.pair(a, b)
                }
                if best == nil || cost < best!.cost { best = (cost, r, j) }
            }
        }
        guard let best else { return nil }
        let bytes = runs[best.run].bytes
        var lo = max(0, best.at - 3)
        var hi = min(bytes.count, lo + 8)
        lo = max(0, hi - 8)
        if nocase {
            // At most four letters: shrink the window on the side away from the key.
            while bytes[lo..<hi].filter(ProtectionYaraAtoms.isLetter).count > 4 {
                if best.at - lo > hi - (best.at + 2) { lo += 1 } else { hi -= 1 }
            }
        }
        var forms: [[UInt8]] = [[]]
        for b in bytes[lo..<hi] {
            if nocase, ProtectionYaraAtoms.isLetter(b) {
                forms = forms.flatMap { [$0 + [b | 0x20], $0 + [b & ~0x20]] }
            } else {
                forms = forms.map { $0 + [b] }
            }
        }
        return (forms, runs[best.run].offset + lo, best.at - lo)
    }

    /// 0 for a test that reads no string (file size, header bytes), more for strings, hashes, loops.
    private static func cost(_ e: ProtectionYaraExpr, ruleCosts: [Int]) -> Int {
        switch e {
        case .const, .filesize, .variable: return 0
        case .read(_, _, _, let x), .unary(_, let x), .not(let x): return cost(x, ruleCosts: ruleCosts)
        case .binary(_, let a, let b): return max(cost(a, ruleCosts: ruleCosts), cost(b, ruleCosts: ruleCosts))
        case .and(let t), .or(let t): return t.map { cost($0, ruleCosts: ruleCosts) }.max() ?? 0
        case .rule(let i): return i < ruleCosts.count ? ruleCosts[i] : 10
        case .hash: return 5
        case .forIn(_, _, _, let body): return 1 + cost(body, ruleCosts: ruleCosts)
        default: return 10
        }
    }

    private static func cheapFirst(_ e: ProtectionYaraExpr, ruleCosts: [Int]) -> ProtectionYaraExpr {
        func sorted(_ terms: [ProtectionYaraExpr]) -> [ProtectionYaraExpr] {
            terms.map { cheapFirst($0, ruleCosts: ruleCosts) }.enumerated()
                .sorted { (cost($0.element, ruleCosts: ruleCosts), $0.offset) < (cost($1.element, ruleCosts: ruleCosts), $1.offset) }
                .map(\.element)
        }
        switch e {
        case .and(let t): return .and(sorted(t))
        case .or(let t): return .or(sorted(t))
        case .not(let x): return .not(cheapFirst(x, ruleCosts: ruleCosts))
        default: return e
        }
    }

    /// The public rules that match `data`. Gives up (no match) past `budget` seconds.
    func scan(_ data: UnsafeRawBufferPointer, budget: TimeInterval = 4) -> [ProtectionYaraRule] {
        guard data.count > 0 else { return [] }
        let file = ProtectionYaraFile(ruleset: self, data: data, deadline: ProcessInfo.processInfo.systemUptime + budget)
        var hits: [ProtectionYaraRule] = []
        for global in rules.indices where rules[global].isGlobal {
            if !file.evaluate(rule: global) { return [] }
        }
        for i in rules.indices where !rules[i].isPrivate && !rules[i].isGlobal {
            if file.evaluate(rule: i) { hits.append(rules[i]) }
            if file.aborted { return [] }
        }
        return hits
    }

    func scan(_ data: Data, budget: TimeInterval = 4) -> [ProtectionYaraRule] {
        data.withUnsafeBytes { scan($0, budget: budget) }
    }
}

/// The state of one file being scanned: matches are searched only when a condition needs them, then kept.
private final class ProtectionYaraFile {
    struct Match {
        var offset: Int
        var length: Int
    }

    let set: ProtectionYaraRuleset
    let p: UnsafePointer<UInt8>
    let n: Int
    let deadline: TimeInterval
    var aborted = false

    private var candidates: [[Int]]?
    private var matchCache: [Int: [Match]] = [:]
    private var ruleCache: [Int: Bool] = [:]
    private var hashCache: [String: String] = [:]
    private var latin1: NSString?
    private var vars: [Int64] = []
    private var steps = 0

    static let maxMatches = 10_000
    static let maxCandidates = 50_000
    static let maxLoop: Int64 = 100_000

    init(ruleset: ProtectionYaraRuleset, data: UnsafeRawBufferPointer, deadline: TimeInterval) {
        set = ruleset
        p = data.bindMemory(to: UInt8.self).baseAddress!
        n = data.count
        self.deadline = deadline
    }

    private func overTime() -> Bool {
        steps += 1
        if steps & 0x3FF == 0, ProcessInfo.processInfo.systemUptime > deadline { aborted = true }
        return aborted
    }

    // MARK: Rules

    func evaluate(rule r: Int) -> Bool {
        if let cached = ruleCache[r] { return cached }
        let rule = set.rules[r]
        let saved = vars
        vars = [Int64](repeating: 0, count: rule.slots)
        let result = !aborted && eval(rule.condition, rule: r, current: nil).truthy && !aborted
        vars = saved
        ruleCache[r] = result
        return result
    }

    private func global(_ ref: Int?, rule r: Int, current: Int?) -> Int? {
        if let ref { return set.stringBase[r] + ref }
        return current
    }

    // MARK: Conditions

    private func eval(_ e: ProtectionYaraExpr, rule r: Int, current: Int?) -> ProtectionYaraValue {
        if aborted { return .undef }
        switch e {
        case .const(let v):
            return v
        case .filesize:
            return .int(Int64(n))
        case .and(let terms):
            for t in terms where !eval(t, rule: r, current: current).truthy { return .int(0) }
            return .int(1)
        case .or(let terms):
            for t in terms where eval(t, rule: r, current: current).truthy { return .int(1) }
            return .int(0)
        case .not(let x):
            let v = eval(x, rule: r, current: current)
            if v == .undef { return .undef }
            return .int(v.truthy ? 0 : 1)
        case .binary(let op, let a, let b):
            return binary(op, eval(a, rule: r, current: current), eval(b, rule: r, current: current))
        case .unary(let op, let x):
            guard let v = eval(x, rule: r, current: current).int else { return .undef }
            return .int(op == "-" ? 0 &- v : ~v)
        case .read(let bytes, let signed, let bigEndian, let off):
            guard let o = eval(off, rule: r, current: current).int, o >= 0, o <= Int64(n - bytes) else { return .undef }
            var v: UInt64 = 0
            for i in 0..<bytes {
                let b = UInt64(p[Int(o) + (bigEndian ? i : bytes - 1 - i)])
                v = v << 8 | b
            }
            if signed {
                let shift = UInt64(64 - bytes * 8)
                return .int(Int64(bitPattern: v << shift) >> Int64(shift))
            }
            return .int(Int64(v))
        case .found(let ref):
            guard let g = global(ref, rule: r, current: current) else { return .undef }
            return .int(matches(g).isEmpty ? 0 : 1)
        case .foundAt(let ref, let at):
            guard let g = global(ref, rule: r, current: current), let o = eval(at, rule: r, current: current).int else { return .undef }
            return .int(matches(g).contains { Int64($0.offset) == o } ? 1 : 0)
        case .foundIn(let ref, let lo, let hi):
            guard let g = global(ref, rule: r, current: current), let l = eval(lo, rule: r, current: current).int,
                  let h = eval(hi, rule: r, current: current).int else { return .undef }
            return .int(matches(g).contains { Int64($0.offset) >= l && Int64($0.offset) <= h } ? 1 : 0)
        case .count(let ref):
            guard let g = global(ref, rule: r, current: current) else { return .undef }
            return .int(Int64(matches(g).count))
        case .countIn(let ref, let lo, let hi):
            guard let g = global(ref, rule: r, current: current), let l = eval(lo, rule: r, current: current).int,
                  let h = eval(hi, rule: r, current: current).int else { return .undef }
            return .int(Int64(matches(g).filter { Int64($0.offset) >= l && Int64($0.offset) <= h }.count))
        case .offset(let ref, let idx), .length(let ref, let idx):
            guard let g = global(ref, rule: r, current: current), let i = eval(idx, rule: r, current: current).int else { return .undef }
            let m = matches(g)
            guard i >= 1, i <= Int64(m.count) else { return .undef }
            if case .offset = e { return .int(Int64(m[Int(i) - 1].offset)) }
            return .int(Int64(m[Int(i) - 1].length))
        case .of(let q, let members):
            let base = set.stringBase[r]
            return quantify(q, total: members.count, rule: r, current: current) { !self.matches(base + members[$0]).isEmpty }
        case .forOf(let q, let members, let body):
            let base = set.stringBase[r]
            return quantify(q, total: members.count, rule: r, current: current) {
                self.eval(body, rule: r, current: base + members[$0]).truthy
            }
        case .forIn(let q, let slot, let iterable, let body):
            var values: [Int64] = []
            switch iterable {
            case .range(let lo, let hi):
                guard let l = eval(lo, rule: r, current: current).int, let h = eval(hi, rule: r, current: current).int else { return .undef }
                let span = h.subtractingReportingOverflow(l)
                if h < l { values = [] } else if span.overflow || span.partialValue >= Self.maxLoop { return .undef } else { values = Array(l...h) }
            case .list(let items):
                for item in items {
                    guard let v = eval(item, rule: r, current: current).int else { return .undef }
                    values.append(v)
                }
            }
            return quantify(q, total: values.count, rule: r, current: current) {
                self.vars[slot] = values[$0]
                return self.eval(body, rule: r, current: current).truthy
            }
        case .variable(let slot):
            return slot < vars.count ? .int(vars[slot]) : .undef
        case .rule(let i):
            return .int(evaluate(rule: i) ? 1 : 0)
        case .hash(let algo, let off, let size):
            guard let o = eval(off, rule: r, current: current).int, let s = eval(size, rule: r, current: current).int,
                  o >= 0, s >= 0, o <= Int64(n), s <= Int64(n) - o else { return .undef }
            return .str(hash(algo, Int(o), Int(s)))
        }
    }

    private func quantify(_ q: ProtectionYaraQuantifier, total: Int, rule r: Int, current: Int?,
                          _ test: (Int) -> Bool) -> ProtectionYaraValue {
        let need: Int
        switch q {
        case .any: need = 1
        case .all: need = total
        case .none:
            for i in 0..<total where test(i) { return .int(0) }
            return .int(1)
        case .count(let e):
            guard let v = eval(e, rule: r, current: current).int else { return .undef }
            need = Int(clamping: v)
        case .percent(let e):
            guard let v = eval(e, rule: r, current: current).int else { return .undef }
            need = Int((Double(v) * Double(total) / 100).rounded(.up))
        }
        if need <= 0 { return .int(1) }
        if need > total { return .int(0) }
        var yes = 0
        for i in 0..<total {
            if aborted { return .undef }
            if test(i) {
                yes += 1
                if yes >= need { return .int(1) }
            } else if total - i - 1 + yes < need {
                return .int(0)
            }
        }
        return .int(yes >= need ? 1 : 0)
    }

    private func binary(_ op: String, _ a: ProtectionYaraValue, _ b: ProtectionYaraValue) -> ProtectionYaraValue {
        if case .str(let x) = a, case .str(let y) = b {
            switch op {
            case "==": return .int(x.lowercased() == y.lowercased() ? 1 : 0)
            case "!=": return .int(x.lowercased() != y.lowercased() ? 1 : 0)
            default: return .undef
            }
        }
        guard let x = a.int, let y = b.int else { return .undef }
        switch op {
        case "==": return .int(x == y ? 1 : 0)
        case "!=": return .int(x != y ? 1 : 0)
        case "<": return .int(x < y ? 1 : 0)
        case "<=": return .int(x <= y ? 1 : 0)
        case ">": return .int(x > y ? 1 : 0)
        case ">=": return .int(x >= y ? 1 : 0)
        case "+": return .int(x &+ y)
        case "-": return .int(x &- y)
        case "*": return .int(x &* y)
        case "\\":
            let r = x.dividedReportingOverflow(by: y)
            return y == 0 || r.overflow ? .undef : .int(r.partialValue)
        case "%":
            let r = x.remainderReportingOverflow(dividingBy: y)
            return y == 0 || r.overflow ? .undef : .int(r.partialValue)
        case "&": return .int(x & y)
        case "|": return .int(x | y)
        case "^": return .int(x ^ y)
        case "<<": return .int(y < 0 || y > 63 ? 0 : x << y)
        case ">>": return .int(y < 0 || y > 63 ? 0 : x >> y)
        default: return .undef
        }
    }

    private func hash(_ algo: String, _ o: Int, _ s: Int) -> String {
        let key = "\(algo):\(o):\(s)"
        if let h = hashCache[key] { return h }
        let buf = UnsafeRawBufferPointer(start: p + o, count: s)
        let hex: String
        switch algo {
        case "md5": hex = Insecure.MD5.hash(data: buf).map { String(format: "%02x", $0) }.joined()
        case "sha1": hex = Insecure.SHA1.hash(data: buf).map { String(format: "%02x", $0) }.joined()
        default: hex = SHA256.hash(data: buf).map { String(format: "%02x", $0) }.joined()
        }
        hashCache[key] = hex
        return hex
    }

    // MARK: Strings

    /// Every place string `g` matches, sorted by offset.
    func matches(_ g: Int) -> [Match] {
        if let m = matchCache[g] { return m }
        let s = set.strings[g]
        var found: [Match] = []
        for (vi, variant) in s.variants.enumerated() {
            if aborted { break }
            let gv = set.variantBase[g] + vi
            if case .regex(let re) = variant.body {
                found += (variant.wide ? wideRegexMatches(re) : regexMatches(re)).filter { fullwordOK(s, variant, $0.offset, $0.length) }
                continue
            }
            if set.indexed[gv] {
                let starts = Set(candidateStarts()[gv]).sorted()
                for start in starts {
                    if overTime() { break }
                    if let len = verify(variant, at: start), fullwordOK(s, variant, start, len) {
                        found.append(Match(offset: start, length: len))
                        if found.count >= Self.maxMatches { break }
                    }
                }
            } else if let anchor = set.anchors[gv] {
                // memchr jumps from one occurrence of the anchor byte to the next.
                var at = anchor.offset
                while at < n, !overTime() {
                    guard let hit = memchr(p + at, Int32(anchor.byte), n - at) else { break }
                    let pos = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)) - p
                    let start = pos - anchor.offset
                    if let len = verify(variant, at: start), fullwordOK(s, variant, start, len) {
                        found.append(Match(offset: start, length: len))
                        if found.count >= Self.maxMatches { break }
                    }
                    at = pos + 1
                }
            } else {
                // No atom: every position is tried, the first element checked before anything else.
                var start = 0
                while start < n {
                    if overTime() { break }
                    if let len = verify(variant, at: start), fullwordOK(s, variant, start, len) {
                        found.append(Match(offset: start, length: len))
                        if found.count >= Self.maxMatches { break }
                    }
                    start += 1
                }
            }
        }
        if s.variants.count > 1 {
            found.sort { $0.offset < $1.offset }
            var unique: [Match] = []
            for m in found where unique.last?.offset != m.offset { unique.append(m) }
            found = unique
        }
        matchCache[g] = found
        return found
    }

    /// One pass over the file for all atoms: where each variant may start.
    private func candidateStarts() -> [[Int]] {
        if let c = candidates { return c }
        var out = [[Int]](repeating: [], count: set.variantCount)
        set.bucket.withUnsafeBufferPointer { bucket in
            set.entries.withUnsafeBufferPointer { entries in
                var i = 0
                let last = n - 1
                while i < last {
                    let key = Int(p[i]) | Int(p[i + 1]) << 8
                    let lo = Int(bucket[key]), hi = Int(bucket[key + 1])
                    if lo != hi {
                        for j in lo..<hi {
                            let e = entries[j]
                            let atomStart = i - Int(e.keyOffset)
                            let length = Int(e.length)
                            guard atomStart >= 0, atomStart + length <= n else { continue }
                            var same = true
                            var k = 0
                            while k < length {
                                if p[atomStart + k] != UInt8(truncatingIfNeeded: e.atom >> (8 * UInt64(k))) {
                                    same = false
                                    break
                                }
                                k += 1
                            }
                            guard same else { continue }
                            let start = atomStart - Int(e.offset)
                            if start >= 0, out[Int(e.variant)].count < Self.maxCandidates { out[Int(e.variant)].append(start) }
                        }
                    }
                    i += 1
                    if i & 0xFFFFF == 0, ProcessInfo.processInfo.systemUptime > deadline {
                        aborted = true
                        break
                    }
                }
            }
        }
        candidates = out
        return out
    }

    private func regexMatches(_ re: NSRegularExpression) -> [Match] {
        // Byte offsets equal string offsets in ISO Latin-1. Big files are left out (memory).
        guard n <= 16 << 20 else { return [] }
        if latin1 == nil {
            latin1 = NSString(bytes: p, length: n, encoding: String.Encoding.isoLatin1.rawValue) ?? ""
        }
        guard let text = latin1, !aborted else { return [] }
        return enumerate(re, in: text, offset: { $0 }, length: { $0 })
    }

    /// The matches of `re`, stopped at the time budget or the match limit (never all materialized at once).
    private func enumerate(_ re: NSRegularExpression, in text: NSString, offset: (Int) -> Int, length: (Int) -> Int) -> [Match] {
        var out: [Match] = []
        re.enumerateMatches(in: text as String, options: [.reportProgress], range: NSRange(location: 0, length: text.length)) { m, _, stop in
            if let m { out.append(Match(offset: offset(m.range.location), length: length(m.range.length))) }
            if out.count >= Self.maxMatches || overTime() { stop.pointee = true }
        }
        return out
    }

    /// A regex over UTF-16 text: run on every other byte (both alignments), where a character whose high byte
    /// is not zero becomes a NUL that no signature looks for.
    private func wideRegexMatches(_ re: NSRegularExpression) -> [Match] {
        guard n <= 16 << 20, !aborted else { return [] }
        var out: [Match] = []
        for parity in 0..<2 {
            let count = (n - parity) / 2
            guard count > 0 else { continue }
            var narrow = [UInt8](repeating: 0, count: count)
            for i in 0..<count where p[2 * i + parity + 1] == 0 { narrow[i] = p[2 * i + parity] }
            let text = NSString(bytes: narrow, length: count, encoding: String.Encoding.isoLatin1.rawValue) ?? ""
            out += enumerate(re, in: text, offset: { 2 * $0 + parity }, length: { 2 * $0 })
        }
        return out.sorted { $0.offset < $1.offset }
    }

    private static func isAlnum(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    private func fullwordOK(_ s: ProtectionYaraString, _ v: ProtectionYaraVariant, _ start: Int, _ len: Int) -> Bool {
        guard s.fullword else { return true }
        let end = start + len
        if v.wide {
            if start >= 2, Self.isAlnum(p[start - 2]), p[start - 1] == 0 { return false }
            if end + 1 < n, Self.isAlnum(p[end]), p[end + 1] == 0 { return false }
        } else {
            if start >= 1, Self.isAlnum(p[start - 1]) { return false }
            if end < n, Self.isAlnum(p[end]) { return false }
        }
        return true
    }

    /// The length of the match of `v` starting at `start`, or nil.
    private func verify(_ v: ProtectionYaraVariant, at start: Int) -> Int? {
        switch v.body {
        case .bytes(let bytes, let nocase):
            guard start + bytes.count <= n else { return nil }
            for (k, b) in bytes.enumerated() {
                let c = p[start + k]
                if c == b { continue }
                if nocase, ProtectionYaraAtoms.isLetter(b), c | 0x20 == b | 0x20 { continue }
                return nil
            }
            return bytes.count
        case .hex(let nodes):
            hexBudget = 100_000
            return matchHex(nodes[...], start) { $0 }.map { $0 - start }
        case .regex:
            return nil
        }
    }

    /// Steps left to the current hex match: pathological jumps and alternatives give up instead of hanging.
    private var hexBudget = 0

    /// Matches `nodes` at `pos`, then `rest` from where they end; returns the end of the whole match.
    private func matchHex(_ nodes: ArraySlice<ProtectionYaraHex>, _ pos: Int, _ rest: (Int) -> Int?) -> Int? {
        hexBudget -= 1
        if hexBudget <= 0 { return nil }
        guard let first = nodes.first else { return rest(pos) }
        let tail = nodes.dropFirst()
        switch first {
        case .byte(let b, let mask, let negated):
            guard pos < n else { return nil }
            let same = p[pos] & mask == b & mask
            guard same != negated else { return nil }
            return matchHex(tail, pos + 1, rest)
        case .jump(let lo, let hi):
            var k = lo
            while k <= hi, pos + k <= n, hexBudget > 0 {
                if let end = matchHex(tail, pos + k, rest) { return end }
                k += 1
            }
            return nil
        case .alt(let alts):
            for a in alts where hexBudget > 0 {
                if let end = matchHex(a[...], pos, { self.matchHex(tail, $0, rest) }) { return end }
            }
            return nil
        }
    }
}
