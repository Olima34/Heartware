import SwiftUI
import AppKit
import Carbon.HIToolbox
import PDFKit
import UniformTypeIdentifiers

// MARK: - Shortcuts

/// A key pressed in the launcher, as the shortcuts of the actions panel read it.
struct LauncherKeyPress {
    var keyCode: Int
    /// What the key types on its own, without any modifier (follows the layout: the A of an AZERTY keyboard is "a").
    var base: String
    /// What it types with Shift when Shift is held ("." for ⇧; on an AZERTY keyboard).
    var typed: String
    var command = false
    var shift = false
    var option = false
    var control = false

    init(keyCode: Int, base: String, typed: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.keyCode = keyCode
        self.base = base
        self.typed = typed
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    init(_ event: NSEvent) {
        let flags = event.modifierFlags
        self.init(keyCode: Int(event.keyCode), base: event.characters(byApplyingModifiers: []) ?? "",
                  typed: event.charactersIgnoringModifiers ?? "", command: flags.contains(.command), shift: flags.contains(.shift),
                  option: flags.contains(.option), control: flags.contains(.control))
    }
}

/// A key and its modifiers, drawn like Raycast does ("⇧ ⌘ D") and matched by the character the key types,
/// so that ⌘D is the D key on an AZERTY keyboard too.
struct LauncherShortcut: Equatable {
    enum Key: Equatable {
        /// Lowercase.
        case character(String)
        case up
        case enter
    }

    var key: Key
    var command = false
    var shift = false
    var option = false
    var control = false

    /// `modifiers` in macOS's own symbols: "⇧⌘", "⌃⌘", "⌥⌘"…
    init(_ key: Key, _ modifiers: String = "") {
        self.key = key
        command = modifiers.contains("⌘")
        shift = modifiers.contains("⇧")
        option = modifiers.contains("⌥")
        control = modifiers.contains("⌃")
    }

    /// One key cap per symbol, in macOS's order (⌃ ⌥ ⇧ ⌘).
    var keys: [String] {
        var out: [String] = []
        if control { out.append("⌃") }
        if option { out.append("⌥") }
        if shift { out.append("⇧") }
        if command { out.append("⌘") }
        switch key {
        case .character(let c): out.append(c.uppercased())
        case .up: out.append("↑")
        case .enter: out.append("↩")
        }
        return out
    }

    func matches(_ p: LauncherKeyPress) -> Bool {
        guard p.command == command, p.option == option, p.control == control else { return false }
        switch key {
        case .up:
            return p.keyCode == kVK_UpArrow && p.shift == shift
        case .enter:
            return (p.keyCode == kVK_Return || p.keyCode == kVK_ANSI_KeypadEnter) && p.shift == shift
        case .character(let c):
            let base = p.base.lowercased(), typed = p.typed.lowercased()
            // The key types it by itself: Shift must be as written (⇧⌘, on an AZERTY keyboard).
            if base == c { return p.shift == shift }
            // Shift is needed to type it ("." on an AZERTY keyboard is ⇧;): it belongs to the character.
            return !shift && p.shift && typed == c && base != typed
        }
    }
}

// MARK: - What ⌘K is pressed on

/// The result the actions panel is open for: its actions depend on what it is.
enum LauncherActionTarget: Equatable {
    case file(path: String)
    case folder(path: String)
    case app(path: String, name: String)
    /// Any other result: an action of Heartware, a setting, a calculation…
    case command(id: String, title: String)

    var path: String? {
        switch self {
        case .file(let p), .folder(let p), .app(let p, _): return p
        case .command: return nil
        }
    }

    var title: String {
        switch self {
        case .file(let p), .folder(let p): return (p as NSString).lastPathComponent
        case .app(_, let name): return name
        case .command(_, let title): return title
        }
    }
}

/// What the actions depend on besides the target, read once when the panel opens.
struct LauncherActionContext {
    var detailsShown = true
    var favorite = false
    /// The result has a place in the usage ranking ("Réinitialiser le classement" does something).
    var ranked = false
    /// A fixed result of the catalogue (a shortcut, a link, a favourite or hiding make sense for it).
    var inCatalog = true
    var bundleID: String?
    var running = false
    var uninstallable = false
    /// It can get a keyboard shortcut (not a result that changes with what is typed), and the one it already has.
    var canAssign = true
    var hotkey: String?
    /// What ↩ does on a command ("Ouvrir", "Copier"…).
    var primary: String?
    /// The file window: ⌘↩ picks the file for a drag with others (⌘R shows it in the Finder), and whether it is picked.
    var selectable = false
    var marked = false
}

enum LauncherActionKind: Hashable {
    case open, mark, reveal, quickLook, openWith, getInfo, packageContents, parent, details, share, claude
    /// What the converter can do with this kind of file.
    case convert(ConverterOperation)
    /// A PDF or the photo of a document, in « Remplir et signer ».
    case fillSign
    case move, copyTo, duplicate
    case favorite, hotkey, resetRanking
    case copyFile, copyName, copyPath, copyBundleID, copyLink
    case quit, forceQuit, hide, uninstall, trash

    var key: String {
        if case .convert(let op) = self { return "convert_" + op.rawValue }
        return String(describing: self)
    }
}

/// One line of the ⌘K panel.
struct LauncherAction: Identifiable, Equatable {
    let kind: LauncherActionKind
    let title: String
    let symbol: String
    var shortcut: LauncherShortcut?
    /// The actions of a group are drawn together, a line between two groups.
    let group: Int
    var keywords: [String] = []

    var id: String { "launcher_act_" + kind.key }
    var destructive: Bool { [.trash, .uninstall, .hide, .forceQuit].contains(kind) }
    /// Opens, copies, moves or changes something on the Mac: refused in the demo (the others only change the launcher).
    var touchesMac: Bool {
        ![.mark, .quickLook, .openWith, .packageContents, .parent, .details, .hotkey, .favorite, .resetRanking, .hide].contains(kind)
    }
}

/// An app that can open the file, for "Ouvrir avec…".
struct LauncherOpenWithApp: Identifiable, Equatable {
    let name: String
    let path: String
    let isDefault: Bool

    var id: String { path }

    /// The apps macOS knows for this file, its default one first.
    static func list(for path: String) -> [LauncherOpenWithApp] {
        if DemoData.isEnabled {
            // The demo's fictional apps, never the ones installed on this Mac.
            let names = ["Plume", "Ardoise", "Archiviste", "Hélios Code", "Keynote"]
            return DemoData.apps().filter { names.contains($0.name) }
                .map { LauncherOpenWithApp(name: $0.name, path: $0.path, isDefault: $0.name == names[0]) }
                .sorted(by: order)
        }
        let url = URL(fileURLWithPath: path)
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: url)?.standardizedFileURL.path
        var seen = Set<String>()
        var out: [LauncherOpenWithApp] = []
        for app in NSWorkspace.shared.urlsForApplications(toOpen: url) {
            let p = app.standardizedFileURL.path
            guard seen.insert(p).inserted else { continue }
            let name = FileManager.default.displayName(atPath: p)
            out.append(LauncherOpenWithApp(name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name, path: p, isDefault: p == preferred))
        }
        return out.sorted(by: order)
    }

    private static func order(_ a: LauncherOpenWithApp, _ b: LauncherOpenWithApp) -> Bool {
        if a.isDefault != b.isDefault { return a.isDefault }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

/// A result kept at the top of the empty search (an app, a command, a file or a folder).
struct LauncherFavorite: Codable, Equatable {
    /// The command's id (for a file, `LauncherModel.fileID`).
    var id: String
    /// Files and folders: they are not in the catalogue.
    var path: String?
    var isDir = false
}

/// What the launcher remembers between launches (nothing is written in the demo).
@MainActor
enum LauncherSaved {
    static let favorites = JSONStore<[LauncherFavorite]>("launcher-favorites", default: [])
    /// Apps and commands taken out of the search ("Masquer de la recherche"), given back from Raccourcis › Heartware.
    static let hidden = JSONStore<[String]>("launcher-hidden", default: [])
}

enum LauncherActions {
    static func all(for target: LauncherActionTarget, _ c: LauncherActionContext) -> [LauncherAction] {
        switch target {
        case .file(let path): return files(path, folder: false, c)
        case .folder(let path): return files(path, folder: true, c)
        case .app: return app(c)
        case .command: return command(c)
        }
    }

    private static func favorite(_ c: LauncherActionContext, group: Int) -> LauncherAction {
        LauncherAction(kind: .favorite, title: c.favorite ? "Retirer des favoris" : "Ajouter aux favoris", symbol: c.favorite ? "star.slash" : "star",
                       shortcut: .init(.character("f"), "⇧⌘"), group: group, keywords: ["favori", "epingler", "favorites"])
    }

    private static func hotkey(_ c: LauncherActionContext, group: Int) -> LauncherAction {
        LauncherAction(kind: .hotkey, title: c.hotkey.map { "Changer le raccourci (\($0))" } ?? "Donner un raccourci clavier…",
                       symbol: "keyboard", shortcut: .init(.character(","), "⇧⌘"), group: group,
                       keywords: ["configurer", "raccourci", "hotkey", "configure"])
    }

    private static func reset(group: Int) -> LauncherAction {
        LauncherAction(kind: .resetRanking, title: "Réinitialiser le classement", symbol: "arrow.counterclockwise", group: group,
                       keywords: ["frequence", "oublier", "reset ranking"])
    }

    private static func hide(group: Int) -> LauncherAction {
        LauncherAction(kind: .hide, title: "Masquer de la recherche", symbol: "eye.slash", shortcut: .init(.character("d"), "⌃⇧⌘"), group: group,
                       keywords: ["desactiver", "cacher", "disable"])
    }

    /// A file or a folder: Raycast's actions, with what the converter can do with this kind of file just after opening.
    private static func files(_ path: String, folder: Bool, _ c: LauncherActionContext) -> [LauncherAction] {
        var list: [LauncherAction] = [
            LauncherAction(kind: .open, title: "Ouvrir", symbol: "doc", shortcut: .init(.enter), group: 0, keywords: ["lancer", "open"])
        ]
        if c.selectable {
            list.append(LauncherAction(kind: .mark, title: c.marked ? "Retirer de la sélection" : "Ajouter à la sélection",
                                       symbol: c.marked ? "minus.circle" : "checkmark.circle", shortcut: .init(.enter, "⌘"), group: 0,
                                       keywords: ["selectionner", "plusieurs", "cocher", "glisser", "select", "multiple"]))
        }
        list += [
            LauncherAction(kind: .reveal, title: "Afficher dans le Finder", symbol: "folder",
                           shortcut: c.selectable ? .init(.character("r"), "⌘") : .init(.enter, "⌘"), group: 0,
                           keywords: ["finder", "montrer", "reveal"]),
            LauncherAction(kind: .quickLook, title: "Coup d'œil", symbol: "eye", shortcut: .init(.character("y"), "⌘"), group: 0,
                           keywords: ["oeil", "apercu", "quick look", "previsualiser"]),
            LauncherAction(kind: .openWith, title: "Ouvrir avec…", symbol: "arrow.up.forward.app", shortcut: .init(.character("o"), "⌘"), group: 0,
                           keywords: ["application", "app", "open with"]),
            LauncherAction(kind: .getInfo, title: "Lire les informations dans le Finder", symbol: "info.circle", shortcut: .init(.character("i"), "⌘"),
                           group: 0, keywords: ["infos", "proprietes", "get info"])
        ]
        let kind = ConverterKind.detect(name: (path as NSString).lastPathComponent, isDirectory: folder)
        if kind == .pdf || kind == .image {
            list.append(LauncherAction(kind: .fillSign, title: "Remplir et signer…", symbol: "signature", group: 1,
                                       keywords: ["signer", "signature", "remplir", "formulaire", "parapher", "paraphe", "contrat"]))
        }
        for op in ConverterOperation.available(for: [kind]) where op != .rename {
            list.append(LauncherAction(kind: .convert(op), title: convertTitle(op), symbol: op.symbol, group: 1,
                                       keywords: op.keywords + ["convertir", "convertisseur"]))
        }
        list += [
            LauncherAction(kind: .parent, title: "Dossier parent", symbol: "arrow.up", shortcut: .init(.up, "⌥⌘"), group: 2,
                           keywords: ["remonter", "dossier", "enclosing folder"]),
            LauncherAction(kind: .details, title: c.detailsShown ? "Masquer les détails" : "Afficher les détails", symbol: "sidebar.right",
                           shortcut: .init(.character("d"), "⇧⌘"), group: 2, keywords: ["details", "apercu", "panneau"]),
            LauncherAction(kind: .share, title: "Partager…", symbol: "square.and.arrow.up", shortcut: .init(.character("e"), "⇧⌘"), group: 2,
                           keywords: ["airdrop", "mail", "messages", "envoyer", "share"])
        ]
        if !folder {
            list.append(LauncherAction(kind: .claude, title: "Joindre à la discussion avec Claude", symbol: "sparkles",
                                       shortcut: .init(.character("a"), "⌃⌘"), group: 2, keywords: ["claude", "assistant", "ia", "ai chat"]))
        }
        list += [
            LauncherAction(kind: .move, title: "Déplacer vers…", symbol: "tray.and.arrow.down", shortcut: .init(.character("m"), "⇧⌘"), group: 3,
                           keywords: ["ranger", "move"]),
            LauncherAction(kind: .copyTo, title: "Copier vers…", symbol: "doc.on.doc", shortcut: .init(.character("c"), "⇧⌘"), group: 3,
                           keywords: ["copy to"]),
            LauncherAction(kind: .duplicate, title: "Dupliquer", symbol: "plus.square.on.square", shortcut: .init(.character("d"), "⌘"), group: 3,
                           keywords: ["copie", "duplicate"]),
            LauncherAction(kind: .hotkey, title: c.hotkey.map { "Changer le raccourci (\($0))" } ?? "Créer un raccourci rapide", symbol: "keyboard",
                           shortcut: .init(.character("l"), "⇧⌘"), group: 4, keywords: ["raccourci clavier", "hotkey", "quicklink"]),
            favorite(c, group: 4),
            LauncherAction(kind: .copyFile, title: "Copier le fichier", symbol: "doc.on.clipboard", shortcut: .init(.character("."), "⌘"), group: 5,
                           keywords: ["presse-papiers", "copy file"]),
            LauncherAction(kind: .copyName, title: "Copier le nom", symbol: "textformat", shortcut: .init(.character("."), "⇧⌘"), group: 5,
                           keywords: ["presse-papiers", "copy name"]),
            LauncherAction(kind: .copyPath, title: "Copier le chemin", symbol: "link", shortcut: .init(.character(","), "⇧⌘"), group: 5,
                           keywords: ["presse-papiers", "copy path"]),
            LauncherAction(kind: .trash, title: "Placer dans la Corbeille", symbol: "trash", shortcut: .init(.character("x"), "⌃"), group: 6,
                           keywords: ["supprimer", "effacer", "jeter", "delete", "move to trash"])
        ]
        return list
    }

    /// An app: Raycast's own list, with quitting it when it is open and the uninstaller of the Applications module.
    private static func app(_ c: LauncherActionContext) -> [LauncherAction] {
        var list: [LauncherAction] = [
            LauncherAction(kind: .open, title: "Ouvrir l'application", symbol: "macwindow", shortcut: .init(.enter), group: 0, keywords: ["lancer", "open"]),
            LauncherAction(kind: .reveal, title: "Afficher dans le Finder", symbol: "folder", shortcut: .init(.enter, "⌘"), group: 0,
                           keywords: ["finder", "montrer", "reveal"]),
            LauncherAction(kind: .getInfo, title: "Lire les informations dans le Finder", symbol: "info.circle", shortcut: .init(.character("i"), "⌘"),
                           group: 0, keywords: ["infos", "version", "get info"]),
            LauncherAction(kind: .packageContents, title: "Afficher le contenu du paquet", symbol: "shippingbox", shortcut: .init(.character("i"), "⌥⌘"),
                           group: 0, keywords: ["contents", "paquet", "bundle"]),
            favorite(c, group: 0)
        ]
        if c.canAssign { list.append(hotkey(c, group: 1)) }
        if c.ranked { list.append(reset(group: 1)) }
        list += [
            LauncherAction(kind: .copyName, title: "Copier le nom", symbol: "textformat", shortcut: .init(.character("."), "⌘"), group: 2,
                           keywords: ["presse-papiers", "copy name"]),
            LauncherAction(kind: .copyPath, title: "Copier le chemin", symbol: "link", shortcut: .init(.character("."), "⇧⌘"), group: 2,
                           keywords: ["presse-papiers", "copy path"])
        ]
        if c.bundleID != nil {
            list.append(LauncherAction(kind: .copyBundleID, title: "Copier l'identifiant du paquet", symbol: "number", shortcut: .init(.character("c"), "⇧⌘"),
                                       group: 2, keywords: ["bundle identifier", "id", "presse-papiers"]))
        }
        if c.running {
            list.append(LauncherAction(kind: .quit, title: "Quitter l'application", symbol: "xmark.circle", group: 3, keywords: ["fermer", "quit"]))
            list.append(LauncherAction(kind: .forceQuit, title: "Forcer à quitter", symbol: "xmark.octagon", group: 3, keywords: ["kill", "force quit", "bloquee"]))
        }
        if c.inCatalog { list.append(hide(group: 3)) }
        if c.uninstallable {
            list.append(LauncherAction(kind: .uninstall, title: "Désinstaller l'application…", symbol: "trash", group: 3,
                                       keywords: ["supprimer", "desinstaller", "uninstall"]))
        }
        return list
    }

    /// An action of Heartware, a setting, a calculation…: running it, and what the launcher knows about it.
    private static func command(_ c: LauncherActionContext) -> [LauncherAction] {
        var list = [LauncherAction(kind: .open, title: c.primary ?? "Lancer", symbol: "play", shortcut: .init(.enter), group: 0, keywords: ["lancer", "ouvrir", "run"])]
        if c.inCatalog { list.append(favorite(c, group: 0)) }
        if c.canAssign { list.append(hotkey(c, group: 1)) }
        if c.ranked { list.append(reset(group: 1)) }
        list.append(LauncherAction(kind: .copyName, title: "Copier le nom", symbol: "textformat", shortcut: .init(.character("."), "⌘"), group: 2,
                                   keywords: ["presse-papiers", "titre", "copy"]))
        if c.inCatalog {
            list.append(LauncherAction(kind: .copyLink, title: "Copier le lien", symbol: "link", shortcut: .init(.character("c"), "⇧⌘"), group: 2,
                                       keywords: ["deeplink", "url", "heartware"]))
            list.append(hide(group: 3))
        }
        return list
    }

    /// The converter's operations for a single file, as actions on it ("…": the converter opens to set it up first).
    static func convertTitle(_ op: ConverterOperation) -> String {
        switch op {
        case .imageConvert: return "Convertir l'image…"
        case .imageResize: return "Redimensionner l'image…"
        case .imageCompress: return "Compresser l'image…"
        case .imageStrip: return "Retirer la localisation de la photo…"
        case .imagesToPDF: return "Transformer en PDF…"
        case .videoCompress: return "Compresser la vidéo…"
        case .videoContainer: return "Convertir la vidéo (MOV ↔ MP4)…"
        case .videoAudio: return "Extraire l'audio…"
        case .videoGIF: return "Transformer en GIF animé…"
        case .audioConvert: return "Convertir l'audio…"
        case .pdfSplit: return "Découper le PDF…"
        case .pdfRotate: return "Pivoter le PDF…"
        case .pdfCompress: return "Compresser le PDF…"
        case .pdfToImages: return "Exporter le PDF en images…"
        case .documentConvert: return "Convertir le document…"
        case .archiveZip: return "Compresser en ZIP…"
        case .archiveExtract: return "Extraire l'archive…"
        case .ocr: return "Extraire le texte (OCR)…"
        case .qrRead: return "Lire le QR code…"
        default: return op.commandTitle + "…"
        }
    }

    /// What the panel's search field keeps, best match first; everything, in order, when it is empty.
    static func filter(_ actions: [LauncherAction], _ query: String) -> [LauncherAction] {
        rank(actions, query, title: \.title, keywords: \.keywords)
    }

    static func rank<T>(_ items: [T], _ query: String, title: (T) -> String, keywords: (T) -> [String]) -> [T] {
        let q: String = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        // Step by step, typed: one chain of anonymous tuples over the two `Fuzzy.best` took the type checker 5 s.
        var scored: [(item: T, score: Double, index: Int)] = []
        for (i, item) in items.enumerated() {
            let score: Double? = Fuzzy.best(q, title: title(item), keywords: keywords(item))
            if let score { scored.append((item: item, score: score, index: i)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.index < b.index }
        return scored.map { $0.item }
    }

    /// The action a key runs, if any (a key without ⌘, ⌃ or ⌥ never runs one: it is typed in the search).
    static func action(for press: LauncherKeyPress, in actions: [LauncherAction]) -> LauncherAction? {
        actions.first { $0.shortcut?.matches(press) == true }
    }

    /// "Rapport.pdf" → "Rapport copie.pdf", like the Finder (FileOps adds " 2" if it is taken).
    static func duplicateName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(name) copie" : "\(base) copie.\(ext)"
    }

    /// A path inside an AppleScript string.
    static func appleScriptString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The panel's rules, on made-up results, keys and names (nothing is read from the disk).
    static func checks() -> [String] {
        var failures: [String] = []
        let pdf = all(for: .file(path: "/Users/test/Documents/Facture.pdf"), LauncherActionContext())
        let folder = all(for: .folder(path: "/Users/test/Documents/Factures"), LauncherActionContext())
        let photo = all(for: .file(path: "/Users/test/Pictures/Plage.heic"), LauncherActionContext())
        let open = LauncherActionContext(inCatalog: true, bundleID: "fr.exemple.monteur", running: true, uninstallable: true)
        let app = all(for: .app(path: "/Applications/Monteur.app", name: "Monteur"), open)
        let systemApp = all(for: .app(path: "/System/Applications/Notes.app", name: "Notes"), LauncherActionContext(inCatalog: true))
        let command = all(for: .command(id: "act_smart_scan", title: "Analyse intelligente"), LauncherActionContext(ranked: true, primary: "Lancer"))
        let dynamic = all(for: .command(id: "calc_result", title: "= 1 725"), LauncherActionContext(inCatalog: false, canAssign: false, primary: "Copier"))
        var window = LauncherActionContext()
        window.selectable = true
        let picking = all(for: .file(path: "/Users/test/Documents/Facture.pdf"), window)
        window.marked = true
        let picked = all(for: .folder(path: "/Users/test/Documents/Factures"), window)
        func kinds(_ l: [LauncherAction]) -> [LauncherActionKind] { l.map(\.kind) }

        // What each kind of result offers.
        if folder.contains(where: { $0.kind == .claude }) || !pdf.contains(where: { $0.kind == .claude }) {
            failures.append("actions : Claude lit un fichier, pas un dossier")
        }
        if pdf.first?.kind != .open || pdf.last?.kind != .trash || pdf.last?.destructive != true {
            failures.append("actions : fichier, Ouvrir d'abord et la Corbeille en dernier")
        }
        if !kinds(pdf).contains(.convert(.pdfCompress)) || kinds(pdf).contains(.convert(.pdfMerge)) || kinds(pdf).contains(.convert(.imageConvert)) {
            failures.append("actions : un PDF propose de le compresser, pas de le fusionner seul ni de convertir une image")
        }
        if !kinds(photo).contains(.convert(.imageConvert)) || !kinds(photo).contains(.convert(.ocr)) || kinds(photo).contains(.convert(.pdfCompress)) {
            failures.append("actions : une photo propose ses conversions")
        }
        if !kinds(folder).contains(.convert(.archiveZip)) || kinds(folder).contains(.convert(.rename)) {
            failures.append("actions : un dossier se compresse en ZIP")
        }
        if let i = kinds(pdf).firstIndex(of: .convert(.pdfCompress)), let parent = kinds(pdf).firstIndex(of: .parent), i > parent {
            failures.append("actions : les conversions du fichier viennent juste après l'ouverture")
        }
        if app.first?.title != "Ouvrir l'application" || app.last?.kind != .uninstall
            || !Set(kinds(app)).isSuperset(of: [.reveal, .getInfo, .packageContents, .favorite, .hotkey, .copyName, .copyPath, .copyBundleID, .quit, .forceQuit, .hide]) {
            failures.append("actions : app, \(app.map(\.title))")
        }
        if kinds(app).contains(.trash) || kinds(app).contains(.quickLook) || kinds(app).contains(.resetRanking) {
            failures.append("actions : une app ne va pas à la Corbeille d'ici, et n'a pas de classement à remettre à zéro sans usage")
        }
        if kinds(systemApp).contains(.uninstall) || kinds(systemApp).contains(.quit) || kinds(systemApp).contains(.copyBundleID) {
            failures.append("actions : une app de macOS fermée ne se désinstalle ni ne se quitte")
        }
        if command.first?.title != "Lancer" || !Set(kinds(command)).isSuperset(of: [.favorite, .hotkey, .resetRanking, .copyName, .copyLink, .hide]) {
            failures.append("actions : commande, \(command.map(\.title))")
        }
        if kinds(dynamic) != [.open, .copyName] || dynamic.first?.title != "Copier" {
            failures.append("actions : un résultat qui change avec la saisie, \(dynamic.map(\.title))")
        }
        if all(for: .app(path: "/Applications/A.app", name: "A"), LauncherActionContext(favorite: true, hotkey: "⌃⌥A"))
            .map(\.title).filter({ $0 == "Retirer des favoris" || $0 == "Changer le raccourci (⌃⌥A)" }).count != 2 {
            failures.append("actions : les libellés suivent les favoris et le raccourci")
        }
        if kinds(pdf).contains(.mark) || kinds(picking).prefix(3) != [.open, .mark, .reveal]
            || picking.first(where: { $0.kind == .mark })?.title != "Ajouter à la sélection" || picked.first(where: { $0.kind == .mark })?.title != "Retirer de la sélection" {
            failures.append("actions : la fenêtre Fichiers propose de choisir le fichier, juste après Ouvrir (\(picking.prefix(3).map(\.title)))")
        }
        if all(for: .file(path: "/a.txt"), LauncherActionContext(detailsShown: false)).first(where: { $0.kind == .details })?.title != "Afficher les détails" {
            failures.append("actions : le libellé des détails suit leur état")
        }
        // Every list: valid ids and symbols, one key per action, no key that would be typed in the search.
        for (name, list) in [("fichier", pdf), ("dossier", folder), ("photo", photo), ("app", app), ("commande", command),
                             ("fenêtre Fichiers", picking), ("fichier choisi", picked)] {
            for a in list where !AppCommand.isValidID(a.id) { failures.append("actions : identifiant invalide \(a.id)") }
            for a in list where NSImage(systemSymbolName: a.symbol, accessibilityDescription: nil) == nil {
                failures.append("actions : symbole introuvable \(a.symbol)")
            }
            let keys = list.compactMap { $0.shortcut?.keys.joined() }
            if Set(keys).count != keys.count { failures.append("actions (\(name)) : deux actions ont le même raccourci") }
            for a in list where a.kind != .open {
                if let s = a.shortcut, !(s.command || s.control || s.option) {
                    failures.append("actions : « \(a.title) » sans ⌘, ⌃ ni ⌥ serait tapé dans la recherche")
                }
            }
        }
        // The search field of the panel.
        if filter(pdf, "").map(\.kind) != kinds(pdf) { failures.append("actions : sans recherche, tout dans l'ordre") }
        if filter(pdf, "corb").first?.kind != .trash { failures.append("actions : « corb » devrait trouver la Corbeille") }
        if filter(pdf, "supprimer").first?.kind != .trash { failures.append("actions : « supprimer » devrait trouver la Corbeille") }
        if filter(pdf, "oeil").first?.kind != .quickLook { failures.append("actions : « oeil » devrait trouver Coup d'œil") }
        if filter(pdf, "dupl").first?.kind != .duplicate { failures.append("actions : « dupl » devrait trouver Dupliquer") }
        if filter(pdf, "alleger").first?.kind != .convert(.pdfCompress) { failures.append("actions : « alleger » devrait trouver Compresser le PDF") }
        if filter(app, "desinst").first?.kind != .uninstall { failures.append("actions : « desinst » devrait trouver Désinstaller") }
        let copies = Set(filter(pdf, "copier").map(\.kind))
        if !copies.isSuperset(of: [.copyTo, .copyFile, .copyName, .copyPath]) { failures.append("actions : « copier » oublie une copie") }
        if !filter(pdf, "zzqx").isEmpty { failures.append("actions : résultat inventé pour « zzqx »") }
        // Keys: an American keyboard, then an AZERTY one.
        func hit(_ list: [LauncherAction], _ keyCode: Int, _ base: String, _ typed: String, _ mods: String = "") -> LauncherActionKind? {
            action(for: LauncherKeyPress(keyCode: keyCode, base: base, typed: typed, command: mods.contains("⌘"), shift: mods.contains("⇧"),
                                         option: mods.contains("⌥"), control: mods.contains("⌃")), in: list)?.kind
        }
        let presses: [(String, LauncherActionKind?, LauncherActionKind?)] = [
            ("⌘↩", hit(pdf, kVK_Return, "\r", "\r", "⌘"), .reveal), ("↩", hit(pdf, kVK_Return, "\r", "\r"), .open),
            ("⌘Y", hit(pdf, kVK_ANSI_Y, "y", "y", "⌘"), .quickLook), ("⌘O", hit(pdf, kVK_ANSI_O, "o", "o", "⌘"), .openWith),
            ("⌘I", hit(pdf, kVK_ANSI_I, "i", "i", "⌘"), .getInfo), ("⌥⌘↑", hit(pdf, kVK_UpArrow, "", "", "⌥⌘"), .parent),
            ("⌘↑", hit(pdf, kVK_UpArrow, "", "", "⌘"), nil), ("⇧⌘D", hit(pdf, kVK_ANSI_D, "d", "D", "⇧⌘"), .details),
            ("⌘D", hit(pdf, kVK_ANSI_D, "d", "d", "⌘"), .duplicate), ("⇧⌘E", hit(pdf, kVK_ANSI_E, "e", "E", "⇧⌘"), .share),
            ("⇧⌘M", hit(pdf, kVK_ANSI_Semicolon, "m", "M", "⇧⌘"), .move), ("⇧⌘C", hit(pdf, kVK_ANSI_C, "c", "C", "⇧⌘"), .copyTo),
            ("⇧⌘L", hit(pdf, kVK_ANSI_L, "l", "L", "⇧⌘"), .hotkey), ("⇧⌘F", hit(pdf, kVK_ANSI_F, "f", "F", "⇧⌘"), .favorite),
            ("⌘.", hit(pdf, kVK_ANSI_Period, ".", ".", "⌘"), .copyFile),
            ("⇧⌘. (US)", hit(pdf, kVK_ANSI_Period, ".", ">", "⇧⌘"), .copyName), ("⇧⌘, (US)", hit(pdf, kVK_ANSI_Comma, ",", "<", "⇧⌘"), .copyPath),
            ("⌃X", hit(pdf, kVK_ANSI_X, "x", "x", "⌃"), .trash), ("⌘X", hit(pdf, kVK_ANSI_X, "x", "x", "⌘"), nil),
            // AZERTY: A is where Q is, "." is ⇧; and "," has its own key.
            ("⌃⌘A (AZERTY)", hit(pdf, kVK_ANSI_Q, "a", "a", "⌃⌘"), .claude), ("⌘Q (AZERTY)", hit(pdf, kVK_ANSI_A, "q", "q", "⌘"), nil),
            ("⌘. (AZERTY)", hit(pdf, kVK_ANSI_Comma, ";", ".", "⇧⌘"), .copyFile), ("⇧⌘, (AZERTY)", hit(pdf, kVK_ANSI_M, ",", "?", "⇧⌘"), .copyPath),
            // An app: Raycast's own keys.
            ("app ⌘.", hit(app, kVK_ANSI_Period, ".", ".", "⌘"), .copyName), ("app ⇧⌘C", hit(app, kVK_ANSI_C, "c", "C", "⇧⌘"), .copyBundleID),
            ("app ⌥⌘I", hit(app, kVK_ANSI_I, "i", "i", "⌥⌘"), .packageContents), ("app ⌃⇧⌘D", hit(app, kVK_ANSI_D, "d", "D", "⌃⇧⌘"), .hide),
            ("app ⇧⌘,", hit(app, kVK_ANSI_Comma, ",", "<", "⇧⌘"), .hotkey), ("app ⌘Y", hit(app, kVK_ANSI_Y, "y", "y", "⌘"), nil),
            ("commande ⇧⌘C", hit(command, kVK_ANSI_C, "c", "C", "⇧⌘"), .copyLink),
            // The file window: ⌘↩ picks the file, ⌘R shows it in the Finder (⌘R does nothing in the launcher).
            ("fenêtre ⌘↩", hit(picking, kVK_Return, "\r", "\r", "⌘"), .mark), ("fenêtre ⌘R", hit(picking, kVK_ANSI_R, "r", "r", "⌘"), .reveal),
            ("lanceur ⌘R", hit(pdf, kVK_ANSI_R, "r", "r", "⌘"), nil), ("fenêtre ↩", hit(picking, kVK_Return, "\r", "\r"), .open),
            // Plain keys are typed in the search, ⌘K opens the panel.
            ("d", hit(pdf, kVK_ANSI_D, "d", "d"), nil), ("D", hit(pdf, kVK_ANSI_D, "d", "D", "⇧"), nil), ("⌘K", hit(pdf, kVK_ANSI_K, "k", "k", "⌘"), nil)
        ]
        for (name, got, expected) in presses where got != expected {
            failures.append("actions : \(name) lance \(got?.key ?? "rien") au lieu de \(expected?.key ?? "rien")")
        }
        if pdf.first(where: { $0.kind == .parent })?.shortcut?.keys != ["⌥", "⌘", "↑"]
            || app.first(where: { $0.kind == .hide })?.shortcut?.keys != ["⌃", "⇧", "⌘", "D"] {
            failures.append("actions : ordre des touches affichées (⌃ ⌥ ⇧ ⌘)")
        }
        if duplicateName("Rapport annuel.pdf") != "Rapport annuel copie.pdf" || duplicateName("Factures") != "Factures copie"
            || duplicateName("archive.tar.gz") != "archive.tar copie.gz" {
            failures.append("actions : nom du double « \(duplicateName("Rapport annuel.pdf")) »")
        }
        if appleScriptString("a\"b\\c") != "a\\\"b\\\\c" { failures.append("actions : chemin mal protégé pour AppleScript") }
        // What Claude receives.
        let long = String(repeating: "é", count: LauncherClaudeAttachment.limit + 50)
        let cut = LauncherClaudeAttachment.compose(name: "notes.md", details: "Markdown, 2 Ko, dans ~/Documents", content: long)
        if !cut.contains("« notes.md »") || !cut.contains("premiers caractères") || cut.count > LauncherClaudeAttachment.limit + 400 {
            failures.append("actions : pièce jointe pour Claude mal coupée")
        }
        let none = LauncherClaudeAttachment.compose(name: "photo.heic", details: "Image HEIF", content: nil)
        if none.contains("début du fichier") || !none.contains("pas du texte") { failures.append("actions : pièce jointe sans texte") }
        return failures
    }
}

// MARK: - What Claude receives

/// A file joined to the conversation with Claude: its text goes in the message (Claude reads nothing on the Mac by itself),
/// and the user sees all of it before sending.
enum LauncherClaudeAttachment {
    static let limit = 20_000

    /// The message and whether the file's content is in it.
    static func message(for path: String) -> (text: String, readable: Bool) {
        let info = LauncherFileInfo.read(path)
        var details = [info.kind, info.size == "…" ? "" : info.size].filter { !$0.isEmpty }
        details.append("dans " + FS.pretty((path as NSString).deletingLastPathComponent))
        let content = text(of: path)
        let readable = !(content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return (compose(name: (path as NSString).lastPathComponent, details: details.joined(separator: ", "), content: readable ? content : nil), readable)
    }

    static func compose(name: String, details: String, content: String?) -> String {
        guard let content else {
            return "Je te joins le fichier « \(name) » (\(details)). Son contenu n'est pas du texte : tu n'en as que le nom et le type."
        }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = text.count > limit
        return "Je te joins le fichier « \(name) » (\(details)).\n\n--- début du fichier ---\n" + (cut ? String(text.prefix(limit)) : text)
            + "\n--- fin du fichier" + (cut ? " (seulement ses \(Fmt.int(limit)) premiers caractères)" : "") + " ---\n\n"
    }

    /// The readable text of a file: text and code, PDF, RTF, Word and OpenDocument. nil for anything else.
    static func text(of path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey]),
              values.isDirectory != true, let type = values.contentType else { return nil }
        if type.conforms(to: .pdf) {
            guard let doc = PDFDocument(url: url) else { return nil }
            var out = ""
            for i in 0..<doc.pageCount {
                out += (doc.page(at: i)?.string ?? "") + "\n"
                if out.count > limit { break }
            }
            return out
        }
        let documents: Set<String> = ["docx", "doc", "odt", "rtf", "rtfd"]
        if documents.contains(url.pathExtension.lowercased()) {
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        guard type.conforms(to: .text) else { return nil }
        // A huge log is cut: what is past the limit would not be sent anyway.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit * 4)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Running the actions

extension LauncherModel {
    var visibleActions: [LauncherAction] { LauncherActions.filter(actionsList, actionFilter) }

    var visibleApps: [LauncherOpenWithApp] {
        LauncherActions.rank(openWithApps ?? [], actionFilter, title: \.name, keywords: { _ in [] })
    }

    /// What ↩ does on the selected result, for the bar at the bottom.
    var selectedPrimary: String? {
        let items = flat
        guard items.indices.contains(selection) else { return nil }
        let command = items[selection]
        switch target(for: command) {
        case .app: return "Ouvrir l'application"
        case .file, .folder: return "Ouvrir"
        case .command: return command.hint?.components(separatedBy: " · ").first.flatMap { $0.contains("⌘") ? nil : $0 } ?? "Lancer"
        }
    }

    /// What ⌘K is pressed on: a file, a folder, an app or any other result. A shortcut of the Raccourcis section
    /// stands for the app or the file it opens.
    func target(for command: AppCommand) -> LauncherActionTarget {
        if case .file(let path) = command.icon {
            let shortcut = command.id.hasPrefix("hk_")
            if command.group == .apps || (shortcut && path.hasSuffix(".app")) { return .app(path: path, name: command.title) }
            if command.group == .files || shortcut { return isFolder(path) ? .folder(path: path) : .file(path: path) }
        }
        return .command(id: command.id, title: command.title)
    }

    /// What a keyboard shortcut would open: the app, the file or the folder itself, or a command of the catalogue.
    func hotkeysTarget(for target: LauncherActionTarget, command: AppCommand?) -> HotkeysTarget? {
        switch target {
        case .app(let path, let name): return .app(path: path, name: name)
        case .file(let path): return .file(path: path)
        case .folder(let path): return .folder(path: path)
        case .command: return command.flatMap { HotkeysModel.target(for: $0, catalogIDs: catalogIDs) }
        }
    }

    /// Everything the actions depend on, read once when the panel opens.
    func actionContext(for target: LauncherActionTarget, command: AppCommand) -> LauncherActionContext {
        var c = LauncherActionContext()
        c.detailsShown = showDetails
        c.favorite = favoriteItems.contains { $0.id == command.id }
        c.ranked = CommandRunner.usage.value[command.id] != nil
        c.inCatalog = inCatalog(command.id)
        let shortcut = hotkeysTarget(for: target, command: command)
        c.canAssign = shortcut != nil
        c.hotkey = shortcut.flatMap { app?.hotkeys.binding(for: $0)?.combo?.display }
        switch target {
        case .app(let path, _):
            c.bundleID = Self.bundleID(path)
            // The demo's fictional apps that "run", never the ones open on this Mac.
            c.running = DemoData.isEnabled ? c.bundleID.map { RunningApps.snapshot().bundleIDs.contains($0) } ?? false
                                           : Self.runningApp(path, bundleID: c.bundleID) != nil
            c.uninstallable = Self.canUninstall(path, bundleID: c.bundleID)
        case .command:
            c.primary = command.hint?.components(separatedBy: " · ").first.flatMap { $0.contains("⌘") ? nil : $0 }
        case .file(let path), .folder(let path):
            c.selectable = scope == .files
            c.marked = marked.contains(path)
        }
        return c
    }

    /// ⌘K: the actions of the selected result.
    func openActions() {
        let items = flat
        guard items.indices.contains(selection) else { return }
        let command = items[selection]
        let target = target(for: command)
        actionsCommand = command
        actionsList = LauncherActions.all(for: target, actionContext(for: target, command: command))
        openWithApps = nil
        actionFilter = ""
        actionSelection = 0
        actionsTarget = target
    }

    func closeActions() {
        actionsTarget = nil
        actionsCommand = nil
        actionsList = []
        openWithApps = nil
        actionFilter = ""
        actionSelection = 0
    }

    func toggleActions() {
        actionsTarget == nil ? openActions() : closeActions()
    }

    func moveAction(_ delta: Int) {
        let count = openWithApps == nil ? visibleActions.count : visibleApps.count
        guard count > 0 else { return }
        actionSelection = (actionSelection + delta + count) % count
    }

    func runSelectedAction() {
        guard let target = actionsTarget else { return }
        if openWithApps != nil {
            let apps = visibleApps
            if apps.indices.contains(actionSelection), let path = target.path { open(path, with: apps[actionSelection]) }
            return
        }
        let actions = visibleActions
        if actions.indices.contains(actionSelection) { perform(actions[actionSelection], on: target, command: actionsCommand) }
    }

    /// The keys of the panel: arrows, ↩, ⎋ (back, then close), ⌘K, and every action's own shortcut.
    func actionsKey(_ event: NSEvent) -> NSEvent? {
        let press = LauncherKeyPress(event)
        let plain = !press.command && !press.option && !press.control && !press.shift
        switch Int(event.keyCode) {
        case kVK_Escape:
            if openWithApps != nil {
                openWithApps = nil
                actionFilter = ""
                actionSelection = 0
            } else {
                closeActions()
            }
            return nil
        case kVK_DownArrow where plain:
            moveAction(1)
            return nil
        case kVK_UpArrow where plain:
            moveAction(-1)
            return nil
        case kVK_Return where plain, kVK_ANSI_KeypadEnter where plain:
            runSelectedAction()
            return nil
        default:
            break
        }
        if press.command, press.typed.lowercased() == "k" {
            closeActions()
            return nil
        }
        if openWithApps == nil, let target = actionsTarget, let action = LauncherActions.action(for: press, in: actionsList) {
            perform(action, on: target, command: actionsCommand)
            return nil
        }
        return event
    }

    /// An action's shortcut on the selected result, without opening the panel (↩ and ⌘↩ go their own way, see `searchKey`).
    func resultShortcut(_ event: NSEvent) -> Bool {
        let items = flat
        guard items.indices.contains(selection) else { return false }
        let command = items[selection]
        let target = target(for: command)
        // Only keys with ⌘, ⌃ or ⌥ can be shortcuts: the context is read for those alone, not for each letter typed.
        guard !event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let actions = LauncherActions.all(for: target, actionContext(for: target, command: command))
        guard let action = LauncherActions.action(for: LauncherKeyPress(event), in: actions),
              action.shortcut?.key != .enter else { return false }
        perform(action, on: target, command: command)
        return true
    }

    func perform(_ action: LauncherAction, on target: LauncherActionTarget, command: AppCommand?) {
        if DemoData.isEnabled, action.touchesMac {
            closeActions()
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        let path = target.path ?? ""
        let name = target.title
        switch action.kind {
        case .open, .reveal:
            closeActions()
            if let command {
                run(command, alternate: action.kind == .reveal)
            } else if !path.isEmpty {
                hide()
                if action.kind == .reveal { Finder.reveal(path) } else { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
        case .mark:
            closeActions()
            if !path.isEmpty { toggleMark(path: path) }
        case .quickLook:
            closeActions()
            mode = .quickLook(path: path)
        case .openWith:
            let apps = LauncherOpenWithApp.list(for: path)
            guard !apps.isEmpty else {
                HUD.show("Aucune app ne sait ouvrir « \(name) »", symbol: "exclamationmark.circle.fill")
                return
            }
            if actionsTarget == nil, let command {
                // ⌘O straight from the results: the panel opens on the list of apps.
                actionsCommand = command
                actionsList = LauncherActions.all(for: target, actionContext(for: target, command: command))
                actionsTarget = target
            }
            actionFilter = ""
            actionSelection = 0
            openWithApps = apps
        case .getInfo:
            closeActions()
            showInfo(path)
        case .packageContents:
            closeActions()
            browse(FS.pretty(path) + "/Contents/")
        case .parent:
            closeActions()
            showParent(of: path)
        case .details:
            closeActions()
            showDetails.toggle()
        case .share:
            closeActions()
            share(path)
        case .claude:
            closeActions()
            attachToClaude(path)
        case .convert(let op):
            closeActions()
            convert(path, with: op)
        case .fillSign:
            closeActions()
            fillSign(path)
        case .move, .copyTo:
            closeActions()
            transfer(path, move: action.kind == .move)
        case .duplicate:
            closeActions()
            duplicate(path)
        case .favorite:
            closeActions()
            if let command { toggleFavorite(command, target: target) }
        case .hotkey:
            closeActions()
            if let command, let i = flat.firstIndex(where: { $0.id == command.id }) { selection = i }
            if let shortcut = hotkeysTarget(for: target, command: command) {
                assignMessage = nil
                mode = .assign(target: shortcut, title: name)
            }
        case .resetRanking:
            closeActions()
            if let command {
                CommandRunner.usage.value[command.id] = nil
                HUD.show("Classement de « \(name) » remis à zéro", symbol: "arrow.counterclockwise.circle.fill")
            }
        case .copyFile:
            closeActions()
            guard !Snapshot.isActive else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
            HUD.show("Fichier copié : colle-le dans le Finder ou un message", symbol: "doc.on.clipboard.fill")
        case .copyName, .copyPath, .copyBundleID, .copyLink:
            closeActions()
            let text: String?
            switch action.kind {
            case .copyName: text = name
            case .copyPath: text = path
            case .copyBundleID: text = Self.bundleID(path)
            default: text = command.map { "heartware://run/" + $0.id }
            }
            if let text, case .copied = CommandRunner.copy(text) {
                let what = [LauncherActionKind.copyName: "Nom", .copyPath: "Chemin", .copyBundleID: "Identifiant", .copyLink: "Lien"][action.kind] ?? ""
                HUD.show("\(what) copié : \(text.count > 40 ? String(text.prefix(40)) + "…" : text)", symbol: "doc.on.clipboard.fill")
            }
        case .quit, .forceQuit:
            closeActions()
            quit(path, name: name, force: action.kind == .forceQuit)
        case .hide:
            closeActions()
            if let command {
                hiddenIDs.append(command.id)
                HUD.show("« \(name) » n'apparaît plus dans la recherche (Raccourcis › Heartware pour le remettre)", symbol: "eye.slash.fill")
                refreshKeepingSelection()
            }
        case .uninstall:
            closeActions()
            uninstall(path)
        case .trash:
            closeActions()
            trash(path)
        }
    }

    // MARK: Apps

    static func bundleID(_ path: String) -> String? {
        if DemoData.isEnabled { return DemoData.apps().first { $0.path == path }?.bundleID }
        return Bundle(path: path)?.bundleIdentifier
    }

    /// The running copy of the app at `path` (never Heartware itself). Always nil in the demo: nothing real is listed.
    static func runningApp(_ path: String, bundleID: String?) -> NSRunningApplication? {
        guard !DemoData.isEnabled else { return nil }
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.first {
            $0 != NSRunningApplication.current && $0.bundleURL?.standardizedFileURL.path == wanted
        }
    }

    /// Only the apps of the Applications folders, never macOS's own nor Heartware (like the Applications module).
    static func canUninstall(_ path: String, bundleID: String?) -> Bool {
        if DemoData.isEnabled { return DemoData.apps().contains { $0.path == path && !$0.isApple } }
        let p = (path as NSString).standardizingPath
        guard p.hasPrefix("/Applications/") || p.hasPrefix(FS.home + "/Applications/"), p.hasSuffix(".app") else { return false }
        guard let id = bundleID else { return true }
        return !id.hasPrefix("com.apple.") && id != Bundle.main.bundleIdentifier
    }

    private func quit(_ path: String, name: String, force: Bool) {
        guard let running = Self.runningApp(path, bundleID: Self.bundleID(path)) else {
            HUD.show("\(name) n'est plus ouverte", symbol: "info.circle.fill")
            return
        }
        if force {
            guard CommandRunner.confirm("Forcer \(name) à quitter ?", "Les documents non enregistrés de \(name) seront perdus.", button: "Forcer à quitter") else {
                refocus()
                return
            }
        }
        let ok = force ? running.forceTerminate() : running.terminate()
        HUD.show(ok ? "\(name) \(force ? "arrêtée" : "fermée")" : "\(name) n'a pas voulu se fermer", symbol: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
        refocus()
    }

    /// The uninstaller of the Applications module, its leftovers listed: the user checks them and confirms there.
    private func uninstall(_ path: String) {
        guard let app = app ?? AppContext.model else { return }
        hide()
        Task {
            let installed = await Task.detached(priority: .userInitiated) { AppInventory.inspect(path, running: RunningApps.snapshot()) }.value
            app.page = .apps
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
            await app.apps.prepareUninstall(installed)
        }
    }

    // MARK: Favourites

    private func toggleFavorite(_ command: AppCommand, target: LauncherActionTarget) {
        if let i = favoriteItems.firstIndex(where: { $0.id == command.id }) {
            favoriteItems.remove(at: i)
            HUD.show("Retiré des favoris", symbol: "star.slash.fill")
        } else {
            var favorite = LauncherFavorite(id: command.id)
            if case .file(let p) = target { favorite.path = p }
            if case .folder(let p) = target { favorite.path = p; favorite.isDir = true }
            favoriteItems.append(favorite)
            HUD.show("Ajouté aux favoris : en tête du lanceur, la recherche vide", symbol: "star.fill")
        }
        refreshKeepingSelection()
    }

    // MARK: Files

    private func open(_ path: String, with app: LauncherOpenWithApp) {
        closeActions()
        guard !DemoData.isEnabled else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        hide()
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: URL(fileURLWithPath: app.path),
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            let message = error.localizedDescription
            DispatchQueue.main.async { HUD.show(message, symbol: "xmark.octagon.fill") }
        }
    }

    /// The Finder's own "Lire les informations" window (macOS asks once to let Heartware drive the Finder).
    private func showInfo(_ path: String) {
        hide()
        let script = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(LauncherActions.appleScriptString(path))" as alias)
        end tell
        """
        Task {
            let r = await Task.detached(priority: .userInitiated) { Shell.appleScript(script) }.value
            guard !r.ok, r.status != -128 else { return }
            HUD.show(r.status == -1743 ? "Autorise \(AppEdition.name) à piloter le Finder : Réglages Système › Confidentialité › Automatisation"
                                       : (r.err.isEmpty ? "Le Finder n'a pas répondu." : r.err), symbol: "xmark.octagon.fill")
        }
    }

    /// The folder that holds the file, browsed in the file window, the file still selected.
    private func showParent(of path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        browse(parent == "/" ? "/" : FS.pretty(parent) + "/")
        if let i = flat.firstIndex(where: { Self.filePath(of: $0) == path }) {
            scrollToSelection = true
            selection = i
        }
    }

    private func share(_ path: String) {
        guard let view = panelView else { return }
        let picker = NSSharingServicePicker(items: [URL(fileURLWithPath: path)])
        let delegate = LauncherShareDelegate { [weak self] in self?.hide() }
        shareDelegate = delegate
        picker.delegate = delegate
        let b = view.bounds
        picker.show(relativeTo: NSRect(x: b.maxX - 220, y: b.midY, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    /// The converter, this file in it and the operation chosen: its settings and a preview come before anything is written.
    private func convert(_ path: String, with op: ConverterOperation) {
        guard let app = app ?? AppContext.model else { return }
        hide()
        app.converter.present([URL(fileURLWithPath: path)], focus: op)
    }

    /// The document opens in the window of « Remplir et signer », ready to be filled in and signed (a copy is saved, never the original).
    private func fillSign(_ path: String) {
        guard let app = app ?? AppContext.model else { return }
        hide()
        app.fillSign.openWindow(URL(fileURLWithPath: path))
    }

    /// Puts the file's text in the message being written to Claude, then shows the conversation: nothing leaves before the user sends it.
    private func attachToClaude(_ path: String) {
        guard let app = app ?? AppContext.model else { return }
        hide()
        Task {
            let attachment = await Task.detached(priority: .userInitiated) { LauncherClaudeAttachment.message(for: path) }.value
            let assistant = app.assistant
            let current = assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            assistant.draft = current.isEmpty ? attachment.text : current + "\n\n" + attachment.text
            app.page = .assistant
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
            HUD.show(attachment.readable ? "Fichier joint : écris ta question, puis envoie" : "Claude ne verra que le nom et le type de ce fichier",
                     symbol: attachment.readable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        }
    }

    /// "Déplacer vers…" and "Copier vers…": the user picks the folder, a name already taken there gets " 2".
    private func transfer(_ path: String, move: Bool) {
        hide()
        let source = URL(fileURLWithPath: path)
        let name = source.lastPathComponent
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.directoryURL = source.deletingLastPathComponent()
        picker.message = move ? "Où ranger « \(name) » ?" : "Où copier « \(name) » ?"
        picker.prompt = move ? "Déplacer ici" : "Copier ici"
        NSApp.activate()
        guard picker.runModal() == .OK, let folder = picker.url else { return }
        if move, folder.standardizedFileURL.path == source.deletingLastPathComponent().standardizedFileURL.path {
            HUD.show("« \(name) » est déjà dans ce dossier", symbol: "exclamationmark.circle.fill")
            return
        }
        let target = folder.appendingPathComponent(name)
        Task {
            let (done, failure) = await Task.detached(priority: .userInitiated) { () -> (String?, String?) in
                do {
                    let url = move ? try FileOps.move(source, to: target) : try FileOps.copy(source, to: target)
                    return (url.path, nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value
            if let done {
                HUD.show("\(move ? "Déplacé" : "Copié") dans \(FS.pretty((done as NSString).deletingLastPathComponent))", symbol: "checkmark.circle.fill")
            } else {
                HUD.show(failure ?? "Échec.", symbol: "xmark.octagon.fill")
            }
        }
    }

    private func duplicate(_ path: String) {
        let source = URL(fileURLWithPath: path)
        let target = source.deletingLastPathComponent().appendingPathComponent(LauncherActions.duplicateName(source.lastPathComponent))
        Task {
            let (done, failure) = await Task.detached(priority: .userInitiated) { () -> (String?, String?) in
                do { return (try FileOps.copy(source, to: target).lastPathComponent, nil) } catch { return (nil, error.localizedDescription) }
            }.value
            if let done {
                HUD.show("Dupliqué : \(done)", symbol: "checkmark.circle.fill")
                refreshKeepingSelection()
            } else {
                HUD.show(failure ?? "Échec.", symbol: "xmark.octagon.fill")
            }
        }
    }

    /// Always to the Trash, after a confirmation: the file can be put back from there.
    private func trash(_ path: String) {
        let name = (path as NSString).lastPathComponent
        guard CommandRunner.confirm("Placer « \(name) » dans la Corbeille ?",
                                    "Tu pourras le remettre à sa place depuis la Corbeille tant qu'elle n'est pas vidée.",
                                    button: "Placer dans la Corbeille") else {
            refocus()
            return
        }
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                Remover.remove([RemovalEntry(path: path, size: FileSizer.size(of: path))], mode: .trash)
            }.value
            if report.removed > 0 {
                HUD.show("« \(name) » est dans la Corbeille", symbol: "checkmark.circle.fill")
                refreshKeepingSelection()
            } else if let failure = report.failures.first {
                HUD.show(failure.reason == "Emplacement protégé" ? "Heartware ne touche pas à cet emplacement" : failure.reason,
                         symbol: "xmark.octagon.fill")
            }
            refocus()
        }
    }

    static func filePath(of command: AppCommand) -> String? {
        guard command.group == .files, case .file(let path) = command.icon else { return nil }
        return path
    }
}

/// Closes the launcher once a way of sharing is chosen (Mail, AirDrop… open their own window under it otherwise).
final class LauncherShareDelegate: NSObject, NSSharingServicePickerDelegate {
    private let onChoose: @MainActor () -> Void

    init(onChoose: @escaping @MainActor () -> Void) {
        self.onChoose = onChoose
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard service != nil else { return }
        MainActor.assumeIsolated { onChoose() }
    }
}
