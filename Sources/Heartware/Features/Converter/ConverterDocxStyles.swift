import AppKit
import CoreText

// MARK: - Units and colors

enum ConverterDocxUnit {
    /// Twentieths of a point (Word's usual unit), or a length with its unit ("12pt", "2.5cm").
    static func twips(_ s: String?) -> CGFloat? {
        guard let s, !s.isEmpty else { return nil }
        if let v = Double(s) { return CGFloat(v) / 20 }
        let units: [(String, Double)] = [("pt", 1), ("in", 72), ("cm", 72 / 2.54), ("mm", 72 / 25.4), ("pc", 12), ("pi", 12)]
        for (suffix, factor) in units where s.hasSuffix(suffix) {
            if let v = Double(s.dropLast(suffix.count)) { return CGFloat(v * factor) }
        }
        return nil
    }

    /// English Metric Units (drawings): 12 700 per point.
    static func emu(_ s: String?) -> CGFloat? {
        guard let s, let v = Double(s) else { return nil }
        return CGFloat(v) / 12_700
    }
}

/// Colors stay as "RRGGBB" strings in properties; "none" removes an inherited highlight or shading.
enum ConverterDocxColor {
    static func color(_ hex: String?) -> NSColor? {
        guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func isHex(_ s: String?) -> Bool {
        guard let s, s.count == 6 else { return false }
        return UInt32(s, radix: 16) != nil
    }

    static func components(_ hex: String) -> (Double, Double, Double) {
        let v = UInt32(hex, radix: 16) ?? 0
        return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
    }

    static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        func c(_ x: Double) -> Int { Int(max(0, min(255, x.rounded()))) }
        return String(format: "%02X%02X%02X", c(r), c(g), c(b))
    }

    /// `w:themeTint` lightens towards white, `w:themeShade` darkens (hex byte, FF = unchanged).
    static func adjust(_ hex: String, tint: String?, shade: String?) -> String {
        var (r, g, b) = components(hex)
        if let t = tint.flatMap({ UInt8($0, radix: 16) }) {
            let f = Double(t) / 255
            r = r * f + 255 * (1 - f); g = g * f + 255 * (1 - f); b = b * f + 255 * (1 - f)
        }
        if let s = shade.flatMap({ UInt8($0, radix: 16) }) {
            let f = Double(s) / 255
            r *= f; g *= f; b *= f
        }
        return self.hex(r, g, b)
    }

    /// `fraction` of `top` over `base`.
    static func mix(_ base: String, _ top: String, _ fraction: Double) -> String {
        let a = components(base), b = components(top)
        return hex(a.0 + (b.0 - a.0) * fraction, a.1 + (b.1 - a.1) * fraction, a.2 + (b.2 - a.2) * fraction)
    }

    /// DrawingML luminance modifiers (`lumMod`, `lumOff`, `tint`, `shade`, in thousandths of a percent).
    static func drawing(_ hex: String, modifiers: [ConverterXMLNode]) -> String {
        var (r, g, b) = components(hex)
        for m in modifiers {
            guard let v = m.val.flatMap(Double.init).map({ $0 / 100_000 }) else { continue }
            switch m.name {
            case "lumMod": r *= v; g *= v; b *= v
            case "lumOff": r += 255 * v; g += 255 * v; b += 255 * v
            case "tint": r = r * v + 255 * (1 - v); g = g * v + 255 * (1 - v); b = b * v + 255 * (1 - v)
            case "shade": r *= v; g *= v; b *= v
            default: break
            }
        }
        return self.hex(r, g, b)
    }

    static let highlights: [String: String] = [
        "yellow": "FFFF00", "green": "00FF00", "cyan": "00FFFF", "magenta": "FF00FF", "blue": "0000FF", "red": "FF0000",
        "darkBlue": "000080", "darkCyan": "008080", "darkGreen": "008000", "darkMagenta": "800080", "darkRed": "800000",
        "darkYellow": "808000", "darkGray": "808080", "lightGray": "C0C0C0", "black": "000000", "white": "FFFFFF"
    ]

    /// `w:color` (its `w:val`) or a border (its `w:color`): the RGB value, or the theme color when only that is given;
    /// "auto" stays "auto".
    static func text(_ e: ConverterXMLNode, theme: ConverterDocxTheme, attribute: String = "val") -> String? {
        if let v = e[attribute], isHex(v) { return v.uppercased() }
        if let name = e["themeColor"], let base = theme.color(name) {
            return adjust(base, tint: e["themeTint"], shade: e["themeShade"])
        }
        return e[attribute] == "auto" ? "auto" : nil
    }

    /// `w:shd`: the fill, or a pattern of its color over the fill.
    static func shading(_ e: ConverterXMLNode, theme: ConverterDocxTheme) -> String {
        var fill = e["fill"].flatMap { isHex($0) ? $0.uppercased() : nil }
        if fill == nil, let name = e["themeFill"], let base = theme.color(name) {
            fill = adjust(base, tint: e["themeFillTint"], shade: e["themeFillShade"])
        }
        let pattern = e.val ?? "clear"
        let color = e["color"].flatMap { isHex($0) ? $0.uppercased() : nil } ?? "000000"
        if pattern == "solid" { return color }
        if pattern.hasPrefix("pct"), let pct = Double(pattern.dropFirst(3)), pct > 0 {
            return mix(fill ?? "FFFFFF", color, pct / 100)
        }
        return fill ?? "none"
    }
}

// MARK: - Theme

struct ConverterDocxTheme {
    var major = "Calibri Light"
    var minor = "Calibri"
    var colors: [String: String] = [:]

    init() {}

    init(_ root: ConverterXMLNode?) {
        guard let elements = root?.find("themeElements") else { return }
        if let scheme = elements.child("clrScheme") {
            for c in scheme.children {
                if let v = c.child("srgbClr")?.val { colors[c.name] = v.uppercased() } else if let sys = c.child("sysClr") {
                    colors[c.name] = sys["lastClr"] ?? (sys.val == "window" ? "FFFFFF" : "000000")
                }
            }
        }
        if let fonts = elements.child("fontScheme") {
            if let f = fonts.child("majorFont")?.child("latin")?["typeface"], !f.isEmpty { major = f }
            if let f = fonts.child("minorFont")?.child("latin")?["typeface"], !f.isEmpty { minor = f }
        }
    }

    func font(_ themeName: String) -> String { themeName.hasPrefix("major") ? major : minor }

    func color(_ name: String) -> String? {
        switch name {
        case "text1", "dark1", "tx1", "dk1": return colors["dk1"]
        case "background1", "light1", "bg1", "lt1": return colors["lt1"]
        case "text2", "dark2", "tx2", "dk2": return colors["dk2"]
        case "background2", "light2", "bg2", "lt2": return colors["lt2"]
        case "hyperlink", "hlink": return colors["hlink"]
        case "followedHyperlink", "folHlink": return colors["folHlink"]
        default: return colors[name]
        }
    }

    /// A DrawingML color element holder (`a:solidFill`, `a:ln`…): its first `srgbClr`, `schemeClr` or `sysClr`.
    func drawingColor(_ holder: ConverterXMLNode?) -> String? {
        guard let holder else { return nil }
        for c in holder.children {
            switch c.name {
            case "srgbClr": if let v = c.val { return ConverterDocxColor.drawing(v, modifiers: c.children) }
            case "schemeClr": if let v = c.val, let base = color(v) { return ConverterDocxColor.drawing(base, modifiers: c.children) }
            case "sysClr": return c["lastClr"] ?? "000000"
            default: break
            }
        }
        return nil
    }
}

// MARK: - Properties

struct ConverterDocxBorder: Equatable {
    var style = "single"
    var width: CGFloat = 0.5
    var space: CGFloat = 0
    var color: String?

    var visible: Bool { !["nil", "none"].contains(style) && width > 0 }

    static func parse(_ e: ConverterXMLNode, theme: ConverterDocxTheme) -> ConverterDocxBorder {
        var b = ConverterDocxBorder()
        b.style = e.val ?? "single"
        if let sz = e["sz"].flatMap(Double.init) { b.width = max(0.25, CGFloat(sz) / 8) }
        if b.style.hasPrefix("thick") && e["sz"] == nil { b.width = 1.5 }
        if b.style == "double" || b.style.hasPrefix("triple") { b.width *= 2 }
        b.space = e["space"].flatMap(Double.init).map { CGFloat($0) } ?? 0
        b.color = ConverterDocxColor.text(e, theme: theme, attribute: "color")
        return b
    }

    static func parseAll(_ e: ConverterXMLNode?, theme: ConverterDocxTheme) -> [String: ConverterDocxBorder] {
        var out: [String: ConverterDocxBorder] = [:]
        for c in e?.children ?? [] {
            let edge = c.name == "start" ? "left" : (c.name == "end" ? "right" : c.name)
            out[edge] = parse(c, theme: theme)
        }
        return out
    }
}

struct ConverterDocxTab: Equatable {
    var position: CGFloat
    var align: String
    var leader: String?
}

struct ConverterDocxRunProps: Equatable {
    var font: String?
    var size: CGFloat?
    var bold: Bool?
    var italic: Bool?
    var underline: String?
    var underlineColor: String?
    var strike: Bool?
    var doubleStrike: Bool?
    var color: String?
    var highlight: String?
    var shading: String?
    var vertAlign: String?
    var caps: Bool?
    var smallCaps: Bool?
    var hidden: Bool?
    var spacing: CGFloat?
    var position: CGFloat?
    var charStyle: String?

    mutating func merge(_ o: ConverterDocxRunProps) {
        font = o.font ?? font
        size = o.size ?? size
        bold = o.bold ?? bold
        italic = o.italic ?? italic
        underline = o.underline ?? underline
        underlineColor = o.underlineColor ?? underlineColor
        strike = o.strike ?? strike
        doubleStrike = o.doubleStrike ?? doubleStrike
        color = o.color ?? color
        highlight = o.highlight ?? highlight
        shading = o.shading ?? shading
        vertAlign = o.vertAlign ?? vertAlign
        caps = o.caps ?? caps
        smallCaps = o.smallCaps ?? smallCaps
        hidden = o.hidden ?? hidden
        spacing = o.spacing ?? spacing
        position = o.position ?? position
    }

    func merged(_ o: ConverterDocxRunProps) -> ConverterDocxRunProps {
        var copy = self
        copy.merge(o)
        return copy
    }

    static func parse(_ e: ConverterXMLNode?, theme: ConverterDocxTheme) -> ConverterDocxRunProps {
        var p = ConverterDocxRunProps()
        guard let e else { return p }
        if let f = e.child("rFonts") {
            if let t = f["asciiTheme"] ?? f["hAnsiTheme"] { p.font = theme.font(t) } else if let a = f["ascii"] ?? f["hAnsi"] { p.font = a }
        }
        if let v = e.child("sz")?.val.flatMap(Double.init) { p.size = CGFloat(v) / 2 }
        p.bold = e.flag("b")
        p.italic = e.flag("i")
        p.strike = e.flag("strike")
        p.doubleStrike = e.flag("dstrike")
        p.caps = e.flag("caps")
        p.smallCaps = e.flag("smallCaps")
        p.hidden = e.flag("vanish")
        if let u = e.child("u") {
            p.underline = u.val ?? "single"
            if let c = u["color"], ConverterDocxColor.isHex(c) { p.underlineColor = c }
        }
        if let c = e.child("color") { p.color = ConverterDocxColor.text(c, theme: theme) }
        if let h = e.child("highlight")?.val { p.highlight = ConverterDocxColor.highlights[h] ?? "none" }
        if let s = e.child("shd") { p.shading = ConverterDocxColor.shading(s, theme: theme) }
        p.vertAlign = e.child("vertAlign")?.val
        p.spacing = ConverterDocxUnit.twips(e.child("spacing")?.val)
        if let v = e.child("position")?.val.flatMap(Double.init) { p.position = CGFloat(v) / 2 }
        p.charStyle = e.child("rStyle")?.val
        return p
    }
}

struct ConverterDocxParaProps: Equatable {
    var align: String?
    var left: CGFloat?
    var right: CGFloat?
    var firstLine: CGFloat?
    var before: CGFloat?
    var after: CGFloat?
    var beforeAuto: Bool?
    var afterAuto: Bool?
    var line: CGFloat?
    var lineRule: String?
    var contextual: Bool?
    var keepNext: Bool?
    var keepLines: Bool?
    var pageBreakBefore: Bool?
    var widowControl: Bool?
    var numID: String?
    var numLevel: Int?
    var borders: [String: ConverterDocxBorder] = [:]
    var shading: String?
    var tabs: [ConverterDocxTab] = []
    var bidi: Bool?
    var style: String?

    mutating func merge(_ o: ConverterDocxParaProps) {
        align = o.align ?? align
        left = o.left ?? left
        right = o.right ?? right
        firstLine = o.firstLine ?? firstLine
        before = o.before ?? before
        after = o.after ?? after
        beforeAuto = o.beforeAuto ?? beforeAuto
        afterAuto = o.afterAuto ?? afterAuto
        line = o.line ?? line
        lineRule = o.lineRule ?? lineRule
        contextual = o.contextual ?? contextual
        keepNext = o.keepNext ?? keepNext
        keepLines = o.keepLines ?? keepLines
        pageBreakBefore = o.pageBreakBefore ?? pageBreakBefore
        widowControl = o.widowControl ?? widowControl
        if o.numID != nil { numID = o.numID; numLevel = o.numLevel ?? 0 } else if o.numLevel != nil { numLevel = o.numLevel }
        for (edge, b) in o.borders { borders[edge] = b }
        shading = o.shading ?? shading
        for t in o.tabs {
            tabs.removeAll { abs($0.position - t.position) < 0.5 }
            if t.align != "clear" { tabs.append(t) }
        }
        tabs.sort { $0.position < $1.position }
        bidi = o.bidi ?? bidi
    }

    static func parse(_ e: ConverterXMLNode?, theme: ConverterDocxTheme) -> ConverterDocxParaProps {
        var p = ConverterDocxParaProps()
        guard let e else { return p }
        p.style = e.child("pStyle")?.val
        p.align = e.child("jc")?.val
        if let ind = e.child("ind") {
            p.left = ConverterDocxUnit.twips(ind["left"] ?? ind["start"])
            p.right = ConverterDocxUnit.twips(ind["right"] ?? ind["end"])
            if let h = ConverterDocxUnit.twips(ind["hanging"]) { p.firstLine = -h } else { p.firstLine = ConverterDocxUnit.twips(ind["firstLine"]) }
        }
        if let s = e.child("spacing") {
            p.before = ConverterDocxUnit.twips(s["before"])
            p.after = ConverterDocxUnit.twips(s["after"])
            if p.before == nil, let lines = s["beforeLines"].flatMap(Double.init) { p.before = CGFloat(lines) * 0.12 }
            if p.after == nil, let lines = s["afterLines"].flatMap(Double.init) { p.after = CGFloat(lines) * 0.12 }
            if let a = s["beforeAutospacing"] { p.beforeAuto = a == "1" || a == "true" || a == "on" }
            if let a = s["afterAutospacing"] { p.afterAuto = a == "1" || a == "true" || a == "on" }
            if let line = s["line"].flatMap(Double.init) {
                p.line = CGFloat(line)
                p.lineRule = s["lineRule"] ?? "auto"
            }
        }
        p.contextual = e.flag("contextualSpacing")
        p.keepNext = e.flag("keepNext")
        p.keepLines = e.flag("keepLines")
        p.pageBreakBefore = e.flag("pageBreakBefore")
        p.widowControl = e.flag("widowControl")
        if let num = e.child("numPr") {
            p.numID = num.child("numId")?.val
            p.numLevel = num.child("ilvl")?.val.flatMap(Int.init)
        }
        p.borders = ConverterDocxBorder.parseAll(e.child("pBdr"), theme: theme)
        if let s = e.child("shd") { p.shading = ConverterDocxColor.shading(s, theme: theme) }
        for t in e.child("tabs")?.all("tab") ?? [] {
            guard let pos = ConverterDocxUnit.twips(t["pos"]) else { continue }
            p.tabs.append(ConverterDocxTab(position: pos, align: t.val ?? "left", leader: t["leader"]))
        }
        p.bidi = e.flag("bidi")
        return p
    }
}

struct ConverterDocxTableProps: Equatable {
    var width: CGFloat?
    var widthType: String?
    var align: String?
    var indent: CGFloat?
    var borders: [String: ConverterDocxBorder] = [:]
    var margins: [String: CGFloat] = [:]
    var shading: String?
    var rowBand: Int?
    var colBand: Int?

    mutating func merge(_ o: ConverterDocxTableProps) {
        width = o.width ?? width
        widthType = o.widthType ?? widthType
        align = o.align ?? align
        indent = o.indent ?? indent
        for (edge, b) in o.borders { borders[edge] = b }
        for (edge, m) in o.margins { margins[edge] = m }
        shading = o.shading ?? shading
        rowBand = o.rowBand ?? rowBand
        colBand = o.colBand ?? colBand
    }

    static func margins(_ e: ConverterXMLNode?) -> [String: CGFloat] {
        var out: [String: CGFloat] = [:]
        for c in e?.children ?? [] where c["type"] != "pct" {
            let edge = c.name == "start" ? "left" : (c.name == "end" ? "right" : c.name)
            if let w = ConverterDocxUnit.twips(c["w"]) { out[edge] = w }
        }
        return out
    }

    static func parse(_ e: ConverterXMLNode?, theme: ConverterDocxTheme) -> ConverterDocxTableProps {
        var p = ConverterDocxTableProps()
        guard let e else { return p }
        if let w = e.child("tblW") {
            p.widthType = w["type"] ?? "dxa"
            if p.widthType == "pct" {
                let raw = w["w"] ?? "0"
                p.width = raw.hasSuffix("%") ? CGFloat(Double(raw.dropLast()) ?? 0) : CGFloat(Double(raw) ?? 0) / 50
            } else {
                p.width = ConverterDocxUnit.twips(w["w"])
            }
        }
        p.align = e.child("jc")?.val
        p.indent = ConverterDocxUnit.twips(e.child("tblInd")?["w"])
        p.borders = ConverterDocxBorder.parseAll(e.child("tblBorders"), theme: theme)
        p.margins = margins(e.child("tblCellMar"))
        if let s = e.child("shd") { p.shading = ConverterDocxColor.shading(s, theme: theme) }
        p.rowBand = e.child("tblStyleRowBandSize")?.val.flatMap(Int.init)
        p.colBand = e.child("tblStyleColBandSize")?.val.flatMap(Int.init)
        return p
    }

    /// `w:tblLook`: which conditional parts of the table style apply.
    static func look(_ e: ConverterXMLNode?) -> Set<String> {
        guard let look = e?.child("tblLook") else { return ["firstRow", "firstColumn", "noVBand"] }
        var out: Set<String> = []
        let bits = look.val.flatMap { Int($0, radix: 16) }
        let names = [("firstRow", 0x20), ("lastRow", 0x40), ("firstColumn", 0x80), ("lastColumn", 0x100), ("noHBand", 0x200), ("noVBand", 0x400)]
        for (name, bit) in names {
            if let v = look[name] { if v == "1" || v == "true" { out.insert(name) } } else if let bits, bits & bit != 0 { out.insert(name) }
        }
        return out
    }
}

struct ConverterDocxCellProps: Equatable {
    var width: CGFloat?
    var widthType: String?
    var span: Int?
    var vMerge: String?
    var borders: [String: ConverterDocxBorder] = [:]
    var shading: String?
    var vAlign: String?
    var margins: [String: CGFloat] = [:]

    mutating func merge(_ o: ConverterDocxCellProps) {
        for (edge, b) in o.borders { borders[edge] = b }
        shading = o.shading ?? shading
        vAlign = o.vAlign ?? vAlign
        for (edge, m) in o.margins { margins[edge] = m }
    }

    static func parse(_ e: ConverterXMLNode?, theme: ConverterDocxTheme) -> ConverterDocxCellProps {
        var p = ConverterDocxCellProps()
        guard let e else { return p }
        if let w = e.child("tcW") {
            p.widthType = w["type"] ?? "dxa"
            p.width = p.widthType == "dxa" ? ConverterDocxUnit.twips(w["w"]) : nil
        }
        p.span = e.child("gridSpan")?.val.flatMap(Int.init)
        if let v = e.child("vMerge") { p.vMerge = v.val ?? "continue" }
        p.borders = ConverterDocxBorder.parseAll(e.child("tcBorders"), theme: theme)
        if let s = e.child("shd") { p.shading = ConverterDocxColor.shading(s, theme: theme) }
        p.vAlign = e.child("vAlign")?.val
        p.margins = ConverterDocxTableProps.margins(e.child("tcMar"))
        return p
    }
}

// MARK: - Styles

/// The formatting a table style gives one of its parts (header row, banded rows…).
struct ConverterDocxConditional {
    var para = ConverterDocxParaProps()
    var run = ConverterDocxRunProps()
    var table = ConverterDocxTableProps()
    var cell = ConverterDocxCellProps()

    mutating func merge(_ o: ConverterDocxConditional) {
        para.merge(o.para)
        run.merge(o.run)
        table.merge(o.table)
        cell.merge(o.cell)
    }
}

final class ConverterDocxStyle {
    let id: String
    let type: String
    var basedOn: String?
    var base = ConverterDocxConditional()
    var conditional: [String: ConverterDocxConditional] = [:]

    init(id: String, type: String) {
        self.id = id
        self.type = type
    }
}

final class ConverterDocxStyles {
    private(set) var byID: [String: ConverterDocxStyle] = [:]
    private(set) var defaultRun = ConverterDocxRunProps()
    private(set) var defaultPara = ConverterDocxParaProps()
    private(set) var defaultParagraphStyle: String?
    private(set) var defaultTableStyle: String?
    private var resolved: [String: ConverterDocxConditional] = [:]
    private var resolvedConditional: [String: [String: ConverterDocxConditional]] = [:]

    init(_ root: ConverterXMLNode?, theme: ConverterDocxTheme) {
        guard let root else { return }
        if let defaults = root.child("docDefaults") {
            defaultRun = ConverterDocxRunProps.parse(defaults.child("rPrDefault")?.child("rPr"), theme: theme)
            defaultPara = ConverterDocxParaProps.parse(defaults.child("pPrDefault")?.child("pPr"), theme: theme)
        }
        for s in root.all("style") {
            guard let id = s["styleId"] else { continue }
            let type = s["type"] ?? "paragraph"
            let style = ConverterDocxStyle(id: id, type: type)
            style.basedOn = s.child("basedOn")?.val
            style.base = Self.parts(s, theme: theme)
            for c in s.all("tblStylePr") {
                if let t = c["type"] { style.conditional[t] = Self.parts(c, theme: theme) }
            }
            byID[id] = style
            if s["default"] == "1" || s["default"] == "true" {
                if type == "paragraph" { defaultParagraphStyle = id }
                if type == "table" { defaultTableStyle = id }
            }
        }
    }

    private static func parts(_ e: ConverterXMLNode, theme: ConverterDocxTheme) -> ConverterDocxConditional {
        var c = ConverterDocxConditional()
        c.para = ConverterDocxParaProps.parse(e.child("pPr"), theme: theme)
        c.run = ConverterDocxRunProps.parse(e.child("rPr"), theme: theme)
        c.table = ConverterDocxTableProps.parse(e.child("tblPr"), theme: theme)
        c.cell = ConverterDocxCellProps.parse(e.child("tcPr"), theme: theme)
        return c
    }

    /// The style and its ancestors, base first.
    private func chain(_ id: String) -> [ConverterDocxStyle] {
        var out: [ConverterDocxStyle] = []
        var next: String? = id
        while let n = next, let s = byID[n], out.count < 24, !out.contains(where: { $0 === s }) {
            out.insert(s, at: 0)
            next = s.basedOn
        }
        return out
    }

    /// Everything a style defines, its ancestors included (document defaults excluded).
    func style(_ id: String?) -> ConverterDocxConditional {
        guard let id else { return ConverterDocxConditional() }
        if let r = resolved[id] { return r }
        var out = ConverterDocxConditional()
        for s in chain(id) { out.merge(s.base) }
        resolved[id] = out
        return out
    }

    func conditional(_ id: String?) -> [String: ConverterDocxConditional] {
        guard let id else { return [:] }
        if let r = resolvedConditional[id] { return r }
        var out: [String: ConverterDocxConditional] = [:]
        for s in chain(id) {
            for (type, c) in s.conditional { out[type, default: ConverterDocxConditional()].merge(c) }
        }
        resolvedConditional[id] = out
        return out
    }

    func exists(_ id: String?) -> Bool { id.map { byID[$0] != nil } ?? false }
}

// MARK: - Numbering

struct ConverterDocxLevel {
    var start = 1
    var format = "decimal"
    var text = ""
    var suffix = "tab"
    var legal = false
    var para = ConverterDocxParaProps()
    var run = ConverterDocxRunProps()

    static func parse(_ e: ConverterXMLNode, theme: ConverterDocxTheme) -> ConverterDocxLevel {
        var l = ConverterDocxLevel()
        l.start = e.child("start")?.val.flatMap(Int.init) ?? 1
        l.format = e.child("numFmt")?.val ?? "decimal"
        l.text = e.child("lvlText")?.val ?? ""
        l.suffix = e.child("suff")?.val ?? "tab"
        l.legal = e.flag("isLgl") ?? false
        l.para = ConverterDocxParaProps.parse(e.child("pPr"), theme: theme)
        l.run = ConverterDocxRunProps.parse(e.child("rPr"), theme: theme)
        return l
    }
}

final class ConverterDocxNumbering {
    private var abstracts: [String: [Int: ConverterDocxLevel]] = [:]
    private var styleLinks: [String: String] = [:]
    private var nums: [String: (abstract: String, starts: [Int: Int], levels: [Int: ConverterDocxLevel])] = [:]
    private var counters: [String: [Int: Int]] = [:]
    private var restarted: Set<String> = []

    init(_ root: ConverterXMLNode?, theme: ConverterDocxTheme) {
        guard let root else { return }
        for a in root.all("abstractNum") {
            guard let id = a["abstractNumId"] else { continue }
            var levels: [Int: ConverterDocxLevel] = [:]
            for l in a.all("lvl") {
                if let i = l["ilvl"].flatMap(Int.init) { levels[i] = ConverterDocxLevel.parse(l, theme: theme) }
            }
            abstracts[id] = levels
            if let link = a.child("numStyleLink")?.val { styleLinks[id] = link }
        }
        for n in root.all("num") {
            guard let id = n["numId"], let abstract = n.child("abstractNumId")?.val else { continue }
            var starts: [Int: Int] = [:]
            var levels: [Int: ConverterDocxLevel] = [:]
            for o in n.all("lvlOverride") {
                guard let i = o["ilvl"].flatMap(Int.init) else { continue }
                if let s = o.child("startOverride")?.val.flatMap(Int.init) { starts[i] = s }
                if let l = o.child("lvl") { levels[i] = ConverterDocxLevel.parse(l, theme: theme) }
            }
            nums[id] = (abstract, starts, levels)
        }
    }

    /// The list definition behind a `w:numId`, following numbering styles (`w:numStyleLink`).
    private func abstract(_ num: String, styles: ConverterDocxStyles) -> String? {
        guard var abstract = nums[num]?.abstract else { return nil }
        var hops = 0
        while abstracts[abstract]?.isEmpty ?? true, let link = styleLinks[abstract], hops < 4,
              let linked = styles.style(link).para.numID, let target = nums[linked]?.abstract, target != abstract {
            abstract = target
            hops += 1
        }
        return abstract
    }

    func level(_ num: String, _ level: Int, styles: ConverterDocxStyles) -> ConverterDocxLevel? {
        if let override = nums[num]?.levels[level] { return override }
        guard let abstract = abstract(num, styles: styles) else { return nil }
        return abstracts[abstract]?[level]
    }

    /// Advances the counters and returns the label of this paragraph ("2.1.", "•"…).
    func next(_ num: String, _ level: Int, styles: ConverterDocxStyles) -> String? {
        guard (0...8).contains(level), let abstract = abstract(num, styles: styles), let def = self.level(num, level, styles: styles) else { return nil }
        var c = counters[abstract] ?? [:]
        if !restarted.contains(num), let starts = nums[num]?.starts, !starts.isEmpty {
            restarted.insert(num)
            for (l, s) in starts where (0...8).contains(l) {
                c[l] = s - 1
                for deeper in (l + 1)..<10 { c[deeper] = nil }
            }
        }
        let value = c[level].map { $0 + 1 } ?? def.start
        c[level] = value
        for deeper in (level + 1)..<10 { c[deeper] = nil }
        counters[abstract] = c
        if def.format == "bullet" { return def.text }
        var text = def.text
        for k in stride(from: 9, through: 1, by: -1) where text.contains("%\(k)") {
            let l = k - 1
            let ldef = self.level(num, l, styles: styles)
            let v = l == level ? value : (c[l] ?? ldef?.start ?? 1)
            let format = (def.legal && l < level) ? "decimal" : (ldef?.format ?? "decimal")
            text = text.replacingOccurrences(of: "%\(k)", with: Self.format(v, format))
        }
        return text
    }

    static func format(_ n: Int, _ format: String) -> String {
        switch format {
        case "decimalZero": return n < 10 ? "0\(n)" : "\(n)"
        case "upperLetter", "lowerLetter":
            guard n > 0 else { return "\(n)" }
            let letter = Character(UnicodeScalar(UInt8(65 + (n - 1) % 26)))
            let s = String(repeating: letter, count: (n - 1) / 26 + 1)
            return format == "lowerLetter" ? s.lowercased() : s
        case "upperRoman", "lowerRoman":
            let s = roman(n)
            return format == "lowerRoman" ? s.lowercased() : s
        case "none": return ""
        case "decimalEnclosedCircle":
            return (1...20).contains(n) ? String(UnicodeScalar(0x2460 + n - 1)!) : "\(n)"
        default: return "\(n)"
        }
    }

    static func roman(_ n: Int) -> String {
        guard n > 0, n < 4000 else { return "\(n)" }
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var rest = n
        var out = ""
        for (v, s) in table {
            while rest >= v {
                out += s
                rest -= v
            }
        }
        return out
    }

    /// Symbol and Wingdings bullets (private-use characters) as ordinary characters, when the meaning is known.
    static func symbol(_ text: String, font: String?) -> (text: String, keepFont: Bool) {
        let symbolFonts: Set<String> = ["Symbol", "Wingdings", "Wingdings 2", "Wingdings 3", "Webdings"]
        guard let font, symbolFonts.contains(font) else { return (text, true) }
        let known: [UInt32: String] = font == "Symbol"
            ? [0xB7: "•", 0x2D: "–", 0xA7: "♣", 0xA8: "♦", 0xA9: "♥", 0xAA: "♠", 0xAE: "→", 0xDE: "⇒", 0xD8: "¬", 0x6F: "ο", 0xB0: "°", 0xE0: "◊"]
            : [0xA7: "▪", 0xA8: "◻", 0x6E: "■", 0x71: "❑", 0x76: "❖", 0xD8: "➢", 0xFC: "✓", 0xFB: "✗", 0x9F: "•", 0x77: "⬥",
               0xE8: "➔", 0xF0: "⇨", 0x6C: "●", 0x6F: "□", 0xA1: "○", 0x75: "◆", 0x8C: "①", 0xE0: "→", 0x4A: "☺", 0x46: "☞"]
        var out = ""
        for scalar in text.unicodeScalars {
            let code = scalar.value >= 0xF000 && scalar.value <= 0xF0FF ? scalar.value - 0xF000 : scalar.value
            if let mapped = known[code] { out += mapped } else { return (text, true) }
        }
        return (out, false)
    }
}

// MARK: - Fonts

/// Word fonts as macOS fonts: installed families first, then the fonts Microsoft Office ships in its bundle
/// (read in place, nothing is installed), then a close substitute.
enum ConverterDocxFonts {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: Set<String>?
    nonisolated(unsafe) private static var office: [String: [CTFontDescriptor]]?
    nonisolated(unsafe) private static var cache: [String: NSFont] = [:]

    static let officeFolders = ["Microsoft Word", "Microsoft Excel", "Microsoft PowerPoint", "Microsoft Outlook", "Microsoft OneNote"]
        .map { "/Applications/\($0).app/Contents/Resources/DFonts" }

    private static let sans: Set<String> = ["calibri", "calibri light", "aptos", "aptos display", "aptos narrow", "segoe ui", "segoe ui light",
                                            "carlito", "corbel", "candara", "tahoma", "century gothic", "franklin gothic book", "gill sans mt",
                                            "lato", "open sans", "roboto", "source sans pro", "montserrat", "poppins", "liberation sans", "arimo"]
    private static let serif: Set<String> = ["cambria", "constantia", "book antiqua", "garamond", "palatino linotype", "bookman old style",
                                             "century schoolbook", "caladea", "liberation serif", "tinos", "minion pro", "sitka text"]
    private static let mono: Set<String> = ["consolas", "lucida console", "liberation mono", "cousine", "source code pro", "inconsolata"]

    /// Whether a family can be drawn as itself (installed, or shipped with Microsoft Office).
    static func exists(_ family: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if installed == nil { installed = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []) }
        if installed?.contains(family) == true { return true }
        if office == nil { office = indexOffice() }
        return office?[family.lowercased()]?.isEmpty == false
    }

    static func font(_ family: String?, size: CGFloat, bold: Bool, italic: Bool, kind: String?) -> NSFont {
        let name = family ?? "Times New Roman"
        let key = "\(name)|\(size)|\(bold)|\(italic)"
        lock.lock()
        defer { lock.unlock() }
        if let f = cache[key] { return f }
        let f = make(name, size: size, bold: bold, italic: italic, kind: kind)
        cache[key] = f
        return f
    }

    private static func make(_ name: String, size: CGFloat, bold: Bool, italic: Bool, kind: String?) -> NSFont {
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if installed == nil { installed = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []) }
        if installed?.contains(name) == true {
            let base = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary), size, nil)
            let styled = traits.isEmpty ? base : (CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base)
            return styled as NSFont
        }
        if office == nil { office = indexOffice() }
        if let faces = office?[name.lowercased()], !faces.isEmpty {
            func score(_ d: CTFontDescriptor) -> Int {
                let t = (CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any])?[kCTFontSymbolicTrait] as? UInt32 ?? 0
                let s = CTFontSymbolicTraits(rawValue: t)
                var points = 0
                if s.contains(.traitBold) == bold { points += 2 }
                if s.contains(.traitItalic) == italic { points += 2 }
                let style = (CTFontDescriptorCopyAttribute(d, kCTFontStyleNameAttribute) as? String ?? "").lowercased()
                if ["regular", "bold", "italic", "bold italic"].contains(style) { points += 1 }
                return points
            }
            if let best = faces.max(by: { score($0) < score($1) }) {
                return CTFontCreateWithFontDescriptor(best, size, nil) as NSFont
            }
        }
        let lower = name.lowercased()
        let substitute: String
        if lower.hasPrefix("palatino") || lower == "book antiqua" {
            substitute = "Palatino"
        } else if mono.contains(lower) || kind == "modern" {
            substitute = "Courier New"
        } else if serif.contains(lower) || kind == "roman" {
            substitute = lower == "cambria" || lower == "constantia" ? "Georgia" : "Times New Roman"
        } else if sans.contains(lower) || kind == "swiss" {
            substitute = "Helvetica Neue"
        } else {
            substitute = "Times New Roman"
        }
        guard substitute != name, installed?.contains(substitute) == true else { return NSFont.systemFont(ofSize: size) }
        return make(substitute, size: size, bold: bold, italic: italic, kind: nil)
    }

    private static func indexOffice() -> [String: [CTFontDescriptor]] {
        var out: [String: [CTFontDescriptor]] = [:]
        let fm = FileManager.default
        for folder in officeFolders where fm.fileExists(atPath: folder) {
            for file in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] {
                let ext = (file as NSString).pathExtension.lowercased()
                guard ["ttf", "ttc", "otf"].contains(ext) else { continue }
                let url = URL(fileURLWithPath: folder).appendingPathComponent(file) as CFURL
                for d in (CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor]) ?? [] {
                    if let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String {
                        out[family.lowercased(), default: []].append(d)
                    }
                }
            }
        }
        return out
    }
}
