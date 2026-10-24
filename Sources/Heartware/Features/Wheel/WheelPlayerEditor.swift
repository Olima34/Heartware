import SwiftUI
import AVKit
import AVFoundation

/// The player of « Couper » and « Capturer une image ». Couper opens macOS's own trimming bar (the one of QuickTime):
/// its yellow handles, then « Découper » makes the copy. Capturer plays the video and keeps the frame on screen.
@MainActor
final class WheelPlayerModel {
    let player: AVPlayer
    weak var view: AVPlayerView?
    private var statusObserver: NSKeyValueObservation?

    init(url: URL) {
        player = AVPlayer(url: url)
    }

    /// Runs `ready` once the video can play (the trimming bar needs it).
    func whenReady(_ ready: @escaping @MainActor () -> Void) {
        guard let item = player.currentItem else { return }
        if item.status == .readyToPlay { return ready() }
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.statusObserver = nil
                    ready()
                }
            }
        }
    }

    var currentSeconds: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }

    func stop() {
        player.pause()
        statusObserver = nil
    }
}

struct WheelPlayerView: NSViewRepresentable {
    let model: WheelPlayerModel
    var trimming: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = model.player
        v.controlsStyle = trimming ? .inline : .floating
        v.showsFrameSteppingButtons = !trimming
        v.showsFullScreenToggleButton = false
        v.allowsPictureInPicturePlayback = false
        model.view = v
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

struct WheelPlayerEditor: View {
    let context: WheelEditorContext
    /// « Capturer une image » (else « Couper »).
    let capturing: Bool
    @State private var model: WheelPlayerModel?
    @State private var state = "Ouverture de la vidéo…"
    @State private var duration: Double?

    var body: some View {
        WheelWindowChrome(title: capturing ? "Capturer une image" : "Couper", subtitle: context.file.name, close: close) {
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    if Snapshot.isActive || DemoData.isEnabled {
                        WheelPlayerStandIn(trimming: !capturing)
                    } else if let model {
                        WheelPlayerView(model: model, trimming: !capturing)
                    } else {
                        Theme.track
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.r(8)))
                .frame(maxHeight: .infinity)
                Text(hint).font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            if let duration { Text("Durée : \(WheelMediaEngine.clock(duration))").font(.ui(10.5).monospacedDigit()).foregroundStyle(Theme.text3) }
            Spacer()
            if capturing {
                Button { capture() } label: { ThemedLabel(title: "Garder cette image", symbol: "camera.viewfinder") }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button { trim() } label: { ThemedLabel(title: "Recommencer la coupe", symbol: "timeline.selection") }
                    .buttonStyle(SoftButtonStyle())
            }
        }
        .onAppear(perform: start)
        .onDisappear { model?.stop() }
    }

    private var hint: String {
        capturing ? "Avance jusqu'au bon moment (←  → image par image), puis garde l'image : elle est enregistrée en PNG."
                  : "Tire les poignées jaunes jusqu'au début et à la fin voulus, puis « Découper ». La copie garde la qualité d'origine."
    }

    private func start() {
        guard model == nil, !DemoData.isEnabled, !Snapshot.isActive else { return }
        let m = WheelPlayerModel(url: context.file.url)
        model = m
        let url = context.file.url
        Task {
            let d = try? await AVURLAsset(url: url).load(.duration)
            duration = d.map(\.seconds).flatMap { $0.isFinite ? $0 : nil }
        }
        m.whenReady {
            if !capturing { trim() }
        }
    }

    /// macOS's trimming bar; « Découper » saves the part kept.
    private func trim() {
        guard let m = model, let view = m.view, view.canBeginTrimming else { return }
        view.beginTrimming { result in
            MainActor.assumeIsolated {
                guard result == .okButton, let item = m.player.currentItem else { return }
                let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime.seconds : 0
                let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime.seconds : (duration ?? item.duration.seconds)
                guard end.isFinite, end > start + 0.05 else { return }
                save(start: start, end: end)
            }
        }
    }

    private func save(start: Double, end: Double) {
        let url = context.file.url
        model?.stop()
        context.save { folder, control in
            try await WheelMediaEngine.trim(url, start: start, end: end, folder: folder, control: control)
        }
    }

    private func capture() {
        guard let m = model else { return }
        m.player.pause()
        let at = m.currentSeconds
        let url = context.file.url
        m.stop()
        context.save { folder, control in
            control.progress(nil)
            return try await WheelMediaEngine.frame(url, at: at, folder: folder)
        }
    }

    private func close() {
        model?.stop()
        context.close()
    }
}

/// What snapshots and the demo show in place of the player (it cannot be drawn there).
private struct WheelPlayerStandIn: View {
    var trimming: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(decorative: WheelDemo.photo(width: 1120, height: 630), scale: 1).resizable().aspectRatio(contentMode: .fill)
            HStack(spacing: 10) {
                Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(.white)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.35)).frame(height: 4)
                        if trimming {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.yellow, lineWidth: 3)
                                .frame(width: g.size.width * 0.52, height: 22)
                                .offset(x: g.size.width * 0.18)
                        } else {
                            Capsule().fill(Color.white).frame(width: g.size.width * 0.4, height: 4)
                        }
                    }
                    .frame(height: g.size.height)
                }
                .frame(height: 24)
                Text(trimming ? "0:41,2" : "0:12,5").font(.system(size: 11).monospacedDigit()).foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.55))
        }
    }
}

/// « Alléger la vidéo » : three weights to choose from, then the copy is encoded with Apple's presets.
struct WheelVideoCompressEditor: View {
    let context: WheelEditorContext
    @State private var choice: ConverterVideoPreset = .hevc1080
    @State private var info: String?

    private let choices: [(ConverterVideoPreset, String, String)] = [
        (.h264_720, "Pour l'envoyer", "H.264 en 720p : léger, lisible partout, idéal pour un message."),
        (.hevc1080, "Équilibrée", "HEVC en 1080p : très léger, net sur un grand écran."),
        (.h264_1080, "Lisible partout", "H.264 en 1080p : pour un vieil ordinateur ou une télé."),
        (.hevcHighest, "Qualité maximale", "HEVC à la taille d'origine : à peu près deux fois plus léger."),
    ]

    var body: some View {
        WheelWindowChrome(title: "Alléger la vidéo", subtitle: context.files.count == 1 ? context.file.name : WheelRunner.summary(context.files),
                          close: context.close) {
            VStack(alignment: .leading, spacing: 8) {
                if let info { Text(info).font(.ui(11)).foregroundStyle(Theme.text3).padding(.bottom, 2) }
                ForEach(choices, id: \.0) { preset, title, detail in
                    Button { choice = preset } label: {
                        HStack(spacing: 10) {
                            Image(systemName: choice == preset ? "largecircle.fill.circle" : "circle")
                                .font(.ui(13)).foregroundStyle(choice == preset ? Theme.accent : Theme.text3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                                Text(detail).font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: Theme.r(10)).fill(choice == preset ? Theme.accent.opacity(0.12) : Theme.card.opacity(0.5)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.r(10)).strokeBorder(choice == preset ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: Theme.line))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        } footer: {
            Text("En MP4 · l'original ne change pas").font(.ui(10.5)).foregroundStyle(Theme.text3)
            Spacer()
            Button("Alléger") { save() }
                .buttonStyle(SoftButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
        }
        .onAppear(perform: read)
    }

    private func read() {
        guard info == nil else { return }
        if DemoData.isEnabled {
            info = "3:42 · 3 840 × 2 160 · 1,2 Go"
            return
        }
        let url = context.file.url
        Task {
            let d = await ConverterInspector.inspect(url, kind: .video)
            info = [d.detail, d.size > 0 ? Fmt.bytes(d.size) : nil].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private func save() {
        let urls = context.files.map(\.url)
        let preset = choice
        context.saveMany { folder, control in
            var out: [URL] = []
            for url in urls {
                try control.check()
                out.append(try await ConverterMediaEngine.compress(url, preset: preset, container: .mp4, folder: folder, control: control))
            }
            return out
        }
    }
}
