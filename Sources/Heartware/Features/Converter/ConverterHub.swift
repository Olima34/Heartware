import SwiftUI
import AppKit

/// The Convertisseur's window: one at a time, glass like the wheel's small windows, next to where the files were dropped
/// (in the middle of the screen when they came from elsewhere). It stays open, for another operation, until closed (× or Esc).
@MainActor
final class ConverterHub {
    static let size = NSSize(width: 860, height: 620)
    private var panel: WheelWindow?

    var isOpen: Bool { panel?.isVisible == true }
    var frame: NSRect? { isOpen ? panel?.frame : nil }
    var center: NSPoint? { frame.map { NSPoint(x: $0.midX, y: $0.midY) } }

    func show(_ model: ConverterModel, near point: NSPoint?) {
        guard !Snapshot.isActive, let app = AppContext.model else { return }
        let p = panel ?? make(model, app)
        panel = p
        if p.isVisible {
            p.makeKeyAndOrderFront(nil)
        } else if let point {
            p.present(near: point)
        } else {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            let f = screen?.visibleFrame ?? .zero
            p.present(near: NSPoint(x: f.midX, y: f.midY))
        }
    }

    func close() {
        panel?.close()
    }

    private func make(_ model: ConverterModel, _ app: AppModel) -> WheelWindow {
        let w = WheelWindow(size: Self.size)
        w.onClose = { [weak model] in DispatchQueue.main.async { model?.closed() } }
        w.setContent(ConverterHubView(model: model) { [weak w] in w?.close() }
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(app))
        return w
    }
}

/// The inside of the window: the files at the top, every operation on the left, the settings and the preview of the one
/// chosen on the right, where the copies go and the main button at the bottom.
struct ConverterHubView: View {
    @Bindable var model: ConverterModel
    var close: () -> Void
    @State private var targeted = false

    static let tip = HelpTip(
        id: "converter.window", title: "La fenêtre du Convertisseur",
        text: "À gauche, tout ce que tu peux faire de ces fichiers. Choisis : ses réglages et l'aperçu du résultat s'affichent à droite. Rien n'est écrit avant le bouton en bas.",
        steps: ["Dépose d'autres fichiers sur la fenêtre pour les ajouter.",
                "Les opérations marquées d'une petite fenêtre s'ouvrent à part (recadrer, annoter, signer…).",
                "En bas à gauche : où vont les copies. Annuler, dans la bulle qui suit, les met à la Corbeille."])

    var body: some View {
        WheelWindowChrome(title: "Convertisseur", subtitle: subtitle, close: close, tip: Self.tip) {
            VStack(spacing: 12) {
                // Without any file, the big drop zone on the right is enough (a QR code keeps this one, to add files).
                if !model.files.isEmpty || model.makingQR { ConverterHubFiles(model: model, targeted: targeted) }
                HStack(alignment: .top, spacing: 0) {
                    ConverterHubList(model: model)
                        .frame(width: 214)
                    Rectangle().fill(Theme.border).frame(width: Theme.line).padding(.horizontal, 14)
                    ConverterHubDetail(model: model)
                }
            }
            .padding(.top, 2)
        } footer: {
            if writesCopies { WheelDestinationMenu() }
            Spacer(minLength: 10)
            if model.makingQR || !model.files.isEmpty {
                Text(model.summary).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.tail)
                Button(model.verb) { model.start() }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .disabled(!model.canStart)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .modifier(ConverterDropTarget(targeted: $targeted) { model.add($0) })
    }

    private var subtitle: String? {
        guard !model.files.isEmpty else { return nil }
        return model.files.count == 1 ? model.files[0].name : "\(Fmt.plural(model.files.count, "fichier", "fichiers")) · \(Fmt.bytes(model.totalSize))"
    }

    /// The operation writes a copy somewhere (not a renaming, a text copied, a QR code saved where the user says…).
    private var writesCopies: Bool {
        guard !model.makingQR, let a = model.action else { return false }
        return ![.rename, .airdrop, .copyPath, .copyText, .qrRead, .sign].contains(a)
    }
}

// MARK: - Files

/// The files, side by side; more can be dropped on the window or added with « + ».
struct ConverterHubFiles: View {
    @Bindable var model: ConverterModel
    var targeted: Bool

    var body: some View {
        if model.files.isEmpty {
            Button(action: choose) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle").font(.ui(12, .medium))
                    Text("Dépose des fichiers ici, ou clique pour les choisir").font(.ui(12))
                }
                .foregroundStyle(targeted ? Theme.accent : Theme.text2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: Theme.r(12)).fill(targeted ? Theme.accent.opacity(0.08) : Theme.card.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: Theme.r(12))
                    .strokeBorder(targeted ? Theme.accent : Theme.borderStrong, style: StrokeStyle(lineWidth: Theme.line, dash: [5, 4])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 6) {
                ConverterScroll(axes: .horizontal) {
                    HStack(spacing: 6) {
                        ForEach(model.files) { f in
                            ConverterHubFileChip(model: model, file: f, ignored: model.operation.map { !$0.accepts.contains(f.kind) && $0 != .rename } ?? false)
                        }
                    }
                }
                .frame(height: 34)
                Button(action: choose) {
                    Image(systemName: "plus")
                        .font(.ui(11, .semibold))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(Theme.track.opacity(0.8)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Ajouter des fichiers")
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: Theme.r(12)).fill(targeted ? Theme.accent.opacity(0.08) : Theme.card.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(12)).strokeBorder(targeted ? Theme.accent : Theme.border, lineWidth: Theme.line))
        }
    }

    private func choose() {
        guard !Snapshot.isActive else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Ajouter"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { model.add(panel.urls) }
    }
}

struct ConverterHubFileChip: View {
    let model: ConverterModel
    var file: ConverterFile
    var ignored: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            FileIcon(path: file.url.path, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name).font(.ui(11.5, .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Text(details).font(.ui(10)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            .frame(maxWidth: 150, alignment: .leading)
            Button { model.remove(file) } label: {
                Image(systemName: "xmark").font(.ui(8.5, .bold)).foregroundStyle(Theme.text3)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Retirer de la liste")
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(Theme.card.opacity(hovering ? 1 : 0.75)))
        .opacity(ignored ? 0.45 : 1)
        .onHover { hovering = $0 }
        .help(ignored ? "Pas concerné par cette opération" : file.url.path)
    }

    private var details: String {
        var parts = [file.kind == .folder ? "Dossier" : (file.ext.isEmpty ? file.kind.title : file.ext)]
        if let d = file.detail { parts.append(d) }
        if file.size > 0 { parts.append(Fmt.bytes(file.size)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Operations

/// Every operation, in sections. Those with a small window of their own are marked: they open it.
struct ConverterHubList: View {
    @Bindable var model: ConverterModel

    var body: some View {
        ConverterScroll {
            VStack(alignment: .leading, spacing: 1) {
                if model.files.isEmpty {
                    SectionLabel(text: "Sans fichier")
                    ConverterHubRow(title: "Créer un QR code", symbol: "qrcode", tint: ConverterFamily.vision.tint, selected: model.makingQR,
                                    window: false) { model.makeQR() }
                } else {
                    let fam = model.family
                    ForEach(model.sections, id: \.group) { section in
                        SectionLabel(text: section.group.title)
                        ForEach(section.actions) { a in
                            ConverterHubRow(title: a.title(count: model.files.count, family: fam), symbol: a.symbol, tint: a.tint,
                                            selected: model.action == a, window: a.opensWindow && a.hubOperation(fam) == nil) {
                                model.select(a)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 6)
        }
    }
}

struct ConverterHubRow: View {
    var title: String
    var symbol: String
    var tint: Color
    var selected: Bool
    /// Opens its own window.
    var window: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IconBadge(symbol: symbol, tint: tint, size: 20)
                Text(title).font(.ui(12, selected ? .semibold : .medium)).foregroundStyle(selected ? Theme.text : Theme.text2).lineLimit(1)
                Spacer(minLength: 2)
                if window { Image(systemName: "macwindow").font(.ui(9.5)).foregroundStyle(Theme.text3) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(selected ? Theme.accent.opacity(0.16) : (hovering ? Theme.hover.opacity(0.6) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(window ? "S'ouvre dans sa propre fenêtre" : "")
    }
}

// MARK: - Settings and preview

/// The operation chosen: its name, its settings, the preview of its result.
struct ConverterHubDetail: View {
    @Bindable var model: ConverterModel

    var body: some View {
        Group {
            if model.makingQR {
                ConverterQRCreator(model: model)
            } else if model.files.isEmpty {
                DropZone(title: dropTitle, subtitle: model.wanted.map { "\($0.commandTitle) · ou clique pour les choisir" } ?? "ou clique pour les choisir",
                         symbol: model.wanted?.symbol ?? "square.and.arrow.down.on.square", allowsFolders: true) { model.add($0) }
            } else if let action = model.action {
                detail(action)
            } else {
                EmptyHint(text: "Choisis à gauche ce que tu veux faire.", symbol: "hand.point.left")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var dropTitle: String {
        guard let op = model.wanted else { return "Dépose tes fichiers ici" }
        switch op.family {
        case .images: return "Dépose des images ici"
        case .videos: return "Dépose des vidéos ici"
        case .audio: return "Dépose des fichiers audio ici"
        case .pdf: return op == .pdfMerge ? "Dépose les PDF ici" : "Dépose un PDF ici"
        case .documents: return "Dépose des documents ici"
        case .files: return op == .archiveExtract ? "Dépose des archives ici" : "Dépose des fichiers ici"
        case .vision: return "Dépose des images ou des PDF ici"
        }
    }

    private func detail(_ action: WheelAction) -> some View {
        let fam = model.family
        return ConverterScroll {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title).font(.serif(20)).foregroundStyle(Theme.text)
                    Text(action.detail).font(.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
                if let message = model.message {
                    ConverterNote(symbol: "info.circle", text: message, tint: Theme.warn)
                }
                if let op = model.operation {
                    if action.runsWithOptions(fam) { ConverterOptionsForm(model: model, op: op) }
                    if op == .rename {
                        ConverterRenameList(model: model)
                    } else if ConverterPreviewer.previews(op) {
                        ConverterPreviewPanel(model: model, height: ConverterPreviewer.usesPiece(op) ? 200 : 220)
                    }
                } else {
                    ConverterHubAtOnce(model: model, action: action)
                }
            }
            .padding(.bottom, 6)
        }
    }
}

/// An operation with nothing to set: the file, and what it becomes.
struct ConverterHubAtOnce: View {
    let model: ConverterModel
    var action: WheelAction

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                ForEach(Array(model.files.prefix(3).enumerated()), id: \.offset) { i, f in
                    FileIcon(path: f.url.path, size: 72)
                        .offset(x: CGFloat(i) * 10, y: CGFloat(i) * -6)
                }
            }
            .frame(width: 100, height: 90)
            Image(systemName: "arrow.right").font(.ui(16, .semibold)).foregroundStyle(Theme.text3)
            Image(systemName: action.symbol)
                .font(.ui(30, .light))
                .foregroundStyle(action.tint)
                .frame(width: 84, height: 84)
                .background(RoundedRectangle(cornerRadius: Theme.r(20), style: .continuous).fill(action.tint.opacity(0.12)))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}

// MARK: - QR code

/// A QR code drawn as the text is typed.
struct ConverterQRCreator: View {
    @Bindable var model: ConverterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Créer un QR code").font(.serif(20)).foregroundStyle(Theme.text)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    ConverterTextField(text: $model.qrText, prompt: "https://… ou n'importe quel texte", symbol: "text.cursor")
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ConverterChip(title: "Lien", symbol: "link", selected: false) { model.qrText = "https://" }
                        ConverterChip(title: "Wi-Fi", symbol: "wifi", selected: false) { model.qrText = "WIFI:T:WPA;S:NomDuRéseau;P:MotDePasse;;" }
                        ConverterChip(title: "E-mail", symbol: "envelope", selected: false) { model.qrText = "mailto:prenom@exemple.fr" }
                        ConverterChip(title: "Téléphone", symbol: "phone", selected: false) { model.qrText = "tel:+33600000000" }
                        ConverterChip(title: "SMS", symbol: "message", selected: false) { model.qrText = "SMSTO:+33600000000:Bonjour !" }
                    }
                    let bytes = model.qrText.utf8.count
                    Text(bytes > ConverterVision.qrCapacity ? "Trop long : \(Fmt.int(bytes)) octets sur \(Fmt.int(ConverterVision.qrCapacity))."
                                                            : "\(Fmt.int(bytes)) octets sur \(Fmt.int(ConverterVision.qrCapacity))")
                        .font(.ui(11)).foregroundStyle(bytes > ConverterVision.qrCapacity ? Theme.warn : Theme.text3)
                }
                VStack(spacing: 10) {
                    ZStack {
                        // A QR code needs a light margin to be scanned, whatever the theme: white under the code only.
                        RoundedRectangle(cornerRadius: Theme.r(12)).fill(model.qrImage == nil ? Theme.bg.opacity(0.6) : Color.white)
                        if let image = model.qrImage {
                            Image(decorative: image, scale: 1).resizable().interpolation(.none).scaledToFit().padding(6)
                        } else {
                            Image(systemName: "qrcode").font(.ui(40, .light)).foregroundStyle(Theme.text3)
                        }
                    }
                    .frame(width: 190, height: 190)
                    Button("Copier l'image") { model.copyQR() }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .disabled(model.qrImage == nil)
                }
            }
        }
    }
}
