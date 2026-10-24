import Foundation

/// Reads what `windscribe-cli` prints (source: github.com/Windscribe/Desktop-App, src/windscribe-cli/backendcommander.cpp
/// and strings.cpp). Its words follow the language of the Windscribe app (`LanguageController::setLanguage(state->language_)`),
/// so `status` is read by the place and the shape of its lines first, its words (English, French, Spanish, German,
/// Italian, from the CLI's translations) only where the shape is not enough:
///
///     Internet connectivity: available          ← always
///     Login state: Logged in                    ← always
///     Firewall state: Off                       ← always
///     Connect state: Connected: Paris - Seine   ← unless logged out ("*" first while the tunnel is tested)
///     Protocol: WireGuard:443                   ← unless disconnected
///     VPN IP: 203.0.113.24                      ← when known ("Public IP" outside the tunnel)
///     Data usage: 3.20 GB / 10.00 GB            ← only when logged in (QLocale data size, base 1024)
///     Update available: 2.25.1                  ← sometimes
enum VPNStatusParser {
    struct Field {
        var raw: String
        var label: String
        var value: String
    }

    // The CLI's words, folded (lower case, no accents, straight apostrophes): en, fr, es, de, it.
    static let loggedInWords: Set<String> = ["logged in", "connecte", "conectado", "eingeloggt", "effettuato l'accesso"]
    static let loggedOutWords: Set<String> = ["logged out", "deconnecte", "sesion cerrada", "abgemeldet", "disconnesso"]
    static let loggingInWords: Set<String> = ["logging in", "connexion", "iniciando sesion", "einloggen", "effettuare l'accesso"]
    static let connectedWords: Set<String> = ["connected", "connecte", "relie", "conectado", "verbunden", "collegato", "connesso"]
    static let connectingWords: Set<String> = ["connecting", "connexion", "connectant", "conectando", "verbinden", "verbindend",
                                               "connessione", "connettivo"]
    static let disconnectingWords: Set<String> = ["disconnecting", "deconnexion", "desconectando", "trennend", "scollegare"]
    static let disconnectedWords: Set<String> = ["disconnected", "coupe", "desconectado", "entfernt", "sconnesso"]
    static let errorWords: Set<String> = ["error", "erreur", "fehler", "errore"]
    static let unavailableWords: Set<String> = ["unavailable", "indisponible", "no disponible", "nicht verfugbar", "indisponibile"]
    static let locationUnavailablePhrases = ["location does not exist", "l'emplacement n'existe pas", "la ubicacion no existe",
                                             "standort ist nicht vorhanden", "la posizione non esiste"]
    static let outOfDataPhrases = ["out of data", "plus de donnees", "sin datos", "keine daten mehr", "esaurito i dati"]

    /// Lower case, no accents, straight apostrophes, single spaces.
    static func fold(_ s: String) -> String {
        Fuzzy.fold(s)
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Label: value" split at its first colon (the French ones have a space, often a non-breaking one, before it).
    static func field(_ line: String) -> Field {
        guard let colon = line.firstIndex(of: ":") else { return Field(raw: line, label: line, value: "") }
        let label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return Field(raw: line, label: label, value: value)
    }

    /// nil when the text is not a status (an error line such as "Not logged in").
    static func parse(_ text: String) -> VPNStatus? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 3 else { return nil }
        let fields = lines.map(field)
        // Connectivity, login and firewall: three "label: value" lines.
        guard fields.prefix(3).allSatisfy({ !$0.label.isEmpty && !$0.value.isEmpty }) else { return nil }

        var s = VPNStatus()
        s.internet = !unavailableWords.contains(fold(fields[0].value))
        let rest = Array(fields.dropFirst(3))

        // The data line: "<size> / <size or Unlimited>".
        if let u = rest.lazy.compactMap({ usage($0.value) }).first {
            s.used = u.used
            s.limit = u.limit
        }
        // The connect line comes first after the firewall, and only when not logged out.
        var connect: Field?
        if let first = rest.first, !isIP(first.value), usage(first.value) == nil {
            connect = first
        }
        for f in rest.dropFirst(connect == nil ? 0 : 1) {
            if s.proto == nil, isProtocol(f.value) {
                s.proto = f.value.replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: " :", with: ":")
            } else if s.ip == nil, isIP(f.value) {
                s.ip = f.value
                s.ipIsVPN = fold(f.label).contains("vpn")
            }
        }

        s.login = login(fields[1].value, hasData: s.used != nil, hasConnectLine: connect != nil)
        if let connect {
            s.testing = connect.raw.hasPrefix("*")
            let (link, interference) = self.link(connect.value)
            s.interference = interference
            // An unknown word: what the other lines show (a protocol only while not disconnected).
            s.link = link ?? (s.proto == nil ? .disconnected : (s.ipIsVPN ? .connected(city: nil) : .connecting(city: nil)))
        }
        return s
    }

    static func login(_ value: String, hasData: Bool, hasConnectLine: Bool) -> VPNStatus.Login {
        // The data line is printed only when logged in, the connect line only when not logged out.
        if hasData { return .loggedIn }
        let v = fold(value)
        if loggedOutWords.contains(v) { return .loggedOut }
        if loggingInWords.contains(v) { return .loggingIn }
        let (head, tail) = splitHead(value)
        if errorWords.contains(fold(head)) { return .failed(tail ?? value) }
        if loggedInWords.contains(v) { return .loggedIn }
        return hasConnectLine ? .loggingIn : .loggedOut
    }

    /// The tunnel's state, and whether "[Network interference]" ended the line; nil for words it does not know.
    static func link(_ value: String) -> (VPNStatus.Link?, Bool) {
        var v = value
        var interference = false
        if let r = v.range(of: #"\s*\[[^\]]*\]\s*$"#, options: .regularExpression) {
            interference = true
            v.removeSubrange(r)
        }
        let (head, tail) = splitHead(v)
        let h = fold(head)
        let city = tail.flatMap { $0.isEmpty ? nil : $0 }
        if errorWords.contains(h) { return (.failed(linkError(tail ?? v)), interference) }
        if connectedWords.contains(h) { return (.connected(city: city), interference) }
        if connectingWords.contains(h) { return (.connecting(city: city), interference) }
        if disconnectingWords.contains(h) { return (.disconnecting, interference) }
        if disconnectedWords.contains(h) { return (.disconnected, interference) }
        // "Disconnected due to reaching WireGuard key limit. Use …": a sentence, no colon.
        if disconnectedWords.contains(where: { h.hasPrefix($0 + " ") }) || h.contains("wireguard") {
            return (.failed(.other(v)), interference)
        }
        return (nil, interference)
    }

    static func linkError(_ message: String) -> VPNLinkError {
        let m = fold(message)
        if locationUnavailablePhrases.contains(where: { m.contains($0) }) { return .locationUnavailable }
        if outOfDataPhrases.contains(where: { m.contains($0) }) { return .outOfData }
        return .other(message)
    }

    /// "Connected: Paris - Seine" → ("Connected", "Paris - Seine").
    static func splitHead(_ value: String) -> (String, String?) {
        guard let colon = value.firstIndex(of: ":") else { return (value.trimmingCharacters(in: .whitespaces), nil) }
        return (String(value[..<colon]).trimmingCharacters(in: .whitespaces),
                String(value[value.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    /// "Paris - Seine" (a city and the nickname of its server) → "Paris".
    static func cityName(_ location: String) -> String {
        if let r = location.range(of: " - ") { return String(location[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return location.trimmingCharacters(in: .whitespaces)
    }

    static func isIP(_ s: String) -> Bool {
        if s.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil { return true }
        return s.filter({ $0 == ":" }).count >= 2 && s.range(of: #"^[0-9A-Fa-f:.]+$"#, options: .regularExpression) != nil
    }

    /// "WireGuard:443", "IKEv2 : 500" (the French one has a non-breaking space before its colon).
    static func isProtocol(_ s: String) -> Bool {
        let t = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        return t.range(of: #"^[A-Za-z][A-Za-z0-9]*\s*:\s*\d{1,5}$"#, options: .regularExpression) != nil
    }

    static func usage(_ value: String) -> VPNUsage? {
        guard let slash = value.firstIndex(of: "/") else { return nil }
        let left = String(value[..<slash]).trimmingCharacters(in: .whitespaces)
        let right = String(value[value.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
        guard let used = size(left), !right.isEmpty else { return nil }
        // "Unlimited", "Illimité"…: any word that is not a size.
        return VPNUsage(used: used, limit: size(right))
    }

    /// A size written by `QLocale::formattedDataSize(…, 2, DataSizeTraditionalFormat)`: base 1024 with SI letters,
    /// "3.20 GB", "3,20 Go", "512 bytes", "1 023 octets" (and "GiB" in the CLI's own documentation).
    static func size(_ text: String) -> Int64? {
        let separators: Set<Character> = [".", ",", " ", "\u{00A0}", "\u{202F}", "'", "\u{2019}"]
        var number = ""
        var index = text.startIndex
        while index < text.endIndex, text[index].isNumber || separators.contains(text[index]) {
            number.append(text[index])
            index = text.index(after: index)
        }
        let unit = String(text[index...].prefix { $0.isLetter })
        let digits = number.filter { $0.isNumber || $0 == "." || $0 == "," }
        guard digits.contains(where: \.isNumber), String(text[index...]).trimmingCharacters(in: .whitespaces).count == unit.count else {
            return nil
        }
        guard let power = power(of: unit) else { return nil }
        if power == 0 {
            return Int64(digits.filter(\.isNumber))
        }
        // The last "." or "," is the decimal one; any other was a group separator.
        var cleaned = digits
        if let last = cleaned.lastIndex(where: { $0 == "." || $0 == "," }) {
            let whole = cleaned[..<last].filter(\.isNumber)
            let fraction = cleaned[cleaned.index(after: last)...]
            cleaned = whole + "." + fraction
        }
        guard let value = Double(cleaned) else { return nil }
        let base = 1024.0
        let multiplier = pow(base, Double(power))
        let bytes = (value * multiplier).rounded()
        return Int64(exactly: bytes)
    }

    /// 0 for bytes ("bytes", "octets", "Bytes", "байт"), 1 for k…, 2 for M…; nil for a word that is no unit.
    static func power(of unit: String) -> Int? {
        guard let first = unit.first else { return 0 }
        switch first {
        case "b", "B", "o", "O", "б", "Б": return 0
        case "k", "K", "К", "к": return 1
        case "M", "М": return 2
        case "G", "Г": return 3
        case "T", "Т": return 4
        case "P", "П": return 5
        case "E", "Э": return 6
        default: return nil
        }
    }

    /// What a CLI command that failed (exit code 1, its message on stdout) means.
    enum Failure: Equatable {
        /// Another windscribe-cli is running (only one at a time).
        case busy
        case notSignedIn
        /// "Aborting: app did not start in time".
        case notStarted
        /// "Aborting: IPC communication error".
        case noAnswer
        case other(String)

        var message: String {
            switch self {
            case .busy: return "Windscribe est occupé par une autre commande : réessaie dans un instant."
            case .notSignedIn: return "Connecte-toi d'abord à ton compte dans Windscribe."
            case .notStarted: return "Windscribe n'a pas démarré à temps : ouvre-le, puis réessaie."
            case .noAnswer: return "Windscribe ne répond plus : quitte-le, rouvre-le, puis réessaie."
            case .other(let text): return text.isEmpty ? "Windscribe n'a pas répondu." : VPNText.windscribeSaid(text)
            }
        }
    }

    static let notSignedInWords: Set<String> = ["not logged in", "non connecte", "no ha iniciado sesion", "nicht eingeloggt",
                                                "non effettuato l'accesso"]

    static func failure(_ output: String) -> Failure {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let text = lines.last ?? ""
        let f = fold(output)
        if f.contains("windscribe cli is already running") { return .busy }
        if notSignedInWords.contains(fold(text)) { return .notSignedIn }
        if ["did not start in time", "n'a pas demarre a temps", "no se inicio a tiempo", "nicht rechtzeitig", "non si e avviata in tempo"]
            .contains(where: { f.contains($0) }) { return .notStarted }
        if f.contains("ipc") { return .noAnswer }
        return .other(text)
    }
}
