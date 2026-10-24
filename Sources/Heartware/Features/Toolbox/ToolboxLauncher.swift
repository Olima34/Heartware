import SwiftUI
import AppKit

/// What the toolbox gives the launcher: fixed `tool_…` commands and answers computed from what is typed.
@MainActor
enum ToolboxLauncher {
    private static let tint = Theme.palette[7]

    private static func open(_ model: ToolboxModel, _ app: AppModel, tab: ToolboxTab) {
        model.tab = tab
        app.page = .toolbox
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
    }

    // MARK: Commands

    static func commands(_ m: ToolboxModel) -> [AppCommand] {
        let caffeineWords = ["caféine", "caffeine", "café", "veille", "éveillé", "empêcher la veille", "écran allumé", "amphetamine", "sleep"]
        var list: [AppCommand] = [
            AppCommand(id: "tool_color_pick", title: "Choisir une couleur à l'écran", subtitle: "Pipette · copie le code HEX",
                       keywords: ["pipette", "couleur", "color picker", "hex", "échantillon", "eyedropper"],
                       icon: .symbol("eyedropper", tint), group: .tools, assistantSafe: true, hint: "Choisir") { _ in
                guard let c = await m.pickColor() else { return .done }
                return m.copy(c.hex)
            },
            AppCommand(id: "tool_password", title: "Générer un mot de passe",
                       subtitle: "\(m.settings.password.length) caractères, copié en confidentiel",
                       keywords: ["mot de passe", "password", "mdp", "sécurisé", "aléatoire"],
                       icon: .symbol("key.fill", tint), group: .tools, assistantSafe: true, hint: "Copier") { _ in
                m.regeneratePassword()
                return m.copy(m.password, secret: true)
            },
            AppCommand(id: "tool_passphrase", title: "Générer une phrase de passe",
                       subtitle: "\(m.settings.passphrase.words) mots faciles à retenir",
                       keywords: ["phrase de passe", "passphrase", "mots", "mot de passe"],
                       icon: .symbol("text.word.spacing", tint), group: .tools, assistantSafe: true, hint: "Copier") { _ in
                m.regeneratePassphrase()
                return m.copy(m.passphrase, secret: true)
            },
            AppCommand(id: "tool_uuid", title: "Générer un UUID", keywords: ["uuid", "guid", "identifiant"],
                       icon: .symbol("number", tint), group: .tools, assistantSafe: true, hint: "Copier") { _ in
                m.copy(m.settings.uuidLowercase ? UUID().uuidString.lowercased() : UUID().uuidString)
            },
            AppCommand(id: "tool_timestamp", title: "Copier l'horodatage Unix actuel", keywords: ["timestamp", "unix", "epoch", "horodatage"],
                       icon: .symbol("clock", tint), group: .tools, assistantSafe: true, hint: "Copier") { _ in
                m.copy(ToolboxTime.unix(Date()))
            },
            AppCommand(id: "tool_lorem", title: "Copier du Lorem ipsum", subtitle: "Trois paragraphes de faux texte",
                       keywords: ["lorem", "ipsum", "faux texte", "texte de remplissage"],
                       icon: .symbol("text.alignleft", tint), group: .tools, assistantSafe: true, hint: "Copier") { _ in
                m.copy(ToolboxText.lorem(3, unit: .paragraphs, seed: UInt64.random(in: 1...UInt64.max)))
            },
            AppCommand(id: "tool_hash_file", title: "Calculer l'empreinte d'un fichier", subtitle: "SHA-256, SHA-1, MD5…",
                       keywords: ["empreinte", "hash", "sha256", "md5", "checksum", "somme de contrôle"],
                       icon: .symbol("number.square", tint), group: .tools, assistantSafe: true, urlSafe: true) { ctx in
                open(m, ctx.app, tab: .hashes)
                return .done
            },
            AppCommand(id: "tool_json", title: "Formater ou valider du JSON", keywords: ["json", "formater", "valider", "indenter"],
                       icon: .symbol("curlybraces", tint), group: .tools, assistantSafe: true, urlSafe: true) { ctx in
                m.textOp = .jsonPretty
                open(m, ctx.app, tab: .text)
                return .done
            },
            AppCommand(id: "tool_text", title: "Transformer du texte", subtitle: "Base64, URL, casse, compteur de mots",
                       keywords: ["base64", "url", "encoder", "décoder", "casse", "majuscules", "camelcase", "compter les mots"],
                       icon: .symbol("textformat", tint), group: .tools, assistantSafe: true, urlSafe: true) { ctx in
                open(m, ctx.app, tab: .text)
                return .done
            }
        ]
        for (minutes, label) in [(15, "15 min"), (60, "1 h"), (120, "2 h"), (0, "indéfiniment")] {
            list.append(AppCommand(id: "tool_caffeine_\(minutes == 0 ? "on" : String(minutes))",
                                   title: "Caféine : garder le Mac éveillé \(minutes == 0 ? "" : "pendant ")\(label)",
                                   keywords: caffeineWords, icon: .symbol("cup.and.saucer.fill", tint), group: .tools,
                                   assistantSafe: true) { _ in
                m.startCaffeine(minutes: minutes == 0 ? nil : minutes)
                guard m.caffeineActive else { return .failed("macOS a refusé de garder le Mac éveillé.") }
                return .message(minutes == 0 ? "Caféine : éveillé jusqu'à nouvel ordre" : "Caféine : éveillé pendant \(label)")
            })
        }
        list.append(AppCommand(id: "tool_caffeine_off", title: "Arrêter la caféine",
                               subtitle: m.caffeineActive ? "Le Mac pourra de nouveau se mettre en veille" : "Caféine n'est pas active",
                               keywords: caffeineWords + ["arrêter", "stop"], icon: .symbol("cup.and.saucer", tint), group: .tools,
                               assistantSafe: true) { _ in
            m.stopCaffeine()
            return .message("Caféine arrêtée")
        })
        let cursorWords = ["curseur", "pointeur", "souris", "cacher", "masquer", "invisible", "cursor", "hide", "lecture", "vidéo"]
        list.append(AppCommand(id: "tool_cursor_on", title: "Cacher le curseur quand la souris ne bouge plus",
                               subtitle: "Après \(ToolboxCursorRule.label(m.cursor.delay))" + (m.cursor.onlyApps ? " dans les apps choisies" : " dans toutes les apps"),
                               keywords: cursorWords, icon: .symbol("cursorarrow.slash", tint), group: .tools, assistantSafe: true) { _ in
            m.cursor.enabled = true
            return .message("Le curseur se cachera après \(ToolboxCursorRule.label(m.cursor.delay)) sans bouger la souris")
        })
        list.append(AppCommand(id: "tool_cursor_off", title: "Ne plus cacher le curseur",
                               subtitle: m.cursor.enabled ? "Il restera toujours visible" : "Le curseur reste déjà visible",
                               keywords: cursorWords + ["arrêter", "stop", "afficher"], icon: .symbol("cursorarrow", tint), group: .tools,
                               assistantSafe: true) { _ in
            m.cursor.enabled = false
            return .message("Le curseur reste visible")
        })
        list.append(AppCommand(id: "tool_cursor", title: "Réglages du curseur caché", subtitle: "Délai et apps concernées",
                               keywords: cursorWords + ["délai", "réglages"], icon: .symbol("cursorarrow.motionlines", tint), group: .tools,
                               assistantSafe: true, urlSafe: true) { ctx in
            open(m, ctx.app, tab: .cursor)
            return .done
        })
        return list
    }

    // MARK: Results

    static func results(_ raw: String, model m: ToolboxModel) -> [AppCommand] {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q.count <= 4000 else { return [] }
        let space = q.firstIndex(of: " ")
        let head = Fuzzy.fold(space.map { String(q[..<$0]) } ?? q)
        let rest = space.map { String(q[q.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
        var out: [AppCommand] = []

        switch head {
        case "uuid", "guid":
            let id = m.settings.uuidLowercase ? UUID().uuidString.lowercased() : UUID().uuidString
            out.append(result("uuid", id, "UUID aléatoire", symbol: "number") { m.copy(id) })
        case "mdp", "password", "pwd", "pass", "motdepasse":
            var o = m.settings.password
            if let n = Int(rest) { o.length = n }
            let pw = ToolboxPassword.generate(o)
            out.append(result("password", pw, "Mot de passe de \(pw.count) caractères · \(Int(ToolboxPassword.entropy(o))) bits",
                              symbol: "key.fill", mono: true) { m.copy(pw, secret: true) })
        case "phrase", "passphrase", "pp":
            var o = m.settings.passphrase
            if let n = Int(rest) { o.words = n }
            let pp = ToolboxPassword.passphrase(o)
            out.append(result("passphrase", pp, "Phrase de passe · \(Int(ToolboxPassword.passphraseEntropy(o))) bits",
                              symbol: "text.word.spacing") { m.copy(pp, secret: true) })
        case "b64", "base64":
            guard !rest.isEmpty else { break }
            let enc = ToolboxText.base64Encode(rest)
            out.append(result("b64_enc", enc, "Base64 de « \(short(rest)) »", symbol: "lock.doc") { m.copy(enc) })
            if let dec = ToolboxText.base64Decode(rest), !dec.isEmpty {
                out.append(result("b64_dec", dec, "Base64 décodé", symbol: "lock.open", boost: 1790) { m.copy(dec) })
            }
        case "b64d", "unb64", "deb64":
            guard !rest.isEmpty else { break }
            if let dec = ToolboxText.base64Decode(rest) {
                out.append(result("b64_dec", dec, "Base64 décodé", symbol: "lock.open") { m.copy(dec) })
            } else {
                out.append(failure("b64_dec", "Ce n'est pas du Base64 de texte valide"))
            }
        case "url", "urlencode":
            guard !rest.isEmpty else { break }
            let enc = ToolboxText.urlEncode(rest)
            out.append(result("url_enc", enc, "Encodage d'URL", symbol: "link") { m.copy(enc) })
            if rest.contains("%"), let dec = ToolboxText.urlDecode(rest), dec != rest {
                out.append(result("url_dec", dec, "URL décodée", symbol: "link", boost: 1790) { m.copy(dec) })
            }
        case "urld", "urldecode":
            guard !rest.isEmpty else { break }
            if let dec = ToolboxText.urlDecode(rest) {
                out.append(result("url_dec", dec, "URL décodée", symbol: "link") { m.copy(dec) })
            }
        case "sha256", "sha-256", "sha1", "sha-1", "md5", "sha384", "sha512", "hash", "empreinte":
            guard !rest.isEmpty else { break }
            let all = ToolboxHash.digests(of: Data(rest.utf8))
            let algos: [ToolboxHashAlgo] = ToolboxHashAlgo.allCases.filter {
                head == "hash" || head == "empreinte" || Fuzzy.fold($0.title).replacingOccurrences(of: "-", with: "") == head.replacingOccurrences(of: "-", with: "")
            }
            for a in algos {
                let v = all[a] ?? ""
                out.append(result("hash_\(a.rawValue)", v, "\(a.title) de « \(short(rest)) »", symbol: "number.square", mono: true) { m.copy(v) })
            }
        case "json":
            guard !rest.isEmpty else { break }
            switch ToolboxText.json(rest, pretty: true) {
            case .success(let s):
                out.append(result("json", short(s.replacingOccurrences(of: "\n", with: " "), 70), "JSON valide · copier la version indentée",
                                  symbol: "curlybraces") { m.copy(s) })
            case .failure(let e):
                out.append(failure("json", "JSON invalide : \(e.description)"))
            }
        case "lorem":
            let n = min(max(Int(rest) ?? 1, 1), 200)
            let text = ToolboxText.lorem(n, unit: .paragraphs, seed: UInt64(n))
            out.append(result("lorem", short(text, 70), "\(Fmt.plural(n, "paragraphe", "paragraphes")) de Lorem ipsum",
                              symbol: "text.alignleft") { m.copy(text) })
        case "ts", "timestamp", "horodatage", "unix", "epoch":
            if rest.isEmpty {
                let now = Date()
                let v = ToolboxTime.unix(now)
                out.append(result("ts_now", v, "Horodatage Unix de maintenant · \(Fmt.clock(now))", symbol: "clock") { m.copy(v) })
            } else if let p = ToolboxTime.parse(rest) {
                out += timeResults(p, m)
            }
        case "cafeine", "caffeine", "cafe", "coffee":
            if let d = ToolboxTime.duration(rest) {
                out.append(caffeine(d, m))
            }
        case "curseur", "pointeur", "cursor":
            if let r = ToolboxCursorRule.parse(rest) {
                out.append(cursor(r, m))
            }
        case "compter", "mots", "count", "wc":
            guard !rest.isEmpty else { break }
            let c = ToolboxText.counts(rest)
            let summary = "\(Fmt.plural(c.words, "mot", "mots")) · \(Fmt.plural(c.characters, "caractère", "caractères"))"
            out.append(result("count", summary, "\(Fmt.int(c.charactersNoSpaces)) sans espaces · \(Fmt.plural(c.lines, "ligne", "lignes"))",
                              symbol: "textformat.123") { m.copy(summary) })
        case "maj", "majuscules", "upper", "min", "minuscules", "lower", "titre", "title", "camel", "camelcase", "pascal",
             "snake", "snakecase", "kebab", "kebabcase", "constante", "const":
            guard !rest.isEmpty else { break }
            let mode: ToolboxCase
            switch head {
            case "maj", "majuscules", "upper": mode = .upper
            case "min", "minuscules", "lower": mode = .lower
            case "titre", "title": mode = .title
            case "camel", "camelcase": mode = .camel
            case "pascal": mode = .pascal
            case "snake", "snakecase": mode = .snake
            case "constante", "const": mode = .constant
            default: mode = .kebab
            }
            let v = ToolboxText.convertCase(rest, to: mode)
            out.append(result("case", v, mode.title, symbol: "textformat") { m.copy(v) })
        default:
            break
        }

        // Colors typed as they are: "#ff8800", "rgb(…)", "hsl(…)".
        if out.isEmpty, let c = ToolboxRGB.parse(q, bare: false) {
            let rows: [(String, String)] = [("HEX", c.hex), ("RGB", c.rgbString), ("HSL", c.hslString), ("SwiftUI", c.swiftUI)]
            for (i, (label, value)) in rows.enumerated() {
                out.append(AppCommand(id: "tool_r_color_\(label.lowercased())", title: value, subtitle: label, icon: .color(c.color),
                                      group: .convert, hint: "Copier", boost: 1700 - Double(i)) { _ in
                    m.remember(c)
                    return m.copy(value)
                })
            }
        }
        // Long numbers and ISO dates: what date it is.
        if out.isEmpty, q.count >= 9, q.first?.isNumber == true, let p = ToolboxTime.parse(q, minDigits: 9) {
            out += timeResults(p, m, boost: 1400)
        }
        return out
    }

    private static func short(_ s: String, _ n: Int = 24) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }

    private static func result(_ id: String, _ title: String, _ subtitle: String, symbol: String, mono: Bool = false,
                               boost: Double = 1800, copy: @escaping @MainActor () -> CommandOutcome) -> AppCommand {
        AppCommand(id: "tool_r_\(id)", title: title.count > 200 ? String(title.prefix(200)) + "…" : title, subtitle: subtitle,
                   icon: .symbol(symbol, tint), group: .tools, hint: "Copier", boost: boost) { _ in copy() }
    }

    private static func failure(_ id: String, _ message: String) -> AppCommand {
        AppCommand(id: "tool_r_\(id)_err", title: message, icon: .symbol("exclamationmark.triangle", Theme.warn),
                   group: .tools, boost: 1800) { _ in .failed(message) }
    }

    private static func timeResults(_ p: ToolboxTime.Parsed, _ m: ToolboxModel, boost: Double = 1800) -> [AppCommand] {
        let d = p.date
        let rows: [(String, String, String)] = [
            ("date", Fmt.cap(ToolboxTime.longString(d)), "\(p.source) · \(ToolboxTime.relative(d))"),
            ("iso", ToolboxTime.isoString(d), "ISO 8601 (UTC)"),
            ("unix", ToolboxTime.unix(d), "Horodatage Unix")
        ]
        return rows.enumerated().map { i, row in
            let value = row.1
            return AppCommand(id: "tool_r_time_\(row.0)", title: value, subtitle: row.2, icon: .symbol("calendar", tint),
                              group: .convert, hint: "Copier", boost: boost - Double(i)) { _ in m.copy(value) }
        }
    }

    private static func cursor(_ r: ToolboxCursorRequest, _ m: ToolboxModel) -> AppCommand {
        switch r {
        case .off:
            return AppCommand(id: "tool_r_cursor_off", title: "Ne plus cacher le curseur",
                              subtitle: m.cursor.enabled ? "Il restera toujours visible" : "Le curseur reste déjà visible",
                              icon: .symbol("cursorarrow", tint), group: .tools, boost: 1800) { _ in
                m.cursor.enabled = false
                return .message("Le curseur reste visible")
            }
        case .on:
            let label = ToolboxCursorRule.label(m.cursor.delay)
            return AppCommand(id: "tool_r_cursor_on", title: "Cacher le curseur après \(label) sans bouger la souris",
                              subtitle: m.cursor.enabled ? "Déjà actif" : "Il revient dès que tu bouges la souris",
                              icon: .symbol("cursorarrow.slash", tint), group: .tools, boost: 1800) { _ in
                m.cursor.enabled = true
                return .message("Le curseur se cachera après \(label)")
            }
        case .seconds(let n):
            let label = ToolboxCursorRule.label(n)
            return AppCommand(id: "tool_r_cursor_delay", title: "Cacher le curseur après \(label) sans bouger la souris",
                              subtitle: "Il revient dès que tu bouges la souris", icon: .symbol("cursorarrow.slash", tint),
                              group: .tools, boost: 1800) { _ in
                m.cursor.delay = n
                m.cursor.enabled = true
                return .message("Le curseur se cachera après \(label)")
            }
        }
    }

    private static func caffeine(_ d: ToolboxTime.Duration, _ m: ToolboxModel) -> AppCommand {
        switch d {
        case .stop:
            return AppCommand(id: "tool_r_caffeine_off", title: "Arrêter la caféine", subtitle: m.caffeineActive ? "Le Mac pourra se mettre en veille" : "Caféine n'est pas active",
                              icon: .symbol("cup.and.saucer", tint), group: .tools, boost: 1800) { _ in
                m.stopCaffeine()
                return .message("Caféine arrêtée")
            }
        case .indefinite:
            return AppCommand(id: "tool_r_caffeine_on", title: "Caféine : garder le Mac éveillé indéfiniment", subtitle: "Jusqu'à ce que tu l'arrêtes",
                              icon: .symbol("cup.and.saucer.fill", tint), group: .tools, boost: 1800) { _ in
                m.startCaffeine(minutes: nil)
                return m.caffeineActive ? .message("Caféine : éveillé jusqu'à nouvel ordre") : .failed("macOS a refusé.")
            }
        case .minutes(let n):
            let label = ToolboxTime.durationLabel(n)
            let end = Date().addingTimeInterval(Double(n) * 60)
            return AppCommand(id: "tool_r_caffeine", title: "Caféine : garder le Mac éveillé pendant \(label)", subtitle: "Jusqu'à \(Fmt.clock(end))",
                              icon: .symbol("cup.and.saucer.fill", tint), group: .tools, boost: 1800) { _ in
                m.startCaffeine(minutes: n)
                return m.caffeineActive ? .message("Caféine : éveillé pendant \(label)") : .failed("macOS a refusé.")
            }
        }
    }
}
