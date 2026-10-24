import SwiftUI
import AppKit

// Small controls of the toolbox page. Text fields and editors are drawn by hand in snapshots
// (`ImageRenderer` turns AppKit controls into yellow boxes).

/// A one-line text field with the card look.
struct ToolboxField: View {
    var placeholder: String
    @Binding var text: String
    var mono = false
    var symbol: String? = nil
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.ui(11.5)).foregroundStyle(Theme.text3)
            }
            if Snapshot.isActive {
                Text(text.isEmpty ? placeholder : text)
                    .font(mono ? .mono(12.5) : .ui(12.5))
                    .foregroundStyle(text.isEmpty ? Theme.text3 : Theme.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(mono ? .mono(12.5) : .ui(12.5))
                    .foregroundStyle(Theme.text)
                    .onSubmit(onSubmit)
            }
            if !text.isEmpty && !Snapshot.isActive {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.ui(11.5)).foregroundStyle(Theme.text3)
                }
                .buttonStyle(.plain)
                .help("Effacer")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(8)).strokeBorder(Theme.border, lineWidth: Theme.line))
    }
}

/// A multi-line editor (or a read-only text) with the card look.
struct ToolboxEditor: View {
    @Binding var text: String
    var placeholder = ""
    var height: CGFloat = 170
    var mono = true
    var editable = true
    var tint: Color? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            if editable && !Snapshot.isActive {
                TextEditor(text: $text)
                    .font(mono ? .mono(12) : .ui(12.5))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 7)
                if text.isEmpty {
                    Text(placeholder)
                        .font(mono ? .mono(12) : .ui(12.5))
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                }
            } else {
                ScrollArea {
                    Text(text.isEmpty ? placeholder : text)
                        .font(mono ? .mono(12) : .ui(12.5))
                        .foregroundStyle(text.isEmpty ? Theme.text3 : (tint ?? Theme.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
            }
        }
        .frame(height: height, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Theme.r(9)).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(9)).strokeBorder(tint?.opacity(0.5) ?? Theme.border, lineWidth: Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: Theme.r(9)))
    }
}

/// "Copier", then a check mark for a moment.
struct ToolboxCopyButton: View {
    var text: String
    var secret = false
    var label: String? = nil
    var prominent = false
    @Environment(AppModel.self) private var app
    @State private var copied = false

    var body: some View {
        Button {
            let outcome = app.toolbox.copy(text, secret: secret)
            if case .message(let m) = outcome, DemoData.isEnabled { HUD.show(m, symbol: "theatermasks") }
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { copied = false }
        } label: {
            if let label {
                Label(copied ? "Copié" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Theme.good : Theme.text2)
                    .frame(width: 14)
            }
        }
        .buttonStyle(SoftButtonStyle(prominent: prominent, small: true))
        .disabled(text.isEmpty)
        .help(secret ? "Copier (marqué confidentiel)" : "Copier")
    }
}

/// A label, a value in monospace and a copy button.
struct ToolboxValueRow: View {
    var label: String
    var value: String
    var labelWidth: CGFloat = 112
    var highlight: Color? = nil
    var note: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.ui(11.5, .medium))
                .foregroundStyle(highlight ?? Theme.text3)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                .font(.mono(12))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let note {
                Text(note).font(.ui(10.5)).foregroundStyle(Theme.text3)
            }
            ToolboxCopyButton(text: value)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(highlight.map { $0.opacity(0.1) } ?? Color.clear))
    }
}

/// A slider drawn with shapes (works in snapshots too).
struct ToolboxSlider: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var tint: Color = Theme.accent

    var body: some View {
        GeometryReader { g in
            let span = Double(range.upperBound - range.lowerBound)
            let frac = span > 0 ? Double(value - range.lowerBound) / span : 0
            let x = 8 + (g.size.width - 16) * frac
            ZStack(alignment: .leading) {
                PillShape().fill(Theme.track).frame(height: 5)
                PillShape().fill(tint).frame(width: max(5, x), height: 5)
                Circle()
                    .fill(Theme.cardRaised)
                    .frame(width: 16, height: 16)
                    .themedShadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .overlay(Circle().strokeBorder(Theme.borderStrong, lineWidth: 1))
                    .offset(x: x - 8)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let f = min(1, max(0, (d.location.x - 8) / max(1, g.size.width - 16)))
                let v = range.lowerBound + Int((f * span).rounded())
                if v != value { value = v }
            })
        }
        .frame(height: 20)
    }
}

/// "−  5  +"
struct ToolboxStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var suffix: String = ""

    var body: some View {
        HStack(spacing: 0) {
            Button { value = max(range.lowerBound, value - 1) } label: {
                Image(systemName: "minus").font(.ui(10.5, .semibold)).frame(width: 26, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(value <= range.lowerBound)
            Text("\(value)\(suffix)")
                .font(.ui(12.5, .semibold))
                .monospacedDigit()
                .frame(minWidth: 30)
            Button { value = min(range.upperBound, value + 1) } label: {
                Image(systemName: "plus").font(.ui(10.5, .semibold)).frame(width: 26, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(value >= range.upperBound)
        }
        .foregroundStyle(Theme.text)
        .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(8)).strokeBorder(Theme.border, lineWidth: Theme.line))
    }
}

/// A small selectable chip.
struct ToolboxChip: View {
    var title: String
    var selected: Bool
    var mono = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(mono ? .mono(11.5, .medium) : .ui(11.5, .medium))
                .foregroundStyle(selected ? Theme.text : Theme.text2)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .chipGround(selected, still: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A switch row: title, explanation, toggle.
struct ToolboxSwitch: View {
    var title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(12.5)).foregroundStyle(Theme.text)
                if let detail {
                    Text(detail).font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .switchToggles()
        .controlSize(.small)
    }
}

/// The strength meter of passwords.
struct ToolboxStrength: View {
    var bits: Double

    var body: some View {
        let s = ToolboxPassword.strength(bits: bits)
        HStack(spacing: 10) {
            UsageBar(fraction: s.score, tint: s.status.color, height: 6)
            Text("\(s.label) · \(Int(bits)) bits")
                .font(.ui(11.5, .medium))
                .foregroundStyle(s.status.color)
                .monospacedDigit()
                .fixedSize()
        }
    }
}

/// The shared `DropZone` (it leaves out its drop target in snapshots).
struct ToolboxDropZone: View {
    var title: String
    var subtitle: String
    var symbol: String
    var onFiles: ([URL]) -> Void

    var body: some View {
        DropZone(title: title, subtitle: subtitle, symbol: symbol, onFiles: onFiles)
    }
}
