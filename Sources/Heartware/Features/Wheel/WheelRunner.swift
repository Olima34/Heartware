import SwiftUI
import AppKit

/// One action under way or done, shown in the toast.
@Observable
@MainActor
final class WheelTask: Identifiable {
    enum State: Equatable {
        case running, done, failed(String), cancelled, undone
    }

    let id = UUID()
    let action: WheelAction
    /// The file (or "3 images") the action works on.
    let title: String
    let count: Int
    /// The file being done, for several.
    var step = 0
    var state: State = .running
    /// nil while the tool gives no progress.
    var progress: Double?
    var result = WheelResult()
    var outputSize: Int64 = 0
    var inputSize: Int64 = 0
    let started = Date()
    var finished: Date?
    @ObservationIgnored private(set) var control: ConverterControl!

    init(action: WheelAction, title: String, count: Int) {
        self.action = action
        self.title = title
        self.count = count
        control = ConverterControl { [weak self] value in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.state == .running else { return }
                    self.progress = value
                }
            }
        }
    }

    var isRunning: Bool { state == .running }
}

/// Runs the actions (at once, or once a window says so), one after the other, and shows them in a toast under the wheel:
/// progress and Arrêter while it works, then Afficher, Copier and Annuler (to the Trash) once the copy is there.
@Observable
@MainActor
final class WheelRunner {
    /// Newest first.
    private(set) var tasks: [WheelTask] = []
    @ObservationIgnored let toast = WheelToast()
    /// A task ended well (the tool was used).
    @ObservationIgnored var onDone: ((WheelTask) -> Void)?
    /// Files were renamed (or got their old names back): the Convertisseur's window follows them.
    @ObservationIgnored var onRenamed: (([ConverterRenamePair]) -> Void)?
    @ObservationIgnored private var queue: [(WheelTask, @Sendable (ConverterControl, @escaping @Sendable (Int) -> Void) async throws -> WheelResult)] = []
    @ObservationIgnored private var busy = false

    init() {
        toast.runner = self
    }

    var isBusy: Bool { tasks.contains { $0.isRunning } }
    var running: Int { tasks.filter(\.isRunning).count }

    /// Queues `work` (it runs off the main thread) and shows it in the toast near `point`, or under `window` (a window
    /// that stays open, the Convertisseur's).
    func run(_ action: WheelAction, files: [WheelFile], at point: NSPoint?, under window: NSRect? = nil,
             work: @escaping @Sendable (ConverterControl, @escaping @Sendable (Int) -> Void) async throws -> WheelResult) {
        let title = files.count == 1 ? files[0].name : Self.summary(files)
        let task = WheelTask(action: action, title: title, count: files.count)
        tasks.insert(task, at: 0)
        if tasks.count > 6 { tasks.removeLast(tasks.count - 6) }
        queue.append((task, work))
        if let window { toast.show(under: window) } else { toast.show(near: point) }
        pump()
    }

    static func summary(_ files: [WheelFile]) -> String {
        let family = WheelFamily.of(files.map(\.kind))
        return family == .other ? Fmt.plural(files.count, "élément", "éléments") : "\(Fmt.int(files.count)) \(family.title.lowercased())"
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        let (task, work) = queue.removeFirst()
        guard task.state == .running else { return pump() }
        busy = true
        let control = task.control!
        Task { [weak self] in
            let outcome: Result<(WheelResult, Int64), Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let result = try await work(control) { i in
                        DispatchQueue.main.async { MainActor.assumeIsolated { task.step = i } }
                    }
                    let size = result.outputs.reduce(Int64(0)) { $0 + ConverterOutputs.size($1) }
                    return .success((result, size))
                } catch {
                    return .failure(error)
                }
            }.value
            self?.finish(task, outcome)
        }
    }

    private func finish(_ task: WheelTask, _ outcome: Result<(WheelResult, Int64), Error>) {
        busy = false
        task.finished = Date()
        switch outcome {
        case .success(let (result, size)):
            task.result = result
            task.outputSize = size
            task.progress = 1
            task.state = .done
            if let text = result.copied {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            if !result.renamed.isEmpty { onRenamed?(result.renamed) }
            onDone?(task)
        case .failure(let error):
            if case ConverterError.cancelled = error { task.state = .cancelled } else { task.state = .failed(error.localizedDescription) }
        }
        notifyIfLong(task)
        toast.taskEnded()
        pump()
    }

    /// A long job that ends while Heartware is in the background: a notification says so.
    private func notifyIfLong(_ task: WheelTask) {
        guard let end = task.finished, end.timeIntervalSince(task.started) > 15, !NSApp.isActive else { return }
        switch task.state {
        case .done: Notifier.post(id: "wheel.done", title: "\(task.action.title) : terminé", body: task.title, throttle: 0)
        case .failed(let why): Notifier.post(id: "wheel.done", title: "\(task.action.title) : échec", body: why, throttle: 0)
        default: break
        }
    }

    // MARK: Toast buttons

    func cancel(_ task: WheelTask) {
        task.control.cancel()
        if !queue.contains(where: { $0.0.id == task.id }) { return }
        queue.removeAll { $0.0.id == task.id }
        task.state = .cancelled
        task.finished = Date()
        toast.taskEnded()
    }

    func reveal(_ task: WheelTask) {
        guard !task.result.outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(task.result.outputs)
    }

    func open(_ task: WheelTask) {
        guard let url = task.result.outputs.first else { return }
        NSWorkspace.shared.open(url)
    }

    /// The copies on the clipboard, ready to paste in a message or another folder.
    func copy(_ task: WheelTask) {
        guard !task.result.outputs.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(task.result.outputs as [NSURL])
        HUD.show(task.result.outputs.count == 1 ? "Copié : prêt à coller" : "\(Fmt.int(task.result.outputs.count)) fichiers copiés",
                 symbol: "doc.on.doc.fill")
    }

    /// The copies go to the Trash (the original was never touched); renamed files get their old names back.
    func undo(_ task: WheelTask) {
        let outputs = task.result.outputs
        guard !outputs.isEmpty, task.state == .done else { return }
        task.state = .undone
        if !task.result.renamed.isEmpty {
            let back = task.result.renamed.map { (url: $0.to, newName: $0.from.lastPathComponent) }
            Task.detached(priority: .userInitiated) {
                let r = Result { try ConverterRename.apply(back, control: ConverterControl { _ in }) }
                await MainActor.run {
                    switch r {
                    case .success(let pairs): self.onRenamed?(pairs)
                    case .failure(let error):
                        task.state = .done
                        HUD.show("Les anciens noms ne sont pas revenus : \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
                    }
                }
            }
            return
        }
        Task.detached(priority: .userInitiated) {
            let failed = outputs.filter { !Remover.trashOwnOutput($0) }.count
            await MainActor.run {
                if failed > 0 {
                    task.state = .done
                    HUD.show("Je n'ai pas pu mettre la copie à la Corbeille.", symbol: "exclamationmark.triangle.fill")
                }
            }
        }
    }

    /// The toast of the snapshots: a video being lightened, a crop done, a text copied.
    func loadDemo() {
        guard tasks.isEmpty else { return }
        let video = WheelTask(action: .videoCompress, title: "Vacances.mov", count: 1)
        video.progress = 0.46
        let crop = WheelTask(action: .crop, title: "Sommet.jpg", count: 1)
        crop.state = .done
        crop.result = WheelResult(outputs: [URL(fileURLWithPath: WheelDemo.desktop + "/Sommet recadrée.jpg")])
        crop.outputSize = 1_240_000
        let text = WheelTask(action: .copyText, title: "Facture.png", count: 1)
        text.state = .done
        text.result = WheelResult(copied: String(repeating: "mot ", count: 86))
        tasks = [video, crop, text]
    }

    func dismiss(_ task: WheelTask) {
        guard !task.isRunning else { return }
        tasks.removeAll { $0.id == task.id }
        if tasks.isEmpty { toast.hide() }
    }
}

// MARK: - Toast

/// The little glass card under the wheel: what is being made, then what was made.
@MainActor
final class WheelToast {
    static let width: CGFloat = 360
    weak var runner: WheelRunner?
    private var panel: WheelToastPanel?
    private var hideWork: DispatchWorkItem?
    /// While the pointer is on it, it stays.
    var hovering = false {
        didSet { if hovering { hideWork?.cancel() } else { scheduleHide() } }
    }

    private func makePanel() -> WheelToastPanel? {
        guard let runner, !Snapshot.isActive else { return nil }
        hideWork?.cancel()
        if let panel { return panel }
        let p = WheelToastPanel()
        p.setContent(WheelToastView(runner: runner, toast: self))
        panel = p
        return p
    }

    /// Under a window that stays open (above it when there is no room below), whole on its screen.
    func show(under rect: NSRect) {
        guard let p = makePanel() else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSPoint(x: rect.midX, y: rect.midY), $0.frame, false) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        let height = p.frame.height
        var origin = NSPoint(x: rect.midX - Self.width / 2, y: rect.minY - 10 - height)
        if origin.y < f.minY + 12 { origin.y = rect.maxY + 10 }
        origin.x = min(max(origin.x, f.minX + 12), f.maxX - Self.width - 12)
        origin.y = min(max(origin.y, f.minY + 12), f.maxY - height - 12)
        p.setFrameOrigin(origin)
        p.alphaValue = 1
        p.orderFrontRegardless()
    }

    func show(near point: NSPoint?) {
        guard let p = makePanel() else { return }
        let screen = point.flatMap { pt in NSScreen.screens.first { NSMouseInRect(pt, $0.frame, false) } } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        let height = p.frame.height
        // Under where the wheel was, or at the bottom of the screen when opened from elsewhere.
        var origin = point.map { NSPoint(x: $0.x - Self.width / 2, y: $0.y - WheelGeometry.radius - 18 - height) }
            ?? NSPoint(x: f.midX - Self.width / 2, y: f.minY + 40)
        if origin.y < f.minY + 12, let point { origin.y = point.y + WheelGeometry.radius + 18 }
        origin.x = min(max(origin.x, f.minX + 12), f.maxX - Self.width - 12)
        origin.y = min(max(origin.y, f.minY + 12), f.maxY - height - 12)
        p.setFrameOrigin(origin)
        p.alphaValue = 1
        p.orderFrontRegardless()
    }

    func taskEnded() {
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        guard let runner, !runner.isBusy, !hovering, panel?.isVisible == true else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if p.alphaValue == 0 { p.orderOut(nil) }
            }
        })
    }

    /// The panel follows the list's height, from its bottom edge.
    func fit(height: CGFloat) {
        guard let p = panel, abs(p.frame.height - height) > 0.5 else { return }
        var f = p.frame
        f.origin.y += f.height - height
        f.size.height = height
        p.setFrame(f, display: true)
    }
}

final class WheelToastPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: WheelToast.width, height: 74),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setContent<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        contentView = host
    }
}

struct WheelToastView: View {
    let runner: WheelRunner
    let toast: WheelToast

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(runner.tasks.prefix(3).enumerated()), id: \.element.id) { i, task in
                if i > 0 { Divider().overlay(Theme.border.opacity(0.6)).padding(.horizontal, 12) }
                WheelTaskRow(task: task, runner: runner)
            }
        }
        .padding(.vertical, 4)
        .frame(width: WheelToast.width)
        .background(WheelGlass(corner: Theme.r(16), veil: 0.75))
        .clipShape(RoundedRectangle(cornerRadius: Theme.r(16), style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { toast.fit(height: g.size.height) }
                .onChange(of: g.size.height) { _, h in toast.fit(height: h) }
        })
        .frame(maxHeight: .infinity, alignment: .top)
        .onHover { toast.hovering = $0 }
    }
}

/// One line of the toast.
struct WheelTaskRow: View {
    let task: WheelTask
    let runner: WheelRunner
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            icon.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.ui(11)).foregroundStyle(detailColor).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if task.isRunning {
                    WheelProgressBar(value: task.progress).padding(.top, 3)
                }
            }
            Spacer(minLength: 4)
            buttons.fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { runner.open(task) }
    }

    @ViewBuilder
    private var icon: some View {
        if task.state == .done, let url = task.result.outputs.first {
            FileIcon(path: url.path, size: 32)
        } else {
            let failed: Bool = { if case .failed = task.state { return true } else { return false } }()
            Image(systemName: failed ? "exclamationmark.triangle.fill" : (task.result.copied != nil ? "doc.on.clipboard" : task.action.symbol))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(failed ? Theme.warn : Theme.accent)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill((failed ? Theme.warn : Theme.accent).opacity(0.14)))
        }
    }

    private var headline: String {
        switch task.state {
        case .done:
            if !task.result.codes.isEmpty { return task.result.codes.count == 1 ? "Code lu et copié" : "\(Fmt.int(task.result.codes.count)) codes lus et copiés" }
            if !task.result.renamed.isEmpty { return Fmt.plural(task.result.renamed.count, "fichier renommé", "fichiers renommés") }
            if task.result.copied != nil { return "Texte copié" }
            if let first = task.result.outputs.first {
                return task.result.outputs.count == 1 ? first.lastPathComponent : "\(Fmt.int(task.result.outputs.count)) fichiers créés"
            }
            return task.title
        default:
            return task.title
        }
    }

    private var detail: String {
        switch task.state {
        case .running:
            let step = task.count > 1 ? "\(Fmt.int(task.step + 1)) sur \(Fmt.int(task.count)) · " : ""
            let pct = task.progress.map { $0 > 0 ? " · \(Fmt.pct($0))" : "" } ?? ""
            return "\(step)\(task.action.title(count: task.count, family: .other))…\(pct)"
        case .done:
            if let code = task.result.codes.first { return code }
            if !task.result.renamed.isEmpty { return "Sur place · Annuler remet les anciens noms" }
            if let text = task.result.copied {
                let words = text.split { $0 == " " || $0 == "\n" }.count
                return "\(Fmt.plural(words, "mot", "mots")) dans le presse-papiers, prêts à coller"
            }
            var parts: [String] = []
            if task.outputSize > 0 { parts.append(Fmt.bytes(task.outputSize)) }
            if let note = task.result.note { parts.append(note) } else if !task.result.outputs.isEmpty { parts.append("original intact") }
            return parts.joined(separator: " · ")
        case .failed(let why):
            return why
        case .cancelled:
            return "Arrêté : rien n'a été gardé."
        case .undone:
            return task.result.renamed.isEmpty ? "Mis à la Corbeille." : "Les anciens noms sont revenus."
        }
    }

    private var detailColor: Color {
        if case .failed = task.state { return Theme.warn }
        return Theme.text3
    }

    @ViewBuilder
    private var buttons: some View {
        switch task.state {
        case .running:
            WheelSmallButton(title: "Arrêter", symbol: "stop.fill") { runner.cancel(task) }
        case .done where task.result.codes.first.flatMap(WheelTaskRow.link) != nil:
            WheelSmallButton(title: "Ouvrir le lien", symbol: "safari") {
                if let url = task.result.codes.first.flatMap(WheelTaskRow.link) { NSWorkspace.shared.open(url) }
            }
        case .done where !task.result.outputs.isEmpty:
            HStack(spacing: 4) {
                WheelSmallButton(title: "Afficher", symbol: "magnifyingglass") { runner.reveal(task) }
                    .help("Afficher dans le Finder")
                WheelIconButton(symbol: "doc.on.doc", help: "Copier le fichier, prêt à coller") { runner.copy(task) }
                WheelIconButton(symbol: "arrow.uturn.backward",
                                help: task.result.renamed.isEmpty ? "Annuler : la copie va à la Corbeille" : "Annuler : les anciens noms reviennent") { runner.undo(task) }
            }
        default:
            if hovering {
                WheelIconButton(symbol: "xmark", help: "Retirer") { runner.dismiss(task) }
            }
        }
    }
}

extension WheelTaskRow {
    /// A web link read in a QR code.
    static func link(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

struct WheelProgressBar: View {
    var value: Double?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                PillShape().fill(Theme.track)
                PillShape().fill(Theme.accent)
                    .frame(width: max(6, g.size.width * CGFloat(value ?? 0.3)))
                    .opacity(value == nil ? 0.5 : 1)
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.25), value: value)
    }
}

struct WheelSmallButton: View {
    var title: String
    var symbol: String?
    var prominent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol, Theme.icons != .hidden { Image(systemName: symbol).font(.ui(9.5, .bold)) }
                Text(title).font(.ui(11, .semibold))
            }
            .foregroundStyle(prominent ? Theme.onAccent : Theme.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(PillShape().fill(prominent ? Theme.accent : Theme.track.opacity(0.85)))
            .contentShape(PillShape())
        }
        .buttonStyle(.plain)
    }
}

struct WheelIconButton: View {
    var symbol: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ui(10.5, .semibold))
                .foregroundStyle(Theme.text2)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.track.opacity(0.85)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
