import SwiftUI
import AppKit

/// The signatures and initials kept on this Mac, next to the page they go on: new ones (drawn, typed or imported),
/// a click to put one on the document, the bin (or a right click) to forget one.
struct FillSignSignaturesPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.fillSign
        VStack(alignment: .leading, spacing: 12) {
            group("Signatures", model.signatures.filter { $0.kind == .signature }, kind: .signature)
            group("Paraphes", model.signatures.filter { $0.kind == .initials }, kind: .initials)
        }
    }

    private func group(_ title: String, _ list: [FillSignSignature], kind: FillSignSignature.Kind) -> some View {
        let model = app.fillSign
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.ui(10, .semibold)).tracking(0.6).foregroundStyle(Theme.text3)
                Spacer()
                Button {
                    model.newSignature(kind)
                } label: {
                    Label(kind == .signature ? "Nouvelle" : "Nouveau", systemImage: "plus").font(.ui(11, .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            if list.isEmpty {
                Text(kind == .signature ? "Aucune pour l'instant." : "Aucun pour l'instant.")
                    .font(.ui(11.5)).foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(list) { sig in
                    FillSignSignatureTile(signature: sig, armed: model.armed?.id == sig.id, height: 44)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A kept signature: a click puts it on the document (the next click on the page places it).
struct FillSignSignatureTile: View {
    @Environment(AppModel.self) private var app
    var signature: FillSignSignature
    var armed: Bool
    var height: CGFloat = 54
    @State private var hovering = false

    var body: some View {
        let model = app.fillSign
        let aspect = signature.size.width / max(1, signature.size.height)
        let w = min(signature.kind == .initials ? 90 : 210, max(48, (height - 12) * aspect))
        Button {
            if model.document != nil { model.arm(signature) }
        } label: {
            FillSignSignatureView(signature: signature)
                .frame(width: w, height: min(max(w / aspect, 10), height - 12))
                .frame(width: w + 20, height: height)
                // The signature is shown on paper, as it will be on the document.
                .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: Theme.r(8)).strokeBorder(armed ? Theme.accent : Theme.border, lineWidth: armed ? 2 : Theme.line))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hovering && !Snapshot.isActive {
                Button { model.deleteSignature(signature) } label: {
                    Image(systemName: "trash").font(.ui(9.5, .semibold)).foregroundStyle(Theme.onBad)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Theme.bad))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .help("Supprimer")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(signature.kind == .signature ? "Supprimer cette signature…" : "Supprimer ce paraphe…") { model.deleteSignature(signature) }
        }
        .help("Clique, puis clique sur la page pour la placer")
    }
}

/// A signature drawn at the size it is given (strokes, script text or picture).
struct FillSignSignatureView: View {
    var signature: FillSignSignature

    var body: some View {
        GeometryReader { g in
            let rect = CGRect(origin: .zero, size: g.size)
            switch signature.style {
            case .drawn(let strokes, let width):
                Path(FillSignDraw.strokesPath(strokes, natural: signature.size, in: rect))
                    .stroke(signature.ink.color, style: StrokeStyle(lineWidth: FillSignDraw.penWidth(width, natural: signature.size, in: rect),
                                                                    lineCap: .round, lineJoin: .round))
            case .typed(let text, let font):
                let layout = FillSignDraw.typedLayout(text, font: font)
                let k = g.size.width / max(1, layout.size.width)
                Text(text)
                    .font(.custom(font, size: FillSignDraw.typedSize * k))
                    .foregroundStyle(signature.ink.color)
                    .fixedSize()
                    .position(x: g.size.width / 2, y: g.size.height / 2)
            case .image(let png):
                if let image = NSImage(data: png) {
                    Image(nsImage: image).resizable().interpolation(.high)
                }
            }
        }
    }
}
