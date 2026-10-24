import SwiftUI
import PDFKit

/// One page in the window: where it came from, whether it stays, its extra quarter turns.
struct WheelPageItem: Identifiable, Equatable {
    let index: Int
    var kept = true
    var turns = 0

    var id: Int { index }
}

/// « Choisir des pages » : the thumbnails of the PDF; a click keeps or drops a page, its buttons turn it or move it.
/// The new PDF has the pages kept, in this order.
struct WheelPagesEditor: View {
    let context: WheelEditorContext
    @State private var items: [WheelPageItem] = []
    @State private var thumbs: [Int: CGImage] = [:]
    @State private var failed: String?
    @State private var loaded = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 4)

    init(context: WheelEditorContext) {
        self.context = context
        if DemoData.isEnabled {
            var demo = (0..<8).map { WheelPageItem(index: $0) }
            demo[2].kept = false
            demo[5].turns = 1
            _items = State(initialValue: demo)
            _thumbs = State(initialValue: Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, WheelDemo.page($0)) }))
            _loaded = State(initialValue: true)
        }
    }

    var body: some View {
        WheelWindowChrome(title: "Choisir des pages", subtitle: context.file.name, close: context.close) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(summary).font(.ui(11.5)).foregroundStyle(Theme.text2)
                    Spacer()
                    WheelSmallButton(title: "Toutes", symbol: nil) { setAll(true) }
                    WheelSmallButton(title: "Aucune", symbol: nil) { setAll(false) }
                }
                if let failed {
                    EmptyHint(text: failed, symbol: "exclamationmark.triangle")
                } else if !loaded {
                    BusyMascot(.inspecting, pixel: 2).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollArea {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                                WheelPageCard(item: item, number: item.index + 1, thumb: thumbs[item.index],
                                              first: position == 0, last: position == items.count - 1,
                                              toggle: { items[position].kept.toggle() },
                                              turn: { items[position].turns = (items[position].turns + 1) % 4 },
                                              move: { delta in move(position, by: delta) })
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        } footer: {
            Text("Clique une page pour la retirer").font(.ui(10.5)).foregroundStyle(Theme.text3)
            Spacer()
            Button { save() } label: { Text(keptCount == 0 ? "Aucune page" : "Enregistrer \(Fmt.plural(keptCount, "page", "pages"))") }
                .buttonStyle(SoftButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(keptCount == 0 || !changed)
        }
        .onAppear { load() }
    }

    private var keptCount: Int { items.filter(\.kept).count }

    /// Something differs from the original: a page left out, turned or moved.
    private var changed: Bool {
        items.contains { !$0.kept || $0.turns != 0 } || items.map(\.index) != items.map(\.index).sorted()
    }

    private var summary: String {
        guard loaded else { return "Lecture du PDF…" }
        let dropped = items.count - keptCount
        return dropped == 0 ? "\(Fmt.plural(items.count, "page", "pages")), toutes gardées"
            : "\(Fmt.plural(keptCount, "page gardée", "pages gardées")) sur \(Fmt.int(items.count))"
    }

    private func setAll(_ on: Bool) {
        for i in items.indices { items[i].kept = on }
    }

    private func move(_ position: Int, by delta: Int) {
        let to = position + delta
        guard items.indices.contains(to) else { return }
        withAnimation(.easeOut(duration: 0.18)) { items.swapAt(position, to) }
    }

    /// The page count first, then the thumbnails one by one, off the main thread.
    private func load() {
        guard !loaded, !DemoData.isEnabled else { return }
        let url = context.file.url
        Task {
            let count = await Task.detached(priority: .userInitiated) { PDFDocument(url: url)?.pageCount }.value
            guard let count, count > 0 else {
                failed = "Je n'arrive pas à lire ce PDF."
                return
            }
            items = (0..<count).map { WheelPageItem(index: $0) }
            loaded = true
            let stream = AsyncStream<(Int, WheelImageBox)> { continuation in
                Task.detached(priority: .utility) {
                    guard let doc = PDFDocument(url: url) else { continuation.finish(); return }
                    for i in 0..<min(count, 400) {
                        guard let page = doc.page(at: i), let image = ConverterPDFEngine.render(page, dpi: 24, maxSide: 220) else { continue }
                        continuation.yield((i, WheelImageBox(image)))
                    }
                    continuation.finish()
                }
            }
            for await (i, box) in stream { thumbs[i] = box.image }
        }
    }

    private func save() {
        let url = context.file.url
        let choices = items.filter(\.kept).map { WheelDocEngine.PageChoice(index: $0.index, turns: $0.turns) }
        context.save { folder, control in
            try WheelDocEngine.pages(url, choices, folder: folder, control: control)
        }
    }
}

private struct WheelPageCard: View {
    var item: WheelPageItem
    var number: Int
    var thumb: CGImage?
    var first: Bool
    var last: Bool
    var toggle: () -> Void
    var turn: () -> Void
    var move: (Int) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Group {
                    if let thumb {
                        Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            .rotationEffect(.degrees(Double(item.turns) * 90))
                            .scaleEffect(item.turns % 2 == 1 ? 0.72 : 1)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.9))
                    }
                }
                .frame(height: 118)
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .opacity(item.kept ? 1 : 0.3)
                if !item.kept {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.bad)
                }
                if hovering {
                    VStack {
                        HStack(spacing: 3) {
                            mini("chevron.left", disabled: first) { move(-1) }
                            Spacer()
                            mini("rotate.right", disabled: false, action: turn)
                            Spacer()
                            mini("chevron.right", disabled: last) { move(1) }
                        }
                        Spacer()
                    }
                    .padding(4)
                }
            }
            .frame(height: 124)
            .padding(5)
            .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(hovering ? Theme.hover.opacity(0.7) : .clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(8)).strokeBorder(item.kept ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: item.kept ? 1.5 : 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            Text("\(number)").font(.ui(10.5, .medium).monospacedDigit()).foregroundStyle(item.kept ? Theme.text2 : Theme.text3)
        }
        .onHover { hovering = $0 }
    }

    private func mini(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.cardRaised.opacity(0.95)))
                .shadow(color: .black.opacity(0.2), radius: 2)
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.3 : 1)
        .disabled(disabled)
    }
}
