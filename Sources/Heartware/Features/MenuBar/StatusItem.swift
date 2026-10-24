import AppKit
import SwiftUI
import Observation

extension MenuMetric {
    /// The text next to the mascot in the menu bar ("" for the icon alone).
    @MainActor
    func text(_ m: SystemMonitor) -> String {
        // The monitor's figures for the menu bar: fresh at its light pace too, when nothing else reads it.
        let f = m.menuFigures
        switch self {
        case .icon: return ""
        case .cpu: return "\(Int((f.cpu * 100).rounded())) %"
        case .memory: return "\(Int((f.memory * 100).rounded())) %"
        case .cpuMemory: return "\(Int((f.cpu * 100).rounded()))% · \(Int((f.memory * 100).rounded()))%"
        case .network: return "↓\(Fmt.speed(f.netIn)) ↑\(Fmt.speed(f.netOut))"
        case .disk: return Fmt.bytes(f.diskFree)
        case .temperature: return PerformanceSensorReader.shared.quickTemperature().map { "\(Int($0.rounded()))°" } ?? "—"
        }
    }

    /// What the monitor must read for this text when the menu bar alone shows it (the temperature has its own sensors).
    var readings: SystemMonitor.Readings {
        switch self {
        case .icon, .temperature: return []
        case .cpu: return .cpu
        case .memory: return .memory
        case .cpuMemory: return [.cpu, .memory]
        case .network: return .network
        case .disk: return .disk
        }
    }
}

/// The menu bar item, built with AppKit. Changing its text is a cheap property update,
/// whereas a SwiftUI `MenuBarExtra` label rebuilds the whole app menu at every refresh (measured: ~2 % of CPU).
/// The text follows the monitor's samples; alone on screen it has the monitor read only what it shows, every 5 s.
/// With the icon alone, the item keeps the monitor running only while its panel is open.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let app: AppModel
    private var metric = StatusItemController.savedMetric
    private static let icon = BrandMark.templateImage()
    private let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
    private var lastText = "-"
    private var shownMood: RefugeMood?
    /// The download shown in the item: its whole percent (-1 before the first figure, -2 while it waits), nil when none.
    private var shownDownload: Int?
    /// The temperature is read at most every 5 s, even while the window has the monitor sample every 2 s.
    private var temperatureText = "—"
    private var temperatureRead = Date.distantPast

    nonisolated private static var savedMetric: MenuMetric {
        MenuMetric(rawValue: UserDefaults.standard.string(forKey: Preferences.menuMetricKey) ?? "") ?? .cpuMemory
    }

    init(app: AppModel) {
        self.app = app
        super.init()
        if let button = item.button {
            button.image = Self.icon
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(toggle(_:))
            button.toolTip = "Heartware"
        }
        popover.behavior = .transient
        popover.delegate = self
        app.monitor.onSample = { [weak self] in self?.update() }
        app.monitor.menuBarReadings = metric.readings
        app.monitor.show(.menuBar, metric != .icon)
        update()
        watchDownloads()
        // The metric is picked in the settings and on the Menu d'état page.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.metricMayHaveChanged() }
        }
    }

    private func metricMayHaveChanged() {
        let saved = Self.savedMetric
        guard saved != metric else { return }
        metric = saved
        app.monitor.menuBarReadings = metric.readings
        app.monitor.show(.menuBar, metric != .icon)
        temperatureRead = .distantPast
        update()
    }

    private func update() {
        // A download in progress takes the item's place until it ends.
        guard shownDownload == nil else { return }
        // The chamois' head follows its mood (asleep at night, glasses during the Boost…), drawn only when it changes.
        if let button = item.button, app.refuge.menuMood != shownMood {
            shownMood = app.refuge.menuMood
            button.image = shownMood.map { RefugeFigure.menuImage($0) } ?? Self.icon
        }
        let text = metric == .temperature ? temperature() : metric.text(app.monitor)
        guard text != lastText, let button = item.button else { return }
        lastText = text
        button.attributedTitle = NSAttributedString(string: text.isEmpty ? "" : " " + text, attributes: [.font: font])
    }

    /// The sensors are read in the background: each call shows the figure of the previous reading. Read again after
    /// 5 s, or at once while there is no figure yet.
    private func temperature() -> String {
        guard temperatureText == "—" || Date().timeIntervalSince(temperatureRead) >= 4.5 else { return temperatureText }
        temperatureRead = Date()
        temperatureText = metric.text(app.monitor)
        return temperatureText
    }

    // MARK: Downloads

    /// Follows the YouTube downloads: called again after each change (at most four a second while one runs), never
    /// in between, so nothing runs while there is nothing to download.
    private func watchDownloads() {
        withObservationTracking {
            _ = app.youtube.activity
        } onChange: { [weak self] in
            // Called before the change: the new values are read once it is done.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.showDownload()
                    self?.watchDownloads()
                }
            }
        }
        showDownload()
    }

    private func showDownload() {
        guard let button = item.button else { return }
        guard let a = app.youtube.activity else {
            guard shownDownload != nil else { return }
            // Over: back to the mascot and the chosen figure.
            shownDownload = nil
            button.image = Self.icon
            button.toolTip = "Heartware"
            lastText = "-"
            update()
            return
        }
        let key = a.running ? (a.progress.map { Int(($0 * 100).rounded(.down)) } ?? -1) : -2
        if key != shownDownload {
            shownDownload = key
            button.image = Self.downloadImage(progress: a.running ? a.progress : nil)
            button.attributedTitle = NSAttributedString(string: " " + (a.running ? a.percent : "en attente"), attributes: [.font: font])
        }
        button.toolTip = a.tooltip
    }

    /// The mascot and a ring that fills as the download goes. A template image: the menu bar colors it, light or dark.
    /// `progress` nil: the ring's track alone (the first figure has not come, or the download waits its turn).
    static func downloadImage(progress: Double?) -> NSImage {
        let mascot = icon.size
        let ring: CGFloat = 13
        let gap: CGFloat = 4
        let size = NSSize(width: mascot.width + gap + ring, height: max(mascot.height, ring))
        let img = NSImage(size: size, flipped: true) { _ in
            icon.draw(in: NSRect(x: 0, y: (size.height - mascot.height) / 2, width: mascot.width, height: mascot.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let line: CGFloat = 2
            let r = NSRect(x: mascot.width + gap, y: (size.height - ring) / 2, width: ring, height: ring).insetBy(dx: line / 2, dy: line / 2)
            let track = NSBezierPath(ovalIn: r)
            track.lineWidth = line
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            if let p = progress, p > 0 {
                // From the top, clockwise (the drawing is flipped: y goes down).
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2, startAngle: -90,
                              endAngle: -90 + 360 * min(1, p), clockwise: false)
                arc.lineWidth = line
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            show()
        }
    }

    private func show() {
        guard let button = item.button else { return }
        // A fresh view each time, so the panel starts and stops reading processes with its own lifetime.
        // The panel keeps its own height (in a scroll view) and reports it; the popover follows, up to the room the
        // screen leaves. Never the popover's size fed back into the panel's layout, which AppKit can turn into an
        // endless resize when the screens change.
        let host = NSHostingController(rootView: StatusItemPanelRoot(app: app) { [weak self] height in self?.fit(height) })
        host.sizingOptions = []
        popover.contentViewController = host
        // Laid out once before opening, so the panel has reported its height and the popover opens at its size.
        // (Without sizing options the hosting view's `fittingSize` is 0 × 0: the popover then kept AppKit's 320 × 320,
        // the panel centered in it and cut at both ends.)
        host.view.frame = NSRect(x: 0, y: 0, width: MenuBarPanel.width, height: max(popover.contentSize.height, 100))
        host.view.layoutSubtreeIfNeeded()
        app.monitor.show(.panel, true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// The popover follows the panel's height, on the screen of the menu bar item (changed only when it really changes).
    private func fit(_ height: CGFloat) {
        guard height > 0 else { return }
        let target = Self.popoverSize(panelHeight: height, room: Self.room(on: item.button?.window?.screen),
                                      legacyScroller: NSScroller.preferredScrollerStyle == .legacy)
        if abs(popover.contentSize.height - target.height) >= 1 || abs(popover.contentSize.width - target.width) >= 1 {
            popover.contentSize = target
        }
    }

    /// The popover for a panel this tall: all of it, or all the room there is (the panel then scrolls, and the popover
    /// widens by a scroll bar when scroll bars always show). One point more than the panel: laid out before it has a
    /// window, the panel reports its height rounded to the point, up to half a point short.
    static func popoverSize(panelHeight: CGFloat, room: CGFloat, legacyScroller: Bool) -> NSSize {
        let height = ceil(panelHeight) + 1
        guard height > floor(room) else { return NSSize(width: MenuBarPanel.width, height: height) }
        let bar = legacyScroller ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return NSSize(width: MenuBarPanel.width + bar, height: floor(room))
    }

    /// The tallest popover the screen leaves: its visible part (without the menu bar and the Dock), less the popover's
    /// arrow and edges.
    static func room(on screen: NSScreen?) -> CGFloat {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame.height else { return 600 }
        return max(200, visible - 40)
    }

    func popoverDidClose(_ notification: Notification) {
        // A click on the icon while it was closing may have opened it again already: that panel keeps its content.
        guard !popover.isShown else { return }
        popover.contentViewController = nil
        app.monitor.show(.panel, false)
    }
}

/// The panel as the popover holds it: at its own height, in a scroll view that only scrolls when the screen is shorter.
private struct StatusItemPanelRoot: View {
    let app: AppModel
    let onHeight: @MainActor (CGFloat) -> Void

    var body: some View {
        ScrollView(.vertical) {
            MenuBarPanel()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.bg)
        .environment(app)
    }
}

/// `--snapshot --page menubar`: the menu bar item while a video downloads, as it looks over a light and a dark bar.
struct StatusItemPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array([(0.08, "8 %"), (0.62, "62 %"), (0.97, "97 %")].enumerated()), id: \.offset) { _, s in
                HStack(spacing: 14) {
                    item(s.0, s.1, dark: false)
                    item(s.0, s.1, dark: true)
                }
            }
            HStack(spacing: 14) {
                item(nil, "en attente", dark: false)
                item(nil, "en attente", dark: true)
            }
        }
        .padding(16)
    }

    private func item(_ progress: Double?, _ text: String, dark: Bool) -> some View {
        // The menu bar's own colors, fixed on purpose: the item is drawn by macOS, not by the theme.
        let ink: Color = dark ? .white : .black
        return HStack(spacing: 3) {
            Image(nsImage: StatusItemController.downloadImage(progress: progress))
                .renderingMode(.template)
            Text(text).font(.system(size: NSFont.systemFontSize - 1).monospacedDigit())
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Rectangle().fill(dark ? Color(white: 0.16) : Color(white: 0.93)))
    }
}

// MARK: - Check

extension StatusItemController {
    /// `--menubar-check [dossier]`: the panel in its real popover, opened from a temporary menu bar item the way a click
    /// opens it, for a few seconds. The popover must show the whole panel: as tall as the panel, or as tall as the
    /// screen allows with the rest within reach by scrolling. With `--demo`: the longest switches, then the YouTube queue
    /// arriving while the popover is open. The popover's pictures go into the folder (top, then scrolled to the end).
    static func check(out: String?) -> Bool {
        let folder = out.flatMap { $0.hasPrefix("-") ? nil : $0 }
        NSApplication.shared.setActivationPolicy(.accessory)
        let app = AppModel(liveMonitor: false)
        let queue = app.youtube.jobs
        if DemoData.isEnabled { app.youtube.jobs = [] }
        let controller = StatusItemController(app: app)
        defer { NSStatusBar.system.removeStatusItem(controller.item) }
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        wait(0.3)
        var ok = true
        func verify(_ step: String, picture: String) {
            let needed = checkPanelHeight(app)
            let shown = controller.popover.contentSize
            let window = controller.popover.contentViewController?.view.window
            let screen = window?.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            print("\(step) : le panneau demande \(Int(needed.rounded(.up))) pt, le popover en montre \(Int(shown.width)) × \(Int(shown.height)) pt"
                  + " (écran utile : \(Int(visible.height)) pt)")
            var failures: [String] = []
            if shown.width < MenuBarPanel.width - 0.5 { failures.append("le popover est plus étroit que le panneau") }
            // Its arrow may reach into the menu bar, never past the screen; its foot stays above the Dock.
            if let frame = window?.frame, let screen, frame.minY < visible.minY - 1 || frame.maxY > screen.frame.maxY + 1 {
                failures.append("le popover sort de l'écran (\(Int(frame.minY)) → \(Int(frame.maxY)) pt)")
            }
            if shown.height < needed {
                // Shorter than the panel: only allowed when the screen is, and then the rest must scroll into view.
                if shown.height < min(needed, visible.height - 60) - 1 { failures.append("le popover est plus court que l'écran ne le permet") }
                if let scroll = checkScrollView(in: controller.popover.contentViewController?.view) {
                    let document = scroll.documentView?.frame.height ?? 0
                    if document < needed - 1 { failures.append("la zone qui défile ne fait que \(Int(document)) pt") }
                } else {
                    failures.append("le panneau est rogné : rien ne défile")
                }
            }
            for f in failures { print("  ✗ \(f)") }
            if failures.isEmpty { print("  ✓ tout le panneau est visible\(shown.height < needed ? " en défilant" : "")") }
            ok = ok && failures.isEmpty
            if let folder, let window { checkCapture(window, to: folder + "/" + picture + ".png") }
        }
        controller.show()
        wait(1.2)
        verify("À l'ouverture", picture: "menubar-check-1")
        if DemoData.isEnabled, !queue.isEmpty {
            app.youtube.jobs = queue
            wait(1.2)
            verify("Après l'arrivée de \(queue.count) téléchargements", picture: "menubar-check-2")
            if let window = controller.popover.contentViewController?.view.window,
               let scroll = checkScrollView(in: controller.popover.contentViewController?.view), let document = scroll.documentView {
                document.scroll(NSPoint(x: 0, y: document.isFlipped ? max(0, document.frame.height - scroll.contentView.bounds.height) : 0))
                wait(0.4)
                if let folder { checkCapture(window, to: folder + "/menubar-check-3.png") }
            }
        }
        controller.popover.performClose(nil)
        wait(0.5)
        print(ok ? "✓ panneau de la barre des menus entier" : "✗ panneau de la barre des menus rogné")
        return ok
    }

    /// The height the panel needs at its width, everything shown.
    private static func checkPanelHeight(_ app: AppModel) -> CGFloat {
        NSHostingController(rootView: MenuBarPanel().environment(app))
            .sizeThatFits(in: CGSize(width: MenuBarPanel.width, height: .greatestFiniteMagnitude)).height
    }

    /// The outermost scroll view (the YouTube list has its own, further in).
    private static func checkScrollView(in view: NSView?) -> NSScrollView? {
        var level = view.map { [$0] } ?? []
        while !level.isEmpty {
            if let scroll = level.lazy.compactMap({ $0 as? NSScrollView }).first { return scroll }
            level = level.flatMap(\.subviews)
        }
        return nil
    }

    /// The popover's window as on screen (needs the terminal's screen recording permission).
    private static func checkCapture(_ window: NSWindow, to path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-l\(window.windowNumber)", "-o", "-x", path]
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
        if FileManager.default.fileExists(atPath: path) { print("  image : \(path)") }
    }

    /// `--selftest`: the panel's root laid out as `show()` lays it out before opening (no window) must report the
    /// height the panel really needs, and the popover keeps to the screen.
    static func selfTest() -> [String] {
        var failures: [String] = []
        let app = AppModel(liveMonitor: false)
        var reported: CGFloat = 0
        let host = NSHostingController(rootView: StatusItemPanelRoot(app: app) { reported = $0 })
        host.sizingOptions = []
        host.view.frame = NSRect(x: 0, y: 0, width: MenuBarPanel.width, height: 100)
        host.view.layoutSubtreeIfNeeded()
        let needed = checkPanelHeight(app)
        if abs(reported - needed) > 1 {
            failures.append("Panneau de la barre des menus : \(Int(reported)) pt annoncés au popover pour \(Int(needed)) pt de contenu")
        }
        let room: CGFloat = 700
        for (height, expected) in [(450.2, NSSize(width: MenuBarPanel.width, height: 452)), (699, NSSize(width: MenuBarPanel.width, height: 700)),
                                   (699.5, NSSize(width: MenuBarPanel.width, height: 700)), (946.5, NSSize(width: MenuBarPanel.width, height: 700))] {
            let size = popoverSize(panelHeight: height, room: room, legacyScroller: false)
            if size != expected { failures.append("Popover de \(size) pour un panneau de \(height) pt (attendu \(expected))") }
        }
        if popoverSize(panelHeight: 946.5, room: room, legacyScroller: true).width <= MenuBarPanel.width {
            failures.append("Le popover qui défile n'a pas la place de sa barre de défilement")
        }
        return failures + MenuPanelItems.selfTest()
    }
}
