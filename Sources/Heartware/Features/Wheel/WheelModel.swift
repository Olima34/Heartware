import SwiftUI
import AppKit

/// Le Convertisseur, as a wheel: as soon as a file is dragged (or after a gesture: held still, shaken, ⇧), a wheel of actions
/// opens under the pointer, made for that kind of file; moving far from it means the file is only being moved, and it goes.
/// Drop the file on an action: a copy is made at once, or a small window opens first (crop, background, marks…). Dropped
/// in the middle, the Convertisseur's window (`ConverterModel`) shows every operation with its settings and a preview.
/// The original never changes, and the big window never opens.
@Observable
@MainActor
final class WheelModel: AppModule {
    static let hotKeyID = "wheel"

    var settings = WheelSettings() {
        didSet {
            settingsStore.value = settings
            watcher.settings = settings
            if settings.enabled != oldValue.enabled { updateWatcher() }
        }
    }
    var capabilities = WheelCapabilities()
    var combo: KeyCombo?
    /// The family shown in the settings' wheel.
    var family: WheelFamily = .image
    let runner = WheelRunner()
    @ObservationIgnored let overlay = WheelOverlay()
    @ObservationIgnored let editors = WheelEditors()
    @ObservationIgnored private let watcher = WheelWatcher()
    @ObservationIgnored private let settingsStore = JSONStore<WheelSettings>("wheel", default: WheelSettings())
    @ObservationIgnored private var started = false
    @ObservationIgnored private var ffmpegPath: String?
    @ObservationIgnored private weak var app: AppModel?

    init() {
        settings = settingsStore.value
        watcher.settings = settings
        watcher.onOpen = { [weak self] point, urls, _ in self?.openWheel(urls, at: point, clicking: false) }
        watcher.onRelease = { [weak self] in self?.overlay.released() }
        watcher.onMove = { [weak self] point in self?.overlay.track(point) }
        overlay.onLeft = { [weak self] in self?.watcher.rearm() }
        overlay.onChoose = { [weak self] action, files, point in self?.choose(action, files: files, at: point) }
        runner.onDone = { [weak self] task in self?.record(task) }
        runner.onRenamed = { [weak self] pairs in self?.appModel?.converter.follow(pairs) }
    }

    private var appModel: AppModel? { app ?? AppContext.model }

    var isActive: Bool { settings.enabled && settings.canOpen }

    /// Used in the last 30 days: the tool stays in the sidebar.
    var recentlyUsed: Bool {
        guard let last = settings.lastUsed else { return false }
        return Date().timeIntervalSince(last) < 30 * 86400
    }

    // MARK: Module

    var sidebarBadge: String? {
        let n = runner.running
        return n > 0 ? "\(n)" : (settings.enabled ? nil : "Pause")
    }

    func start(app: AppModel) {
        self.app = app
        started = true
        // The list of the last copies is gone from the page: its file too.
        let oldHistory = DataStore.url("wheel-history.json").path
        if FS.exists(oldHistory) { _ = Remover.removeInternal(oldHistory) }
        combo = HotKeyCenter.shared.combo(for: Self.hotKeyID, fallback: nil)
        HotKeyCenter.shared.register(Self.hotKeyID, combo: combo) { [weak self] in self?.openOnFinderSelection() }
        updateWatcher()
        // Whether ffmpeg is there (WebP, MP3), without starting it.
        let path = Shell.which("ffmpeg")
        ffmpegPath = path
        capabilities.ffmpeg = path != nil
    }

    func stop() {
        watcher.stop()
        overlay.close()
        editors.closeAll()
        settingsStore.flush()
    }

    private func updateWatcher() {
        guard started else { return }
        if settings.enabled { watcher.start() } else { watcher.stop() }
    }

    var quickToggles: [QuickToggle] {
        [QuickToggle(id: "wheel_gesture", title: "Roue du Convertisseur", symbol: "dial.medium", isOn: settings.enabled) { [weak self] in
            self?.setEnabled(!(self?.settings.enabled ?? true))
        }]
    }

    func setEnabled(_ on: Bool) {
        settings.enabled = on
        HUD.show(on ? "Roue du Convertisseur activée" : "Roue du Convertisseur en pause", symbol: on ? "dial.medium" : "pause.circle.fill")
    }

    func setCombo(_ c: KeyCombo?) {
        if let c, let other = (app ?? AppContext.model)?.hotkeys.owner(of: c, except: .wheel) {
            HUD.show("\(c.display) est déjà utilisé par \(other).", symbol: "exclamationmark.triangle.fill")
            return
        }
        combo = c
        HotKeyCenter.shared.change(Self.hotKeyID, to: c) { [weak self] in self?.openOnFinderSelection() }
    }

    // MARK: The wheel

    /// The rings for these files, as the user arranged them.
    func menu(for files: [WheelFile]) -> WheelMenu {
        let family = WheelFamily.of(files.map(\.kind))
        return WheelMenu.make(files, chosen: settings.layouts[family.rawValue], capabilities: capabilities)
    }

    /// Opens the wheel at `point` (screen, y up). `clicking`: opened by a click or a shortcut, not during a drag.
    func openWheel(_ urls: [URL], at point: NSPoint, clicking: Bool) {
        let files = urls.prefix(500).map { WheelFile(url: $0.standardizedFileURL) }
        guard !files.isEmpty else { return }
        if app?.launcher.isOpen == true { app?.launcher.hide() }
        let menu = menu(for: Array(files))
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        overlay.leaveDistance = CGFloat(settings.leaveDistance) * WheelGeometry.pointsPerCentimetre(screen)
        overlay.open(Array(files), menu: menu, at: point, clicking: clicking, hint: settings.opened < 5)
        if settings.opened < 5 { settings.opened += 1 }
    }

    /// The files selected in the Finder, on the wheel under the pointer (the shortcut, the launcher).
    func openOnFinderSelection() {
        guard !DemoData.isEnabled else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        let point = NSEvent.mouseLocation
        Task {
            let r = await Task.detached(priority: .userInitiated) { Shell.appleScript(Self.finderSelectionScript) }.value
            guard r.ok else {
                HUD.show(r.status == -1743 ? "Autorise \(AppEdition.name) à piloter le Finder : Réglages Système › Confidentialité › Automatisation"
                                           : "Le Finder n'a pas répondu.", symbol: "xmark.octagon.fill")
                return
            }
            let urls = r.out.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            guard !urls.isEmpty else {
                HUD.show("Sélectionne d'abord un fichier dans le Finder.", symbol: "info.circle.fill")
                return
            }
            openWheel(urls, at: point, clicking: true)
        }
    }

    nonisolated static let finderSelectionScript = """
    tell application "Finder"
        set out to ""
        repeat with anItem in (get selection)
            set out to out & POSIX path of (anItem as alias) & linefeed
        end repeat
        return out
    end tell
    """

    /// A segment was chosen (nil: the hub, the Convertisseur's window with every operation).
    func choose(_ action: WheelAction?, files: [WheelFile], at point: NSPoint) {
        guard let action else {
            appModel?.converter.open(files, action: nil, near: point)
            return
        }
        run(action, files: files, at: point)
    }

    func run(_ action: WheelAction, files: [WheelFile], at point: NSPoint, under window: NSRect? = nil) {
        guard !files.isEmpty else { return }
        if action.opensHub {
            appModel?.converter.open(files, action: action, near: point)
            return
        }
        if let kind = action.editor {
            editors.open(kind, action: action, files: files, at: point, model: self)
            return
        }
        switch action {
        case .sign:
            appModel?.fillSign.openWindow(files[0].url)
        case .airdrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files.map(\.url)) else {
                HUD.show("AirDrop n'est pas disponible sur ce Mac.", symbol: "xmark.octagon.fill")
                return
            }
            // Its window comes in front only for the app in front.
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: files.map(\.url))
        case .copyPath:
            let text = files.map(\.url.path).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            HUD.show("Chemin copié", symbol: "link")
        default:
            guard !DemoData.isEnabled else {
                HUD.show(DemoData.refusal, symbol: "info.circle.fill")
                return
            }
            let destination = settings.destination, custom = settings.folder
            let ffmpeg = ffmpegPath ?? Shell.which("ffmpeg")
            runner.run(action, files: files, at: point, under: window) { control, onStep in
                let place = WheelJobs.folder(for: files[0].url, destination: destination, custom: custom)
                var result = try await WheelJobs.perform(action, files: files, context: .init(folder: place.folder, ffmpeg: ffmpeg),
                                                         control: control, onStep: onStep)
                if let note = place.note { result.note = [result.note, note].compactMap { $0 }.joined(separator: " ") }
                return result
            }
        }
    }

    /// An operation of the Convertisseur's window, with its settings, in the toast under that window.
    func run(_ action: WheelAction, operation: ConverterOperation, files: [WheelFile], options: ConverterOptions, names: [String],
             ffmpeg: String?, under window: NSRect?) {
        guard !files.isEmpty else { return }
        guard !DemoData.isEnabled else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        let destination = settings.destination, custom = settings.folder
        runner.run(action, files: files, at: nil, under: window) { control, onStep in
            // A renaming happens in place.
            let place = operation == .rename ? (folder: nil, note: nil)
                : WheelJobs.folder(for: files[0].url, destination: destination, custom: custom)
            var result = try await WheelJobs.converter(operation, files, options: options, names: names,
                                                       context: .init(folder: place.folder, ffmpeg: ffmpeg), control: control, onStep: onStep)
            if let note = place.note { result.note = [result.note, note].compactMap { $0 }.joined(separator: " ") }
            return result
        }
    }

    private func record(_ task: WheelTask) {
        guard !task.result.outputs.isEmpty || task.result.copied != nil else { return }
        settings.lastUsed = Date()
        appModel?.refuge.usedTool("wheel_" + task.action.rawValue)
    }

    // MARK: Where the copies go

    /// The copies of `input`: next to it, in Téléchargements or in the folder chosen.
    func place(for input: URL) -> (folder: URL?, note: String?) {
        WheelJobs.folder(for: input, destination: settings.destination, custom: settings.folder)
    }

    /// The folder every copy goes to (nil: next to each original).
    var copiesFolder: URL? {
        switch settings.destination {
        case .beside: return nil
        case .downloads: return ConverterDestination.downloadsURL
        case .folder: return settings.folder.map { URL(fileURLWithPath: $0) }
        }
    }

    var destinationTitle: String {
        switch settings.destination {
        case .beside: return "À côté de l'original"
        case .downloads: return "Dans Téléchargements"
        case .folder: return "Dans « \(((settings.folder ?? "") as NSString).lastPathComponent) »"
        }
    }

    var destinationSymbol: String {
        switch settings.destination {
        case .beside: return "arrow.down.doc"
        case .downloads: return "arrow.down.circle"
        case .folder: return "folder"
        }
    }

    func setDestination(_ d: WheelDestination) {
        if d == .folder { return chooseFolder() }
        settings.destination = d
    }

    /// A folder of the user's for every copy.
    func chooseFolder() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choisir"
        panel.message = "Où ranger les copies ?"
        panel.directoryURL = settings.folder.map { URL(fileURLWithPath: $0) } ?? ConverterDestination.downloadsURL
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.folder = url.path
        settings.destination = .folder
    }

    // MARK: Settings

    func actions(for family: WheelFamily) -> [WheelAction] {
        settings.actions(family)
    }

    /// Shows or hides an action on a family's wheel (at the end of its ring when it comes back).
    func toggle(_ action: WheelAction, in family: WheelFamily) {
        var list = settings.actions(family)
        if let i = list.firstIndex(of: action) { list.remove(at: i) } else { list.append(action) }
        settings.layouts[family.rawValue] = list
    }

    /// Moves an action one place earlier (-1) or later (+1) among those of its ring.
    func move(_ action: WheelAction, in family: WheelFamily, by delta: Int) {
        var list = settings.actions(family)
        let ring = list.filter { $0.isFormat == action.isFormat }
        guard let i = ring.firstIndex(of: action), ring.indices.contains(i + delta) else { return }
        let other = ring[i + delta]
        guard let a = list.firstIndex(of: action), let b = list.firstIndex(of: other) else { return }
        list.swapAt(a, b)
        settings.layouts[family.rawValue] = list
    }

    func resetLayout(_ family: WheelFamily) {
        settings.layouts[family.rawValue] = nil
    }

    /// A sample file of the family, for the settings' wheel.
    nonisolated static func sample(_ family: WheelFamily) -> WheelFile {
        let names: [WheelFamily: (String, ConverterKind)] = [
            .image: ("photo.heic", .image), .pdf: ("contrat.pdf", .pdf), .video: ("vacances.mov", .video), .audio: ("mémo.m4a", .audio),
            .document: ("rapport.docx", .document), .archive: ("photos.zip", .archive), .folder: ("Projets", .folder), .other: ("notes.key", .other)
        ]
        let (name, kind) = names[family] ?? ("fichier", .other)
        return WheelFile(url: URL(fileURLWithPath: "/tmp/" + name), kind: kind)
    }

    // MARK: Launcher

    func commands(app: AppModel) -> [AppCommand] {
        [
            AppCommand(id: "wheel_finder", title: "Roue du Convertisseur sur la sélection du Finder",
                       subtitle: "Les actions du fichier sélectionné, sous le pointeur", keywords: ["roue", "fichier", "finder", "convertir", "recadrer", "annoter"],
                       icon: .symbol("dial.medium", Theme.brand), group: .tools, hint: "Ouvrir") { ctx in
                ctx.app.launcher.hide()
                ctx.app.wheel.openOnFinderSelection()
                return .done
            },
            AppCommand(id: "wheel_toggle", title: settings.enabled ? "Mettre en pause la roue du Convertisseur" : "Activer la roue du Convertisseur",
                       subtitle: "La roue d'actions qui s'ouvre quand tu glisses un fichier", keywords: ["roue", "geste", "glisser"],
                       icon: .symbol(settings.enabled ? "pause.circle" : "dial.medium", Theme.brand), group: .tools, assistantSafe: true,
                       hint: settings.enabled ? "Pause" : "Activer") { ctx in
                ctx.app.wheel.setEnabled(!ctx.app.wheel.settings.enabled)
                return .done
            },
        ]
    }

    // MARK: Demo and snapshots

    func loadDemo() {
        capabilities = WheelCapabilities(ffmpeg: true, webp: true)
    }

    /// `--tab <famille>` shows that family's wheel in the settings (`image`, `pdf`, `video`…).
    func applySnapshotTab(_ tab: String) {
        if let f = WheelFamily(rawValue: tab) { family = f }
        if tab == "pause" { settings.enabled = false }
    }

    func dump() -> [String] {
        var lines = ["Roue : \(settings.enabled ? "active" : "en pause") · \(settings.instant ? "dès le glisser" : "avec un geste"), disparaît à \(Fmt.dec(settings.leaveDistance)) cm · gestes : " +
                     [settings.hold ? "maintenir (\(Fmt.dec(settings.holdDelay)) s)" : nil, settings.shake ? "secouer" : nil, settings.shift ? "⇧" : nil]
                        .compactMap { $0 }.joined(separator: ", ")]
        lines.append("Copies : \(destinationTitle) · ffmpeg : \(Shell.which("ffmpeg") ?? "absent")")
        lines.append("Surveillance des glisser : \(watcher.isRunning ? "en marche" : "arrêtée")")
        for family in WheelFamily.allCases {
            let m = WheelMenu.make([Self.sample(family)], chosen: settings.layouts[family.rawValue], capabilities: WheelCapabilities(ffmpeg: Shell.which("ffmpeg") != nil))
            lines.append("\(family.title) : formats \(m.formats.map(\.label).joined(separator: " ")) · outils \(m.tools.map(\.label).joined(separator: " "))")
        }
        lines.append("Dernière copie : \(settings.lastUsed.map { Fmt.relative($0) } ?? "aucune")")
        return lines
    }
}
