import SwiftUI
import AppKit

@Observable
@MainActor
final class YouTubeModel: AppModule {
    var options = YouTubeOptions.saved() {
        didSet { if options != oldValue { options.save(); refreshLauncher() } }
    }
    var destination = YouTubeDestination.saved() {
        didSet { if destination != oldValue { destination.save(); refreshLauncher() } }
    }
    /// The part to keep, per video (none: the whole video).
    var clips: [String: YouTubeClip] = [:] {
        didSet { if Set(clips.keys) != Set(oldValue.keys) { refreshLauncher() } }
    }
    var infos: [String: YouTubeInfo] = [:]
    var thumbnails: [String: CGImage] = [:]
    /// Videos yt-dlp is reading.
    var loading: Set<String> = []
    var failures: [String: YouTubeFailure] = [:]
    var tools = YouTubeTools.find()
    var install: YouTubeInstall?
    /// Newest first.
    var jobs: [YouTubeJob] = []

    @ObservationIgnored private var cancels: [UUID: CancelFlag] = [:]
    @ObservationIgnored private var installCancel: CancelFlag?
    @ObservationIgnored private weak var app: AppModel?

    var activeJobs: [YouTubeJob] { jobs.filter { $0.state.isActive } }
    var finishedJobs: [YouTubeJob] { jobs.filter { !$0.state.isActive } }
    /// The download under way, for the sidebar and the menu bar.
    var activity: YouTubeActivity? { YouTubeActivity.from(jobs) }

    // MARK: Module

    func start(app: AppModel) {
        self.app = app
        // What a download left behind when the app quit in the middle of it.
        let work = DataStore.url("YouTube").path
        for name in (try? FileManager.default.contentsOfDirectory(atPath: work)) ?? [] {
            _ = Remover.removeInternal(work + "/" + name)
        }
    }

    /// Downloads still going are stopped with the app (their half-written files go with the work folder).
    func stop() {
        for flag in cancels.values { flag.cancel() }
        installCancel?.cancel()
    }

    func loadDemo() {
        let id = YouTubeDemo.videoID
        infos[id] = YouTubeDemo.info
        clips[id] = YouTubeClip(start: 65, end: 150)
        options = YouTubeOptions(format: .mp4, quality: .p1080)
        destination = .downloads
        jobs = YouTubeDemo.jobs()
    }

    static let listCommandID = "open_youtube"

    /// The demo's link, pasted in the launcher by the snapshots (`--page launcher --tab youtube`).
    static var demoLink: String { "https://youtu.be/\(YouTubeDemo.videoID)?si=atelier" }

    /// The launcher's snapshots pass their own names (`--page launcher --tab youtube:outils`).
    func applySnapshotTab(_ tab: String) {
        let id = YouTubeDemo.videoID
        switch tab {
        case "outils":
            // A Mac without yt-dlp: the line that installs it.
            tools = YouTubeTools(ytdlp: nil, ffmpeg: "/opt/homebrew/bin/ffmpeg", brew: "/opt/homebrew/bin/brew")
            infos[id]?.detailed = false
            infos[id]?.duration = nil
            infos[id]?.streams = []
            clips = [:]
        case "installation":
            tools = YouTubeTools(ytdlp: nil, ffmpeg: "/opt/homebrew/bin/ffmpeg", brew: "/opt/homebrew/bin/brew")
            install = YouTubeInstall(title: "Installation de yt-dlp", lines: YouTubeDemo.installLines)
        case "vide":
            jobs = []
        case "entiere":
            clips = [:]
        case "audio":
            options.format = .mp3
        case "echec":
            failures[id] = YouTubeFailure(message: "YouTube a changé quelque chose : mets yt-dlp à jour, c'est en général réglé.", suggestsUpdate: true)
        case "attente":
            loading.insert(id)
            infos[id]?.detailed = false
        default:
            break
        }
    }

    // MARK: Launcher

    func results(for query: String, app: AppModel) -> [AppCommand] {
        guard let link = YouTubeLink.parse(query) else { return [] }
        let id = link.id
        let known = infos[id]
        let clip = clips[id]
        let red = YouTubeStyle.tint
        let missing = tools.ready ? nil : tools.missing.joined(separator: " et ")
        return [
            // Over everything else: what was pasted is this video, not a file name nor a calculation.
            // It stays in the launcher until the download starts: ↩ may install yt-dlp first, or read the video again.
            AppCommand(id: "youtube_download", title: known.map { "Télécharger « \($0.title) »" } ?? "Télécharger cette vidéo YouTube",
                       subtitle: missing.map { "Il manque \($0) : ↩ l'installe" }
                           ?? (options.summary + (clip == nil ? "" : " · un extrait") + " · dans \(destination.label)"),
                       icon: .symbol("arrow.down.circle.fill", red), group: .tools, hint: missing == nil ? "Télécharger" : "Installer",
                       boost: 2000, staysInLauncher: true,
                       pane: { AnyView(YouTubeLauncherPane(link: link)) }) { ctx in
                if ctx.alternate {
                    ctx.app.launcher.hide()
                    NSWorkspace.shared.open(URL(string: link.watchURL)!)
                } else {
                    ctx.app.youtube.launcherReturn(link)
                }
                return .done
            },
            AppCommand(id: "youtube_open", title: "Ouvrir sur YouTube", subtitle: link.shortURL,
                       icon: .symbol("play.rectangle", red), group: .web, hint: "Ouvrir", boost: 1900) { _ in
                NSWorkspace.shared.open(URL(string: link.watchURL)!)
                return .done
            }
        ]
    }

    /// The download list in the launcher ("téléchargements", "youtube"), the list itself at the right; and yt-dlp's update.
    /// It keeps the identifier of the former page (`open_youtube`): the shortcuts and links made for it still work.
    func commands(app: AppModel) -> [AppCommand] {
        let red = YouTubeStyle.tint
        let active = activeJobs.count
        let finished = finishedJobs.count
        var list = [
            AppCommand(id: Self.listCommandID, title: "Téléchargements YouTube",
                       subtitle: jobs.isEmpty ? "Colle un lien YouTube ici pour le télécharger"
                           : [active > 0 ? "\(active) en cours" : nil, finished > 0 ? Fmt.plural(finished, "terminé", "terminés") : nil]
                               .compactMap { $0 }.joined(separator: " · "),
                       keywords: ["youtube", "vidéos youtube", "téléchargements", "vidéos", "mp4", "mp3", "file"],
                       icon: .symbol("arrow.down.circle", red), group: .tools, assistantSafe: true, urlSafe: true,
                       hint: "Ouvrir le dossier", pane: { AnyView(YouTubeQueuePane()) }) { ctx in
                guard !DemoData.isEnabled else { return .message(DemoData.refusal) }
                // From a shortcut, a link or Claude (nothing typed): a YouTube link just copied waits in the launcher,
                // its options at the right, ↩ to download it.
                if ctx.query.isEmpty, let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   YouTubeLink.parse(copied) != nil {
                    ctx.app.launcher.show(query: copied)
                    return .done
                }
                // The last file downloaded, selected in its folder; or the folder where the next one goes.
                if let file = ctx.app.youtube.jobs.first(where: { $0.output != nil })?.output {
                    Finder.reveal(file.path)
                } else {
                    NSWorkspace.shared.open(ctx.app.youtube.destination.url)
                }
                return .done
            }
        ]
        if tools.brew != nil, tools.ytdlp != nil {
            list.append(AppCommand(id: "youtube_update", title: "Mettre à jour yt-dlp", subtitle: "YouTube change souvent : la dernière version suit",
                                   keywords: ["yt-dlp", "youtube", "homebrew", "mise à jour"], icon: .symbol("arrow.triangle.2.circlepath", red),
                                   group: .tools, hint: "Mettre à jour") { ctx in
                ctx.app.youtube.updateYtdlp()
                return .done
            })
        }
        return list
    }

    /// The launcher's row says the video's title and the chosen settings: it follows them while it is on screen.
    private func refreshLauncher(showing id: String? = nil) {
        guard let launcher = (app ?? AppContext.model)?.launcher, launcher.isOpen,
              let shown = YouTubeLink.parse(launcher.query), id == nil || shown.id == id else { return }
        launcher.refreshKeepingSelection()
    }

    // MARK: Reading a video

    /// Title, picture and channel at once, then yt-dlp's details (duration, streams). Started by the user: a pasted link.
    func load(_ id: String, retry: Bool = false) {
        guard !DemoData.isEnabled, !Snapshot.isActive, YouTubeLink.isVideoID(id) else { return }
        if retry { failures[id] = nil }
        guard infos[id]?.detailed != true, !loading.contains(id), failures[id] == nil else { return }
        loading.insert(id)
        if thumbnails[id] == nil || infos[id] == nil {
            Task {
                if infos[id] == nil, let basic = await YouTubeEngine.oembed(id), infos[id] == nil {
                    infos[id] = YouTubeInfo(id: id, title: basic.title, channel: basic.channel)
                    refreshLauncher(showing: id)
                }
                if thumbnails[id] == nil, let image = await YouTubeEngine.thumbnail(id) { thumbnails[id] = image }
                if tools.ytdlp == nil {
                    loading.remove(id)
                    if infos[id] == nil { failures[id] = YouTubeFailure(message: "Vidéo introuvable : supprimée, privée ou mal copiée.") }
                }
            }
        }
        guard let ytdlp = tools.ytdlp else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) { YouTubeEngine.probe(id, ytdlp: ytdlp) }.value
            loading.remove(id)
            switch result {
            case .success(let info):
                infos[id] = info
                refreshLauncher(showing: id)
            case .failure(let f):
                failures[id] = f
            }
        }
    }

    // MARK: Extract

    /// "En entier" or "Un extrait": the extract starts where the link did ("&t=…"), or at the start.
    func setClip(_ on: Bool, for link: YouTubeLink) {
        guard on else { clips[link.id] = nil; return }
        guard let d = infos[link.id]?.duration, d >= 2 else { return }
        let start = min(max(0, link.start ?? 0), d - 1)
        clips[link.id] = YouTubeClip(start: start.rounded(.down), end: d.rounded(.down))
    }

    /// The extract to cut, or nil when it covers the whole video.
    func effectiveClip(_ id: String) -> YouTubeClip? {
        guard let clip = clips[id] else { return nil }
        let d = infos[id]?.duration ?? .infinity
        return clip.start <= 0.5 && clip.end >= d - 0.5 ? nil : clip
    }

    func estimate(_ id: String, options: YouTubeOptions? = nil) -> Int64? {
        guard let info = infos[id] else { return nil }
        return YouTubeEngine.estimate(info, options: options ?? self.options, clip: effectiveClip(id))
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choisir"
        panel.message = "Où ranger les vidéos et les sons téléchargés ?"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { destination = .folder(url) }
    }

    // MARK: Downloads

    /// ↩ on the launcher's row: the download, once nothing stands in the way. Until then the launcher stays open and its
    /// pane shows what happens: yt-dlp being installed, the video read again.
    func launcherReturn(_ link: YouTubeLink) {
        guard !DemoData.isEnabled else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        tools = YouTubeTools.find()
        if !tools.ready {
            if install?.running == true { return }
            if tools.brew != nil {
                installTools()
            } else {
                (app ?? AppContext.model)?.launcher.hide()
                Finder.open("https://brew.sh/fr/")
            }
            return
        }
        if failures[link.id] != nil {
            load(link.id, retry: true)
            return
        }
        if infos[link.id]?.isLive == true {
            HUD.show("Un direct ne se télécharge pas pendant qu'il est en cours", symbol: "exclamationmark.triangle.fill")
            return
        }
        (app ?? AppContext.model)?.launcher.hide()
        download(link)
    }

    /// Queues the video with the current settings; a message says it started, the menu bar shows how far it is.
    func download(_ link: YouTubeLink) {
        guard !DemoData.isEnabled else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        tools = YouTubeTools.find()
        guard tools.ready else {
            HUD.show("Il manque \(tools.missing.joined(separator: " et ")) : colle le lien dans le lanceur pour l'installer", symbol: "exclamationmark.triangle.fill")
            return
        }
        if let failure = failures[link.id] {
            HUD.show(failure.message, symbol: "exclamationmark.triangle.fill")
            return
        }
        let info = infos[link.id]
        if info?.isLive == true {
            HUD.show("Un direct ne se télécharge pas pendant qu'il est en cours", symbol: "exclamationmark.triangle.fill")
            return
        }
        let job = YouTubeJob(videoID: link.id, title: info?.title ?? "Vidéo \(link.shortURL)", channel: info?.channel ?? "",
                             options: options, clip: effectiveClip(link.id), folder: destination.url)
        jobs.insert(job, at: 0)
        HUD.show("Téléchargement lancé · \(job.summary)", symbol: "arrow.down.circle.fill")
        pump()
    }

    /// One download at a time: YouTube slows down the ones that run side by side.
    private func pump() {
        guard !jobs.contains(where: { $0.state == .running }),
              let next = jobs.lastIndex(where: { $0.state == .waiting }) else { return }
        run(jobs[next].id)
    }

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    private func run(_ jobID: UUID) {
        guard let i = index(jobID) else { return }
        guard let ytdlp = tools.ytdlp, let ffmpeg = tools.ffmpeg else {
            fail(jobID, YouTubeFailure(message: "yt-dlp ou ffmpeg a disparu : colle le lien dans le lanceur pour le réinstaller."))
            return
        }
        let job = jobs[i]
        let work: URL
        do {
            work = try FileOps.makeDirectory(DataStore.url("YouTube").appendingPathComponent(jobID.uuidString))
        } catch {
            fail(jobID, YouTubeFailure(message: "Impossible de préparer le téléchargement : \(error.localizedDescription)"))
            return
        }
        jobs[i].state = .running
        jobs[i].started = Date()
        jobs[i].phase = "Connexion à YouTube"
        let cancel = CancelFlag()
        cancels[jobID] = cancel
        let args = YouTubeEngine.arguments(videoID: job.videoID, options: job.options, clip: job.clip, ffmpeg: ffmpeg, workFolder: work.path)
        let tracker = YouTubeTracker(format: job.options.format, clip: job.clip, info: infos[job.videoID])
        let throttle = YouTubeThrottle()
        ActionLog.write("YOUTUBE yt-dlp \(job.videoID) \(job.summary)")
        Task {
            let out = await Task.detached(priority: .userInitiated) {
                Shell.stream(ytdlp, args, env: ["PYTHONUNBUFFERED": "1"], isCancelled: { cancel.isCancelled }) { line in
                    guard let event = YouTubeEngine.parse(line) else { return }
                    let (state, stepChanged) = tracker.apply(event)
                    guard throttle.due(force: stepChanged) else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { [weak self] in self?.show(state, for: jobID) }
                    }
                }
            }.value
            finish(jobID, status: out.status, cancelled: cancel.isCancelled, tracker: tracker, work: work, lastLines: out.out)
        }
    }

    private func show(_ state: YouTubeTracker.State, for jobID: UUID) {
        guard let i = index(jobID), jobs[i].state == .running else { return }
        jobs[i].phase = state.phase
        jobs[i].progress = state.progress
        jobs[i].speed = state.speed
        jobs[i].eta = state.eta
    }

    private func finish(_ jobID: UUID, status: Int32, cancelled: Bool, tracker: YouTubeTracker, work: URL, lastLines: String) {
        cancels[jobID] = nil
        defer {
            _ = Remover.removeInternal(work.path)
            pump()
        }
        guard let i = index(jobID) else { return }
        if cancelled {
            jobs[i].state = .cancelled
            jobs[i].phase = ""
            return
        }
        let job = jobs[i]
        let produced = tracker.file.map { URL(fileURLWithPath: $0) }
        guard status == 0, let produced, FileManager.default.fileExists(atPath: produced.path) else {
            let error = tracker.error ?? lastLines.split(separator: "\n").last { $0.hasPrefix("ERROR:") }.map(String.init)
            fail(jobID, error.map(YouTubeEngine.friendly)
                 ?? YouTubeFailure(message: "yt-dlp s'est arrêté sans fichier (code \(status)). Mettre yt-dlp à jour règle souvent ça.", suggestsUpdate: true))
            return
        }
        // Queued before the title was known (↩ right after the paste): it is by now.
        if let known = infos[job.videoID]?.title { jobs[i].title = known }
        let name = YouTubeEngine.fileName(title: jobs[i].title, clip: job.clip, ext: produced.pathExtension.isEmpty ? job.options.format.ext : produced.pathExtension)
        do {
            let saved = try FileOps.move(produced, to: job.folder.appendingPathComponent(name))
            jobs[i].state = .done
            jobs[i].output = saved
            jobs[i].progress = 1
            jobs[i].phase = ""
            jobs[i].finished = Date()
            announce(jobs[i])
        } catch {
            fail(jobID, YouTubeFailure(message: "Le fichier n'a pas pu être rangé dans « \(job.folder.lastPathComponent) » : \(error.localizedDescription)"))
        }
    }

    private func fail(_ jobID: UUID, _ failure: YouTubeFailure) {
        guard let i = index(jobID) else { return }
        jobs[i].state = .failed
        jobs[i].error = failure.message
        jobs[i].suggestsUpdate = failure.suggestsUpdate
        jobs[i].phase = ""
        jobs[i].finished = Date()
        if NSApp?.isActive != true {
            Notifier.post(id: "youtube-\(jobID.uuidString)", title: "Téléchargement impossible", body: "\(jobs[i].title) : \(failure.message)", throttle: 0)
        }
    }

    /// Said where the user is: a message over every app, or a notification when Heartware is behind.
    private func announce(_ job: YouTubeJob) {
        let place = job.folder.lastPathComponent == "Downloads" ? "Téléchargements" : "« \(job.folder.lastPathComponent) »"
        let what = job.options.format.isAudio ? "Le son" : "La vidéo"
        if NSApp?.isActive != true, Notifier.available {
            Notifier.post(id: "youtube-\(job.id.uuidString)", title: "\(what) est prêt\(job.options.format.isAudio ? "" : "e")",
                          body: "\(job.title) est dans \(place).", throttle: 0)
        } else {
            HUD.show("\(what) est dans \(place)", symbol: "checkmark.circle.fill")
        }
    }

    func cancel(_ job: YouTubeJob) {
        guard let i = index(job.id) else { return }
        if jobs[i].state == .waiting {
            jobs[i].state = .cancelled
        } else {
            cancels[job.id]?.cancel()
        }
    }

    func cancelAll() {
        for job in activeJobs { cancel(job) }
    }

    func retry(_ job: YouTubeJob) {
        guard !DemoData.isEnabled else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        jobs.removeAll { $0.id == job.id }
        jobs.insert(YouTubeJob(videoID: job.videoID, title: job.title, channel: job.channel, options: job.options, clip: job.clip,
                               folder: job.folder), at: 0)
        pump()
    }

    func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
    }

    // MARK: Tools

    /// "Vérifier à nouveau": installed from the Terminal meanwhile?
    func refreshTools() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        tools = YouTubeTools.find()
    }

    /// The launcher's pane checks again only what is missing (a few file lookups).
    func refreshToolsIfNeeded() {
        if !tools.ready, !DemoData.isEnabled, !Snapshot.isActive { tools = YouTubeTools.find() }
    }

    /// `brew install yt-dlp ffmpeg` (what is missing), after a click, its output shown as it comes.
    func installTools() {
        let names = tools.missing
        guard !names.isEmpty else { return }
        runBrew(["install"] + names, title: "Installation de \(names.joined(separator: " et "))")
    }

    /// YouTube changes often: a newer yt-dlp follows.
    func updateYtdlp() {
        guard !DemoData.isEnabled else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        runBrew(["upgrade", "yt-dlp"], title: "Mise à jour de yt-dlp")
    }

    func cancelInstall() {
        installCancel?.cancel()
    }

    func dismissInstall() {
        if install?.running != true { install = nil }
    }

    private func runBrew(_ args: [String], title: String) {
        guard !DemoData.isEnabled, let brew = tools.brew ?? Shell.which("brew"), install?.running != true else { return }
        let cancel = CancelFlag()
        installCancel = cancel
        install = YouTubeInstall(title: title)
        let throttle = YouTubeThrottle()
        let buffer = YouTubeLines()
        ActionLog.write("HOMEBREW brew " + args.joined(separator: " "))
        Task {
            let out = await Task.detached(priority: .userInitiated) {
                Shell.stream(brew, args, env: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1"],
                             isCancelled: { cancel.isCancelled }) { line in
                    let clean = line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    guard !clean.isEmpty else { return }
                    buffer.append(clean)
                    guard throttle.due() else { return }
                    let lines = buffer.take()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { [weak self] in self?.appendInstall(lines) }
                    }
                }
            }.value
            appendInstall(buffer.take())
            installCancel = nil
            install?.running = false
            install?.failed = out.status != 0 || cancel.isCancelled
            if cancel.isCancelled { install?.lines.append("Annulé.") }
            tools = YouTubeTools.find()
            let upgrade = args.first == "upgrade"
            guard install?.failed == false else {
                // The lines stay in the launcher's pane until closed; elsewhere a message says it failed.
                if (app ?? AppContext.model)?.launcher.isOpen != true, !cancel.isCancelled {
                    HUD.show("Homebrew n'a pas pu \(upgrade ? "mettre à jour" : "installer") yt-dlp", symbol: "exclamationmark.triangle.fill")
                }
                return
            }
            install = nil
            HUD.show(upgrade ? "yt-dlp est à jour" : "C'est installé : tu peux télécharger", symbol: "checkmark.circle.fill")
            // What failed with the old yt-dlp is read again, the video in the launcher first.
            failures = [:]
            if let launcher = (app ?? AppContext.model)?.launcher, launcher.isOpen, let shown = YouTubeLink.parse(launcher.query) {
                load(shown.id)
                launcher.refreshKeepingSelection()
            }
        }
    }

    private func appendInstall(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        install?.lines.append(contentsOf: lines)
        if let n = install?.lines.count, n > 200 { install?.lines.removeFirst(n - 200) }
    }

    // MARK: Checks

    func selfTest() -> [String] {
        var failures = YouTubeChecks.run()
        // The launcher's snapshots paste the demo's link: it must read as the demo's video.
        if YouTubeLink.parse(Self.demoLink)?.id != YouTubeDemo.videoID { failures.append("lanceur : lien de démo non reconnu") }
        // The sidebar and the menu bar show the download under way, then what ended (the list stays until cleared).
        let jobs = YouTubeDemo.jobs()
        if YouTubeActivity.from(jobs)?.running != true { failures.append("activité : le téléchargement en cours n'est pas vu") }
        if YouTubeActivity.from(Array(jobs.dropFirst())) != nil { failures.append("activité : un téléchargement fini est encore en cours") }
        return failures
    }

    func dump() -> [String] {
        let t = YouTubeTools.find()
        var lines = ["yt-dlp : \(t.ytdlp ?? "absent") · ffmpeg : \(t.ffmpeg ?? "absent") · brew : \(t.brew ?? "absent")"]
        if let ytdlp = t.ytdlp, !DemoData.isEnabled {
            lines.append("version de yt-dlp : " + Shell.run(ytdlp, ["--version"], timeout: 20).out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for sample in ["https://youtu.be/jNQXAC9IVRw?t=5", "youtube.com/shorts/jNQXAC9IVRw", "https://www.youtube.com/@chaine"] {
            let l = YouTubeLink.parse(sample)
            lines.append("« \(sample) » → \(l.map { "\($0.id)\($0.start.map { " à \(YouTubeTime.format($0))" } ?? "")\($0.isShort ? " (Short)" : "")" } ?? "pas une vidéo")")
        }
        let args = YouTubeEngine.arguments(videoID: "jNQXAC9IVRw", options: YouTubeOptions(format: .mp4, quality: .p720),
                                           clip: YouTubeClip(start: 5, end: 12), ffmpeg: t.ffmpeg ?? "ffmpeg", workFolder: "/tmp/x")
        lines.append("yt-dlp " + args.joined(separator: " "))
        return lines
    }
}

/// Lines of Homebrew's output waiting for the main thread.
final class YouTubeLines: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []

    func append(_ line: String) {
        lock.lock()
        pending.append(line)
        lock.unlock()
    }

    func take() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let out = pending
        pending = []
        return out
    }
}

/// Follows a download through yt-dlp's lines: which track, how far, then the assembly.
final class YouTubeTracker: @unchecked Sendable {
    struct State: Equatable {
        var phase: String
        var progress: Double?
        var speed: Double?
        var eta: Double?
    }

    private let lock = NSLock()
    private let format: YouTubeFormat
    private let clipped: Bool
    /// The extract's length: ffmpeg's position over it is the progress of the cut.
    private let clipLength: Double
    private var cutSpeed: Double?
    private let info: YouTubeInfo?
    private var weights: [Double] = [1]
    private var track = -1
    private var lastDone: Int64 = 0
    private var state = State(phase: "Connexion à YouTube")
    private var _file: String?
    private var _error: String?

    init(format: YouTubeFormat, clip: YouTubeClip?, info: YouTubeInfo?) {
        self.format = format
        clipped = clip != nil
        clipLength = clip?.length ?? 0
        self.info = info
    }

    var file: String? { lock.lock(); defer { lock.unlock() }; return _file }
    var error: String? { lock.lock(); defer { lock.unlock() }; return _error }

    /// The new state, and whether the step changed (shown at once, whatever the throttle).
    func apply(_ event: YouTubeEngine.Event) -> (State, Bool) {
        lock.lock()
        defer { lock.unlock() }
        let before = state.phase
        switch event {
        case .selected(let ids):
            // Each track weighs its size (the picture is most of a video).
            let sizes = ids.map { id in info?.streams.first { $0.formatID == id }?.bytes(duration: info?.duration) }
            if sizes.count > 1, sizes.allSatisfy({ ($0 ?? 0) > 0 }) {
                let total = Double(sizes.compactMap { $0 }.reduce(0, +))
                weights = sizes.map { Double($0 ?? 0) / total }
            } else {
                weights = ids.count > 1 ? [0.88] + Array(repeating: 0.12 / Double(ids.count - 1), count: ids.count - 1) : [1]
            }
            state.phase = clipped ? "Découpe de l'extrait" : phaseName(0)
            state.progress = 0
        case .progress(let done, let total, let speed, let eta):
            // A track starts again from zero (the estimate of a fragmented track changes as it goes: not a new track).
            if track < 0 || done < lastDone {
                track = min(track + 1, weights.count - 1)
            }
            lastDone = done
            let fraction = total.map { $0 > 0 ? min(1, Double(done) / Double($0)) : 0 }
            if clipped {
                // The cut's position says how far it is (`cutTime`); this line only comes once it is over.
                state.phase = "Découpe de l'extrait"
            } else if let fraction {
                let before = weights.prefix(max(0, track)).reduce(0, +)
                state.progress = min(0.97, (before + weights[max(0, track)] * fraction) * 0.97)
                state.phase = phaseName(track)
            }
            if !clipped {
                state.speed = speed
                state.eta = eta
            }
            // An extract comes in one piece, image and sound together: its only line means the cut is over.
            if fraction == 1, clipped || track >= weights.count - 1 {
                state.phase = finishingName
                state.progress = 0.98
                state.speed = nil
                state.eta = nil
            }
        case .cutTime(let seconds):
            guard clipped, clipLength > 0 else { break }
            let done = min(clipLength, seconds)
            state.phase = "Découpe de l'extrait"
            // Never backwards (ffmpeg's last lines may repeat an earlier time).
            state.progress = max(state.progress ?? 0, min(0.97, done / clipLength * 0.97))
            state.speed = nil
            state.eta = cutSpeed.map { (clipLength - done) / $0 }
        case .cutSpeed(let x):
            cutSpeed = x
        case .file(let path):
            _file = path
            state.phase = "Rangement"
            state.progress = 0.99
        case .error(let text):
            _error = text
        }
        return (state, state.phase != before)
    }

    private func phaseName(_ track: Int) -> String {
        if weights.count > 1 { return track <= 0 ? "Image" : "Son" }
        return format.isAudio ? "Son" : "Vidéo"
    }

    private var finishingName: String {
        switch format {
        case .mp3: return "Conversion en MP3"
        case .m4a: return "Finalisation"
        case .mp4: return weights.count > 1 && !clipped ? "Assemblage de l'image et du son" : "Finalisation"
        }
    }
}
