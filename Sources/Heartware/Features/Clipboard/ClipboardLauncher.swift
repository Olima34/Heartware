import SwiftUI
import AppKit

/// What the clipboard history gives the launcher: `clip_…` commands, and a way into its own window
/// ("cb" followed by words opens it with those words already typed). The items themselves stay in that window.
@MainActor
enum ClipboardLauncher {
    private static let tint = Theme.palette[4]

    static func commands(_ m: ClipboardModel) -> [AppCommand] {
        let words = ["presse-papiers", "historique", "clipboard", "copier", "coller", "copié"]
        return [
            AppCommand(id: "clip_search", title: "Historique du presse-papiers", subtitle: m.isActive ? "Tout ce que tu as copié, dans sa fenêtre" : "L'historique n'est pas activé",
                       keywords: words + ["cb", "rechercher", "fenêtre"], icon: .symbol("doc.on.clipboard", tint), group: .clipboard,
                       assistantSafe: true, urlSafe: true, hint: "Ouvrir", staysInLauncher: true) { _ in
                // Its window replaces the launcher (which closes itself): `staysInLauncher` keeps the launcher from closing first.
                m.openWindow()
                return .done
            },
            AppCommand(id: "clip_settings", title: "Réglages de l'historique du presse-papiers", subtitle: "Ce qui est gardé, apps ignorées, pause",
                       keywords: words + ["réglages", "apps ignorées", "ignorer", "pause", "effacer", "images", "secrets"],
                       icon: .symbol("gearshape", tint), group: .clipboard, assistantSafe: true, urlSafe: true, hint: "Ouvrir",
                       staysInLauncher: true) { _ in
                // Before the first activation, the window shows the activation instead.
                m.openWindow(settings: true)
                return .done
            },
            AppCommand(id: "clip_toggle", title: m.isActive ? "Mettre en pause l'historique du presse-papiers" : "Activer l'historique du presse-papiers",
                       subtitle: m.settings.acknowledged ? nil : "Ouvre la fenêtre qui explique ce qui est enregistré",
                       keywords: words + ["pause", "activer", "désactiver"], icon: .symbol(m.isActive ? "pause.circle" : "play.circle", tint),
                       group: .clipboard, assistantSafe: true) { _ in
                if m.settings.acknowledged {
                    m.setEnabled(!m.settings.enabled)
                } else {
                    m.openWindow()
                }
                return .done
            },
            AppCommand(id: "clip_plain", title: "Coller en texte brut", subtitle: "Retire polices, couleurs et liens du texte copié",
                       keywords: ["texte brut", "sans mise en forme", "plain text", "coller", "nettoyer"],
                       icon: .symbol("textformat", tint), group: .clipboard, assistantSafe: true) { _ in
                m.pastePlainText()
            },
            AppCommand(id: "clip_pin_last", title: "Épingler le dernier élément copié", keywords: words + ["épingler", "garder"],
                       icon: .symbol("pin", tint), group: .clipboard, assistantSafe: true) { _ in
                // The newest item, even when it is already pinned (an older unpinned one is not "the last copied").
                guard let first = m.items.first else { return .failed("Rien à épingler.") }
                guard !first.pinned else { return .message("Déjà épinglé : \(first.title.prefix(40))") }
                m.togglePin(first.id)
                return .message("Épinglé : \(first.title.prefix(40))")
            },
            AppCommand(id: "clip_clear", title: "Effacer l'historique du presse-papiers", subtitle: "Les éléments épinglés restent",
                       keywords: words + ["effacer", "vider", "supprimer"], icon: .symbol("trash", Theme.bad), group: .clipboard,
                       risk: .confirm("Tout l'historique du presse-papiers (sauf les épingles) sera effacé de ce Mac.")) { _ in
                m.clear()
                return .message("Historique effacé")
            }
        ]
    }

    /// "cb" or "cb mots": one row that opens the window, the words already typed in its search.
    static func results(_ raw: String, model m: ClipboardModel) -> [AppCommand] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let q = Fuzzy.fold(trimmed)
        guard q == "cb" || q.hasPrefix("cb ") else { return [] }
        let term = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        let found = term.isEmpty ? m.items.count : ClipboardHistory.search(m.items, query: Fuzzy.fold(term), keys: m.key, limit: 99).count
        let subtitle: String
        if !m.settings.acknowledged {
            subtitle = "L'historique n'est pas encore activé : la fenêtre t'explique tout"
        } else if term.isEmpty {
            subtitle = Fmt.plural(m.items.count, "élément", "éléments") + (m.isActive ? "" : " · en pause")
        } else {
            subtitle = found == 0 ? "Rien de tel pour l'instant" : (found >= 99 ? "99 éléments ou plus" : Fmt.plural(found, "élément trouvé", "éléments trouvés"))
        }
        return [AppCommand(id: "clip_r_open", title: term.isEmpty ? "Ouvrir l'historique du presse-papiers" : "Chercher « \(term) » dans le presse-papiers",
                           subtitle: subtitle, icon: .symbol("doc.on.clipboard", tint), group: .clipboard, hint: "Ouvrir la fenêtre",
                           boost: 1900, staysInLauncher: true) { _ in
            m.window.show(query: term)
            return .done
        }]
    }

    static func icon(_ item: ClipboardItem) -> CommandIcon {
        switch item.kind {
        case .image: return .symbol("photo", tint)
        case .files: return .file(item.files?.first ?? "/")
        case .text:
            switch item.textKind {
            case .link: return .symbol("link", tint)
            case .color: return ClipboardText.color(item.text ?? "").map { .color($0) } ?? .symbol("paintpalette", tint)
            case .code: return .symbol("chevron.left.forwardslash.chevron.right", tint)
            case .plain: return .symbol("text.alignleft", tint)
            }
        }
    }
}
