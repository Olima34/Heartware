import SwiftUI
import AppKit

enum YouTubeStyle {
    /// The accent: a download under way, the choice made (one accent for the whole app).
    static var tint: Color { Theme.accent }

    /// "4K", "1440p", "1080p".
    static func heightName(_ h: Int) -> String {
        h >= 2160 ? "4K" : "\(h)p"
    }
}

// MARK: - Picture

/// The video's picture, its duration in the corner like on YouTube.
struct YouTubeThumbnail: View {
    @Environment(AppModel.self) private var app
    var id: String
    var duration: Double?
    var corner: CGFloat = 10
    var badge = true

    var body: some View {
        Color.clear
            .overlay {
                if DemoData.isEnabled {
                    YouTubeDemoPicture(seed: id)
                } else if let cg = app.youtube.thumbnails[id] {
                    Image(decorative: cg, scale: 1).resizable().interpolation(.high).scaledToFill()
                } else {
                    ZStack {
                        Theme.track
                        Image(systemName: "play.rectangle").font(.ui(18)).foregroundStyle(Theme.text3)
                    }
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if badge, let duration, duration > 0 {
                    Text(YouTubeTime.format(duration))
                        .font(.ui(9.5, .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: Theme.r(4)).fill(Theme.bg.opacity(0.86)))
                        .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.r(corner)))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(corner)).strokeBorder(Theme.border, lineWidth: Theme.line))
    }
}

// MARK: - Controls

/// A row of small choices drawn by hand (no AppKit control: they render in snapshots and in the launcher panel),
/// sharing the width of the row.
struct YouTubeChips<T: Hashable>: View {
    var options: [T]
    var selection: T
    var label: (T) -> String
    /// A second line under the label (the size of each quality).
    var detail: (T) -> String? = { _ in nil }
    /// Offered, but not by this video (a 1080p choice for a 720p video gives 720p).
    var dimmed: (T) -> Bool = { _ in false }
    var help: (T) -> String? = { _ in nil }
    var select: (T) -> Void

    var body: some View {
        GlassGroup(selection: selection, axis: .horizontal, radius: 7, pick: select) {
            HStack(spacing: 4) { chips }
        }
    }

    private var chips: some View {
            ForEach(options, id: \.self) { o in
                let on = o == selection
                Button { select(o) } label: {
                    VStack(spacing: 1) {
                        Text(label(o)).font(.ui(11, on ? .semibold : .regular)).lineLimit(1)
                        if let d = detail(o) {
                            Text(d).font(.ui(9)).monospacedDigit().foregroundStyle(on ? Theme.text2 : Theme.text3)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    .foregroundStyle(on ? Theme.text : Theme.text2)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .chipGround(on)
                    .opacity(dimmed(o) && !on ? 0.45 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(o) ?? "")
                .glassItem(o)
            }
    }
}

/// Two handles on the video's timeline: where the extract starts and ends, to the second.
struct YouTubeRangeSlider: View {
    var duration: Double
    var clip: YouTubeClip
    var onChange: (YouTubeClip) -> Void
    @State private var dragging: Edge?

    private enum Edge { case start, end }
    private let knob: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width - knob)
            let x0 = CGFloat(clip.start / duration) * w
            let x1 = CGFloat(clip.end / duration) * w
            ZStack(alignment: .leading) {
                PillShape().fill(Theme.track).frame(height: 4).padding(.horizontal, knob / 2)
                PillShape().fill(YouTubeStyle.tint).frame(width: max(2, x1 - x0), height: 4).offset(x: x0 + knob / 2)
                handle.offset(x: x0)
                handle.offset(x: x1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let t = min(duration, max(0, Double((v.location.x - knob / 2) / w) * duration)).rounded()
                let edge = dragging ?? (abs(t - clip.start) < abs(t - clip.end) || (t < clip.start) ? .start : .end)
                dragging = edge
                var c = clip
                if edge == .start { c.start = min(t, c.end - 1) } else { c.end = max(t, c.start + 1) }
                if c != clip { onChange(c) }
            }.onEnded { _ in dragging = nil })
        }
        .frame(height: knob + 4)
        .help("Fais glisser les poignées pour choisir le début et la fin")
        .modifier(YouTubeKeepsWindowStill())
    }

    private var handle: some View {
        PillShape()
            .fill(Theme.cardRaised)
            .overlay(PillShape().strokeBorder(YouTubeStyle.tint, lineWidth: 2))
            .frame(width: knob, height: knob)
            .themedShadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }
}

/// The launcher's panel moves when dragged anywhere: over the slider, the drag belongs to the handles.
private struct YouTubeKeepsWindowStill: ViewModifier {
    @State private var held: NSWindow?
    @State private var wasMovable = false

    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside, held == nil, let w = NSApp.keyWindow {
                held = w
                wasMovable = w.isMovableByWindowBackground
                w.isMovableByWindowBackground = false
            } else if !inside, let w = held {
                w.isMovableByWindowBackground = wasMovable
                held = nil
            }
        }
        .onDisappear {
            held?.isMovableByWindowBackground = wasMovable
            held = nil
        }
    }
}

// MARK: - Settings

/// Format, quality (with the size of each), extract, folder: everything a download asks, in the launcher's pane.
/// Kept for the next video.
struct YouTubeSettings: View {
    @Environment(AppModel.self) private var app
    var link: YouTubeLink

    static let labelWidth: CGFloat = 46

    var body: some View {
        let model = app.youtube
        let info = model.infos[link.id]
        let clip = model.clips[link.id]
        VStack(alignment: .leading, spacing: 7) {
            row("Format") {
                YouTubeChips(options: YouTubeFormat.allCases, selection: model.options.format, label: \.title) { model.options.format = $0 }
            }
            if model.options.format == .mp4 {
                row("Qualité") {
                    YouTubeChips(options: YouTubeQuality.allCases, selection: model.options.quality,
                                 label: { qualityLabel($0, info) },
                                 detail: { q in
                                     guard info?.detailed == true else { return nil }
                                     return model.estimate(link.id, options: YouTubeOptions(format: .mp4, quality: q)).map(Fmt.bytes)
                                 },
                                 dimmed: { q in (info?.maxHeight).map { max in (q.height ?? 0) > max } ?? false },
                                 help: { q in qualityHelp(q, info) }) { model.options.quality = $0 }
                }
            }
            row("Durée") {
                YouTubeChips(options: [false, true], selection: clip != nil,
                             label: { $0 ? "Un extrait" : "En entier" },
                             dimmed: { $0 && info?.duration == nil },
                             help: { $0 && info?.duration == nil ? "Dès que la durée est connue" : nil }) { model.setClip($0, for: link) }
            }
            if let clip, let duration = info?.duration {
                VStack(alignment: .leading, spacing: 5) {
                    YouTubeRangeSlider(duration: duration, clip: clip) { model.clips[link.id] = $0 }
                    YouTubeClipFields(id: link.id, clip: clip, duration: duration)
                }
                .padding(.leading, Self.labelWidth + 8)
            }
            if model.options.format == .mp4, let note = codecNote(info) {
                Text(note).font(.ui(10.5)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.labelWidth + 8)
            }
            row("Dossier") { YouTubeDestinationMenu() }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).font(.ui(11)).foregroundStyle(Theme.text3).frame(width: Self.labelWidth, alignment: .leading)
            content()
        }
    }

    private func qualityLabel(_ q: YouTubeQuality, _ info: YouTubeInfo?) -> String {
        guard q == .best else { return q.label }
        if let max = info?.maxHeight, max > 1080 { return YouTubeStyle.heightName(max) }
        return "Max"
    }

    private func qualityHelp(_ q: YouTubeQuality, _ info: YouTubeInfo?) -> String? {
        guard let max = info?.maxHeight else { return nil }
        if q == .best { return "La meilleure image de cette vidéo : \(YouTubeStyle.heightName(max))" }
        if let h = q.height, h > max { return "Cette vidéo s'arrête à \(YouTubeStyle.heightName(max)) : tu auras \(YouTubeStyle.heightName(max))" }
        return nil
    }

    /// Above 1080p YouTube only sends VP9 or AV1, which QuickTime may not read: said before, not discovered after.
    private func codecNote(_ info: YouTubeInfo?) -> String? {
        guard let info, let video = YouTubeEngine.videoStream(info, quality: app.youtube.options.quality),
              let codec = video.codecName, !video.isH264 else { return nil }
        return "\(YouTubeStyle.heightName(video.height ?? 0)) en \(codec) : QuickTime ne la lit pas toujours (IINA ou VLC, si)."
    }
}

/// Where the files go: Téléchargements, or a folder picked once and kept.
struct YouTubeDestinationMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.youtube
        BorderlessMenu {
            Button("Téléchargements") { model.destination = .downloads }
            Divider()
            Button("Choisir un dossier…") { model.chooseFolder() }
        } label: {
            HStack(spacing: 5) {
                if Theme.icons != .hidden { Image(systemName: "folder").font(.ui(10.5)).foregroundStyle(Theme.text3) }
                Text(model.destination.label).font(.ui(11.5, .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            }
        }
        .help(model.destination.url.path)
    }
}

/// The extract to the second, typed: "1:05" → "2:30", and how long it lasts.
struct YouTubeClipFields: View {
    @Environment(AppModel.self) private var app
    var id: String
    var clip: YouTubeClip
    var duration: Double

    var body: some View {
        HStack(spacing: 6) {
            YouTubeTimeField(value: clip.start) { t in
                var c = clip
                c.start = min(max(0, t), clip.end - 1)
                app.youtube.clips[id] = c
            }
            Image(systemName: "arrow.right").font(.ui(9)).foregroundStyle(Theme.text3)
            YouTubeTimeField(value: clip.end) { t in
                var c = clip
                c.end = max(min(duration, t), clip.start + 1)
                app.youtube.clips[id] = c
            }
            Spacer(minLength: 4)
            Text(YouTubeTime.spoken(clip.length)).font(.ui(10.5)).monospacedDigit().foregroundStyle(Theme.text2)
        }
    }
}

/// A time typed by hand ("1:05"). Each time that reads as one is kept at once (↩ in the launcher downloads right away,
/// without leaving the field); what does not goes back to the previous value when the field is left.
struct YouTubeTimeField: View {
    var value: Double
    var set: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if Snapshot.isActive {
                Text(YouTubeTime.format(value)).foregroundStyle(Theme.text)
            } else {
                TextField("0:00", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onChange(of: text) { _, typed in
                        if focused, let t = YouTubeTime.parse(typed), t != value { set(t) }
                    }
                    .onChange(of: focused) { _, f in if !f { text = YouTubeTime.format(value) } }
            }
        }
        .font(.mono(11.5, .medium)).monospacedDigit()
        .frame(width: 54)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: Theme.r(6)).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(6)).strokeBorder(focused ? YouTubeStyle.tint.opacity(0.7) : Theme.border, lineWidth: max(1, Theme.line)))
        .onAppear { text = YouTubeTime.format(value) }
        .onChange(of: value) { _, v in if !focused { text = YouTubeTime.format(v) } }
    }
}

// MARK: - Launcher pane

/// At the right of the launcher, like the preview of a file: the video, then how to download it. ↩ downloads,
/// ⌘↩ opens it on YouTube.
struct YouTubeLauncherPane: View {
    @Environment(AppModel.self) private var app
    var link: YouTubeLink

    var body: some View {
        let model = app.youtube
        let info = model.infos[link.id]
        let job = model.jobs.first { $0.videoID == link.id && $0.state.isActive }
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                YouTubeThumbnail(id: link.id, duration: info?.duration, corner: 7)
                    .frame(width: 112, height: 63)
                VStack(alignment: .leading, spacing: 3) {
                    Text(info?.title ?? (model.failures[link.id] == nil ? "Lecture de la vidéo…" : "Vidéo YouTube"))
                        .font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(meta(info)).font(.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if let failure = model.failures[link.id] {
                YouTubeFailureLine(id: link.id, failure: failure)
            } else {
                if !model.tools.ready || model.install != nil {
                    YouTubeToolsLine()
                }
                if info?.isLive == true {
                    Label("Un direct se télécharge une fois terminé.", systemImage: "dot.radiowaves.left.and.right")
                        .font(.ui(11)).foregroundStyle(Theme.warn)
                } else {
                    YouTubeSettings(link: link)
                }
            }
            Spacer(minLength: 0)
            if let job {
                YouTubeJobProgress(job: job)
            } else if model.loading.contains(link.id) {
                HStack(spacing: 6) {
                    BusyMascot(.downloading, pixel: 1)
                    Text("Lecture de la vidéo…").font(.ui(11)).foregroundStyle(Theme.text3)
                }
            } else if let size = model.estimate(link.id) {
                Text("≈ \(Fmt.bytes(size))").font(.ui(11.5, .medium)).monospacedDigit().foregroundStyle(Theme.text2)
            }
        }
        .padding(14)
        .task(id: link.id) {
            // A link being typed by hand is read once it stays still.
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            model.refreshToolsIfNeeded()
            model.load(link.id)
        }
    }

    private func meta(_ info: YouTubeInfo?) -> String {
        var parts: [String] = []
        if let c = info?.channel, !c.isEmpty { parts.append(c) }
        if let h = info?.maxHeight { parts.append("jusqu'à \(YouTubeStyle.heightName(h))") }
        if link.isShort { parts.append("Short") }
        return parts.isEmpty ? link.shortURL : parts.joined(separator: " · ")
    }
}

/// yt-dlp (or ffmpeg) missing: one line and the button that installs it with Homebrew, then Homebrew's last lines.
struct YouTubeToolsLine: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.youtube
        VStack(alignment: .leading, spacing: 6) {
            if let install = model.install {
                HStack(spacing: 6) {
                    if install.running {
                        BusyMascot(.unpacking, pixel: 1)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").font(.ui(11)).foregroundStyle(Theme.warn)
                    }
                    Text(install.running ? install.title + "…" : "Homebrew n'a pas réussi")
                        .font(.ui(11.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Button(install.running ? "Annuler" : "Fermer") {
                        if install.running { model.cancelInstall() } else { model.dismissInstall() }
                    }
                    .buttonStyle(SoftButtonStyle(small: true))
                }
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(install.lines.suffix(2).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.mono(9.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                    }
                }
            } else {
                let missing = model.tools.missing.joined(separator: " et ")
                Text("Il manque \(missing) pour lire YouTube.")
                    .font(.ui(11.5, .medium)).foregroundStyle(Theme.warn)
                HStack(spacing: 6) {
                    if model.tools.brew != nil {
                        Button("Installer \(missing)") { model.installTools() }
                            .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                            .help("brew install \(model.tools.missing.joined(separator: " "))")
                    } else {
                        Button("Installer Homebrew") { Finder.open("https://brew.sh/fr/") }
                            .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                            .help("Homebrew installe yt-dlp et ffmpeg, puis les tient à jour")
                    }
                    Button("Vérifier") { model.refreshTools() }.buttonStyle(SoftButtonStyle(small: true))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.r(9)).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(9)).strokeBorder(Theme.border, lineWidth: Theme.line))
    }
}

/// Why the video cannot be read, with what to do about it.
struct YouTubeFailureLine: View {
    @Environment(AppModel.self) private var app
    var id: String
    var failure: YouTubeFailure

    var body: some View {
        let model = app.youtube
        VStack(alignment: .leading, spacing: 6) {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .font(.ui(11)).foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Réessayer") { model.load(id, retry: true) }.buttonStyle(SoftButtonStyle(small: true))
                if failure.suggestsUpdate, model.tools.brew != nil {
                    Button("Mettre à jour yt-dlp") { model.updateYtdlp() }
                        .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                        .disabled(model.install?.running == true)
                }
            }
        }
    }
}

// MARK: - Progress

/// Where a download is: its step, its bar, its speed and what is left.
struct YouTubeJobProgress: View {
    var job: YouTubeJob

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if job.state == .running {
                    BusyMascot(.downloading, pixel: 1)
                }
                Text(Self.status(job)).font(.ui(11, .medium)).foregroundStyle(Theme.text2).lineLimit(1)
                Spacer(minLength: 4)
                if let p = job.progress, job.state == .running {
                    Text(Fmt.pct(p)).font(.ui(11)).monospacedDigit().foregroundStyle(Theme.text3)
                }
            }
            if job.state == .running {
                UsageBar(fraction: job.progress ?? 0, tint: YouTubeStyle.tint, height: 4)
                    .opacity(job.progress == nil ? 0.35 : 1)
            }
        }
    }

    /// "Image · 8,4 Mo/s · encore 9 s", "En attente", "Annulé"…
    static func status(_ job: YouTubeJob) -> String {
        switch job.state {
        case .waiting: return "En attente"
        case .running:
            var s = job.phase.isEmpty ? "Téléchargement" : job.phase
            if let speed = job.speed, speed > 0 { s += " · " + Fmt.speed(speed) }
            if let eta = job.eta, eta >= 1 { s += " · encore " + YouTubeTime.spoken(eta) }
            if job.progress == nil, let started = job.started { s += " · " + YouTubeTime.spoken(Date().timeIntervalSince(started)) }
            return s
        case .done: return "Terminé"
        case .failed: return job.error ?? "Échec"
        case .cancelled: return "Annulé"
        }
    }
}
