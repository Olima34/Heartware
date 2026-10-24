import SwiftUI
import AppKit

/// Remplir et signer lives in this window, opened on a document: the Convertisseur's « Signer » (over the Finder, with
/// or without the main window), the launcher's file actions and its commands (a file is chosen first). One document at
/// a time: another one opened meanwhile replaces it here. Closing the window closes the document, after asking when
/// something is not saved; the window never stays open with nothing in it.
@MainActor
final class FillSignWindow: NSObject, NSWindowDelegate {
    static let shared = FillSignWindow()
    /// Comfortable for a whole A4 page next to the tools; smaller on a small screen.
    static let size = CGSize(width: 980, height: 1000)
    static let minSize = CGSize(width: 760, height: 560)
    private static let sizeKey = "fillsign.windowSize"

    private var window: NSWindow?

    var isOpen: Bool { window != nil }

    func show(app: AppModel) {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        let w = window ?? make(app: app)
        window = w
        retitle(app.fillSign.document?.name ?? app.fillSign.opening ?? "Remplir et signer")
        // The Dock icon follows the windows when the user asked for it (Réglages › Général).
        if DockIconMode.current == .whileWindowOpen, NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if w.isMiniaturized { w.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// The window's name in Mission Control and the Window menu: the document's.
    func retitle(_ title: String) {
        window?.title = title
    }

    /// Closes without asking (nothing left in it).
    func close() {
        window?.close()
    }

    private func make(app: AppModel) -> NSWindow {
        let frame = Self.frame(wanted: Self.savedSize ?? Self.size, in: Self.screenUnderMouse)
        let w = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.identifier = NSUserInterfaceItemIdentifier("fillsign")
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.collectionBehavior = [.fullScreenPrimary]
        w.minSize = Self.minSize
        let host = NSHostingView(rootView: FillSignWindowView().environment(app))
        // The window decides its size, not the SwiftUI content.
        host.sizingOptions = []
        w.contentView = host
        w.setFrame(frame, display: false)
        w.delegate = self
        return w
    }

    // MARK: Size

    private static var screenUnderMouse: CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
    }

    private static var savedSize: CGSize? {
        guard let s = UserDefaults.standard.string(forKey: sizeKey) else { return nil }
        let size = NSSizeFromString(s)
        return size.width >= minSize.width && size.height >= minSize.height ? size : nil
    }

    /// The size asked for, kept inside the screen's visible part (menu bar and Dock excluded), in its middle.
    static func frame(wanted: CGSize, in visible: CGRect) -> CGRect {
        let w = max(min(minSize.width, visible.width), min(wanted.width, visible.width - 24)).rounded(.down)
        let h = max(min(minSize.height, visible.height), min(wanted.height, visible.height - 12)).rounded(.down)
        return CGRect(x: (visible.midX - w / 2).rounded(.down), y: (visible.midY - h / 2).rounded(.down), width: w, height: h)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        AppContext.model?.fillSign.windowMayClose() ?? true
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === window else { return }
        UserDefaults.standard.set(NSStringFromSize(w.frame.size), forKey: Self.sizeKey)
        w.delegate = nil
        window = nil
        AppContext.model?.fillSign.windowDidClose()
        // The view goes with the window, so that nothing keeps following the model.
        DispatchQueue.main.async {
            w.contentView = nil
            AppContext.applyDockIcon()
        }
    }
}

/// What the window shows: the editor, or what comes before it (the file being read, its password, its conversion).
struct FillSignWindowView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.fillSign
        Group {
            if let doc = model.document {
                FillSignWorkspace(document: doc)
            } else {
                FillSignWindowHome()
            }
        }
        .padding(.horizontal, 18)
        // Under the traffic lights: the content starts at the very top of the window (and of a snapshot, which has
        // no title bar), the same room is kept in both.
        .padding(.top, 36)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) { FillSignSaveBar() }
        .overlay(alignment: .top) {
            if model.pad != nil { FillSignPadOverlay() }
        }
        .background(Theme.bg)
        .tint(Theme.accent)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: model.isIdle) { _, idle in
            // A password or a conversion given up: nothing is left to show.
            if idle { FillSignWindow.shared.close() }
        }
    }
}

/// The window before its document: the file being read, its password, its conversion, or why it did not open.
struct FillSignWindowHome: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.fillSign
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 0)
            FillSignStatus()
            if model.message != nil && model.opening == nil && model.passwordFor == nil {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Fermer") { FillSignWindow.shared.close() }.buttonStyle(SoftButtonStyle(small: true))
                    Button("Choisir un autre document…") { model.choose() }.buttonStyle(SoftButtonStyle(prominent: true, small: true))
                }
            }
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What happens before the editor: a file on its way (or being laid out as a PDF), a password to type, an error. Over the
/// editor too, when another document is being opened (`showsMessage`: the editor says its own messages).
struct FillSignStatus: View {
    @Environment(AppModel.self) private var app
    var showsMessage = true

    /// A Word, text or Markdown file is laid out as a PDF on its way in.
    static func isText(_ name: String) -> Bool {
        [.document, .markdown].contains(ConverterKind.detect(name: name, isDirectory: false))
    }

    var body: some View {
        let model = app.fillSign
        if showsMessage, let message = model.message {
            Callout(symbol: "exclamationmark.triangle", title: "Impossible d'ouvrir ce document", text: message, tint: Theme.warn)
        }
        if let name = model.opening {
            Card(padding: 16) {
                HStack(spacing: 14) {
                    BusyMascot(.reading, pixel: 2)
                    Text(Self.isText(name) ? "Je mets « \(name) » en PDF…" : "J'ouvre « \(name) »…").font(.serif(18)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        if let url = model.passwordFor {
            FillSignPasswordCard(url: url)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A PDF protected by a password: asked here, kept only while it is open (the saved copy keeps the same password).
struct FillSignPasswordCard: View {
    @Environment(AppModel.self) private var app
    var url: URL
    @State private var password = ""

    var body: some View {
        let model = app.fillSign
        Card(padding: 18) {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(symbol: "lock.doc", tint: Theme.warn, size: 34)
                VStack(alignment: .leading, spacing: 8) {
                    Text("« \(url.lastPathComponent) » est protégé par un mot de passe").font(.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                    Text(model.passwordWrong ? "Ce n'est pas le bon mot de passe : réessaie." : "La copie enregistrée gardera le même mot de passe.")
                        .font(.ui(12)).foregroundStyle(model.passwordWrong ? Theme.warn : Theme.text2)
                    HStack(spacing: 8) {
                        Group {
                            if Snapshot.isActive {
                                Text(password.isEmpty ? "Mot de passe" : String(repeating: "•", count: password.count))
                                    .foregroundStyle(Theme.text3).frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                SecureField("Mot de passe", text: $password)
                                    .textFieldStyle(.plain)
                                    .onSubmit { if !password.isEmpty { model.open(url, password: password) } }
                            }
                        }
                        .font(.ui(12.5))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(Theme.bg))
                        .overlay(RoundedRectangle(cornerRadius: Theme.r(8)).strokeBorder(Theme.border, lineWidth: Theme.line))
                        .frame(width: 240)
                        Button("Ouvrir") { model.open(url, password: password) }
                            .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                            .disabled(password.isEmpty)
                        Button("Annuler") { model.passwordFor = nil }.buttonStyle(SoftButtonStyle(small: true))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Pinned at the bottom of the window while a document is open: what changed and the button that saves the copy,
/// then where it went.
struct FillSignSaveBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.fillSign
        if let doc = model.document {
            ActionBar {
                if model.saving {
                    BusyMascot(.checking, pixel: 2)
                    Text("J'enregistre la copie…").font(.serif(17)).foregroundStyle(Theme.text)
                    Spacer()
                } else if let saved = model.saved {
                    Image(systemName: "checkmark.seal.fill").font(.ui(20)).foregroundStyle(Theme.good)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enregistré : \(saved.lastPathComponent)").font(.serif(17)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        Text("Dans \(FS.pretty(saved.deletingLastPathComponent().path)) · l'original n'a pas changé")
                            .font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    Spacer()
                    Button("Afficher dans le Finder") { model.revealSaved() }.buttonStyle(SoftButtonStyle())
                    Button("Ouvrir") { model.openSaved() }.buttonStyle(SoftButtonStyle())
                    Button {
                        model.mailSaved()
                    } label: {
                        Label("Envoyer par e-mail…", systemImage: "envelope")
                    }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .help("Un nouveau message dans Mail, le PDF en pièce jointe : rien ne part sans toi")
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(model)).font(.serif(18)).foregroundStyle(Theme.text)
                        Text("Copie « \(FillSignExport.outputName(doc.name, signed: model.signatureCount > 0)).pdf »"
                             + (model.keepForm && model.canKeepForm ? " · formulaire modifiable" : " · version finale")
                             + " · l'original ne change pas")
                            .font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        model.save()
                    } label: {
                        Label("Enregistrer le PDF", systemImage: model.signatureCount > 0 ? "signature" : "square.and.arrow.down")
                    }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .disabled(!model.hasChanges)
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
    }

    private func title(_ model: FillSignModel) -> String {
        guard model.hasChanges else { return "Rien n'a encore changé" }
        var parts: [String] = []
        if model.signatureCount > 0 { parts.append(Fmt.plural(model.signatureCount, "signature", "signatures")) }
        let others = model.items.count - model.signatureCount
        if others > 0 { parts.append(Fmt.plural(others, "ajout", "ajouts")) }
        if model.fieldCount > 0 { parts.append("\(model.filledCount)/\(model.fieldCount) champs") }
        return parts.joined(separator: " · ")
    }
}
