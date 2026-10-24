import Foundation
import CryptoKit
import Security
import SwiftUI

// Pure functions of the toolbox: colors, passwords, digests, text, dates. Everything here is checked by `selfTest()`.

// MARK: - Colors

/// An sRGB color, components in 0…1.
struct ToolboxRGB: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = min(1, max(0, r))
        self.g = min(1, max(0, g))
        self.b = min(1, max(0, b))
        self.a = min(1, max(0, a))
    }

    init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    init?(_ ns: NSColor) {
        guard let c = ns.usingColorSpace(.sRGB) else { return nil }
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    var r255: Int { Int((r * 255).rounded()) }
    var g255: Int { Int((g * 255).rounded()) }
    var b255: Int { Int((b * 255).rounded()) }

    var hex: String {
        let base = String(format: "#%02X%02X%02X", r255, g255, b255)
        return a < 1 ? base + String(format: "%02X", Int((a * 255).rounded())) : base
    }

    var rgbString: String {
        a < 1 ? "rgba(\(r255), \(g255), \(b255), \(Self.short(a)))" : "rgb(\(r255), \(g255), \(b255))"
    }

    /// Hue in degrees, saturation and lightness in 0…1.
    var hsl: (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        let d = mx - mn
        guard d > 1e-9 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        if mx == r {
            h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
        } else if mx == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return (h, min(1, s), l)
    }

    var hslString: String {
        let v = hsl
        let body = "\(Int(v.h.rounded()) % 360), \(Int((v.s * 100).rounded()))%, \(Int((v.l * 100).rounded()))%"
        return a < 1 ? "hsla(\(body), \(Self.short(a)))" : "hsl(\(body))"
    }

    var swiftUI: String {
        let base = String(format: "Color(red: %.3f, green: %.3f, blue: %.3f", r, g, b)
        return a < 1 ? base + String(format: ", opacity: %.2f)", a) : base + ")"
    }

    static func fromHSL(h: Double, s: Double, l: Double, a: Double = 1) -> ToolboxRGB {
        let hh = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((hh / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch hh {
        case 0..<60: (r, g, b) = (c, x, 0)
        case 60..<120: (r, g, b) = (x, c, 0)
        case 120..<180: (r, g, b) = (0, c, x)
        case 180..<240: (r, g, b) = (0, x, c)
        case 240..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return ToolboxRGB(r: r + m, g: g + m, b: b + m, a: a)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// Relative luminance (WCAG), to pick black or white text on top of the color.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    var isLight: Bool { luminance > 0.4 }

    /// Same hue, other lightness (for the shade strip).
    func withLightness(_ l: Double) -> ToolboxRGB {
        let v = hsl
        return Self.fromHSL(h: v.h, s: v.s, l: l, a: a)
    }

    private static func short(_ v: Double) -> String {
        let s = String(format: "%.2f", v)
        return s.hasSuffix("0") ? String(s.dropLast()) : s
    }

    /// "#F80", "#FF8800", "#FF880080", "rgb(255, 136, 0)", "hsl(32, 100%, 50%)", "Color(red: 1, green: 0.53, blue: 0)".
    /// With `bare`, "ff8800" and "255, 136, 0" are accepted too.
    static func parse(_ raw: String, bare: Bool = true) -> ToolboxRGB? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, s.count <= 80 else { return nil }
        if s.hasPrefix("#") { return parseHex(String(s.dropFirst())) }
        if s.hasPrefix("rgb") || s.hasPrefix("hsl") {
            guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
            let name = s[..<open].trimmingCharacters(in: .whitespaces)
            let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
            let parts = numbers(String(inner))
            guard parts.count == 3 || parts.count == 4 else { return nil }
            let alpha = parts.count == 4 ? parts[3].value * (parts[3].percent ? 0.01 : 1) : 1
            if name == "rgb" || name == "rgba" {
                let c = parts.prefix(3).map { $0.percent ? $0.value / 100 : $0.value / 255 }
                guard c.allSatisfy({ (0...1).contains($0) }) else { return nil }
                return ToolboxRGB(r: c[0], g: c[1], b: c[2], a: alpha)
            }
            if name == "hsl" || name == "hsla" {
                let s = parts[1].value / 100, l = parts[2].value / 100
                guard (0...1).contains(s), (0...1).contains(l) else { return nil }
                return fromHSL(h: parts[0].value, s: s, l: l, a: alpha)
            }
            return nil
        }
        if s.hasPrefix("color(") || s.hasPrefix("nscolor(") || s.hasPrefix("uicolor(") {
            let parts = numbers(s)
            guard parts.count == 3 || parts.count == 4, parts.allSatisfy({ (0...1).contains($0.value) }) else { return nil }
            return ToolboxRGB(r: parts[0].value, g: parts[1].value, b: parts[2].value, a: parts.count == 4 ? parts[3].value : 1)
        }
        guard bare else { return nil }
        if [3, 6, 8].contains(s.count), s.allSatisfy(\.isHexDigit) { return parseHex(s) }
        let parts = numbers(s)
        if parts.count == 3, s.allSatisfy({ $0.isNumber || $0 == "," || $0 == " " }),
           parts.allSatisfy({ (0...255).contains($0.value) }) {
            return ToolboxRGB(r: parts[0].value / 255, g: parts[1].value / 255, b: parts[2].value / 255)
        }
        return nil
    }

    private static func parseHex(_ h: String) -> ToolboxRGB? {
        guard h.allSatisfy(\.isHexDigit) else { return nil }
        var full = h
        if h.count == 3 || h.count == 4 { full = h.map { "\($0)\($0)" }.joined() }
        guard full.count == 6 || full.count == 8, let v = UInt64(full, radix: 16) else { return nil }
        if full.count == 8 {
            return ToolboxRGB(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
                              b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
        }
        return ToolboxRGB(hex: UInt32(v))
    }

    /// The numbers of a CSS-like list ("255, 136, 0", "32 100% 50% / 0.5"), with their "%" flag.
    private static func numbers(_ s: String) -> [(value: Double, percent: Bool)] {
        var out: [(Double, Bool)] = []
        var current = ""
        func flush(percent: Bool) {
            if let v = Double(current) { out.append((v, percent)) }
            current = ""
        }
        for c in s {
            if c.isNumber || c == "." || (c == "-" && current.isEmpty) {
                current.append(c)
            } else if c == "%" {
                flush(percent: true)
            } else if !current.isEmpty {
                flush(percent: false)
            }
        }
        if !current.isEmpty { flush(percent: false) }
        return out
    }
}

// MARK: - Secure randomness

enum ToolboxRandom {
    static func bytes(_ count: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &b)
        precondition(status == errSecSuccess, "Générateur aléatoire indisponible")
        return b
    }

    /// A uniform integer in 0..<upper, without modulo bias (rejection sampling).
    static func int(_ upper: Int) -> Int {
        precondition(upper > 0)
        guard upper > 1 else { return 0 }
        let bound = UInt64(upper)
        let limit = UInt64.max - (UInt64.max % bound)
        while true {
            let v = bytes(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            if v < limit { return Int(v % bound) }
        }
    }

    static func shuffle<T>(_ a: inout [T]) {
        guard a.count > 1 else { return }
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            a.swapAt(i, int(i + 1))
        }
    }
}

// MARK: - Passwords

struct ToolboxPasswordOptions: Codable, Equatable {
    var length = 20
    var upper = true
    var lower = true
    var digits = true
    var symbols = true
    var avoidAmbiguous = true
}

struct ToolboxPassphraseOptions: Codable, Equatable {
    var words = 6
    var separator = "-"
    var capitalize = true
    var addNumber = true
}

enum ToolboxPassword {
    static let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let lower = Array("abcdefghijklmnopqrstuvwxyz")
    static let digits = Array("0123456789")
    static let symbols = Array("!#$%&*+-=?@^_.,:;~()[]{}<>/|'\"`")
    /// Characters easy to confuse when read or typed by hand.
    static let ambiguous: Set<Character> = ["0", "O", "o", "1", "l", "I", "i", "L", "|", "`", "'", "\"", ",", ".", ";", ":",
                                            "(", ")", "[", "]", "{", "}", "<", ">", "/", "~"]
    static let lengthRange = 6...64

    static func classes(_ o: ToolboxPasswordOptions) -> [[Character]] {
        var sets: [[Character]] = []
        if o.upper { sets.append(upper) }
        if o.lower { sets.append(lower) }
        if o.digits { sets.append(digits) }
        if o.symbols { sets.append(symbols) }
        if sets.isEmpty { sets = [lower] }
        return o.avoidAmbiguous ? sets.map { $0.filter { !ambiguous.contains($0) } } : sets
    }

    /// At least one character of each chosen kind, the rest drawn from all of them, then shuffled.
    static func generate(_ o: ToolboxPasswordOptions) -> String {
        let sets = classes(o)
        let all = sets.flatMap { $0 }
        let length = min(lengthRange.upperBound, max(lengthRange.lowerBound, o.length))
        var chars = sets.prefix(length).map { $0[ToolboxRandom.int($0.count)] }
        while chars.count < length { chars.append(all[ToolboxRandom.int(all.count)]) }
        ToolboxRandom.shuffle(&chars)
        return String(chars)
    }

    static func entropy(_ o: ToolboxPasswordOptions) -> Double {
        let n = classes(o).reduce(0) { $0 + $1.count }
        return Double(min(lengthRange.upperBound, max(lengthRange.lowerBound, o.length))) * log2(Double(max(n, 2)))
    }

    static func passphrase(_ o: ToolboxPassphraseOptions) -> String {
        let count = min(12, max(3, o.words))
        var words = (0..<count).map { _ in ToolboxWords.list[ToolboxRandom.int(ToolboxWords.list.count)] }
        if o.capitalize { words = words.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
        if o.addNumber {
            let i = ToolboxRandom.int(words.count)
            words[i] += String(ToolboxRandom.int(10))
        }
        return words.joined(separator: o.separator)
    }

    static func passphraseEntropy(_ o: ToolboxPassphraseOptions) -> Double {
        let count = Double(min(12, max(3, o.words)))
        return count * log2(Double(ToolboxWords.list.count)) + (o.addNumber ? log2(10) + log2(count) : 0)
    }

    /// A label and a 0…1 score for the strength meter.
    static func strength(bits: Double) -> (label: String, score: Double, status: Status) {
        switch bits {
        case ..<40: return ("Faible", bits / 128, .bad)
        case 40..<60: return ("Correct", bits / 128, .warn)
        case 60..<90: return ("Solide", bits / 128, .info)
        default: return ("Excellent", min(1, bits / 128), .ok)
        }
    }
}

/// Short French words without accents (easy to type on any keyboard) for passphrases.
enum ToolboxWords {
    static let list: [String] = """
    abeille abricot acier agneau aigle algue amande ananas ancre anguille arbre argent armoire artichaut asperge atelier \
    avion avocat badge baguette baleine balcon ballon bambou banane bandeau barque bassin bateau bijou biscuit bison \
    blason bocal bouclier bougie bouquet boussole bouton branche brioche brique brouillard bulle bureau cabane cactus \
    cadeau cahier caillou camion canard  cantine capitaine caramel carnet carotte carton cascade casque castor \
    cerise chaise chameau champ chanson chapeau chardon chariot chaton chemin chemise cheval chocolat cigale citron \
    citrouille clairon clavier cloche coccinelle cocotte coffre colibri collier colline compas concombre coquelicot \
    coquille corbeau corde cornichon costume coton coussin couteau crabe crayon croissant cuisine cygne dauphin \
    dentelle diamant domino dragon drapeau enclume encre escargot fanfare farine faucon fauteuil fenouil fontaine \
    forge fourmi framboise fromage galet garage girafe glacier gland gomme gorille goutte grenier grenouille griffon \
    grotte guitare hamac hamster harpe hibou hirondelle horloge hublot igloo iris jardin jasmin jongleur journal \
    jungle kayak kiwi koala lagune lampe lanterne lapin laurier lavande licorne lierre limace lionne loutre lucarne \
    lune lutin macaron magnolia maison mandarine manteau marmotte marron masque matelas melon menthe miel miroir \
    montagne moulin mouton muguet myrtille nacelle navire nectar nuage oasis olive ombre orange ordinateur oreiller \
    origami ortie oursin palmier panda panier papillon parapluie parfum pastel patin pelote perle perroquet phare \
    piano pigeon pinceau pirate pivoine placard planche plume poivre pomme potiron poulpe prairie puzzle radis \
    raisin rameau raquette renard requin rivage robot roseau rubis ruche ruisseau sable sablier safran salade sapin \
    sardine satin saumon savon serpent sifflet singe sirop soleil sorbet souris statue sucre tambour tapis tasse \
    taupe tigre tilleul tipi tomate tonneau tornade tortue toupie tracteur tricot trompette tulipe tunnel valise \
    vanille velours verger violon voilier volcan wagon yaourt abri  aiguille album allure ambre amiral \
    anorak antenne aquarelle arche arrosoir astre aurore autruche aviron bagage balai balise bambin banjo baobab \
    barbe baril basilic bavoir berceau beignet bivouac blizzard bobine bolide bonnet bordure bosquet bottine boucle \
    boulon bourgeon brindille brise broche brosse buffle buisson cabine cacao cadran caravane carafe carillon cartable \
    cascadeur cellule chaloupe chandail charbon chardonneret chevalet chouette ciboulette cirque  comptoir \
    coquillage cordon corsaire cristal crochet cumulus curseur dalle damier dentiste dirigeable donjon duvet  \
     embrun  esquimau estuaire  falaise fanion fardeau  ficelle figue flacon flamant \
    flocon fougere fournaise frelon fusain gazelle geyser gibier girouette glaive gondole gourde granit grillon \
    guirlande haricot hermine hochet houblon iceberg jonquille joyau kimono lagon lambris lasso lilas lotus luciole \
    lynx madeleine mammouth mangue marelle marimba mascotte meringue mimosa mirabelle mistral mocassin moineau \
     moustique narval noisette nougat  ocelot opale orage orque osier ouragan palette pampa \
    panache papyrus parchemin passerelle pastille patio pelouse pendule  pergola pinson pistache plateau \
    pochoir poivron pompon portail potager poussin prisme pupitre quartz quille radeau ramure rempart rocher \
    roulotte ruban sabot saphir sarbacane    sextant silex sorcier soucoupe sphinx \
    stylo sureau tamis tanuki tartine terrier tisane toboggan topaze torrent toucan tourelle trappeur tremplin \
    triangle troupeau tuba turban vapeur vautour verrou vigie vitrail voyelle  
    """.split(whereSeparator: \.isWhitespace).map(String.init)
}

// MARK: - Digests

enum ToolboxHashAlgo: String, CaseIterable, Codable, Identifiable {
    case sha256, sha384, sha512, sha1, md5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sha256: return "SHA-256"
        case .sha384: return "SHA-384"
        case .sha512: return "SHA-512"
        case .sha1: return "SHA-1"
        case .md5: return "MD5"
        }
    }

    var hexLength: Int {
        switch self {
        case .md5: return 32
        case .sha1: return 40
        case .sha256: return 64
        case .sha384: return 96
        case .sha512: return 128
        }
    }

    /// SHA-1 and MD5 only prove a file was not damaged, not that nobody tampered with it.
    var isWeak: Bool { self == .sha1 || self == .md5 }
}

/// All five digests computed in a single pass.
struct ToolboxHasher {
    private var sha256 = SHA256()
    private var sha384 = SHA384()
    private var sha512 = SHA512()
    private var sha1 = Insecure.SHA1()
    private var md5 = Insecure.MD5()

    mutating func update(_ buffer: UnsafeRawBufferPointer) {
        sha256.update(bufferPointer: buffer)
        sha384.update(bufferPointer: buffer)
        sha512.update(bufferPointer: buffer)
        sha1.update(bufferPointer: buffer)
        md5.update(bufferPointer: buffer)
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    func finalize() -> [ToolboxHashAlgo: String] {
        [.sha256: ToolboxHash.hex(sha256.finalize()), .sha384: ToolboxHash.hex(sha384.finalize()),
         .sha512: ToolboxHash.hex(sha512.finalize()), .sha1: ToolboxHash.hex(sha1.finalize()), .md5: ToolboxHash.hex(md5.finalize())]
    }
}

enum ToolboxHash {
    struct Cancelled: Error {}

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func digests(of data: Data) -> [ToolboxHashAlgo: String] {
        var h = ToolboxHasher()
        h.update(data)
        return h.finalize()
    }

    /// Reads the file 1 Mo at a time (any size, constant memory). `progress` gets the bytes read so far.
    static func file(_ url: URL, cancel: CancelFlag, progress: (Int64) -> Void) throws -> [ToolboxHashAlgo: String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = ToolboxHasher()
        var done: Int64 = 0
        while true {
            if cancel.isCancelled { throw Cancelled() }
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(chunk)
            done += Int64(chunk.count)
            progress(done)
        }
        return hasher.finalize()
    }

    /// Lowercase hex, without spaces, colons or an "sha256:" style prefix.
    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixes = ["md5", "sha1", "sha-1", "sha256", "sha-256", "sha384", "sha-384", "sha512", "sha-512"]
        if let colon = t.firstIndex(of: ":"), prefixes.contains(t[..<colon].trimmingCharacters(in: .whitespaces)) {
            t = String(t[t.index(after: colon)...])
        } else if let p = prefixes.first(where: { t.hasPrefix($0 + " ") || t.hasPrefix($0 + "=") }) {
            t = String(t.dropFirst(p.count + 1))
        }
        return t.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
    }

    /// Which digest `expected` is, if it matches one of `results`.
    static func match(_ expected: String, in results: [ToolboxHashAlgo: String]) -> ToolboxHashAlgo? {
        let e = normalize(expected)
        guard !e.isEmpty else { return nil }
        return ToolboxHashAlgo.allCases.first { results[$0] == e }
    }

    /// The algorithm a pasted digest probably comes from, from its length.
    static func guess(_ expected: String) -> ToolboxHashAlgo? {
        let e = normalize(expected)
        guard e.allSatisfy(\.isHexDigit) else { return nil }
        return ToolboxHashAlgo.allCases.first { $0.hexLength == e.count }
    }
}

// MARK: - Text

enum ToolboxCase: String, CaseIterable, Identifiable, Codable {
    case upper, lower, title, sentence, camel, pascal, snake, constant, kebab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upper: return "MAJUSCULES"
        case .lower: return "minuscules"
        case .title: return "Titre"
        case .sentence: return "Phrase"
        case .camel: return "camelCase"
        case .pascal: return "PascalCase"
        case .snake: return "snake_case"
        case .constant: return "CONSTANTE"
        case .kebab: return "kebab-case"
        }
    }
}

struct ToolboxTextCounts: Equatable {
    var words = 0
    var characters = 0
    var charactersNoSpaces = 0
    var lines = 0
    var paragraphs = 0
    var bytes = 0

    /// About 230 words a minute.
    var readingTime: String {
        guard words > 0 else { return "0 s" }
        let seconds = Double(words) / 230 * 60
        return seconds < 60 ? "\(max(1, Int(seconds.rounded()))) s" : Fmt.duration(seconds)
    }
}

struct ToolboxJSONError: Error, Equatable {
    var message: String
    var line: Int
    var column: Int

    var description: String { "\(message) (ligne \(line), colonne \(column))" }
}

enum ToolboxText {
    static func base64Encode(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    /// Accepts line breaks, missing padding and the URL-safe alphabet. Nil if it is not Base64 of UTF-8 text.
    static func base64Data(_ s: String) -> Data? {
        var t = s.filter { !$0.isWhitespace }
        guard !t.isEmpty else { return nil }
        t = t.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = t.count % 4
        if rem == 1 { return nil }
        if rem > 0 { t += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: t)
    }

    static func base64Decode(_ s: String) -> String? {
        base64Data(s).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Everything but the RFC 3986 unreserved characters is percent-encoded.
    static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func urlDecode(_ s: String) -> String? {
        s.removingPercentEncoding
    }

    static func counts(_ s: String) -> ToolboxTextCounts {
        var c = ToolboxTextCounts()
        guard !s.isEmpty else { return c }
        var words = 0
        s.enumerateSubstrings(in: s.startIndex..<s.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        c.words = words
        c.characters = s.count
        c.charactersNoSpaces = s.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
        c.lines = s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        var paragraphs = 0
        var inParagraph = false
        for line in s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let blank = line.allSatisfy(\.isWhitespace)
            if !blank && !inParagraph { paragraphs += 1 }
            inParagraph = !blank
        }
        c.paragraphs = paragraphs
        c.bytes = s.utf8.count
        return c
    }

    // MARK: Case

    /// Words of an identifier or a sentence: "parseHTTPResponse2" → parse, HTTP, Response2.
    static func words(_ s: String) -> [String] {
        let chars = Array(s)
        var out: [String] = []
        var current = ""
        for (i, c) in chars.enumerated() {
            guard c.isLetter || c.isNumber else {
                if !current.isEmpty { out.append(current); current = "" }
                continue
            }
            if let prev = current.last, c.isUppercase {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && (next?.isLowercase ?? false)) {
                    out.append(current)
                    current = ""
                }
            }
            current.append(c)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func convertCase(_ s: String, to mode: ToolboxCase) -> String {
        let fr = Fmt.fr
        switch mode {
        case .upper: return s.uppercased(with: fr)
        case .lower: return s.lowercased(with: fr)
        case .title:
            var out = ""
            var startOfWord = true
            for c in s.lowercased(with: fr) {
                out += startOfWord ? String(c).uppercased(with: fr) : String(c)
                startOfWord = c.isWhitespace || c == "-" || c == "(" || c == "\"" || c == "«" || c == "/"
            }
            return out
        case .sentence:
            var out = ""
            var capitalize = true
            for c in s.lowercased(with: fr) {
                if capitalize && c.isLetter {
                    out += String(c).uppercased(with: fr)
                    capitalize = false
                } else {
                    out.append(c)
                }
                if c == "." || c == "!" || c == "?" || c.isNewline { capitalize = true }
            }
            return out
        case .camel, .pascal, .snake, .constant, .kebab:
            let plain = s.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: fr)
                .replacingOccurrences(of: "œ", with: "oe").replacingOccurrences(of: "Œ", with: "Oe")
                .replacingOccurrences(of: "æ", with: "ae").replacingOccurrences(of: "ß", with: "ss")
            let w = words(plain).map { $0.lowercased() }
            guard !w.isEmpty else { return "" }
            func cap(_ x: String) -> String { x.prefix(1).uppercased() + x.dropFirst() }
            switch mode {
            case .camel: return w[0] + w.dropFirst().map(cap).joined()
            case .pascal: return w.map(cap).joined()
            case .snake: return w.joined(separator: "_")
            case .constant: return w.joined(separator: "_").uppercased()
            default: return w.joined(separator: "-")
            }
        }
    }

    // MARK: JSON

    /// Validates and reformats JSON, keeping the order of keys and the exact spelling of numbers.
    static func json(_ s: String, pretty: Bool, indent: Int = 2) -> Result<String, ToolboxJSONError> {
        var p = ToolboxJSONFormatter(Array(s.utf8), pretty: pretty, indent: indent)
        do {
            try p.document()
            return .success(String(decoding: p.out, as: UTF8.self))
        } catch let e as ToolboxJSONFormatter.Failure {
            return .failure(p.error(e.message, at: e.offset))
        } catch {
            return .failure(ToolboxJSONError(message: "JSON invalide", line: 1, column: 1))
        }
    }

    // MARK: Lorem ipsum

    enum LoremUnit: String, CaseIterable, Identifiable, Codable {
        case paragraphs, sentences, words
        var id: String { rawValue }
        var title: String {
            switch self {
            case .paragraphs: return "Paragraphes"
            case .sentences: return "Phrases"
            case .words: return "Mots"
            }
        }
    }

    static let loremStart = "Lorem ipsum dolor sit amet, consectetur adipiscing elit"
    private static let loremWords = """
    lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna \
    aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo consequat duis \
    aute irure in reprehenderit voluptate velit esse cillum fugiat nulla pariatur excepteur sint occaecat cupidatat \
    non proident sunt culpa qui officia deserunt mollit anim id est laborum praesent vitae mauris integer feugiat \
    scelerisque varius morbi tristique senectus netus malesuada fames ac turpis egestas pellentesque habitant gravida \
    arcu vulputate eu facilisis volutpat nibh tellus molestie nunc mattis rhoncus urna neque viverra justo nec \
    ultrices dui sapien eget mi proin sagittis nisl quam lacus suspendisse faucibus interdum posuere lobortis cursus \
    vel risus commodo viverra maecenas accumsan semper auctor ornare massa tincidunt dictum fusce placerat orci
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    /// Classic Lorem ipsum: the first sentence is the usual one, the rest is drawn from `seed`.
    static func lorem(_ count: Int, unit: LoremUnit, seed: UInt64 = 1) -> String {
        var rng = ToolboxSplitMix(seed: seed)
        let opening = loremStart.split(separator: " ").map(String.init)
        func word() -> String { loremWords[Int(rng.next() % UInt64(loremWords.count))] }
        func sentence(first: Bool) -> String {
            let n = 7 + Int(rng.next() % 9)
            var w = first ? opening : []
            while w.count < n { w.append(word()) }
            if !first, w.count > 5, rng.next() % 3 == 0 { w[2 + Int(rng.next() % UInt64(w.count - 4))] += "," }
            let text = w.joined(separator: " ")
            return text.prefix(1).uppercased() + text.dropFirst() + "."
        }
        let n = max(1, min(count, 200))
        switch unit {
        case .words:
            var w = opening.map { $0.replacingOccurrences(of: ",", with: "") }
            while w.count < n { w.append(word()) }
            let text = w.prefix(n).joined(separator: " ")
            return text.prefix(1).uppercased() + text.dropFirst()
        case .sentences:
            return (0..<n).map { sentence(first: $0 == 0) }.joined(separator: " ")
        case .paragraphs:
            // Plain loops: Xcode 16's type checker gives up on the nested map version.
            var paragraphs: [String] = []
            for p in 0..<n {
                let length = 4 + Int(rng.next() % 3)
                var sentences: [String] = []
                for s in 0..<length { sentences.append(sentence(first: p == 0 && s == 0)) }
                paragraphs.append(sentences.joined(separator: " "))
            }
            return paragraphs.joined(separator: "\n\n")
        }
    }
}

/// A small deterministic generator (Lorem ipsum, demo data). Not for secrets.
struct ToolboxSplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A recursive descent JSON reader that writes its input back, pretty or compact, with French error messages.
struct ToolboxJSONFormatter {
    struct Failure: Error {
        var message: String
        var offset: Int
    }

    private let s: [UInt8]
    private var i = 0
    private let pretty: Bool
    private let indent: Int
    private var depth = 0
    var out: [UInt8] = []

    init(_ bytes: [UInt8], pretty: Bool, indent: Int) {
        s = bytes
        self.pretty = pretty
        self.indent = indent
        out.reserveCapacity(bytes.count + bytes.count / 4)
    }

    func error(_ message: String, at offset: Int) -> ToolboxJSONError {
        let prefix = s.prefix(max(0, min(offset, s.count)))
        let line = prefix.reduce(1) { $0 + ($1 == 10 ? 1 : 0) }
        let lastLine = prefix.lastIndex(of: 10).map { prefix.index(after: $0) } ?? prefix.startIndex
        let column = String(decoding: prefix[lastLine...], as: UTF8.self).count + 1
        return ToolboxJSONError(message: message, line: line, column: column)
    }

    mutating func document() throws {
        if s.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        skip()
        guard i < s.count else { throw Failure(message: "Le texte est vide", offset: i) }
        try value()
        skip()
        if i < s.count { throw Failure(message: "Contenu en trop après la fin du JSON", offset: i) }
    }

    private mutating func skip() {
        while i < s.count, s[i] == 0x20 || s[i] == 0x0A || s[i] == 0x0D || s[i] == 0x09 { i += 1 }
    }

    private mutating func newline() {
        guard pretty else { return }
        out.append(0x0A)
        out.append(contentsOf: [UInt8](repeating: 0x20, count: depth * indent))
    }

    private mutating func value() throws {
        guard i < s.count else { throw Failure(message: "Valeur attendue, le texte s'arrête trop tôt", offset: i) }
        switch s[i] {
        case UInt8(ascii: "{"): try container(close: UInt8(ascii: "}"), isObject: true)
        case UInt8(ascii: "["): try container(close: UInt8(ascii: "]"), isObject: false)
        case UInt8(ascii: "\""): try string()
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): try number()
        case UInt8(ascii: "t"): try literal("true")
        case UInt8(ascii: "f"): try literal("false")
        case UInt8(ascii: "n"): try literal("null")
        case UInt8(ascii: "'"): throw Failure(message: "Les textes JSON s'écrivent entre guillemets doubles", offset: i)
        case UInt8(ascii: "}"), UInt8(ascii: "]"): throw Failure(message: "Valeur attendue avant « \(Character(Unicode.Scalar(s[i]))) »", offset: i)
        default: throw Failure(message: "Valeur attendue (objet, tableau, texte, nombre, true, false ou null)", offset: i)
        }
    }

    private mutating func container(close: UInt8, isObject: Bool) throws {
        let open = i
        depth += 1
        guard depth <= 512 else { throw Failure(message: "Imbrication trop profonde", offset: i) }
        out.append(s[i])
        i += 1
        skip()
        if i < s.count, s[i] == close {
            out.append(close)
            i += 1
            depth -= 1
            return
        }
        var first = true
        while true {
            if !first {
                out.append(UInt8(ascii: ","))
            }
            newline()
            first = false
            skip()
            if isObject {
                guard i < s.count else { throw Failure(message: "« } » manquant pour fermer l'objet", offset: open) }
                if s[i] == UInt8(ascii: "'") { throw Failure(message: "Les clés JSON s'écrivent entre guillemets doubles", offset: i) }
                guard s[i] == UInt8(ascii: "\"") else { throw Failure(message: "Nom de clé entre guillemets attendu", offset: i) }
                try string()
                skip()
                guard i < s.count, s[i] == UInt8(ascii: ":") else { throw Failure(message: "« : » attendu après la clé", offset: i) }
                i += 1
                out.append(UInt8(ascii: ":"))
                if pretty { out.append(0x20) }
                skip()
            }
            try value()
            skip()
            guard i < s.count else {
                throw Failure(message: isObject ? "« } » manquant pour fermer l'objet" : "« ] » manquant pour fermer le tableau", offset: open)
            }
            if s[i] == UInt8(ascii: ",") {
                i += 1
                skip()
                if i < s.count, s[i] == close { throw Failure(message: "Virgule en trop avant « \(Character(Unicode.Scalar(close))) »", offset: i) }
                continue
            }
            if s[i] == close {
                i += 1
                depth -= 1
                newline()
                out.append(close)
                return
            }
            throw Failure(message: isObject ? "« , » ou « } » attendu" : "« , » ou « ] » attendu", offset: i)
        }
    }

    private mutating func string() throws {
        let start = i
        i += 1
        while i < s.count {
            let c = s[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                out.append(contentsOf: s[start..<i])
                return
            }
            if c < 0x20 { throw Failure(message: "Retour à la ligne ou tabulation dans un texte (écris \\n ou \\t)", offset: i) }
            if c == UInt8(ascii: "\\") {
                guard i + 1 < s.count else { break }
                let e = s[i + 1]
                if e == UInt8(ascii: "u") {
                    guard i + 5 < s.count, s[(i + 2)...(i + 5)].allSatisfy({ Character(Unicode.Scalar($0)).isHexDigit }) else {
                        throw Failure(message: "Échappement \\u invalide (4 chiffres hexadécimaux attendus)", offset: i)
                    }
                    i += 6
                    continue
                }
                guard "\"\\/bfnrt".utf8.contains(e) else { throw Failure(message: "Échappement invalide « \\\(Character(Unicode.Scalar(e))) »", offset: i) }
                i += 2
                continue
            }
            i += 1
        }
        throw Failure(message: "Texte non terminé : guillemet fermant manquant", offset: start)
    }

    private mutating func number() throws {
        let start = i
        func digits() -> Int {
            let from = i
            while i < s.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(s[i]) { i += 1 }
            return i - from
        }
        if s[i] == UInt8(ascii: "-") { i += 1 }
        guard i < s.count else { throw Failure(message: "Nombre invalide", offset: start) }
        if s[i] == UInt8(ascii: "0") {
            i += 1
            if i < s.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(s[i]) {
                throw Failure(message: "Un nombre ne commence pas par 0", offset: start)
            }
        } else if digits() == 0 {
            throw Failure(message: "Nombre invalide", offset: start)
        }
        if i < s.count, s[i] == UInt8(ascii: ".") {
            i += 1
            if digits() == 0 { throw Failure(message: "Chiffre attendu après la virgule décimale", offset: i) }
        }
        if i < s.count, s[i] == UInt8(ascii: "e") || s[i] == UInt8(ascii: "E") {
            i += 1
            if i < s.count, s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-") { i += 1 }
            if digits() == 0 { throw Failure(message: "Exposant invalide", offset: i) }
        }
        out.append(contentsOf: s[start..<i])
    }

    private mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= s.count, Array(s[i..<(i + w.count)]) == w else {
            throw Failure(message: "Mot inconnu (true, false ou null attendu ; les textes vont entre guillemets)", offset: i)
        }
        out.append(contentsOf: w)
        i += w.count
    }
}

// MARK: - Dates

enum ToolboxTime {
    struct Parsed {
        var date: Date
        var source: String
    }

    private static func posix(_ format: String, utc: Bool = false) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // Autoupdating: these formatters live as long as the app, which may cross a time zone change.
        f.timeZone = utc ? TimeZone(identifier: "UTC") : .autoupdatingCurrent
        f.dateFormat = format
        return f
    }

    private static let localFormats: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd",
        "dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm", "dd/MM/yyyy", "dd.MM.yyyy HH:mm", "dd.MM.yyyy", "yyyy/MM/dd HH:mm", "yyyy/MM/dd"
    ].map { posix($0) }

    private static let iso: [ISO8601DateFormatter] = {
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let b = ISO8601DateFormatter()
        b.formatOptions = [.withInternetDateTime]
        return [a, b]
    }()

    /// A Unix timestamp (s, ms, µs or ns, guessed from its length), an ISO 8601 date or a usual local date.
    /// `minDigits` keeps short numbers (years, amounts) from being read as timestamps in the launcher.
    static func parse(_ raw: String, minDigits: Int = 1) -> Parsed? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 40 else { return nil }
        let lower = Fuzzy.fold(s)
        if ["maintenant", "now", "aujourd'hui"].contains(lower) { return Parsed(date: Date(), source: "Maintenant") }
        let unsigned = s.hasPrefix("-") ? String(s.dropFirst()) : s
        let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
           let v = Double(s) {
            let digits = parts[0].count
            guard digits >= minDigits, digits <= 19 else { return nil }
            switch digits {
            case ...11: return Parsed(date: Date(timeIntervalSince1970: v), source: "Horodatage en secondes")
            case 12...14: return Parsed(date: Date(timeIntervalSince1970: v / 1000), source: "Horodatage en millisecondes")
            case 15...17: return Parsed(date: Date(timeIntervalSince1970: v / 1_000_000), source: "Horodatage en microsecondes")
            default: return Parsed(date: Date(timeIntervalSince1970: v / 1_000_000_000), source: "Horodatage en nanosecondes")
            }
        }
        guard minDigits <= 1 || s.contains("-") || s.contains("/") || s.contains(".") else { return nil }
        for f in iso {
            if let d = f.date(from: s) { return Parsed(date: d, source: "Date ISO 8601") }
        }
        for f in localFormats {
            if let d = f.date(from: s) { return Parsed(date: d, source: "Date locale") }
        }
        return nil
    }

    private static let isoUTC: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoLocal: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .autoupdatingCurrent
        return f
    }()

    private static let long: DateFormatter = {
        let f = DateFormatter()
        f.locale = Fmt.fr
        f.timeZone = .autoupdatingCurrent
        f.dateStyle = .full
        f.timeStyle = .medium
        return f
    }()

    private static let relativeF: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Fmt.fr
        f.unitsStyle = .full
        return f
    }()

    static func unix(_ d: Date) -> String { String(Int64(d.timeIntervalSince1970.rounded(.down))) }
    static func unixMillis(_ d: Date) -> String { String(Int64((d.timeIntervalSince1970 * 1000).rounded(.down))) }
    static func isoString(_ d: Date) -> String { isoUTC.string(from: d) }
    static func longString(_ d: Date) -> String { long.string(from: d) }

    static func relative(_ d: Date, now: Date = Date()) -> String {
        abs(d.timeIntervalSince(now)) < 1 ? "maintenant" : relativeF.localizedString(for: d, relativeTo: now)
    }

    /// Every useful way to write `d`, as (label, value) rows.
    static func describe(_ d: Date, now: Date = Date()) -> [(label: String, value: String)] {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        let week = cal.component(.weekOfYear, from: d)
        let day = cal.ordinality(of: .day, in: .year, for: d) ?? 0
        return [
            ("Horodatage Unix", unix(d)),
            ("En millisecondes", unixMillis(d)),
            ("ISO 8601 (UTC)", isoString(d)),
            ("ISO 8601 (local)", isoLocal.string(from: d)),
            ("Date", Fmt.cap(longString(d))),
            ("Par rapport à maintenant", Fmt.cap(relative(d, now: now))),
            ("Calendrier", "Semaine \(week), jour \(day) de l'année")
        ]
    }

    /// "15", "15 min", "1h", "1 h 30", "90min", "2h" → minutes; "indéfiniment" → 0 (no end); "off", "stop" → nil with `stop`.
    enum Duration: Equatable {
        case minutes(Int)
        case indefinite
        case stop
    }

    static func duration(_ raw: String) -> Duration? {
        let s = Fuzzy.fold(raw).replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        if ["off", "stop", "arret", "arreter", "non", "fin", "desactiver"].contains(s) { return .stop }
        if ["on", "indefiniment", "toujours", "infini", "sanslimite", "∞"].contains(s) { return .indefinite }
        var minutes = 0
        var number = ""
        var sawUnit = false
        // More than 6 digits is never a real duration, and could overflow once turned into minutes.
        func value(_ digits: String) -> Int? { digits.count <= 6 ? Int(digits) : nil }
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c.isNumber {
                number.append(c)
                i = s.index(after: i)
                continue
            }
            let rest = s[i...]
            guard let n = value(number) else { return nil }
            if rest.hasPrefix("heures") || rest.hasPrefix("heure") || rest.hasPrefix("h") {
                minutes += n * 60
                let len = rest.hasPrefix("heures") ? 6 : (rest.hasPrefix("heure") ? 5 : 1)
                i = s.index(i, offsetBy: len)
                number = ""
                sawUnit = true
                // "1h30": the trailing number is minutes.
                if i < s.endIndex, s[i...].allSatisfy(\.isNumber), let m = value(String(s[i...])) { return m < 60 ? .minutes(minutes + m) : nil }
                continue
            }
            if rest.hasPrefix("minutes") || rest.hasPrefix("minute") || rest.hasPrefix("min") || rest.hasPrefix("mn") || rest.hasPrefix("m") {
                minutes += n
                let len = rest.hasPrefix("minutes") ? 7 : (rest.hasPrefix("minute") ? 6 : (rest.hasPrefix("min") ? 3 : (rest.hasPrefix("mn") ? 2 : 1)))
                i = s.index(i, offsetBy: len)
                number = ""
                sawUnit = true
                continue
            }
            return nil
        }
        if !number.isEmpty {
            // A bare number is minutes ("15").
            guard !sawUnit, let n = value(number) else { return nil }
            minutes += n
        }
        guard minutes > 0, minutes <= 7 * 24 * 60 else { return nil }
        return .minutes(minutes)
    }

    static func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(String(format: "%02d", m))"
    }
}
