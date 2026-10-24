import AppKit
import SwiftUI

/// Sections of the launcher's results, in display order.
enum CommandSection: Int, CaseIterable, Comparable {
    case calculator, cinema, translation, suggestions, apps, actions, system, tools, convert, clipboard, settings, files, emoji, web, assistant

    static func < (a: CommandSection, b: CommandSection) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .calculator: return "Calcul"
        case .translation: return "Traduction"
        case .cinema: return "Films et séries"
        case .suggestions: return "Suggestions"
        case .apps: return "Applications"
        case .actions: return "Heartware"
        case .system: return "Système"
        case .tools: return "Outils"
        case .convert: return "Convertir"
        case .clipboard: return "Presse-papiers"
        case .settings: return "Réglages Système"
        case .files: return "Fichiers"
        case .emoji: return "Emoji"
        case .web: return "Web"
        case .assistant: return "Claude"
        }
    }
}

enum CommandIcon {
    case symbol(String, Color = Theme.accent)
    case file(String)
    case emoji(String)
    case color(Color)
    /// The app's own mark: the mascot.
    case spark
}

enum CommandRisk: Equatable {
    case safe
    /// Asks before running, with this explanation.
    case confirm(String)
}

enum CommandOutcome {
    case done
    case message(String)
    case copied(String)
    case failed(String)
}

struct CommandContext {
    let app: AppModel
    let query: String
    /// ⌘ was held (secondary action: reveal, copy instead of open…).
    let alternate: Bool
}

/// Anything the launcher (and Claude) can run. Modules contribute them through `AppModule.commands`.
struct AppCommand: Identifiable {
    /// Stable and made of letters, digits, "-" and "_" only (used for frecency and as a Claude tool name).
    let id: String
    var title: String
    var subtitle: String? = nil
    var keywords: [String] = []
    var icon: CommandIcon = .symbol("command")
    var group: CommandSection = .actions
    var risk: CommandRisk = .safe
    /// Claude may suggest it (it is still confirmed by the user when risky).
    var assistantSafe = false
    /// A `heartware://run/<id>` link (from a web page, a mail, another app) may run it without asking:
    /// only navigation (a page of the app, the launcher) and read-only analyses. Never a `.confirm` command.
    var urlSafe = false
    /// Right-hand hint ("Copier", "Ouvrir"…).
    var hint: String? = nil
    /// For dynamic results (calculator, files…): relevance set by the provider, added to the match score.
    var boost: Double = 0
    /// The command shows its own view inside the launcher panel (the translator): the panel stays open.
    var staysInLauncher = false
    /// Shown at the right of the launcher while this result is selected, like the preview of a file
    /// (a YouTube video and its download settings).
    var pane: (@MainActor () -> AnyView)? = nil
    let run: @MainActor (CommandContext) async -> CommandOutcome

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// Fuzzy matching, accent and case insensitive ("reglages" finds "Réglages", "vsc" finds "Visual Studio Code").
enum Fuzzy {
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Fmt.fr).lowercased()
    }

    /// A text folded once, with its words and initials. The launcher keeps its catalogue this way: a keystroke then
    /// only compares, instead of folding thousands of titles and keywords again.
    struct Prepared {
        let folded: String
        let length: Int
        let words: [Substring]
        let initials: String

        init(_ text: String) {
            folded = Fuzzy.fold(text)
            length = folded.count
            words = folded.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." || $0 == "_" })
            initials = String(words.compactMap(\.first))
        }
    }

    /// What is typed, folded once for all the texts it is compared to.
    struct Query {
        let folded: String
        let length: Int

        init(_ text: String) {
            folded = Fuzzy.fold(text).trimmingCharacters(in: .whitespaces)
            length = folded.count
        }
    }

    /// nil when `query` does not match `text` at all; higher is better.
    static func score(_ query: String, in text: String, subsequence: Bool = true) -> Double? {
        score(Query(query), in: Prepared(text), subsequence: subsequence)
    }

    static func score(_ query: Query, in text: Prepared, subsequence: Bool = true) -> Double? {
        let q = query.folded, t = text.folded
        guard !q.isEmpty, !t.isEmpty else { return nil }
        let extra = Double(text.length - query.length)
        if t == q { return 1000 }
        if t.hasPrefix(q) { return 850 - extra }
        if text.words.contains(where: { $0.hasPrefix(q) }) { return 700 - extra * 0.5 }
        if query.length >= 2, text.initials.hasPrefix(q) { return 620 }
        if t.contains(q) { return 500 - extra * 0.5 }
        // Letters in order, with a penalty for gaps (titles only, and only when fairly tight).
        guard subsequence, query.length >= 2 else { return nil }
        var gaps = 0
        var ti = t.startIndex
        for c in q where c != " " {
            guard let found = t[ti...].firstIndex(of: c) else { return nil }
            gaps += t.distance(from: ti, to: found)
            ti = t.index(after: found)
        }
        let s = 300 - Double(gaps) * 15
        return s >= 150 ? s : nil
    }

    static func best(_ query: String, title: String, keywords: [String]) -> Double? {
        best(Query(query), title: Prepared(title), keywords: keywords.map(Prepared.init))
    }

    static func best(_ query: Query, title: Prepared, keywords: [Prepared]) -> Double? {
        var top = score(query, in: title)
        for k in keywords {
            if let s = score(query, in: k, subsequence: false).map({ $0 * 0.92 }), s > (top ?? -.infinity) { top = s }
        }
        return top
    }
}

/// Runs commands: the single confirmation gate for anything risky, usage memory (frecency) and feedback.
@MainActor
enum CommandRunner {
    struct Usage: Codable {
        var count: Int
        var last: Date
    }

    static let usage = JSONStore<[String: Usage]>("launcher-usage", default: [:])
    /// Told of every command run (the Refuge counts the tools used).
    static var onRun: (@MainActor (String) -> Void)?

    /// Frequently and recently used commands rank higher.
    static func frecency(_ id: String) -> Double {
        guard let u = usage.value[id] else { return 0 }
        let days = Date().timeIntervalSince(u.last) / 86400
        let recency = days < 1 ? 1.0 : (days < 7 ? 0.7 : (days < 30 ? 0.45 : 0.25))
        return log2(Double(u.count) + 1) * 60 * recency
    }

    @discardableResult
    static func execute(_ command: AppCommand, app: AppModel, query: String = "", alternate: Bool = false) async -> CommandOutcome {
        if case .confirm(let message) = command.risk, !confirm(command.title, message) {
            return .done
        }
        if !DemoData.isEnabled {
            var u = usage.value[command.id] ?? Usage(count: 0, last: Date())
            u.count += 1
            u.last = Date()
            usage.value[command.id] = u
        }
        let outcome = await command.run(CommandContext(app: app, query: query, alternate: alternate))
        if case .failed = outcome {} else { onRun?(command.id) }
        switch outcome {
        case .done: break
        case .message(let m): HUD.show(m)
        case .copied(let text): HUD.show("Copié : \(text.count > 40 ? String(text.prefix(40)) + "…" : text)", symbol: "doc.on.clipboard.fill")
        case .failed(let m): HUD.show(m, symbol: "xmark.octagon.fill")
        }
        return outcome
    }

    /// A native alert; the app comes to the front for it.
    static func confirm(_ title: String, _ message: String, button: String = "Continuer") -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Copies text. `concealed` marks it as a secret (clipboard managers skip it) and clears it after 90 s
    /// if it is still there. The demo never replaces what the user copied.
    static func copy(_ text: String, concealed: Bool = false) -> CommandOutcome {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return .message(DemoData.refusal) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if concealed {
            pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            let change = pb.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
            }
        }
        return .copied(concealed ? "••••••" : text)
    }
}
