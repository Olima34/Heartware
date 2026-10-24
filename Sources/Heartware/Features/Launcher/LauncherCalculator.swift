import Foundation

/// A small, crash-proof arithmetic parser (NSExpression throws uncatchable exceptions on bad input).
/// Accepts the French decimal comma, × ÷ ^, %, parentheses, a few functions and constants.
enum LauncherCalculator {
    private enum Token: Equatable {
        case number(Double), op(Character), lparen, rparen, ident(String)
    }

    static let functions: [String: (Double) -> Double] = [
        "sqrt": { $0.squareRoot() }, "racine": { $0.squareRoot() }, "abs": { abs($0) },
        "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) },
        "ln": { log($0) }, "log": { log10($0) }, "exp": { exp($0) },
        "round": { $0.rounded() }, "arrondi": { $0.rounded() }, "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) }
    ]
    static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E]

    /// The value of `input` if it is a calculation (a lone number is not), else nil.
    static func evaluate(_ input: String) -> Double? {
        let text = joinThousands(input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "=", with: ""))
        guard !text.isEmpty, text.count <= 200, text.contains(where: \.isNumber) else { return nil }
        guard let tokens = tokenize(text) else { return nil }
        let isCalculation = tokens.contains { if case .op = $0 { return true }; if case .ident = $0 { return true }; return false }
        guard isCalculation else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        return value
    }

    /// French display: "1 234,5". At least 10 significant digits, more for a large number (up to 15, what a Double
    /// holds exactly), so that "12345678901*10" shows and copies every digit.
    static func format(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = Fmt.fr
        f.numberStyle = .decimal
        f.usesSignificantDigits = true
        let integerDigits = abs(v) >= 1 ? Int(log10(abs(v))) + 1 : 1
        f.maximumSignificantDigits = min(15, max(10, integerDigits + 3))
        if abs(v) >= 1e15 || (abs(v) < 1e-6 && v != 0) {
            f.numberStyle = .scientific
        }
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// "1 000" or "1 500,15" (the calculator's own display, with its narrow spaces) → "1000", "1500,15":
    /// spaces between groups of three digits are thousands separators. "2 3" or "06 12 34" stay as typed.
    static func joinThousands(_ s: String) -> String {
        guard s.contains(where: { $0 == " " || $0 == "\u{00A0}" || $0 == "\u{202F}" }) else { return s }
        var out = s
        for m in thousandsPattern.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: out[r].filter(\.isNumber))
        }
        return out
    }

    private static let thousandsPattern = try! NSRegularExpression(pattern: "(?<![0-9.,])[0-9]{1,3}(?:[ \u{00A0}\u{202F}][0-9]{3})+(?![0-9])")

    private static func tokenize(_ s: String) -> [Token]? {
        var tokens: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == " " || c == "\u{00A0}" || c == "\u{202F}" {
                i = s.index(after: i)
            } else if c.isNumber || c == "." || c == "," {
                var j = i
                var seenSep = false
                while j < s.endIndex, s[j].isNumber || ((s[j] == "." || s[j] == ",") && !seenSep) {
                    if s[j] == "." || s[j] == "," { seenSep = true }
                    j = s.index(after: j)
                }
                guard let v = Double(s[i..<j].replacingOccurrences(of: ",", with: ".")) else { return nil }
                tokens.append(.number(v))
                i = j
            } else if "+-*/^%×÷x".contains(c) {
                let op: Character = c == "×" || c == "x" ? "*" : (c == "÷" ? "/" : c)
                // "x" is a multiplication only between two numbers ("3x4").
                if c == "x", !(tokens.last.map { if case .number = $0 { return true }; if case .rparen = $0 { return true }; return false } ?? false) {
                    return nil
                }
                tokens.append(.op(op))
                i = s.index(after: i)
            } else if c == "(" {
                tokens.append(.lparen); i = s.index(after: i)
            } else if c == ")" {
                tokens.append(.rparen); i = s.index(after: i)
            } else if c.isLetter || c == "π" {
                var j = i
                while j < s.endIndex, s[j].isLetter || s[j] == "π" { j = s.index(after: j) }
                let name = s[i..<j].lowercased()
                guard functions[name] != nil || constants[name] != nil else { return nil }
                tokens.append(.ident(name))
                i = j
            } else {
                return nil
            }
        }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var pos = 0

        var atEnd: Bool { pos == tokens.count }

        private func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }

        // expression := term (("+"|"-") term)*
        // "a + b %" and "a - b %" add or take b percent of a, like a pocket calculator ("1500 + 15 %" = 1725).
        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while case .op(let o)? = peek(), o == "+" || o == "-" {
                pos += 1
                if let rate = percentTerm() {
                    v = o == "+" ? v * (1 + rate) : v * (1 - rate)
                    continue
                }
                guard let r = term() else { return nil }
                v = o == "+" ? v + r : v - r
            }
            return v
        }

        /// b/100 when the next term is exactly "number %" (then the end, ")", "+" or "-"), which it consumes.
        private mutating func percentTerm() -> Double? {
            guard pos + 1 < tokens.count, case .number(let n) = tokens[pos], tokens[pos + 1] == .op("%") else { return nil }
            switch pos + 2 < tokens.count ? tokens[pos + 2] : nil {
            case nil, .rparen?, .op("+")?, .op("-")?: break
            default: return nil
            }
            pos += 2
            return n / 100
        }

        // term := unary (("*"|"/") unary)*
        mutating func term() -> Double? {
            guard var v = unary() else { return nil }
            while case .op(let o)? = peek(), o == "*" || o == "/" {
                pos += 1
                guard let r = unary() else { return nil }
                v = o == "*" ? v * r : v / r
            }
            return v
        }

        // unary := ("-"|"+") unary | power   ("-2^2" = -4, as in mathematics)
        mutating func unary() -> Double? {
            if case .op(let o)? = peek(), o == "-" || o == "+" {
                pos += 1
                guard let v = unary() else { return nil }
                return o == "-" ? -v : v
            }
            return power()
        }

        // power := postfix ("^" unary)?   (right-associative, and "2^-1" = 0.5)
        mutating func power() -> Double? {
            guard let base = postfix() else { return nil }
            if case .op("^")? = peek() {
                pos += 1
                guard let e = unary() else { return nil }
                return pow(base, e)
            }
            return base
        }

        // postfix := primary "%"*
        mutating func postfix() -> Double? {
            guard var v = primary() else { return nil }
            while case .op("%")? = peek() {
                pos += 1
                v /= 100
            }
            return v
        }

        mutating func primary() -> Double? {
            guard let t = peek() else { return nil }
            pos += 1
            switch t {
            case .number(let v):
                return v
            case .lparen:
                guard let v = expression(), case .rparen? = peek() else { return nil }
                pos += 1
                return v
            case .ident(let name):
                if let c = LauncherCalculator.constants[name] { return c }
                guard let f = LauncherCalculator.functions[name], case .lparen? = peek() else { return nil }
                pos += 1
                guard let arg = expression(), case .rparen? = peek() else { return nil }
                pos += 1
                return f(arg)
            default:
                return nil
            }
        }
    }
}

/// "10 km en miles", "100 °F en °C", "5 Go en Mo", "2 h en min"…
enum LauncherUnits {
    private static let day = UnitDuration(symbol: "j", converter: UnitConverterLinear(coefficient: 86400))
    private static let week = UnitDuration(symbol: "sem.", converter: UnitConverterLinear(coefficient: 604800))

    /// Exact spellings first (Mb ≠ MB), then case-insensitive ones.
    private static let exact: [String: Dimension] = [
        "B": UnitInformationStorage.bytes, "KB": UnitInformationStorage.kilobytes, "MB": UnitInformationStorage.megabytes,
        "GB": UnitInformationStorage.gigabytes, "TB": UnitInformationStorage.terabytes,
        "Kb": UnitInformationStorage.kilobits, "Mb": UnitInformationStorage.megabits, "Gb": UnitInformationStorage.gigabits,
        "K": UnitTemperature.kelvin
    ]

    private static let names: [String: Dimension] = {
        var d: [String: Dimension] = [:]
        func add(_ unit: Dimension, _ aliases: String...) { aliases.forEach { d[$0] = unit } }
        // Length
        add(UnitLength.millimeters, "mm", "millimètre", "millimètres")
        add(UnitLength.centimeters, "cm", "centimètre", "centimètres")
        add(UnitLength.meters, "m", "mètre", "mètres", "metre", "metres")
        add(UnitLength.kilometers, "km", "kilomètre", "kilomètres")
        add(UnitLength.inches, "in", "pouce", "pouces", "inch", "inches", "\"")
        add(UnitLength.feet, "ft", "pied", "pieds", "foot", "feet")
        add(UnitLength.yards, "yd", "yard", "yards")
        add(UnitLength.miles, "mi", "mile", "miles")
        add(UnitLength.nauticalMiles, "nmi", "mille marin", "milles marins")
        // Mass
        add(UnitMass.milligrams, "mg", "milligramme", "milligrammes")
        add(UnitMass.grams, "g", "gramme", "grammes")
        add(UnitMass.kilograms, "kg", "kilo", "kilos", "kilogramme", "kilogrammes")
        add(UnitMass.metricTons, "t", "tonne", "tonnes")
        add(UnitMass.ounces, "oz", "once", "onces", "ounce", "ounces")
        add(UnitMass.pounds, "lb", "lbs", "livre", "livres", "pound", "pounds")
        // Temperature
        add(UnitTemperature.celsius, "°c", "c", "celsius", "degrés celsius")
        add(UnitTemperature.fahrenheit, "°f", "f", "fahrenheit")
        add(UnitTemperature.kelvin, "kelvin", "kelvins")
        // Volume
        add(UnitVolume.milliliters, "ml", "millilitre", "millilitres")
        add(UnitVolume.centiliters, "cl", "centilitre", "centilitres")
        add(UnitVolume.deciliters, "dl", "décilitre", "décilitres")
        add(UnitVolume.liters, "l", "litre", "litres")
        add(UnitVolume.cubicMeters, "m3", "m³", "mètre cube", "mètres cubes")
        add(UnitVolume.gallons, "gal", "gallon", "gallons")
        add(UnitVolume.fluidOunces, "fl oz", "floz")
        add(UnitVolume.cups, "cup", "cups", "tasse", "tasses")
        // Speed
        add(UnitSpeed.kilometersPerHour, "km/h", "kmh", "kph")
        add(UnitSpeed.milesPerHour, "mph", "mi/h")
        add(UnitSpeed.metersPerSecond, "m/s")
        add(UnitSpeed.knots, "nœud", "nœuds", "noeud", "noeuds", "kn", "kt")
        // Area
        add(UnitArea.squareMeters, "m2", "m²", "mètre carré", "mètres carrés")
        add(UnitArea.squareKilometers, "km2", "km²")
        add(UnitArea.hectares, "ha", "hectare", "hectares")
        add(UnitArea.acres, "acre", "acres")
        add(UnitArea.squareFeet, "ft2", "ft²", "pied carré", "pieds carrés")
        // Data (decimal units, like the Finder)
        add(UnitInformationStorage.bytes, "o", "octet", "octets", "byte", "bytes")
        add(UnitInformationStorage.kilobytes, "ko", "kilooctet", "kilooctets")
        add(UnitInformationStorage.megabytes, "mo", "mégaoctet", "mégaoctets")
        add(UnitInformationStorage.gigabytes, "go", "gigaoctet", "gigaoctets")
        add(UnitInformationStorage.terabytes, "to", "téraoctet", "téraoctets")
        add(UnitInformationStorage.kibibytes, "kio", "kib")
        add(UnitInformationStorage.mebibytes, "mio", "mib")
        add(UnitInformationStorage.gibibytes, "gio", "gib")
        add(UnitInformationStorage.tebibytes, "tio", "tib")
        add(UnitInformationStorage.bits, "bit", "bits")
        add(UnitInformationStorage.kilobits, "kbit", "kbits")
        add(UnitInformationStorage.megabits, "mbit", "mbits")
        add(UnitInformationStorage.gigabits, "gbit", "gbits")
        // Time
        add(UnitDuration.seconds, "s", "sec", "seconde", "secondes")
        add(UnitDuration.minutes, "min", "minute", "minutes")
        add(UnitDuration.hours, "h", "heure", "heures")
        add(day, "j", "jour", "jours", "day", "days")
        add(week, "sem", "semaine", "semaines", "week", "weeks")
        // Energy
        add(UnitEnergy.kilocalories, "kcal", "calorie", "calories")
        add(UnitEnergy.kilojoules, "kj", "kilojoule", "kilojoules")
        add(UnitEnergy.joules, "joule", "joules")
        add(UnitEnergy.kilowattHours, "kwh")
        // Angle
        add(UnitAngle.degrees, "°", "deg", "degré", "degrés")
        add(UnitAngle.radians, "rad", "radian", "radians")
        // Pressure
        add(UnitPressure.bars, "bar", "bars")
        add(UnitPressure.poundsForcePerSquareInch, "psi")
        add(UnitPressure.hectopascals, "hpa")
        return d
    }()

    static func unit(_ raw: String) -> Dimension? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let u = exact[s] { return u }
        return names[s.lowercased()]
    }

    /// (input, result) such as ("10 km", "6,214 mi"), or nil if `query` is not a conversion.
    static func convert(_ raw: String) -> (from: String, to: String, value: Double)? {
        let query = LauncherCalculator.joinThousands(raw)
        let separators = [" en ", " in ", " to ", " vers ", " → ", " -> ", " = "]
        guard let sep = separators.first(where: { query.contains($0) }),
              let range = query.range(of: sep) else { return nil }
        let left = query[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let right = query[range.upperBound...].trimmingCharacters(in: .whitespaces)
        // Split "10km" / "10 km" / "1,5 kg" into number and unit.
        guard let firstNonNumber = left.firstIndex(where: { !($0.isNumber || $0 == "," || $0 == "." || $0 == "-" || $0 == " ") }) else {
            return nil
        }
        let numberText = left[..<firstNonNumber].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(numberText),
              let from = unit(String(left[firstNonNumber...])), let to = unit(right),
              type(of: from).baseUnit().symbol == type(of: to).baseUnit().symbol else { return nil }
        let result = Measurement(value: value, unit: from).converted(to: to).value
        return ("\(LauncherCalculator.format(value)) \(symbol(from))", "\(LauncherCalculator.format(result)) \(symbol(to))", result)
    }

    /// The French symbol of a unit ("h", "Go", "kcal"…): Foundation's are the English ones ("hr", "GB", "kCal").
    static func symbol(_ unit: Dimension) -> String {
        frenchSymbols[unit.symbol] ?? unit.symbol
    }

    private static let frenchSymbols: [String: String] = [
        "hr": "h", "B": "o", "kB": "ko", "MB": "Mo", "GB": "Go", "TB": "To",
        "KiB": "Kio", "MiB": "Mio", "GiB": "Gio", "TiB": "Tio", "kb": "kbit", "Mb": "Mbit", "Gb": "Gbit",
        "kCal": "kcal", "L": "l", "mL": "ml", "cL": "cl", "dL": "dl", "mph": "mi/h", "kn": "nd", "NM": "nmi", "cup": "tasse"
    ]
}

/// "heure Tokyo", "heure à New York" → current time there.
enum LauncherWorldClock {
    private static let french: [String: String] = [
        "londres": "London", "pékin": "Shanghai", "pekin": "Shanghai", "moscou": "Moscow", "le caire": "Cairo",
        "mexico": "Mexico_City", "new york": "New_York", "los angeles": "Los_Angeles", "san francisco": "Los_Angeles",
        "montréal": "Toronto", "montreal": "Toronto", "québec": "Toronto", "lisbonne": "Lisbon", "varsovie": "Warsaw",
        "vienne": "Vienna", "athènes": "Athens", "bruxelles": "Brussels", "genève": "Zurich", "geneve": "Zurich",
        "copenhague": "Copenhagen", "séoul": "Seoul", "seoul": "Seoul", "singapour": "Singapore", "bombay": "Kolkata",
        "dubaï": "Dubai", "rio": "Sao_Paulo", "sao paulo": "Sao_Paulo", "la réunion": "Reunion", "réunion": "Reunion",
        "nouméa": "Noumea", "papeete": "Tahiti", "pointe-à-pitre": "Guadeloupe", "fort-de-france": "Martinique",
        "paris": "Paris", "tokyo": "Tokyo", "sydney": "Sydney", "berlin": "Berlin", "madrid": "Madrid", "rome": "Rome"
    ]

    static func answer(_ query: String) -> (city: String, time: String)? {
        let q = query.lowercased()
        let prefixes = ["heure à ", "heure a ", "heure ", "time in ", "time "]
        guard let p = prefixes.first(where: { q.hasPrefix($0) }) else { return nil }
        let city = String(q.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        guard city.count >= 3 else { return nil }
        let key = french[city] ?? city.replacingOccurrences(of: " ", with: "_")
        guard let id = TimeZone.knownTimeZoneIdentifiers.first(where: { $0.lowercased().hasSuffix("/" + key.lowercased()) }),
              let tz = TimeZone(identifier: id) else { return nil }
        let f = DateFormatter()
        f.locale = Fmt.fr
        f.timeZone = tz
        f.dateFormat = "HH:mm, EEEE d MMMM"
        return (title(city), f.string(from: Date()))
    }

    /// "new york" → "New York", "le caire" → "Le Caire", "pointe-à-pitre" → "Pointe-à-Pitre".
    static func title(_ city: String) -> String {
        let small: Set<String> = ["à", "a", "de", "du", "des", "la", "le", "les", "sur", "en"]
        var out = "", word = ""
        var first = true
        func flush() {
            out += !first && small.contains(word) ? word : word.prefix(1).uppercased() + word.dropFirst()
            word = ""
            first = false
        }
        for c in city {
            if c == " " || c == "-" {
                flush()
                out.append(c)
            } else {
                word.append(c)
            }
        }
        flush()
        return out
    }
}
