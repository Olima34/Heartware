import SwiftUI
import AppKit

/// The download under way, as the app shows it from anywhere: the sidebar, the menu bar icon and its panel.
struct YouTubeActivity: Equatable {
    var jobID: UUID
    var videoID: String
    var title: String
    /// "Image", "Son", "Découpe de l'extrait"…, or "En attente" before it starts.
    var phase: String
    /// 0…1, nil before the first figure.
    var progress: Double?
    var speed: Double?
    var eta: Double?
    var running: Bool
    /// The downloads waiting behind it.
    var queued: Int

    /// The running download, or else the next one to start (the list is newest first, the oldest goes first).
    static func from(_ jobs: [YouTubeJob]) -> YouTubeActivity? {
        guard let job = jobs.first(where: { $0.state == .running }) ?? jobs.last(where: { $0.state == .waiting }) else { return nil }
        let running = job.state == .running
        return YouTubeActivity(jobID: job.id, videoID: job.videoID, title: job.title,
                               phase: running ? (job.phase.isEmpty ? "Téléchargement" : job.phase) : "En attente",
                               progress: running ? job.progress : nil, speed: running ? job.speed : nil, eta: running ? job.eta : nil,
                               running: running, queued: jobs.filter { $0.state == .waiting && $0.id != job.id }.count)
    }

    /// "62 %", or "…" while no figure is known yet.
    var percent: String {
        guard let progress else { return "…" }
        // Rounded down: 99,6 % is not done yet.
        return "\(Int((min(1, max(0, progress)) * 100).rounded(.down))) %"
    }

    /// "Image · 8,4 Mo/s · encore 9 s · 2 en attente".
    var detail: String {
        var parts = [phase]
        if let speed, speed > 0 { parts.append(Fmt.speed(speed)) }
        if let eta, eta >= 1 { parts.append("encore " + YouTubeTime.spoken(eta)) }
        if queued > 0 { parts.append("\(queued) en attente") }
        return parts.joined(separator: " · ")
    }

    /// The menu bar icon's tooltip.
    var tooltip: String {
        "Téléchargement de « \(title) » : \(progress == nil ? phase.lowercased() : percent)\n\(detail)"
    }
}

/// The downloads in the sidebar (under the pages) and in the menu bar panel, shown while the list has any.
/// In the sidebar: the one under way, or what ended; a click opens the list in a popover. In the menu bar panel: the list.
struct YouTubeActivityCard: View {
    enum Style { case sidebar, menu }

    @Environment(AppModel.self) private var app
    var style: Style = .sidebar
    @State private var hovering = false
    @State private var showList = false

    var body: some View {
        switch style {
        case .sidebar:
            sidebar
        case .menu:
            YouTubeQueueView(maxListHeight: 186)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.r(10)).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.r(10)).strokeBorder(Theme.border, lineWidth: Theme.line))
        }
    }

    private var sidebar: some View {
        let model = app.youtube
        return HStack(spacing: 4) {
            Button { showList.toggle() } label: {
                Group {
                    if let activity = model.activity {
                        running(activity)
                    } else {
                        ended
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.activity.map { $0.tooltip + "\nClique pour voir les téléchargements." } ?? "Clique pour voir les téléchargements")
            if model.activity == nil {
                Button { model.clearFinished() } label: {
                    Image(systemName: "xmark").font(.ui(8.5, .bold)).foregroundStyle(Theme.text3)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Retirer de la liste")
                .padding(.trailing, 4)
            }
        }
        // The sidebar's floating module: an activity under way takes the accent.
        .floatingSurface(radius: 12, shadow: false)
        .overlay { RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).fill(hovering || showList ? Theme.fill1 : .clear).allowsHitTesting(false) }
        .onHover { hovering = $0 }
        .popover(isPresented: $showList, arrowEdge: .trailing) {
            YouTubeQueueView()
                .padding(14)
                .frame(width: 380)
                .background(Theme.bg)
                .presentationBackground(Theme.bg)
        }
    }

    /// The sidebar is narrow: the title and the figure, the bar, then the step and the time left.
    private func running(_ activity: YouTubeActivity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(activity.title)
                    .font(.ui(11.5, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if activity.running {
                    Text(activity.percent).font(.ui(12, .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                } else {
                    Image(systemName: "clock").font(.ui(11)).foregroundStyle(Theme.text3)
                }
            }
            UsageBar(fraction: activity.progress ?? 0, tint: Theme.accent, height: 4)
                .opacity(activity.progress == nil ? 0.35 : 1)
            Text(shortDetail(activity))
                .font(.ui(10.5))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Nothing under way: what ended since, in one line ("2 téléchargements terminés", "1 échec").
    private var ended: some View {
        let jobs = app.youtube.finishedJobs
        let failed = jobs.filter { $0.state == .failed }.count
        let done = jobs.filter { $0.state == .done }.count
        return HStack(spacing: 7) {
            if Theme.icons != .hidden {
                Image(systemName: failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.ui(11)).foregroundStyle(failed > 0 ? Theme.warn : Theme.good)
            }
            Text(failed > 0 ? Fmt.plural(failed, "téléchargement en échec", "téléchargements en échec")
                            : done > 0 ? Fmt.plural(done, "téléchargement terminé", "téléchargements terminés") : "Téléchargements annulés")
                .font(.ui(11.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
        }
        .padding(.vertical, 8)
        .padding(.leading, 10)
    }

    /// The step and the time left; the speed stays in the tooltip.
    private func shortDetail(_ activity: YouTubeActivity) -> String {
        var parts = [activity.phase]
        if let eta = activity.eta, eta >= 1 { parts.append("encore " + YouTubeTime.spoken(eta)) }
        if activity.queued > 0 { parts.append("+\(activity.queued)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The list

/// The downloads, newest first: cancel one, show it in the Finder, try a failed one again. In the sidebar's popover, the
/// menu bar panel and the launcher ("Téléchargements YouTube").
struct YouTubeQueueView: View {
    @Environment(AppModel.self) private var app
    /// The list scrolls past this height.
    var maxListHeight: CGFloat = 300

    static let rowHeight: CGFloat = 54

    var body: some View {
        let model = app.youtube
        let active = model.activeJobs.count
        let finished = model.finishedJobs.count
        let updateNeeded = model.jobs.contains { $0.state == .failed && $0.suggestsUpdate } && model.tools.brew != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Téléchargements").font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                if active > 1 {
                    Button("Tout annuler") { model.cancelAll() }.buttonStyle(SoftButtonStyle(small: true))
                }
                if finished > 0 {
                    Button("Effacer") { model.clearFinished() }.buttonStyle(SoftButtonStyle(small: true))
                        .help("Retire de la liste ce qui est terminé (les fichiers restent)")
                }
            }
            if let install = model.install, install.running {
                HStack(spacing: 6) {
                    BusyMascot(.unpacking, pixel: 1)
                    Text(install.title + "…").font(.ui(11)).foregroundStyle(Theme.text2).lineLimit(1)
                }
            } else if updateNeeded {
                Button("Mettre à jour yt-dlp") { model.updateYtdlp() }
                    .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                    .help("YouTube change souvent : la dernière version de yt-dlp suit")
            }
            if model.jobs.isEmpty {
                Text("Colle un lien YouTube dans le lanceur (⌥Espace) pour le télécharger.")
                    .font(.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            } else {
                let n = CGFloat(model.jobs.count)
                ScrollArea {
                    VStack(spacing: 4) {
                        ForEach(model.jobs) { YouTubeQueueRow(job: $0) }
                    }
                }
                .frame(height: min(maxListHeight, n * Self.rowHeight + (n - 1) * 4))
            }
        }
    }
}

/// One download of the list: its picture, its title, where it is, and the one thing to do with it.
struct YouTubeQueueRow: View {
    @Environment(AppModel.self) private var app
    var job: YouTubeJob
    @State private var hovering = false

    var body: some View {
        let model = app.youtube
        HStack(spacing: 9) {
            YouTubeThumbnail(id: job.videoID, duration: nil, corner: 5, badge: false)
                .frame(width: 60, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.ui(11.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                switch job.state {
                case .running:
                    UsageBar(fraction: job.progress ?? 0, tint: YouTubeStyle.tint, height: 3)
                        .opacity(job.progress == nil ? 0.35 : 1)
                    line((job.progress.map { Fmt.pct($0) + " · " } ?? "") + YouTubeJobProgress.status(job))
                case .waiting:
                    line("En attente · " + job.summary)
                case .done:
                    line(job.summary + " · " + (job.folder.lastPathComponent == "Downloads" ? "Téléchargements" : job.folder.lastPathComponent))
                case .failed:
                    Text(job.error ?? "Échec").font(.ui(10.5)).foregroundStyle(Theme.warn).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                case .cancelled:
                    line("Annulé · " + job.summary)
                }
            }
            Spacer(minLength: 4)
            switch job.state {
            case .running, .waiting:
                YouTubeRowButton(symbol: "xmark", help: "Annuler") { model.cancel(job) }
            case .done:
                if let url = job.output {
                    YouTubeRowButton(symbol: "magnifyingglass", help: "Afficher dans le Finder") {
                        if !DemoData.isEnabled { Finder.reveal(url.path) }
                    }
                }
            case .failed, .cancelled:
                YouTubeRowButton(symbol: "arrow.clockwise", help: "Réessayer") { model.retry(job) }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: YouTubeQueueView.rowHeight)
        .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(hovering ? Theme.hover.opacity(0.5) : Theme.bg.opacity(0.55)))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            // A double click opens the file, like in the Finder.
            if let url = job.output, !DemoData.isEnabled { NSWorkspace.shared.open(url) }
        }
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.ui(10.5)).monospacedDigit().foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.tail)
    }
}

/// The one action of a row, as a small round button (its name in the tooltip): the title keeps the room.
private struct YouTubeRowButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.ui(10, .bold)).foregroundStyle(hovering ? Theme.text : Theme.text2)
                .frame(width: 24, height: 24)
                .background(PillShape().fill(hovering ? Theme.hover : Theme.card))
                .overlay(PillShape().strokeBorder(Theme.border, lineWidth: Theme.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// The list at the right of the launcher, for its "Téléchargements YouTube" result.
struct YouTubeQueuePane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            YouTubeQueueView(maxListHeight: 330)
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}
