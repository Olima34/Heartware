import SwiftUI
import AppKit

/// A new signature or initials, over the page: drawn with the mouse or the trackpad, typed in a script font, or imported
/// from a photo of a signature on paper.
struct FillSignPadOverlay: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.fillSign
        if let pad = model.pad {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.black.opacity(0.32))
                    .contentShape(Rectangle())
                    .onTapGesture {}
                card(pad)
                    .padding(.top, 70)
            }
            .onExitCommand { model.pad = nil }
        }
    }

    private func card(_ pad: FillSignPad) -> some View {
        let model = app.fillSign
        let kinds: [FillSignSignature.Kind] = [.signature, .initials]
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(pad.kind == .signature ? "Nouvelle signature" : "Nouveau paraphe").font(.serif(24)).foregroundStyle(Theme.text)
                Spacer()
                HStack(spacing: 2) {
                    ForEach(kinds, id: \.self) { k in
                        let on = pad.kind == k
                        Button { model.pad?.kind = k } label: {
                            Text(k.title).font(.ui(12, on ? .semibold : .regular))
                                .foregroundStyle(on ? Theme.text : Theme.text2)
                                .padding(.horizontal, 11).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: Theme.r(7)).fill(on ? Theme.selected : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: Theme.r(9)).fill(Theme.bg))
            }
            PillPicker(options: FillSignPad.Mode.allCases,
                       selection: Binding(get: { model.pad?.mode ?? .draw }, set: { model.pad?.mode = $0 }), label: \.title)
            Group {
                switch pad.mode {
                case .draw:
                    FillSignDrawArea(strokes: Binding(get: { model.pad?.strokes ?? [] }, set: { model.pad?.strokes = $0 }), ink: pad.ink)
                case .type:
                    FillSignTypeArea()
                case .image:
                    imageArea(pad)
                }
            }
            .frame(width: FillSignPad.size.width, height: FillSignPad.size.height)
            .background(RoundedRectangle(cornerRadius: Theme.r(10)).fill(Color.white))
            .clipShape(RoundedRectangle(cornerRadius: Theme.r(10)))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(10)).strokeBorder(Theme.border, lineWidth: Theme.line))
            if pad.mode == .type {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(FillSignDraw.scriptFonts, id: \.name) { f in
                        let on = pad.font == f.name
                        Button { model.pad?.font = f.name } label: {
                            Text(pad.text.isEmpty ? f.title : pad.text)
                                .font(.custom(f.name, size: 17))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .frame(height: 26)
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .frame(maxWidth: 170)
                                .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(on ? Theme.selected : Theme.bg))
                                .overlay(RoundedRectangle(cornerRadius: Theme.r(8)).strokeBorder(on ? Theme.accent : Theme.border, lineWidth: on ? 1.5 : Theme.line))
                        }
                        .buttonStyle(.plain)
                        .help(f.title)
                    }
                }
            }
            HStack(spacing: 8) {
                if pad.mode != .image {
                    Text("Encre").font(.ui(12)).foregroundStyle(Theme.text2)
                    ForEach(FillSignInk.allCases) { ink in
                        Button { model.pad?.ink = ink } label: {
                            Circle().fill(ink.color).frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Theme.borderStrong, lineWidth: Theme.line))
                                .padding(3)
                                .overlay(Circle().strokeBorder(pad.ink == ink ? Theme.accent : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .help(ink.title)
                    }
                }
                Spacer()
                Button("Effacer") {
                    model.pad?.strokes = []
                    model.pad?.text = ""
                    model.pad?.image = nil
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(pad.signature == nil)
                Button("Annuler") { model.pad = nil }.buttonStyle(SoftButtonStyle())
                Button(pad.placeAt != nil ? "Enregistrer et placer" : "Enregistrer") { model.savePad() }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .disabled(pad.signature == nil)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "lock").font(.ui(10.5)).foregroundStyle(Theme.text3)
                Text("Gardée sur ce Mac seulement, pour la prochaine fois.")
                    .font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(width: FillSignPad.size.width + 44)
        .background(RoundedRectangle(cornerRadius: Theme.r(16), style: .continuous).fill(Theme.cardRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(16), style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: Theme.line))
        .themedShadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }

    @ViewBuilder
    private func imageArea(_ pad: FillSignPad) -> some View {
        let model = app.fillSign
        if let image = pad.image, let ns = NSImage(data: image.png) {
            let aspect = image.size.width / max(1, image.size.height)
            let h = min(FillSignPad.size.height - 30, (FillSignPad.size.width - 60) / aspect)
            Image(nsImage: ns).resizable().interpolation(.high)
                .frame(width: h * aspect, height: h)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    Button("Autre image…") { model.importPadImage() }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .padding(10)
                }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "photo.badge.plus").font(.system(size: 26, weight: .light)).foregroundStyle(Color.black.opacity(0.45))
                Button("Choisir une photo de ta signature…") { model.importPadImage() }
                    .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                Text("Signe sur une feuille blanche et prends-la en photo bien à plat : le blanc devient transparent.")
                    .font(.ui(11)).foregroundStyle(Color.black.opacity(0.55)).multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Where the signature is drawn: a line to sign on, strokes smoothed as they come.
struct FillSignDrawArea: View {
    @Binding var strokes: [[CGPoint]]
    var ink: FillSignInk
    @State private var current: [CGPoint] = []

    var body: some View {
        let size = FillSignPad.size
        let rect = CGRect(origin: .zero, size: size)
        ZStack(alignment: .topLeading) {
            // A paper guide (document side: the same on every theme).
            Path { p in
                p.move(to: CGPoint(x: 34, y: size.height * 0.72))
                p.addLine(to: CGPoint(x: size.width - 34, y: size.height * 0.72))
            }
            .stroke(Color.black.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            Text("✕").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.black.opacity(0.35))
                .position(x: 24, y: size.height * 0.72 - 9)
            if strokes.isEmpty && current.isEmpty {
                Text("Signe ici avec la souris ou le trackpad (clic maintenu)")
                    .font(.ui(12)).foregroundStyle(Color.black.opacity(0.4))
                    .position(x: size.width / 2, y: size.height * 0.72 + 22)
            }
            Path(FillSignDraw.strokesPath(strokes + [current], natural: size, in: rect))
                .stroke(ink.color, style: StrokeStyle(lineWidth: FillSignPad.pen, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                let p = CGPoint(x: min(max(0, v.location.x), size.width), y: min(max(0, v.location.y), size.height))
                if let last = current.last, hypot(last.x - p.x, last.y - p.y) < 1 { return }
                current.append(p)
            }
            .onEnded { _ in
                if !current.isEmpty { strokes.append(FillSignDraw.thinned(current)) }
                current = []
            })
    }
}

/// The name typed, shown in the chosen script font.
struct FillSignTypeArea: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        let model = app.fillSign
        let pad = model.pad ?? FillSignPad(kind: .signature)
        VStack(spacing: 6) {
            Group {
                if Snapshot.isActive {
                    Text(pad.text.isEmpty ? (pad.kind == .signature ? "Prénom Nom" : "Initiales") : pad.text)
                        .foregroundStyle(pad.text.isEmpty ? Color.black.opacity(0.35) : pad.ink.color)
                } else {
                    TextField(pad.kind == .signature ? "Prénom Nom" : "Initiales",
                              text: Binding(get: { model.pad?.text ?? "" }, set: { model.pad?.text = String($0.prefix(60)) }))
                        .textFieldStyle(.plain)
                        .foregroundStyle(pad.ink.color)
                        .focused($focused)
                        .onAppear { focused = true }
                }
            }
            .font(.custom(pad.font, size: pad.kind == .signature ? 40 : 46))
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Color.black.opacity(0.18)).frame(height: 1).padding(.horizontal, 34).padding(.bottom, 34)
        }
    }
}
