import SwiftUI

/// What a feature needs to be understood once: the pages keep a short line, the rest waits here. The tip opens by itself
/// the first time its « ? » appears on screen, then only when the user clicks the « ? ».
struct HelpTip: Equatable {
    /// Remembered once seen ("media.videoOnly").
    let id: String
    var title: String
    var text: String
    /// Numbered steps under the text, when there is something to do outside the app.
    var steps: [String] = []
}

@MainActor
enum HelpTips {
    private static let prefix = "helpTip.seen."
    /// The tip open right now: one at a time, the others wait for their next appearance.
    static var showing: String?

    static func seen(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: prefix + id) }

    static func markSeen(_ id: String) { UserDefaults.standard.set(true, forKey: prefix + id) }

    /// Réglages › Général › Astuces › « Revoir ».
    static func resetAll() {
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys where key.hasPrefix(prefix) { d.removeObject(forKey: key) }
    }

    /// Never on its own in the demo, the snapshots or during the first-launch cards.
    static var opensByItself: Bool {
        !DemoData.isEnabled && !Snapshot.isActive && !(AppContext.model?.showOnboarding ?? false)
    }
}

/// The « ? » of a tip, next to a title. Put it where the feature is, so that the first explanation points at it.
struct HelpTipButton: View {
    let tip: HelpTip
    var size: CGFloat = 14
    /// False for a side feature of a screen that already explains itself: one bubble a visit is plenty.
    var opensByItself = true
    @State private var open = false
    @Environment(\.mainWindowOnScreen) private var onScreen

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.ui(size))
                .foregroundStyle(open ? Theme.accent : Theme.text3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip.title)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            HelpTipCard(tip: tip)
        }
        .onChange(of: open) { _, now in
            if now { HelpTips.showing = tip.id } else if HelpTips.showing == tip.id { HelpTips.showing = nil }
        }
        .task(id: tip.id) {
            guard opensByItself, HelpTips.opensByItself, !HelpTips.seen(tip.id) else { return }
            // Once the page has settled, and only if the window is really on screen.
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, onScreen, HelpTips.showing == nil else { return }
            // Taken at once: another « ? » appearing with this one waits for its next appearance.
            HelpTips.showing = tip.id
            HelpTips.markSeen(tip.id)
            open = true
        }
    }
}

/// The inside of a tip's bubble.
struct HelpTipCard: View {
    let tip: HelpTip

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tip.title).font(.ui(13, .semibold)).foregroundStyle(Theme.text)
            Text(tip.text)
                .font(.ui(12))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            if !tip.steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(tip.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1)")
                                .font(.ui(10.5, .semibold))
                                .foregroundStyle(Theme.onAccent)
                                .frame(width: 17, height: 17)
                                .background(Circle().fill(Theme.accent))
                            Text(step)
                                .font(.ui(12))
                                .foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .presentationBackground(Theme.card)
    }
}
