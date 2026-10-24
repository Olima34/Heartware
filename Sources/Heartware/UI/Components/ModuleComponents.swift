import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Placeholder

/// The page of a module that is not built yet.
struct ModulePlaceholder: View {
    var page: Page
    var subtitle: String
    var features: [String]
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHero(symbol: page.symbol, title: page.title, subtitle: subtitle, tint: tint, seed: UInt64(page.rawValue.count * 7))
            Card(padding: 22) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("En construction").font(.serif(22)).foregroundStyle(Theme.text)
                        Text("Ce module arrive dans la prochaine version. Voici ce qu'il saura faire :")
                            .font(.ui(13)).foregroundStyle(Theme.text2)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(features, id: \.self) { f in
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: "sparkle").font(.ui(10.5, .semibold)).foregroundStyle(tint).padding(.top, 2)
                                    Text(f).font(.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    PixelMascot(pixel: 3.5).padding(.top, 16)
                }
            }
        }
    }
}

// MARK: - Drop zone

/// A large area that accepts files dragged from the Finder, with a "Choisir…" button.
struct DropZone: View {
    var title = "Dépose tes fichiers ici"
    var subtitle = "ou clique pour les choisir"
    var symbol = "square.and.arrow.down.on.square"
    var allowedTypes: [UTType] = [.item]
    var allowsFolders = false
    var onFiles: ([URL]) -> Void
    @State private var targeted = false

    @ViewBuilder
    var body: some View {
        // A drop destination renders as yellow corners in ImageRenderer: none in snapshots.
        if Snapshot.isActive {
            zone
        } else {
            zone.dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                onFiles(files)
                return true
            } isTargeted: { targeted = $0 }
        }
    }

    private var zone: some View {
        Button(action: choose) {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(targeted ? Theme.accent : Theme.text3)
                Text(title).font(.serif(19)).foregroundStyle(Theme.text)
                Text(subtitle).font(.ui(12)).foregroundStyle(Theme.text3)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous).fill(targeted ? Theme.accent.opacity(0.08) : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous)
                .strokeBorder(targeted ? Theme.accent : Theme.borderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = allowsFolders
        panel.allowedContentTypes = allowedTypes
        panel.prompt = "Choisir"
        if panel.runModal() == .OK { onFiles(panel.urls) }
    }
}

// MARK: - Permission card

/// Explains why a macOS permission is needed and asks for it on click (never on its own).
struct PermissionCard: View {
    var permission: AppPermission
    var reason: String
    /// Bump to re-read the status (after the user comes back from System Settings).
    @State private var refresh = 0

    var body: some View {
        let _ = refresh
        let granted = permission.isGranted
        Group {
            if granted {
                // Once granted, a line is enough: the reason was for the decision, not for every visit.
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield").font(.ui(13, .medium)).foregroundStyle(Theme.good)
                    Text(permission.title).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
                    StatusBadge(status: .ok, text: "Accordée")
                    Spacer(minLength: 0)
                }
                .help(reason)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
            } else {
                full(granted: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh += 1 }
    }

    private func full(granted: Bool) -> some View {
        Card(padding: 18) {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(symbol: granted ? "checkmark.shield" : "hand.raised", tint: granted ? Theme.good : Theme.warn, size: 34)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(permission.title).font(.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                        StatusBadge(status: granted ? .ok : .warn, text: granted ? "Accordée" : "À accorder")
                    }
                    Text(reason).font(.ui(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    if !granted {
                        HStack(spacing: 8) {
                            Button("Autoriser") { permission.request() }
                                .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                            Button("C'est fait, vérifier") { refresh += 1 }
                                .buttonStyle(SoftButtonStyle(small: true))
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Shortcut recorder

/// Click, then press the new shortcut (with at least ⌘, ⌥ or ⌃). Esc cancels, ⌫ clears.
struct ShortcutRecorder: View {
    var combo: KeyCombo?
    var onChange: (KeyCombo?) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Tape le raccourci…" : (combo?.display ?? "Aucun"))
                .font(.ui(12.5, .medium))
                .monospacedDigit()
                .foregroundStyle(recording ? Theme.accent : Theme.text)
                .frame(minWidth: 120)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(recording ? Theme.accent.opacity(0.1) : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.r(8)).strokeBorder(recording ? Theme.accent : Theme.border))
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
                return nil
            }
            // Backspace alone clears; with modifiers it is a shortcut like any other (⌃⌥⌫ is a default one).
            if event.keyCode == 51, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                onChange(nil)
                stop()
                return nil
            }
            let combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: KeyCombo.carbon(from: event.modifierFlags))
            guard combo.hasModifier else { NSSound.beep(); return nil }
            onChange(combo)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
