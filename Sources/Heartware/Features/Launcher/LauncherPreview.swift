import SwiftUI
import AppKit
import Quartz
import UniformTypeIdentifiers

/// The pane next to the results: a Quick Look preview of the selected file, without opening it, and its details.
struct LauncherPreview: View {
    @Environment(AppModel.self) private var app
    var path: String
    @State private var info = LauncherFileInfo()
    /// The file Quick Look shows: follows `path` once the selection rests for a moment (sweeping the list stays fluid).
    @State private var shown: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if Snapshot.isActive || DemoData.isEnabled {
                    LauncherDemoPreview(path: path)
                } else {
                    LauncherQuickLook(url: URL(fileURLWithPath: shown ?? path))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 236)
            .background(RoundedRectangle(cornerRadius: Theme.r(12)).fill(Theme.card))
            .clipShape(RoundedRectangle(cornerRadius: Theme.r(12)))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(12)).strokeBorder(Theme.border, lineWidth: Theme.line))

            // The name, with its icon, can be dragged anywhere: copied there (with the other picked files if it is one).
            HStack(spacing: 8) {
                FileIcon(path: path, size: 22)
                Text((path as NSString).lastPathComponent)
                    .font(.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "hand.draw").font(.ui(11)).foregroundStyle(Theme.text3)
                    .help("Glisse le fichier où tu veux")
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).onChanged { _ in app.launcher.beginFileDrag(path, fromRow: false) })
            // A snapshot never runs the reading task: its fictional details are read right here.
            let info = Snapshot.isActive ? LauncherFileInfo.read(path) : info
            VStack(alignment: .leading, spacing: 5) {
                row("Type", info.kind)
                row(info.isDir ? "Contenu" : "Taille", info.size)
                row("Modifié", info.modified)
                row("Créé", info.created)
                row("Dossier", FS.pretty((path as NSString).deletingLastPathComponent))
            }
            Spacer(minLength: 0)
            Text(info.isDir ? "↩ Ouvrir · ⇥ Entrer · \(app.launcher.scope == .files ? "⌘R" : "⌘↩") Finder · ⌘K Actions" : "↩ Ouvrir · ⌘Y Coup d'œil · ⌘K Actions")
                .font(.ui(10.5)).foregroundStyle(Theme.text3)
        }
        .padding(14)
        .task(id: path) {
            if shown != nil { try? await Task.sleep(nanoseconds: 110_000_000) }
            guard !Task.isCancelled else { return }
            // Another selection: the size of the previous app, if any, stops adding up.
            let ticket = Self.sizeTicket.next()
            shown = path
            // Read off the main thread: a folder of thousands of files, or a disk that is slow to answer, never holds the keys.
            let target = path
            guard let read = await DiskQueue.read({ LauncherFileInfo.read(target) }), !Task.isCancelled, target == path else { return }
            info = read
            guard info.size == "…" else { return }
            // A package (an app): its content is added up in the background, one at a time, only for the latest selection
            // (adding up a big app takes seconds: sweeping the list must not pile them up).
            let bytes: Int64? = await withTaskCancellationHandler {
                await withCheckedContinuation { c in
                    Self.sizes.async {
                        // Stops as soon as another file is selected, or the panel closes.
                        let total = FileSizer.size(of: target) { !Self.sizeTicket.isCurrent(ticket) }
                        c.resume(returning: Self.sizeTicket.isCurrent(ticket) ? total : nil)
                    }
                }
            } onCancel: {
                if Self.sizeTicket.isCurrent(ticket) { Self.sizeTicket.next() }
            }
            if let bytes, !Task.isCancelled, target == path { info.size = Fmt.bytes(bytes) }
        }
    }

    nonisolated private static let sizes = DispatchQueue(label: "heartware.launcher.sizes", qos: .utility)
    nonisolated private static let sizeTicket = LauncherTicket()

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.ui(11)).foregroundStyle(Theme.text3).frame(width: 58, alignment: .leading)
            Text(value.isEmpty ? "—" : value).font(.ui(11.5)).foregroundStyle(Theme.text2)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// What the pane says about a file, read in one call (no content is read).
struct LauncherFileInfo {
    var kind = ""
    var size = ""
    var modified = ""
    var created = ""
    var isDir = false

    static func read(_ path: String) -> LauncherFileInfo {
        if DemoData.isEnabled { return demo(path) }
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                         .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return LauncherFileInfo(kind: "Introuvable") }
        var info = LauncherFileInfo()
        info.kind = v.localizedTypeDescription ?? ""
        info.isDir = v.isDirectory == true && v.isPackage != true
        if info.isDir {
            let count = (try? FileManager.default.contentsOfDirectory(atPath: path))?.filter { !$0.hasPrefix(".") }.count ?? 0
            info.size = Fmt.plural(count, "élément", "éléments")
        } else {
            // An app or another package is a folder for the disk: its real size is the sum of its content.
            info.size = v.isPackage == true ? "…" : Fmt.bytes(Int64(v.fileSize ?? v.totalFileAllocatedSize ?? 0))
        }
        info.modified = v.contentModificationDate.map(stamp) ?? ""
        info.created = v.creationDate.map(stamp) ?? ""
        return info
    }

    private static func stamp(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Fmt.fr))
    }

    /// Fictional but stable details for the demo's fictional files.
    private static func demo(_ path: String) -> LauncherFileInfo {
        let ext = (path as NSString).pathExtension.lowercased()
        let seed = path.utf8.reduce(7) { ($0 &* 31 &+ Int($1)) & 0xFFFFFF }
        let isDir = ext.isEmpty
        let type = UTType(filenameExtension: ext)?.localizedDescription ?? "Dossier"
        let modified = Date().addingTimeInterval(-Double(seed % 40) * 86_400 - Double(seed % 7) * 3600)
        return LauncherFileInfo(kind: isDir ? "Dossier" : type,
                                size: isDir ? Fmt.plural(4 + seed % 30, "élément", "éléments") : Fmt.bytes(Int64(40_000 + seed % 4_000_000)),
                                modified: stamp(modified), created: stamp(modified.addingTimeInterval(-86_400 * 12)), isDir: isDir)
    }
}

/// Quick Look's own view: the same preview as the space bar in the Finder, drawn by macOS.
struct LauncherQuickLook: NSViewRepresentable {
    var url: URL
    /// `.normal` for "Coup d'œil": the whole document, with its own controls.
    var style: QLPreviewViewStyle = .compact

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: style) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// Snapshots cannot draw Quick Look: a sheet of paper or an image-like card stands in for it.
struct LauncherDemoPreview: View {
    var path: String

    var body: some View {
        let ext = (path as NSString).pathExtension.lowercased()
        ZStack {
            if ["jpg", "jpeg", "heic", "png"].contains(ext) {
                LinearGradient(colors: [Color(hex: 0xF2A65A), Color(hex: 0xD9576B), Color(hex: 0x5B4B8A)], startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(hex: 0xFFE3A3).opacity(0.9)).frame(width: 54).offset(y: 18)
                Rectangle().fill(Color(hex: 0x1F2A44)).frame(height: 70).frame(maxHeight: .infinity, alignment: .bottom)
            } else if ext.isEmpty {
                FileIcon(path: path, size: 96)
            } else {
                RoundedRectangle(cornerRadius: Theme.r(4)).fill(Color.white)
                    .frame(width: 150, height: 200)
                    .themedShadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 7) {
                            RoundedRectangle(cornerRadius: Theme.r(2)).fill(Color(hex: 0xD97757)).frame(width: 60, height: 8)
                            ForEach(0..<9, id: \.self) { i in
                                RoundedRectangle(cornerRadius: Theme.r(1.5)).fill(Color.black.opacity(0.16))
                                    .frame(width: i % 3 == 2 ? 80 : 118, height: 5)
                            }
                            RoundedRectangle(cornerRadius: Theme.r(2)).fill(Color.black.opacity(0.08)).frame(width: 118, height: 34)
                        }
                        .padding(14)
                    }
            }
        }
    }
}

/// The demo's fictional home: what the launcher finds when Camille types.
enum LauncherDemoFiles {
    static var paths: [(path: String, isDir: Bool)] {
        let h = FS.home
        let dirs = ["Documents", "Documents/Factures", "Documents/Factures/2026", "Documents/Atelier", "Documents/Atelier/Boussole",
                    "Desktop", "Downloads", "Pictures/Vacances Bretagne", "Developer/boussole-web", "Documents/Administratif"]
        let files = [
            "Documents/Factures/2026/Facture EDF mars 2026.pdf", "Documents/Factures/2026/Facture Orange avril 2026.pdf",
            "Documents/Factures/2026/Facture Atelier Lumen.pdf", "Documents/Factures/Facture plombier 2025.pdf",
            "Documents/Atelier/Boussole/Maquettes Boussole v3.fig", "Documents/Atelier/Boussole/Brief Boussole.docx",
            "Documents/Atelier/Devis Atelier Lumen.pdf", "Documents/Atelier/Planning printemps.numbers",
            "Desktop/Présentation client.key", "Desktop/Notes réunion lundi.md", "Downloads/rapport-annuel-2025.pdf",
            "Downloads/Formulaire inscription.pdf", "Pictures/Vacances Bretagne/Falaises au coucher du soleil.heic",
            "Pictures/Vacances Bretagne/Plage de Pen Hat.jpg", "Developer/boussole-web/README.md",
            "Documents/Administratif/Attestation assurance habitation.pdf", "Documents/Administratif/Avis d'imposition 2026.pdf",
            "Documents/Rapport d'activité 2025.pages", "Documents/CV Camille Martin.pdf"
        ]
        return dirs.map { (h + "/" + $0, true) } + files.map { (h + "/" + $0, false) }
    }

    /// What Camille opened lately: the file window's first screen.
    static var recent: [(path: String, isDir: Bool)] {
        ["Desktop/Notes réunion lundi.md", "Documents/Atelier/Boussole/Maquettes Boussole v3.fig", "Documents/Atelier/Devis Atelier Lumen.pdf",
         "Downloads/rapport-annuel-2025.pdf", "Documents/Atelier/Planning printemps.numbers", "Pictures/Vacances Bretagne/Plage de Pen Hat.jpg",
         "Desktop/Présentation client.key"].map { (FS.home + "/" + $0, false) }
    }
}
