import SwiftUI
import AppKit
import Translation

/// What Apple's on-device translation is asked to do.
struct TranslatorRequest: Equatable {
    /// Tells a request from a newer one with the same text (only the current one may change what is shown).
    let id = UUID()
    var text: String
    var source: String?
    var target: String
    /// Ask macOS to download the languages first (it shows its own confirmation).
    var download = false
}

/// The places that ask Apple's on-device translation: the translator inside the launcher panel, the quick results of
/// the launcher's search ("trad …"), and the small window where a language is downloaded (macOS asks to confirm there).
enum TranslatorChannel {
    case panel, launcher, download
}

/// Apple's translation only runs inside a view (`translationTask`): this invisible view does it for a channel.
/// Nothing before macOS 15.
struct TranslatorHost: View {
    var channel: TranslatorChannel

    var body: some View {
        if #available(macOS 15.0, *), !Snapshot.isActive, !DemoData.isEnabled {
            TranslatorAppleHost(channel: channel)
        }
    }
}

@available(macOS 15.0, *)
private struct TranslatorAppleHost: View {
    @Environment(AppModel.self) private var app
    var channel: TranslatorChannel
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        let ticket = app.translator.ticket(for: channel)
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                let request = await MainActor.run { app.translator.request(for: channel) }
                guard let request else { return }
                do {
                    if request.download { try await session.prepareTranslation() }
                    let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let result = text.isEmpty ? nil : try await session.translate(request.text).targetText
                    await MainActor.run { app.translator.appleFinished(request, result: result, channel: channel) }
                } catch {
                    await MainActor.run { app.translator.appleFailed(request, error: error, channel: channel) }
                }
            }
            .onChange(of: ticket) { _, _ in ask() }
            // The download window opens with its request already made: it starts as soon as it is there.
            .onAppear { if channel == .download { ask() } }
    }

    private func ask() {
        guard let request = app.translator.request(for: channel) else { return }
        let fresh = TranslationSession.Configuration(source: request.source.map { Locale.Language(identifier: $0) },
                                                     target: Locale.Language(identifier: request.target))
        if configuration?.source == fresh.source, configuration?.target == fresh.target {
            configuration?.invalidate()
        } else {
            configuration = fresh
        }
    }
}

/// A language is downloaded in its own small window: macOS asks to confirm there (in the launcher panel its window
/// would take the keyboard and close the panel). The window closes itself once the language is on the Mac.
@MainActor
enum TranslatorDownloadWindow {
    private static var window: NSWindow?
    private static let watcher = Watcher()

    /// Closed by the user (its red button) in the middle of a download: the view goes, and the download with it.
    private final class Watcher: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                let w = notification.object as? NSWindow
                DispatchQueue.main.async {
                    w?.contentView = nil
                    AppContext.model?.translator.downloadWindowClosed()
                }
            }
        }
    }

    static func show(app: AppModel, language: String) {
        guard !Snapshot.isActive, !DemoData.isEnabled else { return }
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 96), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Langues de traduction"
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.delegate = watcher
            window = w
            return w
        }()
        let host = NSHostingView(rootView: TranslatorDownloadView(language: language).environment(app))
        host.sizingOptions = []
        w.contentView = host
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    static func close() {
        if window?.isVisible == true { window?.close() }
    }
}

private struct TranslatorDownloadView: View {
    @Environment(AppModel.self) private var app
    var language: String

    var body: some View {
        HStack(spacing: 14) {
            BusyMascot(.downloading, pixel: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Téléchargement : \(TranslatorLanguage.named(language).lowercased())")
                    .font(.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                Text("Confirme dans la fenêtre de macOS.").font(.ui(11.5)).foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 380, height: 96)
        .background(Theme.bg)
        .background(TranslatorHost(channel: .download))
    }
}

/// Which languages macOS has, can download, or does not offer (asked without downloading anything).
enum TranslatorAvailability {
    static func status(from source: String, to target: String) async -> TranslatorPairStatus {
        guard #available(macOS 15.0, *), !DemoData.isEnabled else { return .unsupported }
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        switch status {
        case .installed: return .installed
        case .supported: return .downloadable
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    static var isAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    static func message(_ error: Error) -> String {
        if #available(macOS 15.0, *) {
            if TranslationError.unsupportedLanguagePairing ~= error { return "Apple ne traduit pas cette paire de langues : essaie avec Claude." }
            if TranslationError.unableToIdentifyLanguage ~= error { return "Je n'arrive pas à reconnaître la langue : choisis-la en haut à gauche." }
            if TranslationError.nothingToTranslate ~= error { return "Rien à traduire." }
        }
        if (error as? CancellationError) != nil { return "Téléchargement annulé." }
        return error.localizedDescription
    }
}
