import Foundation

/// `--selftest` for the toolbox: known digests, encodings, colors, cases, passwords, dates and launcher answers.
@MainActor
enum ToolboxChecks {
    static func run(_ m: ToolboxModel) -> [String] {
        var f: [String] = []
        func expect(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { f.append(message()) } }
        func equal<T: Equatable>(_ got: T, _ want: T, _ label: String) {
            if got != want { f.append("\(label) : « \(got) », attendu « \(want) »") }
        }

        // Digests of known values (FIPS 180 and RFC 1321 test vectors).
        let abc = ToolboxHash.digests(of: Data("abc".utf8))
        equal(abc[.md5], "900150983cd24fb0d6963f7d28e17f72", "MD5(abc)")
        equal(abc[.sha1], "a9993e364706816aba3e25717850c26c9cd0d89d", "SHA-1(abc)")
        equal(abc[.sha256], "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256(abc)")
        equal(abc[.sha384], "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7", "SHA-384(abc)")
        equal(abc[.sha512], "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f", "SHA-512(abc)")
        equal(ToolboxHash.digests(of: Data())[.md5], "d41d8cd98f00b204e9800998ecf8427e", "MD5(vide)")
        // Reading by blocks gives the same digests as all at once.
        let blob = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var chunked = ToolboxHasher()
        for start in stride(from: 0, to: blob.count, by: 65_536) { chunked.update(blob[start..<min(blob.count, start + 65_536)]) }
        expect(chunked.finalize() == ToolboxHash.digests(of: blob), "empreintes par blocs différentes")
        equal(ToolboxHash.match("  SHA256: BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD ", in: abc), .sha256, "comparaison d'empreinte")
        equal(ToolboxHash.match("ba7816bf", in: abc), nil, "comparaison d'empreinte partielle")
        equal(ToolboxHash.guess("a9993e364706816aba3e25717850c26c9cd0d89d"), .sha1, "algorithme deviné")

        // Base64 and URLs.
        equal(ToolboxText.base64Encode("hello"), "aGVsbG8=", "Base64(hello)")
        equal(ToolboxText.base64Decode("aGVsbG8"), "hello", "Base64 sans remplissage")
        equal(ToolboxText.base64Decode(ToolboxText.base64Encode("Été à Brest ☀️")), "Été à Brest ☀️", "Base64 aller-retour")
        equal(ToolboxText.base64Decode("_-8"), nil, "Base64 binaire refusé comme texte")
        expect(ToolboxText.base64Data("_-8") != nil, "Base64 variante URL")
        equal(ToolboxText.base64Decode("@@@@"), nil, "Base64 invalide")
        equal(ToolboxText.urlEncode("a b&c=é/"), "a%20b%26c%3D%C3%A9%2F", "encodage d'URL")
        equal(ToolboxText.urlDecode("a%20b%26c%3D%C3%A9%2F"), "a b&c=é/", "décodage d'URL")

        // JSON: order kept, exact numbers, French errors with a position.
        let json = #"{"b":1.50,"a":[1,2,{"c":null}],"s":"x\"y","e":{},"t":[]}"#
        let pretty = "{\n  \"b\": 1.50,\n  \"a\": [\n    1,\n    2,\n    {\n      \"c\": null\n    }\n  ],\n  \"s\": \"x\\\"y\",\n  \"e\": {},\n  \"t\": []\n}"
        equal(try? ToolboxText.json(json, pretty: true).get(), pretty, "JSON indenté")
        equal(try? ToolboxText.json(pretty, pretty: false).get(), json, "JSON compacté")
        if case .failure(let e) = ToolboxText.json(#"{"a":1,}"#, pretty: true) {
            expect(e.message.contains("Virgule en trop") && e.line == 1 && e.column == 8, "erreur JSON : \(e.description)")
        } else { f.append("JSON avec virgule en trop accepté") }
        if case .failure(let e) = ToolboxText.json("{\n  \"a\": 1\n  \"b\": 2\n}", pretty: true) {
            expect(e.line == 3 && e.column == 3, "position de l'erreur JSON : \(e.description)")
        } else { f.append("JSON sans virgule accepté") }
        for bad in ["{'a':1}", "[1 2]", "01", "\"abc", "[1,]", "{\"a\" 1}", "tru", "", "{} x", "1.", "\"a\nb\""] {
            if case .success = ToolboxText.json(bad, pretty: false) { f.append("JSON invalide accepté : \(bad)") }
        }
        for good in ["0", "-1.5e-3", "\"é\\u00e9\"", "[]", "true", " null ", "[[[]]]"] {
            if case .failure(let e) = ToolboxText.json(good, pretty: false) { f.append("JSON valide refusé : \(good) (\(e.message))") }
        }

        // Colors.
        let orange = ToolboxRGB(hex: 0xFF8800)
        equal(orange.hex, "#FF8800", "HEX")
        equal(orange.rgbString, "rgb(255, 136, 0)", "RGB")
        equal(orange.hslString, "hsl(32, 100%, 50%)", "HSL")
        equal(orange.swiftUI, "Color(red: 1.000, green: 0.533, blue: 0.000)", "SwiftUI")
        equal(ToolboxRGB.fromHSL(h: 210, s: 0.5, l: 0.4).hex, "#336699", "HSL → HEX")
        let parsed: [(String, String?)] = [
            ("#f80", "#FF8800"), ("ff8800", "#FF8800"), ("rgb(51, 102, 153)", "#336699"), ("hsl(210, 50%, 40%)", "#336699"),
            ("rgba(255, 136, 0, 0.5)", "#FF880080"), ("Color(red: 1.000, green: 0.533, blue: 0.000)", "#FF8800"),
            ("51, 102, 153", "#336699"), ("#12345", nil), ("rgb(300, 0, 0)", nil), ("bonjour", nil), ("facade", "#FACADE")
        ]
        for (input, want) in parsed { equal(ToolboxRGB.parse(input)?.hex, want, "couleur « \(input) »") }
        equal(ToolboxRGB.parse("facade", bare: false)?.hex, nil, "mot pris pour une couleur dans le lanceur")
        for hex: UInt32 in [0x000000, 0xFFFFFF, 0xD97757, 0x4C9AE6, 0x123456] {
            let c = ToolboxRGB(hex: hex)
            let h = c.hsl
            equal(ToolboxRGB.fromHSL(h: h.h, s: h.s, l: h.l).hex, c.hex, "HSL aller-retour \(c.hex)")
        }

        // Case.
        let cases: [(String, ToolboxCase, String)] = [
            ("Hello wonderful World", .camel, "helloWonderfulWorld"), ("Hello wonderful World", .snake, "hello_wonderful_world"),
            ("Hello wonderful World", .kebab, "hello-wonderful-world"), ("parseHTTPResponse2", .snake, "parse_http_response2"),
            ("user_id-value", .pascal, "UserIdValue"), ("Été à la plage", .camel, "eteALaPlage"), ("max retry count", .constant, "MAX_RETRY_COUNT"),
            ("bonjour le monde", .title, "Bonjour Le Monde"), ("jean-pierre", .title, "Jean-Pierre"), ("été", .upper, "ÉTÉ"),
            ("BONJOUR. ÇA VA ?", .sentence, "Bonjour. Ça va ?"), ("ÉCOLE", .lower, "école")
        ]
        for (input, mode, want) in cases { equal(ToolboxText.convertCase(input, to: mode), want, "\(mode.title)(\(input))") }

        // Counts.
        let counts = ToolboxText.counts("Bonjour le monde.\n\nDeuxième ligne")
        equal(counts.words, 5, "nombre de mots")
        equal(counts.lines, 3, "nombre de lignes")
        equal(counts.paragraphs, 2, "nombre de paragraphes")
        equal(ToolboxText.counts("a b").charactersNoSpaces, 2, "caractères sans espaces")

        // Passwords: length, kinds, no look-alikes, secure draws.
        var options = ToolboxPasswordOptions(length: 24, upper: true, lower: true, digits: true, symbols: true, avoidAmbiguous: true)
        for _ in 0..<200 {
            let p = ToolboxPassword.generate(options)
            if p.count != 24 { f.append("mot de passe de \(p.count) caractères"); break }
            if let bad = p.first(where: { ToolboxPassword.ambiguous.contains($0) }) { f.append("caractère ambigu « \(bad) » dans \(p)"); break }
            if !(p.contains(where: \.isUppercase) && p.contains(where: \.isLowercase) && p.contains(where: \.isNumber)
                 && p.contains(where: { !$0.isLetter && !$0.isNumber })) { f.append("type de caractère manquant dans \(p)"); break }
        }
        options = ToolboxPasswordOptions(length: 10, upper: false, lower: false, digits: true, symbols: false, avoidAmbiguous: false)
        expect(ToolboxPassword.generate(options).allSatisfy(\.isNumber), "mot de passe chiffres seulement")
        expect(ToolboxPassword.generate(ToolboxPasswordOptions(length: 500)).count == ToolboxPassword.lengthRange.upperBound, "longueur plafonnée")
        var seen = Set<Int>()
        for _ in 0..<500 { seen.insert(ToolboxRandom.int(10)) }
        expect(seen == Set(0..<10), "tirage aléatoire incomplet : \(seen.sorted())")
        expect(Set(ToolboxWords.list).count == ToolboxWords.list.count, "mots en double dans la liste")
        expect(ToolboxWords.list.count >= 400, "liste de mots trop courte (\(ToolboxWords.list.count))")
        expect(ToolboxWords.list.allSatisfy { $0.count >= 3 && $0.allSatisfy { ("a"..."z").contains($0) } }, "mot avec accent ou majuscule")
        let pp = ToolboxPassword.passphrase(ToolboxPassphraseOptions(words: 6, separator: ".", capitalize: true, addNumber: true))
        equal(pp.split(separator: ".").count, 6, "phrase de passe : nombre de mots")
        expect(pp.contains(where: \.isNumber), "phrase de passe sans chiffre")
        expect(ToolboxPassword.entropy(ToolboxPasswordOptions()) > 100, "entropie du mot de passe par défaut")

        // Dates and durations.
        equal(ToolboxTime.parse("1700000000").map { ToolboxTime.isoString($0.date) }, "2023-11-14T22:13:20Z", "horodatage en secondes")
        equal(ToolboxTime.parse("1700000000000").map { ToolboxTime.isoString($0.date) }, "2023-11-14T22:13:20Z", "horodatage en ms")
        equal(ToolboxTime.parse("2023-11-14T22:13:20Z").map { ToolboxTime.unix($0.date) }, "1700000000", "date ISO 8601")
        equal(ToolboxTime.parse("2023-11-14T22:13:20.500Z").map { ToolboxTime.unixMillis($0.date) }, "1700000000500", "date ISO avec ms")
        expect(ToolboxTime.parse("18/10/2026 14:30") != nil, "date française")
        expect(ToolboxTime.parse("2024", minDigits: 9) == nil, "année prise pour un horodatage")
        expect(ToolboxTime.parse("bonjour") == nil, "texte pris pour une date")
        let durations: [(String, ToolboxTime.Duration?)] = [
            ("15", .minutes(15)), ("15 min", .minutes(15)), ("1h", .minutes(60)), ("1 h 30", .minutes(90)), ("2 heures", .minutes(120)),
            ("90min", .minutes(90)), ("indéfiniment", .indefinite), ("off", .stop), ("arrêt", .stop), ("bientôt", nil), ("0", nil),
            // Huge numbers used to overflow (and crash) once turned into minutes.
            ("200000000000000000h", nil), ("99999999999999999999 min", nil), ("1h200000000000000000", nil), ("1000000", nil)
        ]
        for (input, want) in durations { equal(ToolboxTime.duration(input), want, "durée « \(input) »") }

        // Lorem ipsum.
        let lorem = ToolboxText.lorem(3, unit: .paragraphs)
        expect(lorem.hasPrefix("Lorem ipsum dolor sit amet, consectetur"), "Lorem ipsum ne commence pas par l'incipit")
        equal(lorem.components(separatedBy: "\n\n").count, 3, "paragraphes de Lorem ipsum")
        equal(ToolboxText.lorem(12, unit: .words).split(separator: " ").count, 12, "mots de Lorem ipsum")
        equal(ToolboxText.lorem(500, unit: .words).split(separator: " ").count, 200, "mots de Lorem ipsum plafonnés")
        equal(ToolboxText.lorem(2, unit: .paragraphs, seed: 9), ToolboxText.lorem(2, unit: .paragraphs, seed: 9), "Lorem ipsum reproductible")

        // Text operations of the page.
        if case .failure = ToolboxTextOp.base64Decode.apply("aGVsbG8=") { f.append("opération Base64 décodage") }
        if case .success = ToolboxTextOp.jsonPretty.apply("{") { f.append("opération JSON sur texte invalide") }

        // Launcher answers.
        let q: [(String, String)] = [
            ("uuid", "tool_r_uuid"), ("mdp 24", "tool_r_password"), ("b64 hello", "tool_r_b64_enc"), ("#ff8800", "tool_r_color_hex"),
            ("caféine 1h", "tool_r_caffeine"), ("cafeine off", "tool_r_caffeine_off"), ("sha256 abc", "tool_r_hash_sha256"),
            ("json {\"a\":1}", "tool_r_json"), ("snake Bonjour le monde", "tool_r_case"), ("1700000000", "tool_r_time_date"),
            ("rgb(51,102,153)", "tool_r_color_hex"), ("lorem 2", "tool_r_lorem"), ("ts", "tool_r_ts_now")
        ]
        for (input, id) in q {
            let r = ToolboxLauncher.results(input, model: m)
            if !r.contains(where: { $0.id == id }) { f.append("lanceur « \(input) » : pas de \(id) (\(r.map(\.id)))") }
        }
        if let pw = ToolboxLauncher.results("mdp 24", model: m).first?.title, pw.count != 24 { f.append("lanceur « mdp 24 » : \(pw.count) caractères") }
        equal(ToolboxLauncher.results("b64 hello", model: m).first?.title, "aGVsbG8=", "lanceur Base64")
        // Negative or huge counts used to crash (UInt64 of a negative number).
        for (input, want) in [("lorem -3", "1 paragraphe de Lorem ipsum"), ("lorem 0", "1 paragraphe de Lorem ipsum"),
                              ("lorem 99999999", "200 paragraphes de Lorem ipsum")] {
            equal(ToolboxLauncher.results(input, model: m).first?.subtitle, want, "lanceur « \(input) »")
        }
        expect(ToolboxLauncher.results("caféine 200000000000000000h", model: m).isEmpty, "lanceur : durée de caféine énorme acceptée")
        for noise in ["safari", "facade", "bonjour", "2024", "12 + 4"] where !ToolboxLauncher.results(noise, model: m).isEmpty {
            f.append("le lanceur répond à « \(noise) »")
        }

        // The hidden pointer.
        f += cursor(m)
        return f
    }

    private static func cursor(_ m: ToolboxModel) -> [String] {
        var f: [String] = []
        func equal<T: Equatable>(_ got: T, _ want: T, _ label: String) {
            if got != want { f.append("curseur : \(label) « \(got) », attendu « \(want) »") }
        }
        var s = ToolboxCursorSettings()
        s.enabled = true
        s.delay = 5
        equal(ToolboxCursorRule.next(idle: 6, settings: s, frontmost: "com.x"), .hide, "immobile depuis 6 s")
        equal(ToolboxCursorRule.next(idle: 1, settings: s, frontmost: "com.x"), .check(after: 4), "immobile depuis 1 s")
        // Never a busy loop: a clock just short of the delay still waits a quarter second.
        equal(ToolboxCursorRule.next(idle: 4.99, settings: s, frontmost: nil), .check(after: 0.25), "juste avant le délai")
        s.onlyApps = true
        s.apps = [ToolboxCursorApp(bundleID: "com.livres", name: "Livres")]
        equal(ToolboxCursorRule.next(idle: 60, settings: s, frontmost: "com.autre"), .waitForApp, "app non choisie au premier plan")
        equal(ToolboxCursorRule.next(idle: 60, settings: s, frontmost: nil), .waitForApp, "aucune app au premier plan")
        equal(ToolboxCursorRule.next(idle: 60, settings: s, frontmost: "com.livres"), .hide, "app choisie au premier plan")
        s.apps = []
        equal(ToolboxCursorRule.next(idle: 60, settings: s, frontmost: "com.livres"), .waitForApp, "liste d'apps vide")
        equal(ToolboxCursorRule.label(5), "5 s", "étiquette")
        equal(ToolboxCursorRule.label(60), "1 min", "étiquette d'une minute")
        equal(ToolboxCursorRule.label(90), "90 s", "étiquette de 90 s")
        for (text, want) in [("", ToolboxCursorRequest.on), ("off", .off), ("Arrêter", .off), ("10", .seconds(10)), ("10 s", .seconds(10)),
                             ("10s", .seconds(10)), ("2 min", .seconds(120)), ("1 minute", .seconds(60))] as [(String, ToolboxCursorRequest)] {
            equal(ToolboxCursorRule.parse(text), want, "lanceur « curseur \(text) »")
        }
        for bad in ["0", "-3", "abc", "10 h", "99999999999999999999", "700", "11 min"] {
            equal(ToolboxCursorRule.parse(bad), nil, "lanceur « curseur \(bad) » accepté")
        }
        // An older or damaged file keeps what it can, and a delay out of range comes back within bounds.
        let decoded = try? JSONDecoder.store.decode(ToolboxCursorSettings.self, from: Data(#"{"enabled":true,"delay":-4}"#.utf8))
        equal(decoded?.enabled, true, "réglage relu")
        equal(decoded?.delay, 1, "délai négatif relu")
        equal(decoded?.apps.count, 0, "liste d'apps absente")
        for (input, id) in [("curseur 10 s", "tool_r_cursor_delay"), ("curseur off", "tool_r_cursor_off"), ("curseur", "tool_r_cursor_on")] {
            let r = ToolboxLauncher.results(input, model: m)
            if !r.contains(where: { $0.id == id }) { f.append("curseur : lanceur « \(input) » sans \(id) (\(r.map(\.id)))") }
        }
        return f
    }
}
