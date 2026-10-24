import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The souvenir photo: its portrait in its room, its name, its stage, its days with the user and what they did together.
/// Made on this Mac only when the user clicks, to keep or to share. At the end of the year, « Ton année avec … ».
struct RefugeSouvenirCard: View {
    static let size = CGSize(width: 640, height: 360)
    var model: RefugeModel
    var freed: Int64
    var now = Date()

    var body: some View {
        let s = model.state
        let year = model.events(now: now).contains(.finAnnee)
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Rectangle().fill(Theme.track)
                Canvas { ctx, size in
                    let c = Theme.mascot
                    // The window behind it, the floor under it.
                    ctx.fill(Path(CGRect(x: 30, y: 36, width: 120, height: 96)), with: .color(c.woodShade))
                    ctx.fill(Path(CGRect(x: 38, y: 44, width: 104, height: 80)), with: .color(c.sky))
                    var mountain = Path()
                    mountain.move(to: CGPoint(x: 38, y: 124))
                    mountain.addLine(to: CGPoint(x: 80, y: 74))
                    mountain.addLine(to: CGPoint(x: 104, y: 98))
                    mountain.addLine(to: CGPoint(x: 120, y: 82))
                    mountain.addLine(to: CGPoint(x: 142, y: 108))
                    mountain.addLine(to: CGPoint(x: 142, y: 124))
                    mountain.closeSubpath()
                    ctx.fill(mountain, with: .color(c.mountain))
                    ctx.fill(Path(CGRect(x: 0, y: size.height - 48, width: size.width, height: 48)), with: .color(c.wood))
                }
                RefugeAvatar(look: model.look(now: now), pixel: 13, animated: false)
                    .padding(.bottom, 36)
            }
            .frame(width: 280)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(year ? "Ton année avec" : "Souvenir du Refuge").font(.ui(11, .semibold)).tracking(0.8).foregroundStyle(Theme.text3)
                    Text(s.name).font(.serif(40)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.6)
                    Text("\(s.stage.title) · jour \(RefugeRules.dayNumber(s, now: now))").font(.ui(14)).foregroundStyle(Theme.text2)
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    GridRow {
                        stat(Fmt.int(s.eaten), "myrtilles mangées")
                        stat(Fmt.bytes(freed), "libérés ensemble")
                    }
                    GridRow {
                        stat("\(s.daysTogether)", s.daysTogether > 1 ? "jours ensemble" : "jour ensemble")
                        stat("\(s.badges.count)", s.badges.count > 1 ? "médailles" : "médaille")
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    BrandMark(size: 22, ornament: false)
                    Text("Chamois").font(.serif(15)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(Fmt.day(now)).font(.ui(11)).foregroundStyle(Theme.text3)
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.card)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.serif(24)).foregroundStyle(Theme.text)
            Text(label).font(.ui(11)).foregroundStyle(Theme.text3)
        }
    }

    /// The card as a PNG, twice the size for sharp edges.
    @MainActor
    static func png(model: RefugeModel, freed: Int64) -> Data? {
        let renderer = ImageRenderer(content: RefugeSouvenirCard(model: model, freed: freed))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// The souvenir photo on the page, as a polaroid pinned a little askew, and what to do with it.
struct RefugePolaroid: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.refuge
        let year = m.events().contains(.finAnnee)
        VStack(alignment: .leading, spacing: 10) {
            RefugeSectionTitle(title: year ? "Ton année avec \(m.name)" : "La photo souvenir",
                               subtitle: "Faite sur ce Mac, seulement quand tu cliques. À garder ou à partager.")
            HStack(alignment: .center, spacing: 22) {
                VStack(spacing: 8) {
                    RefugeSouvenirCard(model: m, freed: app.history.totalFreed, now: m.clock)
                        .scaleEffect(0.5, anchor: .topLeading)
                        .frame(width: RefugeSouvenirCard.size.width / 2, height: RefugeSouvenirCard.size.height / 2, alignment: .topLeading)
                        .clipped()
                    Text("\(m.name), jour \(m.day)").font(.serif(15).italic()).foregroundStyle(Theme.mascot.horn)
                        .padding(.bottom, 4)
                }
                .padding(10)
                .background(Rectangle().fill(Theme.mascot.prop("creme")))
                .themedShadow(color: .black.opacity(0.2), radius: 8, y: 4)
                .rotationEffect(.degrees(-2.5))
                .padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 10) {
                    Button { copy(m) } label: { ThemedLabel(title: "Copier l'image", symbol: "doc.on.doc") }
                        .buttonStyle(SoftButtonStyle(prominent: true))
                    Button { save(m) } label: { ThemedLabel(title: "Enregistrer…", symbol: "square.and.arrow.down") }
                        .buttonStyle(SoftButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy(_ m: RefugeModel) {
        guard !DemoData.isEnabled else { HUD.show(DemoData.refusal, symbol: "xmark.octagon.fill"); return }
        guard let png = RefugeSouvenirCard.png(model: m, freed: app.history.totalFreed) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        m.photoTaken()
        HUD.show("Photo de \(m.name) copiée", symbol: "camera")
    }

    private func save(_ m: RefugeModel) {
        guard !DemoData.isEnabled else { HUD.show(DemoData.refusal, symbol: "xmark.octagon.fill"); return }
        guard let png = RefugeSouvenirCard.png(model: m, freed: app.history.totalFreed) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(m.name), jour \(m.day).png"
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let saved = try FileOps.write(png, to: url)
            m.photoTaken()
            HUD.show("Enregistrée : \(saved.lastPathComponent)", symbol: "camera")
            NSWorkspace.shared.activateFileViewerSelecting([saved])
        } catch {
            HUD.show(error.localizedDescription, symbol: "xmark.octagon.fill")
        }
    }
}
