import SwiftUI

// Small controls drawn in SwiftUI only, so they look the same in `--snapshot` renders (no AppKit-backed views).

/// A pill to pick an option.
struct ConverterChip: View {
    var title: String
    var symbol: String? = nil
    var selected: Bool
    var tint: Color = Theme.accent
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol, Theme.icons != .hidden { Image(systemName: symbol).font(.ui(10, .semibold)) }
                Text(title).font(.ui(11.5, selected ? .semibold : .medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? Theme.text : Theme.text2)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .chipGround(selected, still: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A choice among a few, as pills that wrap.
struct ConverterChips<T: Hashable>: View {
    var options: [T]
    @Binding var selection: T
    var symbol: ((T) -> String?)? = nil
    var label: (T) -> String

    var body: some View {
        ChipPicker(options: options, selection: $selection, label: label, symbol: symbol, wraps: true)
    }
}

/// A short remark under a setting (a missing tool, a choice that changes nothing).
struct ConverterNote: View {
    var symbol: String
    var text: String
    var tint: Color = Theme.text3

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.ui(10.5, .medium))
            Text(text).font(.ui(11)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
    }
}

/// A slider drawn with shapes.
struct ConverterSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0.01
    var tint: Color = Theme.accent

    var body: some View {
        GeometryReader { g in
            let span = range.upperBound - range.lowerBound
            let f = span > 0 ? min(1, max(0, (value - range.lowerBound) / span)) : 0
            ZStack(alignment: .leading) {
                PillShape().fill(Theme.track).frame(height: 5)
                PillShape().fill(tint).frame(width: max(5, g.size.width * f), height: 5)
                Circle()
                    .fill(Color.white)
                    .themedShadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: 16, height: 16)
                    .offset(x: (g.size.width - 16) * f)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let x = min(1, max(0, drag.location.x / max(1, g.size.width)))
                let raw = range.lowerBound + x * span
                value = min(range.upperBound, max(range.lowerBound, (raw / step).rounded() * step))
            })
        }
        .frame(height: 18)
    }
}

/// A text field, drawn as plain text in snapshots.
struct ConverterTextField: View {
    @Binding var text: String
    var prompt: String
    var symbol: String? = nil
    var mono = false

    var body: some View {
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).font(.ui(11.5)).foregroundStyle(Theme.text3) }
            if Snapshot.isActive {
                Text(text.isEmpty ? prompt : text)
                    .font(mono ? .mono(12) : .ui(12.5))
                    .foregroundStyle(text.isEmpty ? Theme.text3 : Theme.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .font(mono ? .mono(12) : .ui(12.5))
            }
            if !text.isEmpty && !Snapshot.isActive {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.ui(11)).foregroundStyle(Theme.text3) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(8)).strokeBorder(Theme.border, lineWidth: Theme.line))
    }
}

/// A setting: its name on the left (and a few words under it), its controls on the right.
struct ConverterOptionRow<Content: View>: View {
    var label: String
    var hint: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.ui(11.5, .semibold)).foregroundStyle(Theme.text2)
                if let hint { Text(hint).font(.ui(10.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(width: 118, alignment: .leading)
            .padding(.top, 4)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// − value + for small integers.
struct ConverterStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 0) {
            Button { value = max(range.lowerBound, value - 1) } label: {
                Image(systemName: "minus").font(.ui(10, .bold)).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            Text("\(value)").font(.ui(12.5, .medium)).monospacedDigit().frame(minWidth: 30)
            Button { value = min(range.upperBound, value + 1) } label: {
                Image(systemName: "plus").font(.ui(10, .bold)).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Theme.text)
        .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(8)).strokeBorder(Theme.border, lineWidth: Theme.line))
    }
}

/// A scrolling area that never makes its window grow: the content scrolls inside the space it gets (in snapshots, where
/// scroll views come out empty, it is cut there).
struct ConverterScroll<Content: View>: View {
    var axes: Axis.Set = .vertical
    @ViewBuilder var content: Content

    var body: some View {
        if Snapshot.isActive {
            Color.clear
                .overlay(alignment: .topLeading) {
                    content.fixedSize(horizontal: axes == .horizontal, vertical: axes == .vertical)
                }
                .clipped()
        } else {
            ScrollView(axes, showsIndicators: false) { content }
        }
    }
}

/// Accepts files dragged from the Finder. Left out of snapshots, where `ImageRenderer` draws drop targets with yellow corners.
struct ConverterDropTarget: ViewModifier {
    @Binding var targeted: Bool
    var onFiles: ([URL]) -> Void

    func body(content: Content) -> some View {
        if Snapshot.isActive {
            content
        } else {
            content.dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                onFiles(files)
                return true
            } isTargeted: { targeted = $0 }
        }
    }
}
