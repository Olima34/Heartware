import SwiftUI
import AppKit

/// Réglages › Autorisations: every permission at a glance, and one button to ask for all of them.
struct PermissionsSettings: View {
    @Environment(AppModel.self) private var app
    @State private var center = PermissionCenter.shared
    /// The settings window is on screen (closed, minimised or covered: nothing is checked).
    @State private var onScreen = true
    /// Permissions asked from a row, still waiting for macOS' or the user's answer.
    @State private var asking = 0
    private let stable = PermissionCenter.hasStableSignature

    /// Checked quickly only while a permission asked for is awaited; otherwise when the window shows and when the app
    /// comes back to the front (from System Settings, typically).
    private var polling: Bool {
        onScreen && (center.waitingForSettings || (asking > 0 && !center.isRunning))
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(center.grantedCount) sur \(PermissionKind.allCases.count) accordées").font(.headline)
                        Text(statusLine).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if center.isRunning {
                        if center.waitingForSettings {
                            Button("Passer") { center.skip() }
                        }
                        BusyMascot(.checking, pixel: 1)
                    } else {
                        Button("Tout autoriser") {
                            Task {
                                await center.requestAll()
                                // The folders are readable now: the launcher can index them.
                                if center.states[.folders] == .granted { app.launcher.enableIndex() }
                                app.fullDiskAccess = Permissions.hasFullDiskAccess
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(center.grantedCount == PermissionKind.allCases.count)
                    }
                }
                if !stable {
                    Label("Copie signée « ad hoc » : macOS oubliera ces autorisations à la prochaine compilation (./scripts/setup_signing.sh).",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionSettingsRow(kind: kind, state: center.states[kind] ?? .notAsked,
                                          isCurrent: center.current == kind, center: center) {
                        Task {
                            asking += 1
                            await center.request(kind)
                            await center.refresh()
                            asking -= 1
                        }
                    }
                }
            } footer: {
                Text("Chacune ne sert qu'à ce qui est écrit. Certaines se donnent dans Réglages Système : active \(AppEdition.name), puis reviens ici.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .background { if !Snapshot.isActive { MascotWindowProbe(onScreen: $onScreen) } }
        // Shown again: the states as they are now.
        .task(id: onScreen) { if onScreen { await center.refresh() } }
        .task(id: polling) {
            guard polling else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5), tolerance: .seconds(0.5))
                guard !Task.isCancelled else { return }
                await center.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard onScreen, !center.isRunning || center.waitingForSettings else { return }
            Task { await center.refresh() }
        }
    }

    private var statusLine: String {
        if center.isRunning, let k = center.current {
            return center.waitingForSettings
                ? "Active \(AppEdition.name) dans Réglages Système (\(k.title))."
                : "Je demande : \(k.title)…"
        }
        return stable
            ? "Elles restent acquises après chaque mise à jour."
            : "Un clic, et macOS pose ses questions l'une après l'autre."
    }
}

private struct PermissionSettingsRow: View {
    var kind: PermissionKind
    var state: PermissionState
    var isCurrent: Bool
    var center: PermissionCenter
    var ask: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol).frame(width: 20).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                    Text(kind.purpose).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                trailing
            }
            if isCurrent, center.waitingForSettings, center.addBack == kind {
                Text("Pas dans la liste ? Glisse \(AppEdition.name) depuis le Finder dans Réglages Système, puis active-la.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30)
            } else if isCurrent, center.waitingForSettings {
                // The switch may already be on for an older build of the app: macOS then ignores it.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let since = center.waitingSince, context.date.timeIntervalSince(since) > 5 {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Déjà activée ? macOS garde une ancienne version de l'app : réinitialise, puis réactive.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Réinitialiser") { Task { await center.reset(kind) } }.controlSize(.small)
                            Button("Passer") { center.skip() }.controlSize(.small)
                        }
                        .padding(.leading, 30)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isCurrent {
            BusyMascot(.checking, pixel: 1)
        } else if state == .granted {
            Label("Accordée", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(Theme.good)
        } else if state == .denied {
            HStack(spacing: 6) {
                if kind.needsSettings || kind == .finder || kind == .systemEvents || kind == .safari {
                    Button("Réinitialiser") { Task { await center.reset(kind) } }.controlSize(.small)
                        .help("macOS ne redemande plus : efface sa réponse pour cette app, puis redemande.")
                }
                Button("Réglages…") { Finder.open(kind.settingsURL) }.controlSize(.small)
                    .help("Refusée : à activer dans Réglages Système.")
            }
        } else if state == .asked {
            HStack(spacing: 6) {
                Text("Demandée").font(.caption).foregroundStyle(.secondary)
                Button("Réglages…") { Finder.open(kind.settingsURL) }.controlSize(.small)
            }
        } else if kind.needsSettings {
            HStack(spacing: 6) {
                Button("Réinitialiser") { Task { await center.reset(kind) } }.controlSize(.small)
                    .help("Interrupteur déjà activé mais sans effet ? macOS se souvient d'une ancienne version de l'app.")
                Button("Ouvrir…", action: ask).controlSize(.small)
            }
        } else {
            Button("Autoriser", action: ask).controlSize(.small)
        }
    }
}
