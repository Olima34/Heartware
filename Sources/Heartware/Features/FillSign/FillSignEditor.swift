import SwiftUI
import AppKit

/// The open document, in its window: its name, the tools, the pages (thumbnails on the left) and, on the right, what
/// is selected, the signatures and how the copy is saved. The window's close button closes the document.
struct FillSignWorkspace: View {
    @Environment(AppModel.self) private var app
    var document: FillSignDocument

    var body: some View {
        let model = app.fillSign
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                FileIcon(path: document.url?.path ?? "/document.pdf", size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(document.name).font(.serif(21)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Text(details(model)).font(.ui(12)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer(minLength: 12)
                Button("Ouvrir un autre…") { model.choose() }.buttonStyle(SoftButtonStyle(small: true))
            }
            if let message = model.message {
                Callout(symbol: "exclamationmark.triangle", title: "À savoir", text: message, tint: Theme.warn)
            }
            // « Ouvrir un autre… »: the next document on its way, its password or its conversion.
            FillSignStatus(showsMessage: false)
            VStack(spacing: 0) {
                FillSignToolbar()
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 0) {
                    if document.pageCount > 1 {
                        FillSignThumbnails()
                            .frame(width: 104)
                        Rectangle().fill(Theme.border).frame(width: 1)
                    }
                    FillSignCanvas()
                    Rectangle().fill(Theme.border).frame(width: 1)
                    FillSignInspector()
                        .frame(width: 276)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous).fill(Theme.card))
            .clipShape(RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.line))
            .frame(maxHeight: .infinity)
        }
    }

    private func details(_ model: FillSignModel) -> String {
        var parts = [Fmt.plural(document.pageCount, "page", "pages")]
        if document.fromImage {
            parts.append("photo devenue PDF : écris où tu veux")
        } else if model.fieldCount > 0 {
            parts.append("formulaire de \(Fmt.plural(model.fieldCount, "champ", "champs")), \(model.filledCount) rempli\(model.filledCount > 1 ? "s" : "")")
        } else {
            parts.append("sans champs : écris où tu veux")
        }
        if let url = document.url { parts.append(FS.pretty(url.deletingLastPathComponent().path)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Toolbar

struct FillSignToolbar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.fillSign
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                tool(.select, titled: true)
                tool(.text, titled: true)
                HStack(spacing: 1) {
                    tool(.check, titled: false)
                    tool(.cross, titled: false)
                    tool(.dot, titled: false)
                }
                tool(.date, titled: true)
                tool(.signature, titled: true)
                tool(.initials, titled: true)
                separator
                ForEach(FillSignInk.allCases) { ink in
                    Button { model.setInk(ink) } label: {
                        Circle().fill(ink.color)
                            .overlay(Circle().strokeBorder(Theme.borderStrong, lineWidth: Theme.line))
                            .frame(width: 14, height: 14)
                            .padding(3)
                            .overlay(Circle().strokeBorder(model.ink == ink ? Theme.accent : .clear, lineWidth: 1.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Encre \(ink.title.lowercased())")
                }
                separator
                Button { model.setFontSize(model.fontSize - 1) } label: { Text("A").font(.ui(10.5, .semibold)).frame(width: 22, height: 24) }
                    .buttonStyle(.plain).help("Texte plus petit")
                Text("\(Int(model.fontSize)) pt").font(.ui(11.5, .medium)).monospacedDigit().foregroundStyle(Theme.text2).frame(minWidth: 36)
                Button { model.setFontSize(model.fontSize + 1) } label: { Text("A").font(.ui(14, .semibold)).frame(width: 22, height: 24) }
                    .buttonStyle(.plain).help("Texte plus grand")
                Spacer(minLength: 8)
                iconButton("arrow.uturn.backward", "Annuler (⌘Z)", enabled: model.undoCount > 0) { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                iconButton("arrow.uturn.forward", "Rétablir (⇧⌘Z)", enabled: model.redoCount > 0) { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                separator
                iconButton("minus.magnifyingglass", "Réduire (⌘−)", enabled: model.zoom > 0.5) { model.zoom = max(0.5, (model.zoom - 0.25)) }
                    .keyboardShortcut("-", modifiers: .command)
                Button { model.zoom = 1 } label: {
                    Text(model.zoom == 1 ? "Ajusté" : "\(Int((model.zoom * 100).rounded())) %")
                        .font(.ui(11.5, .medium)).monospacedDigit().foregroundStyle(Theme.text2).frame(minWidth: 52)
                }
                .buttonStyle(.plain)
                .help("Ajuster à la largeur (⌘0)")
                .keyboardShortcut("0", modifiers: .command)
                iconButton("plus.magnifyingglass", "Agrandir (⌘+)", enabled: model.zoom < 3) { model.zoom = min(3, model.zoom + 0.25) }
                    .keyboardShortcut("+", modifiers: .command)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            HStack(spacing: 8) {
                Image(systemName: model.armed != nil ? "hand.point.up.left" : "info.circle")
                    .font(.ui(10.5)).foregroundStyle(model.armed != nil || model.tool != .select ? Theme.accent : Theme.text3)
                Text(model.armed.map { "Clique où placer \($0.kind == .signature ? "ta signature" : "ton paraphe") · ⎋ annule" } ?? model.tool.hint)
                    .font(.ui(11)).foregroundStyle(Theme.text2).lineLimit(1)
                Spacer()
                if let doc = model.document, doc.pageCount > 1 {
                    Text("Page \(model.visiblePage + 1) sur \(doc.pageCount)").font(.ui(11)).monospacedDigit().foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Theme.bg.opacity(0.5))
        }
    }

    private var separator: some View {
        Rectangle().fill(Theme.border).frame(width: 1, height: 20).padding(.horizontal, 6)
    }

    private func tool(_ t: FillSignTool, titled: Bool) -> some View {
        let model = app.fillSign
        let on = model.tool == t
        return Button { model.choose(t) } label: {
            HStack(spacing: 5) {
                Image(systemName: t.symbol).font(.ui(t == .dot ? 7 : 12, .medium)).frame(width: 14)
                if titled { Text(t.title).font(.ui(12, on ? .semibold : .regular)) }
            }
            .foregroundStyle(on ? Theme.text : Theme.text2)
            .padding(.horizontal, titled ? 9 : 7)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.r(7)).fill(on ? Theme.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t.title)
    }

    private func iconButton(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.ui(12.5)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }
}

// MARK: - Pages

/// Where each page's top is in the scrolled list: the one at the top is the page shown.
struct FillSignPageTops: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

struct FillSignCanvas: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        let model = app.fillSign
        if let doc = model.document {
            GeometryReader { geo in
                let widest = doc.pageSizes.map(\.width).max() ?? 595
                let fit = max(0.25, (geo.size.width - 56) / widest)
                let scale = fit * model.zoom
                Group {
                    if Snapshot.isActive {
                        // No scrolling in a snapshot: the list starts at the page shown.
                        pages(doc, scale: scale, from: model.visiblePage).frame(width: geo.size.width, height: geo.size.height, alignment: .top).clipped()
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView([.vertical, .horizontal]) {
                                pages(doc, scale: scale)
                                    .frame(minWidth: geo.size.width)
                            }
                            .coordinateSpace(name: "fillsign")
                            .onPreferenceChange(FillSignPageTops.self) { tops in
                                let current = tops.filter { $0.value < geo.size.height * 0.4 }.max { $0.value < $1.value }?.key
                                    ?? tops.min { $0.value < $1.value }?.key ?? 0
                                if model.visiblePage != current { model.visiblePage = current }
                            }
                            .onChange(of: model.scrollTarget) { _, target in
                                guard let target else { return }
                                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .top) }
                                model.scrollTarget = nil
                            }
                        }
                    }
                }
            }
            .background(Theme.track.opacity(0.6))
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onDeleteCommand { model.deleteSelection() }
            .onExitCommand { model.escape() }
            .onMoveCommand { direction in
                switch direction {
                case .left: model.nudge(-1, 0)
                case .right: model.nudge(1, 0)
                case .up: model.nudge(0, -1)
                case .down: model.nudge(0, 1)
                default: break
                }
            }
            .onChange(of: model.selection) { _, id in
                if id != nil, model.editing == nil { focused = true }
            }
        }
    }

    private func pages(_ doc: FillSignDocument, scale: CGFloat, from first: Int = 0) -> some View {
        LazyVStack(spacing: 22) {
            ForEach(min(first, doc.pageCount - 1)..<doc.pageCount, id: \.self) { i in
                FillSignPageView(index: i, scale: scale)
                    .id(i)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FillSignPageTops.self, value: [i: g.frame(in: .named("fillsign")).minY])
                    })
            }
        }
        .padding(28)
    }
}

struct FillSignPageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    var index: Int
    var scale: CGFloat
    @State private var image: CGImage?

    var body: some View {
        let model = app.fillSign
        if let doc = model.document, doc.pageSizes.indices.contains(index) {
            let size = doc.pageSizes[index]
            // Sharp up to a strong zoom; beyond, a page would take hundreds of megabytes.
            let pixelWidth = min(2200, Int((size.width * scale * max(1, displayScale)).rounded()))
            let shown = Snapshot.isActive ? doc.image(page: index, pixelWidth: pixelWidth) : (image ?? model.cachedImage(index))
            ZStack(alignment: .topLeading) {
                // The sheet of paper: white whatever the theme, like the PDF.
                Color.white
                if let shown {
                    Image(decorative: shown, scale: 1).resizable().interpolation(.high)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in
                        model.pageClick(at: CGPoint(x: p.x / scale, y: p.y / scale), page: index)
                    }
                ForEach(doc.fields.filter { $0.page == index && !$0.readOnly }) { field in
                    FillSignFieldView(field: field, scale: scale)
                }
                ForEach(model.items.filter { $0.page == index }) { item in
                    FillSignItemView(item: item, scale: scale)
                }
            }
            .frame(width: size.width * scale, height: size.height * scale)
            .clipped()
            .themedShadow(color: .black.opacity(0.2), radius: 7, y: 2)
            .task(id: pixelWidth) {
                // While zooming, only the size the user stops on is drawn.
                if image != nil { try? await Task.sleep(nanoseconds: 180_000_000) }
                guard !Task.isCancelled, let drawn = await model.pageImage(index, pixelWidth: pixelWidth), !Task.isCancelled else { return }
                image = drawn
            }
        }
    }
}

// MARK: - Fields

/// A form field over the page: a box to type in, to tick, a list, or a place to sign.
struct FillSignFieldView: View {
    @Environment(AppModel.self) private var app
    var field: FillSignField
    var scale: CGFloat

    var body: some View {
        let model = app.fillSign
        let r = field.rect
        let w = r.width * scale, h = r.height * scale
        Group {
            switch field.kind {
            case .text(let multiline, _, let fs, let alignment):
                let size = Self.fontSize(fs, height: r.height, multiline: multiline) * scale
                FillSignTypingBox(text: Binding(get: { model.value(field) }, set: { model.setValue(field, $0) }),
                                  font: .custom(FillSignText.fontName, size: size), multiline: multiline,
                                  alignment: alignment == 1 ? .center : (alignment == 2 ? .trailing : .leading), placeholder: field.label)
                    .padding(.horizontal, 2 * scale)
                    .frame(width: w, height: h, alignment: multiline ? .topLeading : .leading)
                    .background(highlight(filled: !model.value(field).isEmpty))
            case .checkbox, .radio:
                Button { model.toggle(field) } label: {
                    ZStack {
                        highlight(filled: model.isOn(field))
                        if model.isOn(field) {
                            // The same mark as in the saved PDF, in the field's own box.
                            let m = FillSignDocument.buttonMark(field)
                            let inner = CGRect(x: (m.rect.minX - r.minX) * scale, y: (m.rect.minY - r.minY) * scale,
                                               width: m.rect.width * scale, height: m.rect.height * scale)
                            if m.mark == .dot {
                                Path(FillSignDraw.markPath(.dot, in: inner)).fill(FillSignInk.black.color)
                            } else {
                                Path(FillSignDraw.markPath(.check, in: inner))
                                    .stroke(FillSignInk.black.color, style: StrokeStyle(lineWidth: FillSignDraw.markWidth(inner), lineCap: .round, lineJoin: .round))
                            }
                        }
                    }
                    .frame(width: w, height: h)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(field.label)
            case .choice(let options):
                BorderlessMenu(indicator: false) {
                    ForEach(options, id: \.self) { o in Button(o) { model.setValue(field, o) } }
                    if !model.value(field).isEmpty {
                        Divider()
                        Button("Vider") { model.setValue(field, "") }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(model.value(field).isEmpty ? " " : model.value(field))
                            .font(.custom(FillSignText.fontName, size: Self.fontSize(0, height: r.height, multiline: false) * scale))
                            .foregroundStyle(FillSignInk.black.color)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.system(size: max(6, h * 0.35), weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 3 * scale)
                    .frame(width: w, height: h)
                }
                .frame(width: w, height: h)
                .background(highlight(filled: !model.value(field).isEmpty))
                .help(field.label)
            case .signature where model.items.contains { $0.page == field.page && $0.signature != nil && $0.rect.intersects(field.rect) }:
                // Signed: the frame makes way for the signature.
                EmptyView()
            case .signature:
                Button { model.sign(field) } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(0.08))
                        RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        Label("Signer ici", systemImage: "signature").font(.ui(min(12, max(8, h * 0.3)), .medium)).foregroundStyle(Theme.accent)
                    }
                    .frame(width: w, height: h)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clique pour signer dans ce cadre")
            }
        }
        .offset(x: r.minX * scale, y: r.minY * scale)
    }

    /// The size the PDF asks for, or one that fits the box (as PDF readers do for an automatic size).
    static func fontSize(_ asked: CGFloat, height: CGFloat, multiline: Bool) -> CGFloat {
        if asked > 0 { return asked }
        return multiline ? 10 : min(12, max(6, height * 0.62))
    }

    /// The tint of fillable boxes in the editor (never in the saved PDF).
    private func highlight(filled: Bool) -> some View {
        Rectangle()
            .fill(Theme.accent.opacity(filled ? 0.05 : 0.12))
            .overlay(Rectangle().strokeBorder(Theme.accent.opacity(filled ? 0.25 : 0.45), lineWidth: 0.75))
    }
}

/// A text field drawn as plain text in snapshots.
struct FillSignTypingBox: View {
    @Binding var text: String
    var font: Font
    var multiline = false
    var alignment: TextAlignment = .leading
    var placeholder = ""
    var ink: Color = FillSignInk.black.color

    var body: some View {
        if Snapshot.isActive {
            Text(text)
                .font(font)
                .foregroundStyle(ink)
                .multilineTextAlignment(alignment)
                .lineLimit(multiline ? nil : 1)
                .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : (alignment == .trailing ? .trailing : .leading))
        } else {
            TextField("", text: $text, axis: multiline ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(ink)
                .multilineTextAlignment(alignment)
                .help(placeholder)
        }
    }
}

// MARK: - Added items

/// Text, a mark or a signature on the page: a click selects it, a drag moves it, the handle resizes it; a click on a
/// selected text types in it.
struct FillSignItemView: View {
    @Environment(AppModel.self) private var app
    var item: FillSignItem
    var scale: CGFloat
    @GestureState private var drag: CGSize = .zero
    @State private var resize: CGFloat?
    @FocusState private var typing: Bool

    var body: some View {
        let model = app.fillSign
        let selected = model.selection == item.id
        let editing = model.editing == item.id
        let r = item.rect
        let w = r.width * scale, h = r.height * scale
        let k = resize.map { max(0.2, $0 / max(1, w)) } ?? 1
        content(editing: editing)
            .frame(width: w, height: h, alignment: .topLeading)
            .scaleEffect(k, anchor: .topLeading)
            .overlay(alignment: .topLeading) {
                if selected || editing {
                    Rectangle()
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: editing ? [] : [4, 3]))
                        .frame(width: w * k + 6, height: h * k + 6)
                        .offset(x: -3, y: -3)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if selected && !editing {
                    Circle()
                        .fill(Theme.accent)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                        .frame(width: 11, height: 11)
                        .offset(x: w * k - 2, y: h * k - 2)
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { v in resize = max(8, w + v.translation.width) }
                            .onEnded { v in
                                model.resize(item.id, width: max(8, w + v.translation.width) / scale)
                                resize = nil
                            })
                        .help("Glisse pour agrandir ou réduire")
                }
            }
            .contentShape(Rectangle())
            .offset(x: r.minX * scale + drag.width, y: r.minY * scale + drag.height)
            .gesture(DragGesture(minimumDistance: 2)
                .updating($drag) { v, state, _ in state = v.translation }
                .onEnded { v in model.move(item.id, by: CGSize(width: v.translation.width / scale, height: v.translation.height / scale)) },
                     including: editing ? .subviews : .all)
            .onTapGesture {
                if selected, item.text != nil { model.edit(item.id) } else { model.select(item.id) }
            }
            .onChange(of: editing) { _, now in typing = now }
            .onAppear { if editing { typing = true } }
    }

    @ViewBuilder
    private func content(editing: Bool) -> some View {
        let model = app.fillSign
        let size = CGSize(width: item.rect.width * scale, height: item.rect.height * scale)
        switch item.content {
        case .text(let text):
            let font = Font.custom(FillSignText.fontName, size: item.fontSize * scale)
            if editing && !Snapshot.isActive {
                TextField("", text: Binding(get: { text }, set: { model.setText(item.id, $0) }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundStyle(item.ink.color)
                    .focused($typing)
                    .onSubmit { model.endEditing() }
                    .onExitCommand { model.endEditing() }
                    .frame(minWidth: max(size.width, 40 * scale), alignment: .topLeading)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(FillSignText.lines(text).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(font)
                            .foregroundStyle(item.ink.color)
                            .fixedSize()
                            .frame(height: FillSignText.lineHeight(item.fontSize) * scale, alignment: .topLeading)
                    }
                }
            }
        case .mark(let mark):
            let rect = CGRect(origin: .zero, size: size)
            if mark == .dot {
                Path(FillSignDraw.markPath(.dot, in: rect)).fill(item.ink.color)
            } else {
                Path(FillSignDraw.markPath(mark, in: rect))
                    .stroke(item.ink.color, style: StrokeStyle(lineWidth: FillSignDraw.markWidth(rect), lineCap: .round, lineJoin: .round))
            }
        case .signature(let sig):
            FillSignSignatureView(signature: sig)
        }
    }
}

// MARK: - Thumbnails

struct FillSignThumbnails: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.fillSign
        if let doc = model.document {
            ScrollArea(showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    ForEach(0..<doc.pageCount, id: \.self) { i in
                        let size = doc.pageSizes[i]
                        let on = model.visiblePage == i
                        Button { model.go(to: i) } label: {
                            VStack(spacing: 4) {
                                FillSignThumb(index: i)
                                    .frame(width: 70, height: 70 * size.height / max(1, size.width))
                                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(on ? Theme.accent : Theme.border, lineWidth: on ? 2 : Theme.line))
                                    .overlay(alignment: .topTrailing) {
                                        if model.items.contains(where: { $0.page == i }) {
                                            Circle().fill(Theme.accent).frame(width: 7, height: 7).padding(4)
                                        }
                                    }
                                Text("\(i + 1)").font(.ui(10.5, on ? .semibold : .regular)).foregroundStyle(on ? Theme.text : Theme.text3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct FillSignThumb: View {
    @Environment(AppModel.self) private var app
    var index: Int
    @State private var image: CGImage?

    var body: some View {
        let model = app.fillSign
        let shown = Snapshot.isActive ? model.document?.image(page: index, pixelWidth: 140) : image
        ZStack {
            Color.white
            if let shown { Image(decorative: shown, scale: 1).resizable().interpolation(.high) }
        }
        .task(id: index) { image = await model.thumbnail(index) }
    }
}

// MARK: - Inspector

/// What is selected, the signatures, the form, how the copy is saved.
struct FillSignInspector: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.fillSign
        ScrollArea {
            VStack(alignment: .leading, spacing: 20) {
                if let item = model.selected {
                    selection(item)
                }
                section("Signer", tip: FillSignModel.tip) {
                    FillSignSignaturesPanel()
                }
                if let doc = model.document, doc.hasForm {
                    section("Formulaire") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(model.filledCount) sur \(Fmt.plural(model.fieldCount, "champ rempli", "champs remplis"))")
                                    .font(.ui(12)).foregroundStyle(Theme.text2)
                                Spacer()
                            }
                            UsageBar(fraction: model.fieldCount > 0 ? Double(model.filledCount) / Double(model.fieldCount) : 0,
                                     tint: FillSignStyle.tint, height: 5)
                            Text("⇥ passe au champ suivant.").font(.ui(11)).foregroundStyle(Theme.text3)
                            Button("Vider les champs") { model.clearFields() }
                                .buttonStyle(SoftButtonStyle(small: true))
                                .disabled(model.filledCount == 0)
                        }
                    }
                }
                section("Enregistrement") {
                    saving(model)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func saving(_ model: FillSignModel) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            if let doc = model.document {
                if model.canKeepForm {
                    Toggle(isOn: $model.keepForm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Garder le formulaire modifiable").font(.ui(12)).foregroundStyle(Theme.text)
                            Text("Les champs restent des champs : pour renvoyer un formulaire à compléter.")
                                .font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .switchToggles()
                } else if doc.hasForm && !model.items.isEmpty {
                    note("lock.doc", "Tout sera intégré aux pages : plus rien ne bougera.")
                }
                note("folder", doc.url != nil ? "La copie va à côté de l'original." : "La copie va dans Téléchargements.")
                if doc.password != nil {
                    note("lock", "La copie garde le mot de passe de l'original.")
                }
            }
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol).font(.ui(10.5)).foregroundStyle(Theme.text3).frame(width: 14)
            Text(text).font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(_ title: String, tip: HelpTip? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title.uppercased()).font(.ui(10, .semibold)).tracking(0.7).foregroundStyle(Theme.text3)
                if let tip { HelpTipButton(tip: tip, size: 11.5) }
            }
            content()
        }
    }

    @ViewBuilder
    private func selection(_ item: FillSignItem) -> some View {
        let model = app.fillSign
        let title: String = {
            switch item.content {
            case .text: return "Texte"
            case .mark(let m): return m == .check ? "Coche" : (m == .cross ? "Croix" : "Point")
            case .signature(let s): return s.kind.title
            }
        }()
        section(title) {
            VStack(alignment: .leading, spacing: 10) {
                if item.text != nil {
                    HStack(spacing: 8) {
                        Text("Taille").font(.ui(12)).foregroundStyle(Theme.text2)
                        Spacer()
                        Button { model.setFontSize(item.fontSize - 1) } label: { Image(systemName: "minus").frame(width: 22, height: 22) }
                            .buttonStyle(.plain)
                        Text("\(Int(item.fontSize)) pt").font(.ui(12, .medium)).monospacedDigit().foregroundStyle(Theme.text).frame(minWidth: 40)
                        Button { model.setFontSize(item.fontSize + 1) } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                            .buttonStyle(.plain)
                    }
                }
                if item.signature?.takesInk ?? true {
                    HStack(spacing: 6) {
                        Text("Encre").font(.ui(12)).foregroundStyle(Theme.text2)
                        Spacer()
                        ForEach(FillSignInk.allCases) { ink in
                            Button { model.setInk(ink) } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(ink.color).frame(width: 10, height: 10)
                                        .overlay(Circle().strokeBorder(Theme.borderStrong, lineWidth: Theme.line))
                                    Text(ink.title).font(.ui(11.5, item.ink == ink ? .semibold : .regular))
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(PillShape().fill(item.ink == ink ? Theme.selected : .clear))
                                .overlay(PillShape().strokeBorder(Theme.border, lineWidth: Theme.line))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.text)
                        }
                    }
                }
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    if item.text != nil {
                        Button("Modifier le texte") { model.edit(item.id) }.buttonStyle(SoftButtonStyle(small: true))
                    }
                    Button("Dupliquer") { model.duplicateSelection() }.buttonStyle(SoftButtonStyle(small: true))
                    if (model.document?.pageCount ?? 1) > 1 {
                        Button("Sur toutes les pages") { model.copyToAllPages() }
                            .buttonStyle(SoftButtonStyle(small: true))
                            .help("Le même élément, au même endroit, sur chaque page (un paraphe, par exemple)")
                    }
                    Button("Supprimer") { model.deleteSelection() }.buttonStyle(SoftButtonStyle(destructive: true, small: true))
                }
                Text("Glisse pour déplacer · flèches : au point près · ⌫ supprime").font(.ui(10.5)).foregroundStyle(Theme.text3)
            }
        }
    }
}
