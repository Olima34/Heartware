import Foundation
import NaturalLanguage

/// A language the translator offers. Codes are BCP 47, the same as NaturalLanguage and Apple's Translation.
struct TranslatorLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    /// Words that name it in a launcher query ("trad hello en espagnol", "to spanish").
    let aliases: [String]

    var id: String { code }

    static let all: [TranslatorLanguage] = [
        .init(code: "fr", name: "Français", aliases: ["francais", "french"]),
        .init(code: "en", name: "Anglais", aliases: ["anglais", "english"]),
        .init(code: "es", name: "Espagnol", aliases: ["espagnol", "spanish"]),
        .init(code: "de", name: "Allemand", aliases: ["allemand", "german"]),
        .init(code: "it", name: "Italien", aliases: ["italien", "italian"]),
        .init(code: "pt", name: "Portugais", aliases: ["portugais", "portuguese"]),
        .init(code: "nl", name: "Néerlandais", aliases: ["neerlandais", "hollandais", "dutch"]),
        .init(code: "pl", name: "Polonais", aliases: ["polonais", "polish"]),
        .init(code: "ru", name: "Russe", aliases: ["russe", "russian"]),
        .init(code: "uk", name: "Ukrainien", aliases: ["ukrainien", "ukrainian"]),
        .init(code: "tr", name: "Turc", aliases: ["turc", "turkish"]),
        .init(code: "ar", name: "Arabe", aliases: ["arabe", "arabic"]),
        .init(code: "zh-Hans", name: "Chinois (simplifié)", aliases: ["chinois", "chinese", "mandarin"]),
        .init(code: "zh-Hant", name: "Chinois (traditionnel)", aliases: ["chinois traditionnel"]),
        .init(code: "ja", name: "Japonais", aliases: ["japonais", "japanese"]),
        .init(code: "ko", name: "Coréen", aliases: ["coreen", "korean"]),
        .init(code: "hi", name: "Hindi", aliases: ["hindi"]),
        .init(code: "id", name: "Indonésien", aliases: ["indonesien", "indonesian"]),
        .init(code: "th", name: "Thaï", aliases: ["thai", "thailandais"]),
        .init(code: "vi", name: "Vietnamien", aliases: ["vietnamien", "vietnamese"]),
        .init(code: "sv", name: "Suédois", aliases: ["suedois", "swedish"]),
        .init(code: "da", name: "Danois", aliases: ["danois", "danish"]),
        .init(code: "nb", name: "Norvégien", aliases: ["norvegien", "norwegian"]),
        .init(code: "fi", name: "Finnois", aliases: ["finnois", "finnish"]),
        .init(code: "cs", name: "Tchèque", aliases: ["tcheque", "czech"]),
        .init(code: "el", name: "Grec", aliases: ["grec", "greek"]),
        .init(code: "he", name: "Hébreu", aliases: ["hebreu", "hebrew"]),
        .init(code: "ro", name: "Roumain", aliases: ["roumain", "romanian"]),
        .init(code: "hu", name: "Hongrois", aliases: ["hongrois", "hungarian"]),
        .init(code: "ca", name: "Catalan", aliases: ["catalan"]),
        .init(code: "br", name: "Breton", aliases: ["breton"])
    ]

    static func named(_ code: String?) -> String {
        guard let code else { return "Détection automatique" }
        return all.first { $0.code == code }?.name ?? (Locale(identifier: "fr_FR").localizedString(forIdentifier: code)?.capitalized ?? code)
    }

    /// The name with its article, for a sentence: "l'anglais", "l'hindi", "l'hébreu", "le japonais", "le hongrois" (h aspiré).
    static func withArticle(_ code: String) -> String {
        let name = named(code).lowercased()
        let elided = ["hindi", "hébreu"].contains(name) || name.first.map { "aeiouàâäéèêëîïôöùûü".contains($0) } == true
        return (elided ? "l'" : "le ") + name
    }

    /// The language of a text, or nil when it is too short or too mixed to tell.
    static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = all.compactMap { NLLanguage(rawValue: $0.code) }
        recognizer.processString(trimmed)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else { return nil }
        // One or two words are guessed with low confidence: accepted only when the guess is clear enough.
        if trimmed.split(separator: " ").count < 3, confidence < 0.35 { return nil }
        return language.rawValue
    }

    /// A sentence typed or pasted in the launcher (not a command, a calculation, a path or an app name):
    /// its language when it is clear, so that « Traduire » comes first. nil otherwise.
    static func sentenceLanguage(_ query: String) -> String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard words.count >= 3 || (words.count >= 2 && text.count >= 12) || (text.count >= 18 && text.contains(where: { ",.!?".contains($0) })) else { return nil }
        guard looksLikeText(text) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = all.compactMap { NLLanguage(rawValue: $0.code) }
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= (words.count >= 3 ? 0.5 : 0.75) else { return nil }
        return language.rawValue
    }

    /// Words someone could want translated: not a launcher command, a calculation, a conversion or a path.
    static func looksLikeText(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return false }
        let lower = Fuzzy.fold(text)
        let prefixes = ["g ", "ddg ", "yt ", "gh ", "wiki ", "maps ", "gtrad ", "trad ", "tr ", "traduire ", "traduis ", "translate ",
                        "dans ", "in ", "quitter ", "forcer ", "volume ", "heure ", "?", ":", "/", "~", "#", "cb ", "qr ", "mdp ", "cafeine "]
        if prefixes.contains(where: { lower.hasPrefix($0) }) { return false }
        // A web address (a YouTube link to download, a page to open) is not text to translate.
        if !text.contains(where: \.isWhitespace), lower.contains("://") || (lower.contains(".") && lower.contains("/")) { return false }
        // A calculation or a conversion ("10 km en miles") starts with a number.
        if let first = text.first, first.isNumber { return false }
        // Mostly letters: a calculation, a conversion or a path is not text to translate.
        let letters = text.filter(\.isLetter).count
        return Double(letters) / Double(max(1, text.count)) > 0.6
    }

    /// Always an answer for a non-empty text: the sure detection, else the likeliest language, favouring `preferred`
    /// (those installed on the Mac). Apple's on-device translation must never be left to guess: when unsure, it shows
    /// its own "choose the language" window, which takes the keyboard and closes the launcher panel.
    static func bestGuess(_ text: String, preferring preferred: [String] = []) -> String? {
        if let sure = detect(text) { return sure }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = all.compactMap { NLLanguage(rawValue: $0.code) }
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 8)
        if let favourite = hypotheses.filter({ preferred.contains($0.key.rawValue) }).max(by: { $0.value < $1.value }),
           favourite.value >= 0.05 {
            return favourite.key.rawValue
        }
        return hypotheses.max(by: { $0.value < $1.value })?.key.rawValue ?? preferred.first
    }

    /// Where the text goes: the chosen language, unless the text is already in it (then French, or English from French).
    static func effectiveTarget(_ chosen: String, detected: String?) -> String {
        guard let detected, detected == chosen else { return chosen }
        return chosen == "fr" ? "en" : "fr"
    }

    /// "trad bonjour en anglais", "tr hello to french", "traduire buenos días": the text and, if named, the language.
    static func parseLauncher(_ query: String) -> (text: String, target: String?)? {
        let lower = Fuzzy.fold(query)
        guard let prefix = ["traduire ", "traduis ", "translate ", "trad ", "tr "].first(where: { lower.hasPrefix($0) }) else { return nil }
        var text = String(query.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        var target: String?
        let folded = Fuzzy.fold(text)
        search: for language in all {
            for alias in [Fuzzy.fold(language.name)] + language.aliases {
                for joiner in [" en ", " to ", " in ", " vers ", " -> ", " → "] where folded.hasSuffix(joiner + alias) {
                    target = language.code
                    text = String(text.dropLast(joiner.count + alias.count)).trimmingCharacters(in: .whitespaces)
                    break search
                }
            }
        }
        guard !text.isEmpty else { return nil }
        return (text, target)
    }
}

enum TranslatorEngine: String, CaseIterable, Identifiable, Codable {
    case apple, claude

    var id: String { rawValue }
    var title: String { self == .apple ? "Sur ton Mac" : "Claude" }
    var detail: String {
        self == .apple
            ? "Hors ligne et instantané, avec les langues téléchargées par macOS"
            : "Les nuances, le ton et les tournures, avec ton abonnement Claude"
    }
}

enum TranslatorTone: String, CaseIterable, Identifiable, Codable {
    case neutral, formal, casual

    var id: String { rawValue }
    var title: String {
        switch self {
        case .neutral: return "Neutre"
        case .formal: return "Formel"
        case .casual: return "Familier"
        }
    }

    var instruction: String {
        switch self {
        case .neutral: return ""
        case .formal: return " Adopte un registre soutenu et poli (vouvoiement, formules professionnelles)."
        case .casual: return " Adopte un registre familier et naturel, comme entre amis."
        }
    }
}

/// Whether macOS can translate a pair of languages on this Mac.
enum TranslatorPairStatus: Equatable {
    case unknown, installed, downloadable, unsupported

    var label: String {
        switch self {
        case .unknown: return "Vérification…"
        case .installed: return "Sur ton Mac"
        case .downloadable: return "À télécharger"
        case .unsupported: return "Non proposé par Apple"
        }
    }
}

struct TranslatorEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var source: String
    var result: String
    var from: String?
    var to: String
    var engine: TranslatorEngine
}
