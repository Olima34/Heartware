import SwiftUI
import CoreText

// MARK: - Marks

/// What can be drawn on a picture: annotations (arrows, boxes, highlighter, text, numbered steps, a pen) and redactions.
/// Points go from 0 to 1 across the picture (y going down), widths are a share of its longest side: the same marks draw
/// on the small preview and on the full-size picture.
struct WheelMark: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case arrow, box, oval, highlight, pen, text, step, redact

        var id: String { rawValue }

        var title: String {
            switch self {
            case .arrow: return "Flèche"
            case .box: return "Cadre"
            case .oval: return "Cercle"
            case .highlight: return "Surligneur"
            case .pen: return "Crayon"
            case .text: return "Texte"
            case .step: return "Numéro"
            case .redact: return "Masque"
            }
        }

        var symbol: String {
            switch self {
            case .arrow: return "arrow.up.right"
            case .box: return "square"
            case .oval: return "circle"
            case .highlight: return "highlighter"
            case .pen: return "scribble.variable"
            case .text: return "textformat"
            case .step: return "number.circle"
            case .redact: return "rectangle.dashed"
            }
        }

        /// Drawn by dragging from one corner to the other (the others: a click, or a free line).
        var isSpan: Bool { self == .arrow || self == .box || self == .oval || self == .highlight || self == .redact }
    }

    let id = UUID()
    var kind: Kind
    var points: [CGPoint]
    var color = 0
    var width: CGFloat = 0.006
    var text = ""
    var number = 1
    var redaction: WheelRedaction = .black

    /// The box from its first to its last point.
    var span: CGRect {
        guard let a = points.first, let b = points.last else { return .zero }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Too small to keep (a click that drew nothing).
    var isEmpty: Bool {
        switch kind {
        case .arrow:
            guard let a = points.first, let b = points.last else { return true }
            return hypot(b.x - a.x, b.y - a.y) < 0.01
        case .box, .oval, .highlight, .redact: return span.width < 0.006 || span.height < 0.006
        case .pen: return points.count < 2
        case .text: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .step: return false
        }
    }

    static func == (a: WheelMark, b: WheelMark) -> Bool {
        a.id == b.id && a.kind == b.kind && a.points == b.points && a.color == b.color && a.width == b.width
            && a.text == b.text && a.number == b.number && a.redaction == b.redaction
    }
}

enum WheelRedaction: String, CaseIterable, Identifiable {
    case black, blur, pixels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black: return "Noir"
        case .blur: return "Flou"
        case .pixels: return "Pixels"
        }
    }
}

/// The colors of the marks: they go into the picture itself, so they do not follow the theme.
enum WheelInk {
    static let all: [UInt32] = [0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x0A84FF, 0xAF52DE, 0x1C1C1E, 0xFFFFFF]
    static let names = ["Rouge", "Orange", "Jaune", "Vert", "Bleu", "Violet", "Noir", "Blanc"]

    static func cg(_ i: Int, alpha: CGFloat = 1) -> CGColor {
        let hex = all[(i % all.count + all.count) % all.count]
        return CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func color(_ i: Int) -> Color { Color(cgColor: cg(i)) }

    static func isLight(_ i: Int) -> Bool {
        let hex = all[(i % all.count + all.count) % all.count]
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return 0.299 * r + 0.587 * g + 0.114 * b > 170
    }

    /// White on the dark inks, near-black on the light ones (the number of a step).
    static func onInk(_ i: Int) -> CGColor {
        isLight(i) ? CGColor(gray: 0.1, alpha: 1) : CGColor(gray: 1, alpha: 1)
    }
}

// MARK: - Drawing

/// Draws marks into a Core Graphics context whose y goes down (the preview's, or the full picture flipped for it).
/// The same code draws what the user sees and what gets saved.
enum WheelMarkRenderer {
    static func draw(_ marks: [WheelMark], in ctx: CGContext, size: CGSize, layers: WheelRedactionLayers?) {
        let side = max(size.width, size.height)
        // Redactions first: annotations stay readable on top of them.
        for mark in marks where mark.kind == .redact { redact(mark, in: ctx, size: size, layers: layers) }
        for mark in marks where mark.kind != .redact {
            let pts = mark.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            let w = max(1, mark.width * side)
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(WheelInk.cg(mark.color))
            ctx.setFillColor(WheelInk.cg(mark.color))
            ctx.setLineWidth(w)
            switch mark.kind {
            case .arrow:
                if let a = pts.first, let b = pts.last { arrow(from: a, to: b, width: w, in: ctx) }
            case .box:
                let r = rect(mark.span, size)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(w * 1.5, r.width / 2), cornerHeight: min(w * 1.5, r.height / 2), transform: nil))
                ctx.strokePath()
            case .oval:
                ctx.strokeEllipse(in: rect(mark.span, size))
            case .highlight:
                ctx.setBlendMode(.multiply)
                ctx.setFillColor(WheelInk.cg(mark.color, alpha: 0.42))
                let r = rect(mark.span, size)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(w, r.width / 2), cornerHeight: min(w, r.height / 2), transform: nil))
                ctx.fillPath()
            case .pen:
                guard let first = pts.first else { break }
                ctx.move(to: first)
                for p in pts.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            case .text:
                if let a = pts.first { text(mark.text, at: a, size: w * 5.5, color: mark.color, in: ctx) }
            case .step:
                if let a = pts.first { step(mark.number, at: a, radius: w * 3.2, color: mark.color, in: ctx) }
            case .redact:
                break
            }
            ctx.restoreGState()
        }
    }

    private static func rect(_ r: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
    }

    private static func arrow(from a: CGPoint, to b: CGPoint, width w: CGFloat, in ctx: CGContext) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let length = hypot(b.x - a.x, b.y - a.y)
        let head = min(length * 0.6, max(w * 4.2, 10))
        // The shaft stops under the head, so that its round end does not show past the tip.
        let base = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
        ctx.move(to: a)
        ctx.addLine(to: base)
        ctx.strokePath()
        let spread = CGFloat.pi / 7
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: b.x - cos(angle - spread) * head, y: b.y - sin(angle - spread) * head))
        ctx.addLine(to: CGPoint(x: b.x - cos(angle + spread) * head, y: b.y - sin(angle + spread) * head))
        ctx.closePath()
        ctx.fillPath()
    }

    /// Bold text in the mark's color with a thin white outline, readable on any picture; `a` is its top left corner.
    static func text(_ string: String, at a: CGPoint, size: CGFloat, color: Int, in ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let lines = string.components(separatedBy: "\n")
        ctx.saveGState()
        // Text is laid out with y going up: flipped back inside this y-down context.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        var y = a.y
        for line in lines {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): WheelInk.cg(color),
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): WheelInk.isLight(color)
                    ? CGColor(gray: 0, alpha: 0.55) : CGColor(gray: 1, alpha: 0.9),
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -2.5,
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            y += CTFontGetAscent(font)
            ctx.textPosition = CGPoint(x: a.x, y: y)
            CTLineDraw(ctLine, ctx)
            y += CTFontGetDescent(font) + CTFontGetLeading(font) + size * 0.12
        }
        ctx.restoreGState()
    }

    /// The box a text takes (for the editor: picking it, moving it), in the drawing's units.
    static func textBounds(_ string: String, at a: CGPoint, size: CGFloat) -> CGRect {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let lines = string.components(separatedBy: "\n")
        var width: CGFloat = 0
        for line in lines {
            let attributed = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            width = max(width, CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)))
        }
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font) + size * 0.12
        return CGRect(x: a.x, y: a.y, width: max(width, size), height: lineHeight * CGFloat(lines.count))
    }

    private static func step(_ n: Int, at c: CGPoint, radius r: CGFloat, color: Int, in ctx: CGContext) {
        ctx.setShadow(offset: CGSize(width: 0, height: r * 0.12), blur: r * 0.35, color: CGColor(gray: 0, alpha: 0.35))
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, r * 1.15, nil)
        let attributed = NSAttributedString(string: "\(n)", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): WheelInk.onInk(color),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: c.x - bounds.midX, y: c.y + bounds.midY)
        CTLineDraw(line, ctx)
    }

    private static func redact(_ mark: WheelMark, in ctx: CGContext, size: CGSize, layers: WheelRedactionLayers?) {
        let r = rect(mark.span, size).integral
        ctx.saveGState()
        ctx.clip(to: r)
        let layer: CGImage? = mark.redaction == .blur ? layers?.blur : (mark.redaction == .pixels ? layers?.pixels : nil)
        if let layer {
            // Images are drawn with y going up: flipped back inside this y-down context.
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = mark.redaction == .pixels ? .none : .high
            ctx.draw(layer, in: CGRect(origin: .zero, size: size))
        } else {
            ctx.setFillColor(CGColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1))
            ctx.fill(r)
        }
        ctx.restoreGState()
    }
}
