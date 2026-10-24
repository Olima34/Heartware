import SwiftUI
import AppKit
import Carbon.HIToolbox

enum ClipboardFilterTab: String, CaseIterable, Identifiable {
    case all, text, links, images, files, pinned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Tout"
        case .text: return "Texte"
        case .links: return "Liens"
        case .images: return "Images"
        case .files: return "Fichiers"
        case .pinned: return "Épinglés"
        }
    }

    func accepts(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all: return true
        case .text: return item.kind == .text && item.textKind != .link
        case .links: return item.textKind == .link
        case .images: return item.kind == .image
        case .files: return item.kind == .files
        case .pinned: return item.pinned
        }
    }
}

/// How macOS (15.4 and later) lets the app read the clipboard.
enum ClipboardAccess {
    case unknown, notAsked, ask, allowed, denied

    @MainActor
    static var current: ClipboardAccess {
        if DemoData.isEnabled { return .allowed }
        #if compiler(>=6.1)
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: return .allowed
            case .alwaysDeny: return .denied
            case .ask: return .ask
            case .default: return .notAsked
            @unknown default: return .unknown
            }
        }
        #endif
        return .unknown
    }

    var status: Status {
        switch self {
        case .allowed: return .ok
        case .denied: return .bad
        case .ask: return .warn
        case .notAsked, .unknown: return .info
        }
    }

    var label: String {
        switch self {
        case .allowed: return "Toujours autorisé"
        case .denied: return "Refusé"
        case .ask: return "Demande à chaque fois"
        case .notAsked: return "Pas encore demandé"
        case .unknown: return "Libre"
        }
    }

    var explanation: String {
        switch self {
        case .allowed: return "macOS laisse \(AppEdition.name) lire le presse-papiers sans te déranger."
        case .denied: return "L'historique ne peut rien enregistrer. Dans Confidentialité et sécurité, au réglage « Coller depuis d'autres apps », choisis « Toujours autoriser » pour \(AppEdition.name)."
        case .ask: return "macOS te demande ton accord à chaque copie : dans Confidentialité et sécurité, choisis « Toujours autoriser » pour \(AppEdition.name)."
        case .notAsked: return "À la première copie, macOS te demandera ton accord : choisis « Toujours autoriser »."
        case .unknown: return "Ta version de macOS ne demande pas d'autorisation pour lire le presse-papiers."
        }
    }

    /// One line under « Activer l'historique », when macOS has something to say.
    var firstStep: String? {
        switch self {
        case .notAsked: return "À la première copie, macOS te demandera ton accord : choisis « Toujours autoriser »."
        case .ask: return "macOS te demandera ton accord à chaque copie."
        case .denied: return "macOS refuse l'accès au presse-papiers."
        case .allowed, .unknown: return nil
        }
    }

    /// Where « Coller depuis d'autres apps » is set for each app.
    @MainActor
    static func openPrivacySettings() {
        Finder.open("x-apple.systempreferences:com.apple.preference.security")
    }
}

/// The app in front when something was copied.
private struct ClipboardSource: Sendable {
    var name: String?
    var id: String?
    var path: String?
}

/// What one copy holds, read from the pasteboard on the main thread (AppKit does not promise more), and weighed,
/// digested and stored off it.
private enum ClipboardRaw: Sendable {
    case files([String])
    case text(String)
    case image(Data)
}

/// One copy, prepared off the main thread.
private enum ClipboardRead: Sendable {
    case item(ClipboardItem)
    case skipped
    case nothing
}

@Observable
@MainActor
final class ClipboardModel: AppModule {
    static let hotKeyID = "clipboard"

    var items: [ClipboardItem] = [] {
        didSet {
            historyStore.value = items
            keys = [:]
        }
    }
    var settings = ClipboardSettings() {
        didSet { settingsStore.value = settings }
    }
    var combo: KeyCombo?
    /// Copies left out since launch (secrets, excluded apps), counted at the foot of the settings.
    var skipped = 0
    var watching = false
    /// The history, its settings and its activation, all in one floating window (shortcut, « cb » in the launcher).
    let window = ClipboardWindow()

    /// The general pasteboard; the live tests swap in a private one so the user's clipboard is never touched.
    @ObservationIgnored var pasteboard = NSPasteboard.general
    /// Compact JSON: the history can weigh a few megabytes of text, rewritten after each copy.
    @ObservationIgnored private let historyStore = JSONStore<[ClipboardItem]>("clipboard-history", default: [], excludeFromBackup: true,
                                                                              compact: true)
    @ObservationIgnored private let settingsStore = JSONStore<ClipboardSettings>("clipboard", default: ClipboardSettings())
    @ObservationIgnored private var keys: [UUID: String] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChange = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    /// A copy being read off the main thread: the next poll waits for it (one copy at a time, in order).
    @ObservationIgnored private var reading = false
    /// Moves on when the history is cleared or the watch stops: a copy being prepared then is dropped.
    @ObservationIgnored private var readGeneration = 0
    /// Screen asleep or session switched away: nobody copies, the poll rests.
    @ObservationIgnored private var resting = false
    @ObservationIgnored private var restObservers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var app: AppModel?

    init() {
        settings = settingsStore.value
        items = historyStore.value
        window.model = self
    }

    var isActive: Bool { settings.enabled && settings.acknowledged }

    // MARK: Module

    func start(app: AppModel) {
        self.app = app
        started = true
        combo = HotKeyCenter.shared.combo(for: Self.hotKeyID, fallback: nil)
        HotKeyCenter.shared.register(Self.hotKeyID, combo: combo) { [weak self] in self?.window.toggle() }
        prune()
        let names = Set(items.compactMap(\.image).flatMap { [$0.file, $0.thumb] })
        _ = ClipboardStorage.removeOrphans(keeping: names)
        if isActive { startWatching() }
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        stopWatching()
        historyStore.flush()
        settingsStore.flush()
    }

    /// `--snapshot --page hotkeys --tab presse-papiers[:…]`, passed by the snapshot code itself (the module has no page):
    /// `:reglages` the settings, `:effacer` with the clearing asked, `:apps` with the ignored apps unfolded, `:activer`
    /// the activation, `:images` (any filter) filtered, `:cherche:lumiere` with a search typed.
    func applySnapshotTab(_ tab: String) {
        guard tab == Self.snapshotTab || tab.hasPrefix(Self.snapshotTab + ":") else { return }
        let rest = String(tab.dropFirst(Self.snapshotTab.count + 1))
        switch rest {
        case "reglages": window.showSettings = true
        case "effacer":
            window.showSettings = true
            window.confirmClear = true
        case "apps":
            window.showSettings = true
            window.showExcluded = true
        case "activer": window.forceActivation = true
        default:
            if let f = ClipboardFilterTab(rawValue: rest) { window.filter = f }
            if rest.hasPrefix("cherche:") { window.query = String(rest.dropFirst(8)) }
        }
    }

    static let snapshotTab = "presse-papiers"

    var quickToggles: [QuickToggle] {
        [QuickToggle(id: "clip_history", title: "Presse-papiers", symbol: "doc.on.clipboard", isOn: isActive) { [weak self] in
            guard let self else { return }
            if self.settings.acknowledged {
                self.setEnabled(!self.settings.enabled)
            } else {
                // The first time, the window explains what is recorded before anything starts.
                self.openWindow()
            }
        }]
    }

    func commands(app: AppModel) -> [AppCommand] { ClipboardLauncher.commands(self) }

    func results(for query: String, app: AppModel) -> [AppCommand] { ClipboardLauncher.results(query, model: self) }

    // MARK: On / off

    func setEnabled(_ on: Bool) {
        settings.enabled = on
        if on { settings.acknowledged = true }
        if on { startWatching() } else { stopWatching() }
        HUD.show(on ? "Historique du presse-papiers activé" : "Historique du presse-papiers en pause",
                 symbol: on ? "doc.on.clipboard.fill" : "pause.circle.fill")
    }

    /// The history has no page: its window holds everything, the activation and the settings included.
    func openWindow(settings: Bool = false) {
        window.show(settings: settings)
    }

    func setCombo(_ c: KeyCombo?) {
        // A shortcut already used elsewhere in Heartware would answer only one of the two.
        if let c, let other = (app ?? AppContext.model)?.hotkeys.owner(of: c, except: .clipboard) {
            HUD.show("\(c.display) est déjà utilisé par \(other).", symbol: "exclamationmark.triangle.fill")
            return
        }
        combo = c
        HotKeyCenter.shared.change(Self.hotKeyID, to: c) { [weak self] in self?.window.toggle() }
    }

    // MARK: Watching

    /// Reads only the change counter, once a second; the content is read only when it changed.
    private func startWatching() {
        guard started, timer == nil, isActive, !DemoData.isEnabled, !Snapshot.isActive else { return }
        // What was already on the clipboard before is not recorded.
        lastChange = pasteboard.changeCount
        watching = true
        watchRest()
        if !resting { startTimer() }
    }

    private func stopWatching() {
        readGeneration += 1
        timer?.invalidate()
        timer = nil
        watching = false
        let center = NSWorkspace.shared.notificationCenter
        for o in restObservers { center.removeObserver(o) }
        restObservers = []
        resting = false
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The poll rests while the screens sleep or another user's session is in front, and looks once on waking up
    /// (a copy made meanwhile, from another device for instance, is recorded then).
    private func watchRest() {
        guard restObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let pairs: [(NSNotification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.sessionDidResignActiveNotification, true),
            (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, false)
        ]
        restObservers = pairs.map { name, rest in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setResting(rest) }
            }
        }
    }

    private func setResting(_ rest: Bool) {
        guard rest != resting else { return }
        resting = rest
        guard watching else { return }
        if rest {
            timer?.invalidate()
            timer = nil
        } else {
            startTimer()
            poll()
        }
    }

    /// The marker of Universal Clipboard: the content is still on the other device, and reading it waits for it.
    static let remoteType = "com.apple.is-remote-clipboard"

    private func poll() {
        guard !reading else { return }
        let pb = pasteboard
        let change = pb.changeCount
        guard change != lastChange else { return }
        lastChange = change
        // Reading the list of types does not read the content (and does not make macOS ask anything).
        let types = (pb.types ?? []).map(\.rawValue)
        guard !types.isEmpty else { return }
        // A copy made on the iPhone or another Mac is not kept: its content is still on the other device, and reading it
        // would hold the whole app until that device answers (seconds when it is locked or out of reach).
        guard !types.contains(Self.remoteType) else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if ClipboardFilter.isSensitive(types) || ClipboardFilter.isExcluded(front?.bundleIdentifier, list: settings.excluded) {
            skipped += 1
            return
        }
        if ClipboardAccess.current == .denied { return }
        let hasFiles = types.contains(NSPasteboard.PasteboardType.fileURL.rawValue)
        // Files left out: the file name the Finder also puts on the clipboard as text is not kept either.
        if hasFiles && !settings.keepFiles { return }
        let raw: ClipboardRaw
        if hasFiles, let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            raw = .files(urls.map(\.path))
        } else if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw = .text(text)
        } else if settings.keepImages,
                  // The compressed kinds first: a TIFF next to a PNG weighs many times more.
                  let type = [.png, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"), .tiff]
                      .first(where: { types.contains($0.rawValue) }),
                  let data = pb.data(forType: type) {
            raw = .image(data)
        } else {
            return
        }
        // The types were read for an earlier change: if another copy landed in between (a password manager writing
        // its concealed item, typically), what was just read is not what they described. Left for the next poll.
        guard pb.changeCount == change else { return }
        let source = ClipboardSource(name: front?.localizedName, id: front?.bundleIdentifier, path: front?.bundleURL?.path)
        let skipSecrets = settings.skipSecrets
        let generation = readGeneration
        // Weighed, digested and stored (an image file and its thumbnail) off the main thread.
        reading = true
        Task {
            let read = await Task.detached(priority: .userInitiated) {
                Self.prepare(raw, skipSecrets: skipSecrets, source: source)
            }.value
            reading = false
            // Cleared or switched off meanwhile: what was being read is not added back.
            guard generation == readGeneration, watching else {
                if case .item(let item) = read, let image = item.image {
                    ClipboardStorage.remove(image.file)
                    ClipboardStorage.remove(image.thumb)
                }
                return
            }
            switch read {
            case .item(let item): add(item)
            case .skipped: skipped += 1
            case .nothing: break
            }
        }
    }

    /// What one copy gives.
    nonisolated private static func prepare(_ raw: ClipboardRaw, skipSecrets: Bool, source: ClipboardSource) -> ClipboardRead {
        let now = Date()
        func item(_ kind: ClipboardKind, text: String? = nil, files: [String]? = nil, image: ClipboardImageInfo? = nil,
                  id: UUID = UUID(), digest: String) -> ClipboardRead {
            .item(ClipboardItem(id: id, kind: kind, text: text, files: files, image: image, digest: digest, date: now, firstDate: now,
                                appName: source.name, appBundleID: source.id, appPath: source.path))
        }
        switch raw {
        case .files(let paths):
            return item(.files, files: paths, digest: ClipboardStorage.digest(Data(paths.joined(separator: "\n").utf8)))
        case .text(let text):
            guard text.utf8.count <= ClipboardHistory.maxTextBytes else { return .skipped }
            // A key, a token or a password copied from a browser or a terminal carries no marker: recognized by its look.
            if skipSecrets && ClipboardFilter.looksSecret(text) { return .skipped }
            return item(.text, text: text, digest: ClipboardStorage.digest(Data(text.utf8)))
        case .image(let data):
            guard data.count <= ClipboardStorage.maxImageBytes, let p = ClipboardStorage.prepare(data) else { return .nothing }
            let info = ClipboardImageInfo(file: p.file, thumb: p.thumb, width: p.width, height: p.height, bytes: p.bytes)
            return item(.image, image: info, id: p.id, digest: p.digest)
        }
    }

    private func add(_ item: ClipboardItem) {
        let r = ClipboardHistory.insert(item, into: items)
        if r.duplicate, let image = item.image {
            ClipboardStorage.remove(image.file)
            ClipboardStorage.remove(image.thumb)
        }
        items = r.list
        prune()
    }

    /// Applies the caps (count, weight, age) and deletes the images of what goes away.
    func prune() {
        let r = ClipboardHistory.prune(items, maxItems: settings.maxItems, maxBytes: settings.maxStorageMB * 1_000_000,
                                       retentionDays: settings.retentionDays)
        guard !r.removed.isEmpty || r.kept.map(\.id) != items.map(\.id) else { return }
        deleteFiles(of: r.removed)
        items = r.kept
    }

    private func deleteFiles(of removed: [ClipboardItem]) {
        for item in removed {
            if let i = item.image {
                ClipboardStorage.remove(i.file)
                ClipboardStorage.remove(i.thumb)
            }
        }
    }

    // MARK: Actions

    /// Puts the item back on the clipboard, then pastes it into the app in front when allowed.
    @discardableResult
    func recopy(_ item: ClipboardItem, paste: Bool = false) -> CommandOutcome {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return .message(DemoData.refusal) }
        let pb = pasteboard
        switch item.kind {
        case .text:
            pb.clearContents()
            pb.setString(item.text ?? "", forType: .string)
        case .files:
            let urls = (item.files ?? []).filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) as NSURL }
            guard !urls.isEmpty else { return .failed("Ce fichier n'existe plus.") }
            pb.clearContents()
            pb.writeObjects(urls)
        case .image:
            guard let info = item.image, let data = ClipboardStorage.read(info.file) else { return .failed("Cette image n'est plus disponible.") }
            pb.clearContents()
            pb.setData(data, forType: .png)
            if let tiff = NSImage(data: data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        }
        // Our own copy is not recorded again: the item just moves to the top.
        lastChange = pb.changeCount
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            var moved = items.remove(at: i)
            moved.date = Date()
            items.insert(moved, at: 0)
        }
        if paste && canPaste {
            // The launcher has just closed: give the app underneath a moment to take the keyboard back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Self.postPaste() }
            return .done
        }
        return .copied(item.kind == .text ? (item.text ?? "") : item.title)
    }

    var canPaste: Bool { settings.pasteDirectly && AppPermission.accessibility.isGranted && !DemoData.isEnabled }

    /// ⌘V for the app in front (needs Accessibility).
    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Rewrites what is on the clipboard as plain text (no fonts, colors or links), then pastes it when allowed.
    func pastePlainText() -> CommandOutcome {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return .message(DemoData.refusal) }
        let pb = pasteboard
        guard let text = pb.string(forType: .string), !text.isEmpty else { return .failed("Le presse-papiers ne contient pas de texte.") }
        let types = (pb.types ?? []).map(\.rawValue)
        // Already plain (a password from a manager, typically): left as it is, so the change count the manager
        // compares before clearing it does not move.
        if !ClipboardFilter.isPlainTextOnly(types) {
            // Secrets and temporary data keep their markers: histories (this one included) still skip them.
            let markers = ClipboardFilter.markers(in: types).map { NSPasteboard.PasteboardType($0) }
            let saved = markers.map { ($0, pb.data(forType: $0) ?? Data()) }
            pb.clearContents()
            pb.declareTypes([.string] + markers, owner: nil)
            pb.setString(text, forType: .string)
            for (type, data) in saved { pb.setData(data, forType: type) }
            lastChange = pb.changeCount
            if markers.contains(where: { $0.rawValue == ClipboardFilter.concealed }) {
                // The app that copied the secret no longer recognizes the clipboard: clear it after 90 s ourselves.
                let count = pb.changeCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                    if pb.changeCount == count { pb.clearContents() }
                }
            }
        }
        if canPaste {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Self.postPaste() }
            return .done
        }
        return .message("Texte brut prêt : colle-le avec ⌘V")
    }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned.toggle()
        if !items[i].pinned { prune() }
    }

    func delete(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        deleteFiles(of: [items[i]])
        items.remove(at: i)
    }

    /// Clears the history; pinned items stay unless `includingPinned`.
    func clear(includingPinned: Bool = false) {
        readGeneration += 1
        let removed = items.filter { includingPinned || !$0.pinned }
        deleteFiles(of: removed)
        items.removeAll { includingPinned || !$0.pinned }
    }

    func exclude(bundleID: String, name: String) {
        guard !ClipboardFilter.isExcluded(bundleID, list: settings.excluded) else { return }
        settings.excluded.append(ClipboardExcludedApp(bundleID: bundleID, name: name))
    }

    func removeExclusion(_ bundleID: String) {
        settings.excluded.removeAll { $0.bundleID == bundleID }
    }

    /// Picks an app in /Applications and adds it to the excluded list. Shown above the history's floating window.
    func chooseExcludedApp() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Ignorer"
        panel.message = "Ce que tu copies dans ces apps ne sera jamais enregistré."
        panel.level = .modalPanel
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            exclude(bundleID: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
    }

    /// Apps to ignore in one click: those open now and those already in the history (only the latter in the demo),
    /// minus the ignored ones and Heartware itself.
    var excludeCandidates: [ClipboardExcludedApp] {
        var seen = Set<String>()
        var out: [ClipboardExcludedApp] = []
        func add(_ id: String?, _ name: String?) {
            guard let id, let name, !name.isEmpty, id != Bundle.main.bundleIdentifier,
                  !ClipboardFilter.isExcluded(id, list: settings.excluded), seen.insert(id.lowercased()).inserted else { return }
            out.append(ClipboardExcludedApp(bundleID: id, name: name))
        }
        if !DemoData.isEnabled {
            for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular { add(a.bundleIdentifier, a.localizedName) }
        }
        for i in items { add(i.appBundleID, i.appName) }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Search

    func key(_ item: ClipboardItem) -> String {
        if let k = keys[item.id] { return k }
        let k = item.searchKey
        keys[item.id] = k
        return k
    }

    func count(_ tab: ClipboardFilterTab) -> Int { items.filter { tab.accepts($0) }.count }

    var totalBytes: Int { items.reduce(0) { $0 + $1.bytes } }

    // MARK: Demo

    func loadDemo() {
        settings = ClipboardSettings()
        settings.enabled = true
        settings.acknowledged = true
        combo = KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func app(_ name: String, _ id: String) -> (String, String, String) { (name, id, "/Applications/\(name).app") }
        let helios = app("Hélios Code", "com.helios.code"), ruche = app("Ruche", "com.ruche.desktop")
        let claude = app("Claude", "com.anthropic.claudefordesktop"), pixel = app("Pixelune", "com.pixelune.Pixelune")
        let tisserand = app("Tisserand", "app.tisserand.mac")
        func text(_ s: String, _ minutes: Double, _ a: (String, String, String), pinned: Bool = false, count: Int = 1) -> ClipboardItem {
            ClipboardItem(kind: .text, text: s, digest: ClipboardStorage.digest(Data(s.utf8)), date: ago(minutes), firstDate: ago(minutes + 600),
                          count: count, pinned: pinned, appName: a.0, appBundleID: a.1, appPath: a.2)
        }
        func image(_ kind: Int, _ w: Int, _ h: Int, _ minutes: Double, _ a: (String, String, String)) -> ClipboardItem {
            let id = UUID()
            let info = ClipboardImageInfo(file: "demo-\(kind).png", thumb: "demo-\(kind)-thumb.png", width: w, height: h, bytes: w * h / 3)
            if let cg = ClipboardThumbs.demoImage(kind: kind) { ClipboardThumbs.put(info.thumb, cg) }
            return ClipboardItem(id: id, kind: .image, image: info, digest: "demo-image-\(kind)", date: ago(minutes), firstDate: ago(minutes),
                                 appName: a.0, appBundleID: a.1, appPath: a.2)
        }
        items = [
            text("git commit -m \"Boussole : nouvelle page d'accueil\"", 2, helios),
            text("https://atelier-camille.fr/projets/boussole/maquettes", 6, ruche),
            image(0, 2880, 1800, 11, pixel),
            text("#D97757", 19, pixel),
            text("Rendez-vous jeudi 14 h avec l'équipe Lumière, salle Ventoux (3e étage). Penser aux maquettes imprimées.", 34, tisserand, count: 3),
            text("func greet(_ name: String) -> String {\n    \"Bonjour, \\(name) !\"\n}", 52, helios),
            ClipboardItem(kind: .files, files: [DemoData.home + "/Documents/Devis-Atelier.pdf"], digest: "demo-files", date: ago(75), firstDate: ago(75),
                          appName: "Finder", appBundleID: "com.apple.finder", appPath: "/System/Library/CoreServices/Finder.app"),
            text("Peux-tu résumer ce compte rendu en cinq points, avec les décisions et les prochaines étapes ?", 130, claude),
            image(1, 1600, 1000, 190, ruche),
            text("12 rue des Lilas, 69007 Lyon", 60 * 24 * 2, tisserand, pinned: true, count: 14),
            text("camille@atelier-camille.fr", 60 * 24 * 6, ruche, pinned: true, count: 9),
            text("Bien à toi,\nCamille — Atelier Camille, design et illustration", 60 * 24 * 9, tisserand, pinned: true, count: 21)
        ]
        skipped = 4
        // The window shows a text of several lines, the kind that needs the whole preview.
        window.selection = items.first { $0.text?.hasPrefix("Bien à toi") == true }?.id
    }

    // MARK: Checks

    func selfTest() -> [String] { ClipboardChecks.run(self) }

    func dump() -> [String] {
        let byKind = ClipboardKind.allCases.map { k in "\(k.rawValue) \(items.filter { $0.kind == k }.count)" }.joined(separator: ", ")
        return [
            "Historique : \(isActive ? "actif" : (settings.acknowledged ? "en pause" : "jamais activé")) · surveillance \(watching ? "en cours" : "arrêtée")",
            "Éléments : \(items.count) (\(byKind)) · \(items.filter(\.pinned).count) épinglés · \(Fmt.bytes(totalBytes))",
            "Dossier des images : \(FS.pretty(ClipboardStorage.folder.path)) · \(Fmt.bytes(ClipboardStorage.folderSize()))",
            "Plafonds : \(settings.maxItems) éléments, \(settings.maxStorageMB) Mo, \(settings.retentionDays == 0 ? "sans limite d'âge" : "\(settings.retentionDays) jours")",
            "Accès macOS au presse-papiers : \(ClipboardAccess.current.label) · Accessibilité : \(AppPermission.accessibility.isGranted ? "accordée" : "non accordée")",
            "Apps ignorées : \(settings.excluded.map(\.name).joined(separator: ", "))",
            "Raccourci : \(combo?.display ?? "aucun")",
            "Types ignorés : \(ClipboardFilter.sensitiveTypes.sorted().joined(separator: ", "))"
        ]
    }
}
