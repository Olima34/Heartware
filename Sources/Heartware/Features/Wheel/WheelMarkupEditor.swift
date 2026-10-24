import SwiftUI

/// « Annoter » and « Masquer » : marks drawn on the picture with the mouse, then saved into a copy.
/// Annoter: arrows, boxes, circles, highlighter, text, numbered steps and a pen, in eight inks and three widths.
/// Masquer: boxes in black, blur or pixels, and a search for faces, e-mail addresses, phone, card and IBAN numbers.
struct WheelMarkupEditor: View {
    let context: WheelEditorContext
    let redacting: Bool
    @State private var preview: WheelPreview
    @State private var marks: [WheelMark]
    @State private var current: WheelMark?
    @State private var tool: WheelMark.Kind
    @State private var ink = 0
    @State private var thickness: WheelThickness = .medium
    @State private var redaction: WheelRedaction = .black
    @State private var layers: WheelRedactionLayers?
    @State private var editing: UUID?
    @State private var draft = ""
    @State private var searching: String?
    @State private var found: String?
    @FocusState private var typing: Bool

    init(context: WheelEditorContext, redacting: Bool) {
        self.context = context
        self.redacting = redacting
        let preview = WheelPreview(context.file.url)
        _preview = State(initialValue: preview)
        _tool = State(initialValue: redacting ? .redact : .arrow)
        // Snapshots draw once, without waiting for the blurred and pixelated pictures.
        if Snapshot.isActive && redacting, let p = preview.picture {
            _layers = State(initialValue: WheelImageEngine.redactionLayers(p.image))
        }
        _marks = State(initialValue: DemoData.isEnabled ? WheelDemo.marks(redacting: redacting) : [])
    }

    var body: some View {
        WheelWindowChrome(title: redacting ? "Masquer des zones" : "Annoter", subtitle: context.file.name, close: context.close) {
            VStack(alignment: .leading, spacing: 12) {
                toolbar
                WheelPictureView(preview: preview) { size in canvas(size) }
                    .frame(maxHeight: .infinity)
                if redacting { finder } else { inks }
            }
            .padding(.bottom, 2)
        } footer: {
            Button { undo() } label: { ThemedLabel(title: "Annuler", symbol: "arrow.uturn.backward") }
                .buttonStyle(SoftButtonStyle())
                .keyboardShortcut("z", modifiers: .command)
                .disabled(marks.isEmpty)
            Button("Tout effacer") { marks.removeAll(); editing = nil }
                .buttonStyle(SoftButtonStyle())
                .disabled(marks.isEmpty)
            Spacer()
            Button { save() } label: { Text("Enregistrer la copie") }
                .buttonStyle(SoftButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(preview.picture == nil || marks.allSatisfy(\.isEmpty))
        }
        .onAppear { preview.start(); prepareLayers() }
        .onChange(of: preview.picture?.width) { _, _ in prepareLayers() }
    }

    // MARK: Tools

    private var toolbar: some View {
        HStack(spacing: 8) {
            if redacting {
                WheelFieldLabel(text: "Masquer en")
                WheelChips(options: WheelRedaction.allCases, selection: $redaction, label: \.title)
            } else {
                WheelChips(options: [.arrow, .box, .oval, .highlight, .text, .step, .pen], selection: $tool,
                           label: \.title, symbol: { $0.symbol })
            }
            Spacer(minLength: 0)
        }
    }

    private var inks: some View {
        HStack(spacing: 7) {
            ForEach(WheelInk.all.indices, id: \.self) { i in
                Button { ink = i } label: {
                    Circle().fill(WheelInk.color(i))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                        .frame(width: 16, height: 16)
                        .padding(2.5)
                        .overlay(Circle().strokeBorder(ink == i ? Theme.accent : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(WheelInk.names[i])
            }
            Spacer()
            WheelChips(options: WheelThickness.allCases, selection: $thickness, label: \.title)
        }
    }

    private var finder: some View {
        HStack(spacing: 8) {
            WheelSmallButton(title: "Visages", symbol: "faceid") { detect(faces: true) }
            WheelSmallButton(title: "E-mails et numéros", symbol: "at") { detect(faces: false) }
            if let searching {
                BusyMascot(.inspecting, pixel: 1)
                Text(searching).font(.ui(11)).foregroundStyle(Theme.text3)
            } else if let found {
                Text(found).font(.ui(11)).foregroundStyle(Theme.text3)
            } else {
                Text("ou trace des cadres à la souris").font(.ui(11)).foregroundStyle(Theme.text3)
            }
            Spacer()
        }
    }

    // MARK: Canvas

    private func canvas(_ size: CGSize) -> some View {
        let shown = marks + (current.map { [$0] } ?? [])
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, s in
                ctx.withCGContext { cg in
                    WheelMarkRenderer.draw(shown.filter { $0.id != editing }, in: cg, size: s, layers: layers)
                }
            }
            if let id = editing, let mark = marks.first(where: { $0.id == id }), let a = mark.points.first {
                let fontSize = max(10, mark.width * max(size.width, size.height) * 5.5)
                TextField("Ton texte", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(WheelInk.color(mark.color))
                    .focused($typing)
                    .frame(minWidth: 80, maxWidth: size.width - a.x * size.width, alignment: .topLeading)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .offset(x: a.x * size.width - 2, y: a.y * size.height - 2)
                    .onSubmit { commitText() }
            }
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in drag(v, size) }.onEnded { v in end(v, size) })
        }
        .frame(width: size.width, height: size.height)
    }

    private func unit(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, p.x / size.width), 1), y: min(max(0, p.y / size.height), 1))
    }

    private var activeTool: WheelMark.Kind { redacting ? .redact : tool }

    private func drag(_ v: DragGesture.Value, _ size: CGSize) {
        if editing != nil { commitText() }
        let start = unit(v.startLocation, size), now = unit(v.location, size)
        let kind = activeTool
        guard kind != .text && kind != .step else { return }
        if current == nil {
            current = WheelMark(kind: kind, points: [start], color: ink, width: thickness.value, redaction: redaction)
        }
        if kind == .pen {
            if let last = current?.points.last, hypot(now.x - last.x, now.y - last.y) > 0.002 { current?.points.append(now) }
        } else {
            current?.points = [start, now]
        }
    }

    private func end(_ v: DragGesture.Value, _ size: CGSize) {
        let point = unit(v.startLocation, size)
        switch activeTool {
        case .step:
            let n = (marks.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1
            marks.append(WheelMark(kind: .step, points: [point], color: ink, width: thickness.value, number: n))
        case .text:
            if editing != nil { return }
            let mark = WheelMark(kind: .text, points: [point], color: ink, width: thickness.value)
            marks.append(mark)
            draft = ""
            editing = mark.id
            DispatchQueue.main.async { typing = true }
        default:
            if let c = current, !c.isEmpty { marks.append(c) }
        }
        current = nil
    }

    private func commitText() {
        guard let id = editing, let i = marks.firstIndex(where: { $0.id == id }) else { editing = nil; return }
        marks[i].text = draft
        if marks[i].isEmpty { marks.remove(at: i) }
        editing = nil
        typing = false
    }

    private func undo() {
        if editing != nil { commitText() }
        guard !marks.isEmpty else { return }
        marks.removeLast()
    }

    // MARK: Redactions

    /// The blurred and pixelated pictures that blur and pixel boxes show, at the preview's size.
    private func prepareLayers() {
        guard redacting, layers == nil, let p = preview.picture else { return }
        let box = WheelImageBox(p.image)
        if Snapshot.isActive {
            layers = WheelImageEngine.redactionLayers(box.image)
            return
        }
        Task {
            let l = await Task.detached(priority: .userInitiated) { WheelImageEngine.redactionLayers(box.image) }.value
            layers = l
        }
    }

    private func detect(faces: Bool) {
        guard searching == nil, let p = preview.picture else { return }
        searching = faces ? "Je cherche les visages…" : "Je lis le texte…"
        found = nil
        let box = WheelImageBox(p.image)
        let style = redaction
        Task {
            let rects = await Task.detached(priority: .userInitiated) {
                faces ? WheelImageEngine.faces(box.image) : WheelImageEngine.sensitiveText(box.image)
            }.value
            searching = nil
            let fresh = rects.filter { r in !marks.contains { $0.kind == .redact && $0.span.intersects(r) && $0.span.contains(CGPoint(x: r.midX, y: r.midY)) } }
            for r in fresh {
                marks.append(WheelMark(kind: .redact, points: [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)], redaction: style))
            }
            if fresh.isEmpty {
                found = faces ? "Aucun visage trouvé." : "Rien de tel trouvé."
            } else {
                found = faces ? "\(Fmt.plural(fresh.count, "visage masqué", "visages masqués"))." : "\(Fmt.plural(fresh.count, "zone masquée", "zones masquées"))."
            }
        }
    }

    // MARK: Saving

    private func save() {
        if editing != nil { commitText() }
        let url = context.file.url
        let kept = marks.filter { !$0.isEmpty }
        let redacting = redacting
        context.save { folder, control in
            control.progress(nil)
            let p = try WheelImageEngine.load(url)
            let needsLayers = kept.contains { $0.kind == .redact && $0.redaction != .black }
            let layers = needsLayers ? WheelImageEngine.redactionLayers(p.image) : nil
            guard let image = WheelImageEngine.marked(p, marks: kept, layers: layers) else {
                throw ConverterError.failed("L'image n'a pas pu être dessinée.")
            }
            // A masked copy leaves everything behind (date, camera, position); an annotated one only its position.
            return try WheelImageEngine.save(image, from: url, picture: p, suffix: redacting ? "masquée" : "annotée", as: .same,
                                             keepMetadata: !redacting, dropGPS: true, folder: folder)
        }
    }
}

enum WheelThickness: String, CaseIterable, Identifiable {
    case thin, medium, thick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thin: return "Fin"
        case .medium: return "Moyen"
        case .thick: return "Épais"
        }
    }

    var value: CGFloat {
        switch self {
        case .thin: return 0.0035
        case .medium: return 0.006
        case .thick: return 0.01
        }
    }
}
