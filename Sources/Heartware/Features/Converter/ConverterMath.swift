import AppKit
import CoreText

/// A piece of Office Math laid out around its baseline (y up): text, strokes and the boxes it is made of.
final class ConverterMathBox {
    var width: CGFloat = 0
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    fileprivate var line: CTLine?
    fileprivate var lineScale: CGFloat = 1
    fileprivate var lineShift: CGFloat = 0
    fileprivate var children: [(x: CGFloat, y: CGFloat, box: ConverterMathBox)] = []
    fileprivate var strokes: [(path: CGPath, width: CGFloat, fill: Bool)] = []
    fileprivate var color = CGColor(gray: 0, alpha: 1)

    fileprivate func add(_ box: ConverterMathBox, x: CGFloat, y: CGFloat) {
        children.append((x, y, box))
        ascent = max(ascent, y + box.ascent)
        descent = max(descent, box.descent - y)
        width = max(width, x + box.width)
    }

    /// Draws with the baseline at `baseline`, in a context whose y axis points down.
    func draw(_ ctx: CGContext, x: CGFloat, baseline: CGFloat) {
        if let line {
            ctx.saveGState()
            ctx.translateBy(x: x, y: baseline - lineShift)
            ctx.scaleBy(x: 1, y: lineScale)
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        for s in strokes {
            ctx.saveGState()
            ctx.translateBy(x: x, y: baseline)
            ctx.scaleBy(x: 1, y: -1)
            ctx.addPath(s.path)
            if s.fill {
                ctx.setFillColor(color)
                ctx.fillPath()
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(s.width)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        for c in children { c.box.draw(ctx, x: x + c.x, baseline: baseline - c.y) }
    }
}

/// Office Math (OMML) laid out the way Word shows it: math italic letters, spaced operators, stacked fractions,
/// scripts, radicals, stretchy delimiters, n-ary operators with their limits, accents, bars, matrices.
struct ConverterMath {
    let size: CGFloat
    let color: CGColor
    let display: Bool

    // MARK: Fonts and text

    static let fontName: String = {
        ConverterDocxFonts.exists("Cambria Math") ? "Cambria Math" : (ConverterDocxFonts.exists("STIX Two Math") ? "STIX Two Math" : "Times New Roman")
    }()

    /// Function names Word sets upright on its own.
    static let functions: Set<String> = ["sin", "cos", "tan", "cot", "sec", "csc", "sinh", "cosh", "tanh", "arcsin", "arccos", "arctan",
                                         "ln", "log", "exp", "lim", "max", "min", "sup", "inf", "det", "dim", "ker", "deg", "gcd", "arg", "mod"]

    private func scale(_ level: Int) -> CGFloat { [1, 0.71, 0.58][min(level, 2)] }
    private func font(_ level: Int, plain: Bool = false, bold: Bool = false) -> NSFont {
        ConverterDocxFonts.font(Self.fontName, size: size * scale(level), bold: bold && plain, italic: false, kind: nil)
    }

    /// Letters in mathematical italic (or bold), as Word does; digits and signs stay upright.
    static func styled(_ s: String, style: String) -> String {
        guard style != "p" else { return s }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let v = u.value
            var mapped: UInt32?
            switch style {
            case "b":
                if (65...90).contains(v) { mapped = 0x1D400 + v - 65 } else if (97...122).contains(v) { mapped = 0x1D41A + v - 97 }
                else if (48...57).contains(v) { mapped = 0x1D7CE + v - 48 }
            case "bi":
                if (65...90).contains(v) { mapped = 0x1D468 + v - 65 } else if (97...122).contains(v) { mapped = 0x1D482 + v - 97 }
            default:
                if v == 104 { mapped = 0x210E } else if (65...90).contains(v) { mapped = 0x1D434 + v - 65 }
                else if (97...122).contains(v) { mapped = 0x1D44E + v - 97 } else if (0x3B1...0x3C9).contains(v) { mapped = 0x1D6FC + v - 0x3B1 }
            }
            out.append(mapped.flatMap(UnicodeScalar.init) ?? u)
        }
        return String(out)
    }

    private func text(_ s: String, level: Int, style: String = "i", spaced: Bool = true) -> ConverterMathBox {
        let f = font(level, plain: style == "p" || style == "b")
        let binary: Set<Character> = ["+", "−", "±", "∓", "×", "÷", "·", "∗", "⋅", "∘", "∪", "∩", "∧", "∨"]
        let relation: Set<Character> = ["=", "<", ">", "≤", "≥", "≠", "≈", "≡", "∝", "→", "←", "↔", "⇒", "⇐", "⇔", "∈", "∉", "⊂", "⊃", "⊆", "⊇", "∼", "≅", "≪", "≫", "∶"]
        let attributed = NSMutableAttributedString()
        let source = s.replacingOccurrences(of: "-", with: "−").replacingOccurrences(of: "*", with: "∗")
            .replacingOccurrences(of: "'", with: "′")
        var previousOrdinary = false
        for ch in source {
            let isRelation = relation.contains(ch), isBinary = binary.contains(ch)
            let gap = spaced && level == 0 ? (isRelation ? size * 0.28 : (isBinary && (previousOrdinary || attributed.length == 0) ? size * 0.22 : 0)) : 0
            if gap > 0, attributed.length == 0 {
                // A sign that starts a run follows another piece of the equation: its space goes before it too.
                attributed.append(NSAttributedString(string: "\u{2005}", attributes: [.font: f]))
            } else if gap > 0 {
                // The whole last character: math letters take two UTF-16 units.
                let last = (attributed.string as NSString).rangeOfComposedCharacterSequence(at: attributed.length - 1)
                let k = (attributed.attribute(.kern, at: last.location, effectiveRange: nil) as? CGFloat) ?? 0
                attributed.addAttribute(.kern, value: k + gap, range: last)
            }
            let shown = (ch.isLetter && style != "p") ? Self.styled(String(ch), style: style) : String(ch)
            var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor(cgColor: color) ?? .black]
            if gap > 0 { attrs[.kern] = gap }
            if ch == "," || ch == ";" { attrs[.kern] = size * 0.17 * scale(level) }
            attributed.append(NSAttributedString(string: shown, attributes: attrs))
            previousOrdinary = !(isRelation || isBinary || ch == "(" || ch == "[" || ch == "{")
        }
        let box = ConverterMathBox()
        box.color = color
        let line = CTLineCreateWithAttributedString(attributed)
        var a: CGFloat = 0, d: CGFloat = 0
        box.width = CGFloat(CTLineGetTypographicBounds(line, &a, &d, nil))
        // Heights of the ink, as TeX and Word use them: Cambria Math's line metrics are far taller than its letters.
        let ink = CTLineGetImageBounds(line, nil)
        if ink.isNull || ink.isEmpty {
            box.ascent = f.xHeight
            box.descent = 0
        } else {
            box.ascent = max(f.xHeight, ink.maxY)
            box.descent = max(0, -ink.minY)
        }
        box.line = line
        return box
    }

    private func axis(_ level: Int) -> CGFloat { size * scale(level) * 0.25 }
    private func rule(_ level: Int) -> CGFloat { max(0.5, size * scale(level) * 0.055) }

    // MARK: Building

    /// One `m:oMath`.
    func layout(_ node: ConverterXMLNode) -> ConverterMathBox { row(node.children, level: 0) }

    private func row(_ nodes: [ConverterXMLNode], level: Int, style: String? = nil) -> ConverterMathBox {
        let box = ConverterMathBox()
        box.color = color
        var x: CGFloat = 0
        for n in nodes {
            guard let b = element(n, level: level, style: style) else { continue }
            box.add(b, x: x, y: 0)
            x += b.width
        }
        box.width = x
        return box
    }

    private func part(_ n: ConverterXMLNode, _ name: String, level: Int, style: String? = nil) -> ConverterMathBox {
        row(n.child(name)?.children ?? [], level: level, style: style)
    }

    private func prop(_ n: ConverterXMLNode, _ props: String, _ name: String) -> String? {
        n.child(props)?.child(name)?.val
    }

    private func element(_ n: ConverterXMLNode, level: Int, style: String?) -> ConverterMathBox? {
        switch n.name {
        case "r":
            let text = n.children.filter { $0.name == "t" }.map(\.text).joined()
            guard !text.isEmpty else { return nil }
            // m:rPr (math) and w:rPr (text) are both "rPr" here.
            var rStyle = n.all("rPr").compactMap { $0.child("sty")?.val }.first ?? style ?? "i"
            let normal = n.all("rPr").contains { $0.child("nor") != nil }
            if rStyle == "i", Self.functions.contains(text) { rStyle = "p" }
            return self.text(text, level: level, style: normal ? "p" : rStyle)
        case "e", "num", "den", "sub", "sup", "deg", "fName", "lim", "oMath": return row(n.children, level: level, style: style)
        case "f": return fraction(n, level: level)
        case "sSup", "sSub", "sSubSup", "sPre": return scripts(n, level: level)
        case "rad": return radical(n, level: level)
        case "d": return delimited(n, level: level)
        case "nary": return nary(n, level: level)
        case "func":
            let name = part(n, "fName", level: level, style: "p")
            let body = part(n, "e", level: level)
            let box = ConverterMathBox()
            box.add(name, x: 0, y: 0)
            box.add(body, x: name.width + size * scale(level) * 0.17, y: 0)
            return box
        case "acc": return accent(n, level: level)
        case "bar": return bar(n, level: level)
        case "groupChr": return group(n, level: level)
        case "limLow", "limUpp": return limit(n, level: level, upper: n.name == "limUpp")
        case "m": return matrix(n.all("mr").map { $0.all("e") }, level: level)
        case "eqArr": return matrix(n.all("e").map { [$0] }, level: level)
        case "box", "borderBox", "phant": return part(n, "e", level: level, style: style)
        case "AlternateContent": return row(n.child("Choice")?.children ?? n.child("Fallback")?.children ?? [], level: level, style: style)
        default: return nil
        }
    }

    private func fraction(_ n: ConverterXMLNode, level: Int) -> ConverterMathBox {
        let type = prop(n, "fPr", "type") ?? "bar"
        let inner = display ? level : level + 1
        let num = part(n, "num", level: type == "lin" || type == "skw" ? level : inner)
        let den = part(n, "den", level: type == "lin" || type == "skw" ? level : inner)
        let box = ConverterMathBox()
        box.color = color
        if type == "lin" || type == "skw" {
            let slash = text("/", level: level, spaced: false)
            box.add(num, x: 0, y: type == "skw" ? size * 0.2 : 0)
            box.add(slash, x: num.width, y: 0)
            box.add(den, x: num.width + slash.width, y: type == "skw" ? -size * 0.2 : 0)
            return box
        }
        let pad = size * scale(level) * 0.12
        let t = rule(level)
        let gap = size * scale(level) * (display ? 0.14 : 0.1)
        let a = axis(level)
        let w = max(num.width, den.width) + 2 * pad
        box.add(num, x: (w - num.width) / 2, y: a + t / 2 + gap + num.descent)
        box.add(den, x: (w - den.width) / 2, y: a - t / 2 - gap - den.ascent)
        if type != "noBar" {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: pad * 0.4, y: a))
            p.addLine(to: CGPoint(x: w - pad * 0.4, y: a))
            box.strokes.append((p, t, false))
        }
        box.width = w
        return box
    }

    private func scripts(_ n: ConverterXMLNode, level: Int) -> ConverterMathBox {
        let base = part(n, "e", level: level)
        let sup = n.child("sup").map { row($0.children, level: level + 1) }
        let sub = n.child("sub").map { row($0.children, level: level + 1) }
        let s = size * scale(level)
        var up = max(s * 0.4, base.ascent - (sup?.ascent ?? 0) * 0.55)
        var down = max(s * 0.18, base.descent + (sub?.ascent ?? 0) * 0.3 - s * 0.1)
        if let sup, let sub {
            let clash = (up - sup.descent) - (sub.ascent - down)
            if clash < s * 0.12 {
                up += (s * 0.12 - clash) / 2
                down += (s * 0.12 - clash) / 2
            }
        }
        let box = ConverterMathBox()
        box.color = color
        let gap = s * 0.04
        if n.name == "sPre" {
            let w = max(sup?.width ?? 0, sub?.width ?? 0)
            if let sup { box.add(sup, x: w - sup.width, y: up) }
            if let sub { box.add(sub, x: w - sub.width, y: -down) }
            box.add(base, x: w + gap, y: 0)
            return box
        }
        box.add(base, x: 0, y: 0)
        if let sup { box.add(sup, x: base.width + gap, y: up) }
        if let sub { box.add(sub, x: base.width + gap, y: -down) }
        box.width += s * 0.04
        return box
    }

    private func radical(_ n: ConverterXMLNode, level: Int) -> ConverterMathBox {
        let body = part(n, "e", level: level)
        let s = size * scale(level)
        let t = rule(level)
        let gap = s * 0.12
        let rw = s * 0.55
        let hideDegree = n.child("radPr")?.flag("degHide") ?? false
        let degree = hideDegree ? nil : n.child("deg").map { row($0.children, level: level + 2) }
        let shift = max(0, (degree?.width ?? 0) - rw * 0.45)
        let top = body.ascent + gap + t / 2
        let bottom = -body.descent - t
        let p = CGMutablePath()
        let mid = bottom + (top - bottom) * 0.45
        p.move(to: CGPoint(x: shift, y: mid))
        p.addLine(to: CGPoint(x: shift + rw * 0.22, y: mid + rw * 0.12))
        p.addLine(to: CGPoint(x: shift + rw * 0.55, y: bottom))
        p.addLine(to: CGPoint(x: shift + rw, y: top))
        p.addLine(to: CGPoint(x: shift + rw + body.width + s * 0.08, y: top))
        let box = ConverterMathBox()
        box.color = color
        box.strokes.append((p, t, false))
        box.add(body, x: shift + rw + s * 0.04, y: 0)
        if let degree, degree.width > 0 { box.add(degree, x: 0, y: mid + s * 0.15 + degree.descent) }
        box.width = shift + rw + body.width + s * 0.12
        box.ascent = max(box.ascent, top + t)
        box.descent = max(box.descent, -bottom + t)
        return box
    }

    /// A delimiter glyph, stretched to cover the content when it is taller than a line.
    private func fence(_ ch: String, ascent: CGFloat, descent: CGFloat, level: Int) -> ConverterMathBox {
        let glyph = text(ch, level: level, style: "p", spaced: false)
        let s = size * scale(level)
        guard ascent + descent > s * 1.2, let line = glyph.line else { return glyph }
        var a: CGFloat = 0, d: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &a, &d, nil)
        let k = (ascent + descent) / max(1, a + d)
        glyph.lineScale = k
        glyph.lineShift = d * k - descent
        glyph.ascent = ascent
        glyph.descent = descent
        glyph.width *= min(1.6, max(1, sqrt(k) * 0.9))
        return glyph
    }

    private func delimited(_ n: ConverterXMLNode, level: Int) -> ConverterMathBox {
        let pr = n.child("dPr")
        let open = pr?.child("begChr").map { $0.val ?? "" } ?? "("
        let close = pr?.child("endChr").map { $0.val ?? "" } ?? ")"
        let separator = pr?.child("sepChr").map { $0.val ?? "" } ?? "|"
        let inner = ConverterMathBox()
        inner.color = color
        var x: CGFloat = 0
        for (i, e) in n.all("e").enumerated() {
            if i > 0, !separator.isEmpty {
                let sep = text(separator, level: level, style: "p", spaced: false)
                inner.add(sep, x: x, y: 0)
                x += sep.width
            }
            let b = row(e.children, level: level)
            inner.add(b, x: x, y: 0)
            x += b.width
        }
        inner.width = x
        let a = axis(level)
        let half = max(inner.ascent - a, inner.descent + a) + size * scale(level) * 0.08
        let box = ConverterMathBox()
        box.color = color
        var cursor: CGFloat = 0
        if !open.isEmpty {
            let f = fence(open, ascent: a + half, descent: half - a, level: level)
            box.add(f, x: 0, y: 0)
            cursor = f.width
        }
        box.add(inner, x: cursor, y: 0)
        cursor += inner.width
        if !close.isEmpty {
            let f = fence(close, ascent: a + half, descent: half - a, level: level)
            box.add(f, x: cursor, y: 0)
            cursor += f.width
        }
        box.width = cursor
        return box
    }

    private func nary(_ n: ConverterXMLNode, level: Int) -> ConverterMathBox {
        let pr = n.child("naryPr")
        let op = pr?.child("chr")?.val ?? "∫"
        let integral = ["∫", "∬", "∭", "∮", "∯", "∰"].contains(op)
        let location = pr?.child("limLoc")?.val ?? (integral ? "subSup" : "undOvr")
        let sub = (pr?.flag("subHide") ?? false) ? nil : n.child("sub").map { row($0.children, level: level + 1) }
        let sup = (pr?.flag("supHide") ?? false) ? nil : n.child("sup").map { row($0.children, level: level + 1) }
        let body = part(n, "e", level: level)
        let s = size * scale(level)
        let opSize: CGFloat = display && level == 0 ? 1.45 : 1.15
        let glyph = ConverterMathBox()
        glyph.color = color
        let f = ConverterDocxFonts.font(Self.fontName, size: s * opSize, bold: false, italic: false, kind: nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: op, attributes: [.font: f, .foregroundColor: NSColor(cgColor: color) ?? .black]))
        var a: CGFloat = 0, d: CGFloat = 0
        glyph.width = CGFloat(CTLineGetTypographicBounds(line, &a, &d, nil))
        let ink = CTLineGetImageBounds(line, nil)
        let center = ink.isNull || ink.height == 0 ? (a - d) / 2 : ink.midY
        glyph.line = line
        glyph.lineShift = axis(level) - center
        glyph.ascent = (ink.isNull ? a : ink.maxY) + glyph.lineShift
        glyph.descent = -((ink.isNull ? -d : ink.minY) + glyph.lineShift)
        let box = ConverterMathBox()
        box.color = color
        var right: CGFloat
        if location == "undOvr" {
            let w = max(glyph.width, sub?.width ?? 0, sup?.width ?? 0)
            box.add(glyph, x: (w - glyph.width) / 2, y: 0)
            if let sup { box.add(sup, x: (w - sup.width) / 2, y: glyph.ascent + s * 0.1 + sup.descent) }
            if let sub { box.add(sub, x: (w - sub.width) / 2, y: -glyph.descent - s * 0.1 - sub.ascent) }
            right = w
        } else {
            box.add(glyph, x: 0, y: 0)
            let x = glyph.width + (integral ? -s * 0.05 : s * 0.05)
            if let sup { box.add(sup, x: x + s * 0.12, y: glyph.ascent - sup.ascent * 0.7) }
            if let sub { box.add(sub, x: x, y: -glyph.descent + sub.descent * 0.2) }
            right = max(glyph.width, x + max(sup.map { $0.width + s * 0.12 } ?? 0, sub?.width ?? 0))
        }
        box.add(body, x: right + s * 0.12, y: 0)
        box.width = right + s * 0.12 + body.width
        return box
    }

    private func accent(_ n: ConverterXMLNode, level: Int) -> ConverterMathBox {
        let body = part(n, "e", level: level)
        let mark = n.child("accPr")?.child("chr")?.val ?? "\u{0302}"
        let s = size * scale(level)
        let box = ConverterMathBox()
        box.color = color
        box.add(body, x: 0, y: 0)
        let top = body.ascent + s * 0.06
        let cx = body.width / 2 + s * 0.05
        let w = mark == "\u{0305}" || mark == "\u{0304}" || mark == "\u{20D7}" || mark == "\u{20D6}" || mark == "¯"
            ? max(s * 0.4, body.width * 0.9) : s * 0.38
        let p = CGMutablePath()
        var fill = false
        switch mark {
        case "\u{0305}", "\u{0304}", "¯", "\u{203E}":
            p.move(to: CGPoint(x: cx - w / 2, y: top + s * 0.06))
            p.addLine(to: CGPoint(x: cx + w / 2, y: top + s * 0.06))
        case "\u{20D7}", "\u{2192}":
            p.move(to: CGPoint(x: cx - w / 2, y: top + s * 0.08))
            p.addLine(to: CGPoint(x: cx + w / 2, y: top + s * 0.08))
            p.move(to: CGPoint(x: cx + w / 2 - s * 0.1, y: top + s * 0.14))
            p.addLine(to: CGPoint(x: cx + w / 2, y: top + s * 0.08))
            p.addLine(to: CGPoint(x: cx + w / 2 - s * 0.1, y: top + s * 0.02))
        case "\u{0307}", "\u{0308}":
            fill = true
            let r = s * 0.045
            let xs = mark == "\u{0307}" ? [cx] : [cx - s * 0.09, cx + s * 0.09]
            for x in xs { p.addEllipse(in: CGRect(x: x - r, y: top + s * 0.06, width: 2 * r, height: 2 * r)) }
        case "\u{0303}", "~":
            p.move(to: CGPoint(x: cx - w / 2, y: top + s * 0.05))
            p.addCurve(to: CGPoint(x: cx + w / 2, y: top + s * 0.09), control1: CGPoint(x: cx - w / 6, y: top + s * 0.2),
                       control2: CGPoint(x: cx + w / 6, y: top - s * 0.06))
        case "\u{030C}":
            p.move(to: CGPoint(x: cx - w / 2, y: top + s * 0.17))
            p.addLine(to: CGPoint(x: cx, y: top + s * 0.03))
            p.addLine(to: CGPoint(x: cx + w / 2, y: top + s * 0.17))
        default:
            p.move(to: CGPoint(x: cx - w / 2, y: top + s * 0.03))
            p.addLine(to: CGPoint(x: cx, y: top + s * 0.17))
            p.addLine(to: CGPoint(x: cx + w / 2, y: top + s * 0.03))
        }
        box.strokes.append((p, rule(level), fill))
        box.ascent = max(box.ascent, top + s * 0.22)
        return box
    }

    private func bar(_ n: ConverterXMLNode, level: Int) -> ConverterMathBox {
        let body = part(n, "e", level: level)
        let top = (prop(n, "barPr", "pos") ?? "bot") == "top"
        let s = size * scale(level)
        let t = rule(level)
        let box = ConverterMathBox()
        box.color = color
        box.add(body, x: 0, y: 0)
        let y = top ? body.ascent + s * 0.08 : -body.descent - s * 0.08
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: y))
        p.addLine(to: CGPoint(x: body.width, y: y))
        box.strokes.append((p, t, false))
        if top { box.ascent = max(box.ascent, y + t) } else { box.descent = max(box.descent, -y + t) }
        return box
    }

    private func group(_ n: ConverterXMLNode, level: Int) -> ConverterMathBox {
        let body = part(n, "e", level: level)
        let top = (prop(n, "groupChrPr", "pos") ?? "bot") == "top"
        let s = size * scale(level)
        let box = ConverterMathBox()
        box.color = color
        box.add(body, x: 0, y: 0)
        let y = top ? body.ascent + s * 0.1 : -body.descent - s * 0.1
        let h = (top ? 1 : -1) * s * 0.15
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: y))
        p.addQuadCurve(to: CGPoint(x: body.width / 2, y: y + h), control: CGPoint(x: 0, y: y + h))
        p.addQuadCurve(to: CGPoint(x: body.width, y: y), control: CGPoint(x: body.width, y: y + h))
        box.strokes.append((p, rule(level), false))
        if top { box.ascent = max(box.ascent, y + h) } else { box.descent = max(box.descent, -(y + h)) }
        return box
    }

    private func limit(_ n: ConverterXMLNode, level: Int, upper: Bool) -> ConverterMathBox {
        let base = part(n, "e", level: level)
        let lim = part(n, "lim", level: level + 1)
        let s = size * scale(level)
        let w = max(base.width, lim.width)
        let box = ConverterMathBox()
        box.color = color
        box.add(base, x: (w - base.width) / 2, y: 0)
        box.add(lim, x: (w - lim.width) / 2, y: upper ? base.ascent + s * 0.08 + lim.descent : -base.descent - s * 0.08 - lim.ascent)
        box.width = w
        return box
    }

    private func matrix(_ rows: [[ConverterXMLNode]], level: Int) -> ConverterMathBox {
        let cells = rows.map { $0.map { row($0.children, level: level) } }
        let columns = cells.map(\.count).max() ?? 0
        let s = size * scale(level)
        var widths = Array(repeating: CGFloat(0), count: columns)
        for r in cells { for (i, c) in r.enumerated() { widths[i] = max(widths[i], c.width) } }
        let colGap = s * 0.7, rowGap = s * 0.25
        let heights = cells.map { r in (r.map(\.ascent).max() ?? s * 0.7, r.map(\.descent).max() ?? s * 0.2) }
        let total = heights.reduce(0) { $0 + $1.0 + $1.1 } + rowGap * CGFloat(max(0, cells.count - 1))
        let box = ConverterMathBox()
        box.color = color
        var y = axis(level) + total / 2
        for (ri, r) in cells.enumerated() {
            y -= heights[ri].0
            var x: CGFloat = 0
            for (ci, c) in r.enumerated() {
                box.add(c, x: x + (widths[ci] - c.width) / 2, y: y)
                x += widths[ci] + colGap
            }
            y -= heights[ri].1 + rowGap
        }
        box.width = widths.reduce(0, +) + colGap * CGFloat(max(0, columns - 1))
        return box
    }
}

/// An equation in the text, drawn in any graphics context (off the main thread too).
final class ConverterMathCell: NSTextAttachmentCell {
    private let box: ConverterMathBox

    init(_ box: ConverterMathBox) {
        self.box = box
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func cellSize() -> NSSize { NSSize(width: box.width, height: box.ascent + box.descent) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -box.descent) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        if !(NSGraphicsContext.current?.isFlipped ?? false) {
            ctx.translateBy(x: 0, y: cellFrame.minY + cellFrame.maxY)
            ctx.scaleBy(x: 1, y: -1)
        }
        box.draw(ctx, x: cellFrame.minX, baseline: cellFrame.minY + box.ascent)
        ctx.restoreGState()
    }
}
