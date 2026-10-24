import AppKit
import CoreText
import ImageIO

/// Windows metafiles (EMF, WMF) drawn as pictures: shapes, paths, text, bitmaps, transforms and clipping.
/// Word keeps charts pasted from Excel, old equations and many logos in these formats; macOS cannot read them.
enum ConverterMetafile {
    static func isMetafile(_ data: Data) -> Bool { kind(data) != nil }

    private static func kind(_ data: Data) -> String? {
        guard data.count > 44 else { return nil }
        let b = [UInt8](data.prefix(44))
        if b[0] == 1, b[1] == 0, b[2] == 0, b[3] == 0, b[40] == 0x20, b[41] == 0x45, b[42] == 0x4D, b[43] == 0x46 { return "emf" }
        if b[0] == 0xD7, b[1] == 0xCD, b[2] == 0xC6, b[3] == 0x9A { return "wmf" }
        if (b[0] == 1 || b[0] == 2), b[1] == 0, b[2] == 9, b[3] == 0 { return "wmf" }
        return nil
    }

    /// The metafile as an image of `size` points (about 300 dpi), or nil when it is not one or draws nothing.
    static func image(_ data: Data, size: CGSize) -> CGImage? {
        guard let kind = kind(data) else { return nil }
        let bytes = [UInt8](data)
        let reader = ConverterMetafileBytes(bytes)
        // The picture's own frame, in its logical or device units.
        var frame: CGRect
        var natural: CGSize
        var pixelsPerMM = CGSize(width: 96 / 25.4, height: 96 / 25.4)
        if kind == "emf" {
            let bounds = CGRect(x: CGFloat(reader.i32(8)), y: CGFloat(reader.i32(12)), width: CGFloat(reader.i32(16) - reader.i32(8) + 1),
                                height: CGFloat(reader.i32(20) - reader.i32(12) + 1))
            let mm = CGRect(x: CGFloat(reader.i32(24)), y: CGFloat(reader.i32(28)), width: CGFloat(reader.i32(32) - reader.i32(24)),
                            height: CGFloat(reader.i32(36) - reader.i32(28)))
            let device = CGSize(width: CGFloat(reader.i32(72)), height: CGFloat(reader.i32(76)))
            let millimeters = CGSize(width: CGFloat(reader.i32(80)), height: CGFloat(reader.i32(84)))
            if device.width > 0, device.height > 0, millimeters.width > 0, millimeters.height > 0, mm.width > 0, mm.height > 0 {
                let sx = device.width / (millimeters.width * 100), sy = device.height / (millimeters.height * 100)
                pixelsPerMM = CGSize(width: sx * 100, height: sy * 100)
                frame = CGRect(x: mm.minX * sx, y: mm.minY * sy, width: mm.width * sx, height: mm.height * sy)
                natural = CGSize(width: mm.width / 2540 * 72, height: mm.height / 2540 * 72)
            } else {
                frame = bounds
                natural = CGSize(width: bounds.width * 0.75, height: bounds.height * 0.75)
            }
        } else if bytes[0] == 0xD7 {
            let l = CGFloat(reader.i16(6)), t = CGFloat(reader.i16(8)), r = CGFloat(reader.i16(10)), b = CGFloat(reader.i16(12))
            let inch = max(1, CGFloat(reader.u16(14)))
            frame = CGRect(x: min(l, r), y: min(t, b), width: abs(r - l), height: abs(b - t))
            natural = CGSize(width: frame.width / inch * 72, height: frame.height / inch * 72)
        } else {
            frame = .zero
            natural = .zero
        }
        var target = size.width > 0 && size.height > 0 ? size : natural
        if target.width <= 0 || target.height <= 0 { target = CGSize(width: 300, height: 200) }
        let scale = min(300.0 / 72, 5000 / max(target.width, target.height))
        let w = max(1, Int((target.width * scale).rounded())), h = max(1, Int((target.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let canvas = ConverterMetafileCanvas(ctx, output: CGSize(width: w, height: h), pixelsPerPoint: scale)
        if kind == "emf" {
            guard frame.width > 0, frame.height > 0 else { return nil }
            canvas.frame = frame
            canvas.pixelsPerMM = pixelsPerMM
            canvas.playEMF(reader)
        } else {
            canvas.frame = frame.width > 0 && frame.height > 0 ? frame : nil
            canvas.playWMF(reader, start: bytes[0] == 0xD7 ? 22 : 0)
        }
        return canvas.drew ? ctx.makeImage() : nil
    }
}

/// Little-endian reads that never trap on a damaged file.
struct ConverterMetafileBytes {
    let b: [UInt8]
    init(_ b: [UInt8]) { self.b = b }
    var count: Int { b.count }
    func u8(_ i: Int) -> Int { i >= 0 && i < b.count ? Int(b[i]) : 0 }
    func u16(_ i: Int) -> Int { u8(i) | u8(i + 1) << 8 }
    func i16(_ i: Int) -> Int { Int(Int16(truncatingIfNeeded: u16(i))) }
    func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
    func i32(_ i: Int) -> Int { Int(Int32(truncatingIfNeeded: u32(i))) }
    func f32(_ i: Int) -> CGFloat { CGFloat(Float(bitPattern: UInt32(truncatingIfNeeded: u32(i)))) }
    func slice(_ i: Int, _ n: Int) -> [UInt8] {
        guard i >= 0, n > 0, i + n <= b.count else { return [] }
        return Array(b[i..<(i + n)])
    }
}

/// The GDI drawing state a metafile plays against, drawn into a bitmap (y pointing down, in pixels).
final class ConverterMetafileCanvas {
    private struct Pen { var color: CGColor?; var width: CGFloat; var dash: [CGFloat]; var cap: CGLineCap; var join: CGLineJoin }
    private struct Font { var height: CGFloat; var escapement: CGFloat; var bold: Bool; var italic: Bool; var underline: Bool; var strike: Bool
        var charset: Int; var face: String }
    private enum Object { case pen(Pen), brush(CGColor?), font(Font), other }
    private struct State {
        var pen = Pen(color: CGColor(gray: 0, alpha: 1), width: 0, dash: [], cap: .round, join: .round)
        var brush: CGColor? = CGColor(gray: 1, alpha: 1)
        var font = Font(height: -12, escapement: 0, bold: false, italic: false, underline: false, strike: false, charset: 0, face: "Arial")
        var textColor = CGColor(gray: 0, alpha: 1)
        var backColor = CGColor(gray: 1, alpha: 1)
        var opaqueText = true
        var align = 0
        var evenOdd = true
        var mapMode = 1
        var windowOrg = CGPoint.zero
        var windowExt = CGSize(width: 1, height: 1)
        var viewportOrg = CGPoint.zero
        var viewportExt = CGSize(width: 1, height: 1)
        var world = CGAffineTransform.identity
        var position = CGPoint.zero
        var clip: [CGRect]?
    }

    private let ctx: CGContext
    private let output: CGSize
    private let pixelsPerPoint: CGFloat
    var frame: CGRect?
    var pixelsPerMM = CGSize(width: 96 / 25.4, height: 96 / 25.4)
    private(set) var drew = false
    private var s = State()
    private var stack: [State] = []
    private var objects: [Int: Object] = [:]
    private var path: CGMutablePath?
    private var wmf = false

    init(_ ctx: CGContext, output: CGSize, pixelsPerPoint: CGFloat) {
        self.ctx = ctx
        self.output = output
        self.pixelsPerPoint = pixelsPerPoint
    }

    // MARK: Coordinates

    /// Logical units → device units (EMF: reference device pixels; WMF: the picture's own units).
    private var page: CGAffineTransform {
        // WMF coordinates are logical units mapped straight onto the picture (see `device`).
        if wmf { return .identity }
        var t = s.world
        switch s.mapMode {
        case 7, 8: // anisotropic, isotropic
            let wx = s.windowExt.width == 0 ? 1 : s.windowExt.width, wy = s.windowExt.height == 0 ? 1 : s.windowExt.height
            var sx = s.viewportExt.width / wx, sy = s.viewportExt.height / wy
            if s.mapMode == 8 {
                let m = min(abs(sx), abs(sy))
                sx = sx < 0 ? -m : m
                sy = sy < 0 ? -m : m
            }
            t = t.concatenating(CGAffineTransform(translationX: -s.windowOrg.x, y: -s.windowOrg.y))
                .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                .concatenating(CGAffineTransform(translationX: s.viewportOrg.x, y: s.viewportOrg.y))
        default:
            let units: [Int: CGFloat] = [2: 0.1, 3: 0.01, 4: 0.254, 5: 0.0254, 6: 25.4 / 1440]
            if let mm = units[s.mapMode] {
                // Metric modes: y points up; millimeters to the reference device's pixels.
                t = t.concatenating(CGAffineTransform(translationX: -s.windowOrg.x, y: -s.windowOrg.y))
                    .concatenating(CGAffineTransform(scaleX: mm * pixelsPerMM.width, y: -mm * pixelsPerMM.height))
                    .concatenating(CGAffineTransform(translationX: s.viewportOrg.x, y: s.viewportOrg.y))
            } else {
                t = t.concatenating(CGAffineTransform(translationX: s.viewportOrg.x - s.windowOrg.x, y: s.viewportOrg.y - s.windowOrg.y))
            }
        }
        return t
    }

    /// Device units → output pixels. A WMF maps its bounding box (or its window) onto the picture, flipped when its
    /// window says the y axis points up.
    private var device: CGAffineTransform {
        let f = (frame ?? CGRect(origin: s.windowOrg, size: s.windowExt)).standardized
        let w = f.width == 0 ? 1 : f.width, h = f.height == 0 ? 1 : f.height
        let flipX = wmf && s.windowExt.width < 0, flipY = wmf && s.windowExt.height < 0
        let sx = output.width / w * (flipX ? -1 : 1), sy = output.height / h * (flipY ? -1 : 1)
        return CGAffineTransform(translationX: -(flipX ? f.maxX : f.minX), y: -(flipY ? f.maxY : f.minY))
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
    }

    private var transform: CGAffineTransform { page.concatenating(device) }

    private func pt(_ x: Int, _ y: Int) -> CGPoint { CGPoint(x: x, y: y).applying(transform) }

    private func scale(_ t: CGAffineTransform) -> CGFloat { sqrt(abs(t.a * t.d - t.b * t.c)) }

    // MARK: Drawing

    private func clipped(_ draw: () -> Void) {
        ctx.saveGState()
        if let clip = s.clip {
            let d = device
            let rects = clip.map { $0.applying(d) }
            if rects.isEmpty { ctx.restoreGState(); return }
            ctx.clip(to: rects)
        }
        draw()
        ctx.restoreGState()
        drew = true
    }

    private func strokeWidth() -> CGFloat {
        let w = s.pen.width * scale(transform)
        return max(w, 0.75 * pixelsPerPoint * 0.5)
    }

    private func paint(_ p: CGPath, fill: Bool, stroke: Bool) {
        if let path {
            path.addPath(p)
            return
        }
        clipped {
            if fill, let brush = s.brush {
                ctx.addPath(p)
                ctx.setFillColor(brush)
                ctx.fillPath(using: s.evenOdd ? .evenOdd : .winding)
            }
            if stroke, let color = s.pen.color {
                ctx.addPath(p)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(strokeWidth())
                ctx.setLineCap(s.pen.cap)
                ctx.setLineJoin(s.pen.join)
                if !s.pen.dash.isEmpty { ctx.setLineDash(phase: 0, lengths: s.pen.dash.map { $0 * strokeWidth() }) }
                ctx.strokePath()
            }
        }
    }

    private func poly(_ points: [CGPoint], closed: Bool, bezier: Bool = false, from current: Bool = false) -> CGMutablePath {
        let p = CGMutablePath()
        guard !points.isEmpty else { return p }
        var list = points
        if current { list.insert(s.position.applying(transform), at: 0) }
        p.move(to: list[0])
        if bezier {
            var i = 1
            while i + 2 < list.count {
                p.addCurve(to: list[i + 2], control1: list[i], control2: list[i + 1])
                i += 3
            }
        } else {
            for q in list.dropFirst() { p.addLine(to: q) }
        }
        if closed { p.closeSubpath() }
        return p
    }

    private func rect(_ l: Int, _ t: Int, _ r: Int, _ b: Int) -> CGRect {
        let a = pt(l, t), c = pt(r, b)
        return CGRect(x: min(a.x, c.x), y: min(a.y, c.y), width: abs(c.x - a.x), height: abs(c.y - a.y))
    }

    private func image(_ bytes: ConverterMetafileBytes, bmi: Int, bmiSize: Int, bits: Int, bitsSize: Int) -> CGImage? {
        guard bmiSize >= 12, bitsSize > 0 else { return nil }
        let header = bytes.slice(bmi, bmiSize)
        let data = bytes.slice(bits, bitsSize)
        guard header.count == bmiSize, data.count == bitsSize else { return nil }
        let compression = bmiSize >= 20 ? ConverterMetafileBytes(header).u32(16) : 0
        var file: [UInt8]
        if compression == 4 || compression == 5 {
            file = data
        } else {
            let total = 14 + bmiSize + bitsSize
            file = [0x42, 0x4D]
            for v in [total, 0, 14 + bmiSize] { file += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
            file += header
            file += data
        }
        guard let src = CGImageSourceCreateWithData(Data(file) as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func blit(_ img: CGImage?, dest: CGRect, src: CGRect?) {
        guard var img else { return }
        if let src, src.width > 0, src.height > 0 {
            let full = CGRect(x: 0, y: 0, width: img.width, height: img.height)
            let r = src.standardized.intersection(full).integral
            if !r.isNull, r != full, let c = img.cropping(to: r) { img = c }
        }
        clipped {
            ctx.saveGState()
            ctx.translateBy(x: dest.minX, y: dest.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(origin: .zero, size: dest.size))
            ctx.restoreGState()
        }
    }

    // MARK: Text

    private func decode(_ bytes: [UInt8], charset: Int, face: String) -> String {
        if charset == 2 || face.lowercased() == "symbol" {
            // MacSymbol (33) maps the Symbol font's codes to Unicode (Greek letters, math signs).
            if let s = String(bytes: bytes, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(33))) { return s }
        }
        let pages: [Int: UInt32] = [0: 1252, 1: 1252, 238: 1250, 204: 1251, 161: 1253, 162: 1254, 177: 1255, 178: 1256, 186: 1257, 77: 10000]
        let cf = CFStringConvertWindowsCodepageToEncoding(pages[charset] ?? 1252)
        return String(bytes: bytes, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)))
            ?? String(decoding: bytes, as: UTF8.self)
    }

    private func text(_ string: String, at reference: CGPoint, dx: [Int]) {
        guard !string.isEmpty else { return }
        var str = string
        let f = s.font
        let face = f.face.isEmpty ? "Arial" : f.face
        if face.lowercased() == "symbol" {
            str = String(String.UnicodeScalarView(str.unicodeScalars.map { u in
                let code = u.value >= 0xF020 && u.value <= 0xF0FF ? u.value - 0xF000 : u.value
                if code >= 0x20, code <= 0xFF, let b = UInt8(exactly: code),
                   let m = String(bytes: [b], encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(33))),
                   let first = m.unicodeScalars.first { return first }
                return u
            }))
        }
        let t = transform
        let k = scale(t)
        let probe = ConverterDocxFonts.font(face, size: 100, bold: f.bold, italic: f.italic, kind: nil)
        let em = f.height < 0 ? -f.height : f.height * 100 / max(1, probe.ascender - probe.descender)
        let size = max(1, em * k)
        let font = ConverterDocxFonts.font(face, size: size, bold: f.bold, italic: f.italic, kind: nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: s.textColor) ?? .black]
        let chars = Array(str)
        var advances: [CGFloat] = []
        if dx.count >= chars.count {
            advances = dx.prefix(chars.count).map { CGFloat($0) * k }
        } else {
            advances = chars.map { NSAttributedString(string: String($0), attributes: attrs).size().width }
        }
        let width = advances.reduce(0, +)
        let origin = reference.applying(t)
        let horizontal = s.align & 6
        let vertical = s.align & 24
        var x: CGFloat = horizontal == 6 ? -width / 2 : (horizontal == 2 ? -width : 0)
        let y: CGFloat = vertical == 24 ? 0 : (vertical == 8 ? font.descender : font.ascender)
        // The world transform may turn the text; escapement turns it further, counterclockwise, in tenths of a degree.
        let angle = atan2(t.b, t.a) - f.escapement / 10 * .pi / 180
        clipped {
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.rotate(by: angle)
            if s.opaqueText {
                ctx.setFillColor(s.backColor)
                ctx.fill(CGRect(x: x, y: y - font.ascender, width: width, height: font.ascender - font.descender))
            }
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            for (i, ch) in chars.enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(ch), attributes: attrs))
                ctx.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, ctx)
                x += advances[i]
            }
            if f.underline || f.strike {
                ctx.setStrokeColor(s.textColor)
                ctx.setLineWidth(max(1, size / 14))
                let start = horizontal == 6 ? -width / 2 : (horizontal == 2 ? -width : 0)
                for yy in [f.underline ? y + size * 0.12 : nil, f.strike ? y - size * 0.3 : nil].compactMap({ $0 }) {
                    ctx.move(to: CGPoint(x: start, y: yy))
                    ctx.addLine(to: CGPoint(x: start + width, y: yy))
                }
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        if s.align & 1 != 0 { s.position = CGPoint(x: s.position.x + width / max(0.0001, k), y: s.position.y) }
    }

    // MARK: Objects

    private func color(_ ref: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(ref & 0xFF) / 255, green: CGFloat(ref >> 8 & 0xFF) / 255, blue: CGFloat(ref >> 16 & 0xFF) / 255, alpha: 1)
    }

    private func pen(style: Int, width: Int, color ref: Int) -> Pen {
        var p = Pen(color: style & 0xF == 5 ? nil : color(ref), width: CGFloat(width), dash: [], cap: .round, join: .round)
        switch style & 0xF {
        case 1: p.dash = [6, 3]
        case 2: p.dash = [1, 2]
        case 3: p.dash = [6, 2, 1, 2]
        case 4: p.dash = [6, 2, 1, 2, 1, 2]
        default: break
        }
        switch style & 0xF00 {
        case 0x100: p.cap = .square
        case 0x200: p.cap = .butt
        default: break
        }
        switch style & 0xF000 {
        case 0x1000: p.join = .bevel
        case 0x2000: p.join = .miter
        default: break
        }
        return p
    }

    private func brush(style: Int, color ref: Int) -> CGColor? {
        style == 1 ? nil : color(ref)
    }

    private func select(_ index: Int) {
        if index & 0x8000_0000 != 0 {
            switch index & 0x7FFF_FFFF {
            case 0: s.brush = CGColor(gray: 1, alpha: 1)
            case 1: s.brush = CGColor(gray: 0.75, alpha: 1)
            case 2: s.brush = CGColor(gray: 0.5, alpha: 1)
            case 3: s.brush = CGColor(gray: 0.25, alpha: 1)
            case 4: s.brush = CGColor(gray: 0, alpha: 1)
            case 5: s.brush = nil
            case 6: s.pen = Pen(color: CGColor(gray: 1, alpha: 1), width: 0, dash: [], cap: .round, join: .round)
            case 7: s.pen = Pen(color: CGColor(gray: 0, alpha: 1), width: 0, dash: [], cap: .round, join: .round)
            case 8: s.pen.color = nil
            default: break
            }
            return
        }
        switch objects[index] {
        case .pen(let p): s.pen = p
        case .brush(let b): s.brush = b
        case .font(let f): s.font = f
        default: break
        }
    }

    private func font(_ r: ConverterMetafileBytes, at i: Int, wide: Bool) -> Font {
        let height = wide ? r.i32(i) : r.i16(i)
        let o = wide ? 4 : 2
        let escapement = wide ? r.i32(i + 2 * o) : r.i16(i + 2 * o)
        let weight = wide ? r.i32(i + 4 * o) : r.i16(i + 4 * o)
        let flags = i + 5 * o
        var face = ""
        if wide {
            var units: [UInt16] = []
            for k in 0..<32 {
                let u = UInt16(r.u16(flags + 8 + 2 * k))
                if u == 0 { break }
                units.append(u)
            }
            face = String(decoding: units, as: UTF16.self)
        } else {
            var chars: [UInt8] = []
            for k in 0..<32 {
                let c = r.u8(flags + 8 + k)
                if c == 0 { break }
                chars.append(UInt8(c))
            }
            face = String(bytes: chars, encoding: .windowsCP1252) ?? ""
        }
        return Font(height: CGFloat(height), escapement: CGFloat(escapement), bold: weight >= 600, italic: r.u8(flags) != 0,
                    underline: r.u8(flags + 1) != 0, strike: r.u8(flags + 2) != 0, charset: r.u8(flags + 3), face: face)
    }

    private func region(_ r: ConverterMetafileBytes, at i: Int, size: Int, mode: Int) {
        if size == 0 || mode == 5 && size < 32 {
            s.clip = nil
            return
        }
        let count = r.u32(i + 8)
        var rects: [CGRect] = []
        for k in 0..<min(count, 4096) {
            let o = i + 32 + k * 16
            rects.append(CGRect(x: r.i32(o), y: r.i32(o + 4), width: r.i32(o + 8) - r.i32(o), height: r.i32(o + 12) - r.i32(o + 4)))
        }
        switch mode {
        case 1: // and
            if let current = s.clip {
                s.clip = current.flatMap { a in rects.map { a.intersection($0) } }.filter { !$0.isNull && !$0.isEmpty }
            } else {
                s.clip = rects
            }
        case 2: s.clip = (s.clip ?? []) + rects // or
        default: s.clip = rects // copy, and approximations of the rest
        }
    }

    private func intersect(_ r: CGRect) {
        // Clip rectangles are kept in device units, the units the regions of the file use.
        let d = r.applying(page)
        if let current = s.clip {
            s.clip = current.map { $0.intersection(d) }.filter { !$0.isNull }
        } else {
            s.clip = [d]
        }
    }

    // MARK: EMF

    func playEMF(_ r: ConverterMetafileBytes) {
        var i = 0
        var guardCount = 0
        while i + 8 <= r.count, guardCount < 2_000_000 {
            guardCount += 1
            let type = r.u32(i), size = r.u32(i + 4)
            guard size >= 8, i + size <= r.count else { break }
            emf(type, r, i, size)
            if type == 14 { break }
            i += size
        }
    }

    private func points(_ r: ConverterMetafileBytes, at i: Int, count: Int, short: Bool) -> [CGPoint] {
        let n = min(count, (r.count - i) / (short ? 4 : 8))
        guard n > 0 else { return [] }
        return (0..<n).map { k in short ? pt(r.i16(i + k * 4), r.i16(i + k * 4 + 2)) : pt(r.i32(i + k * 8), r.i32(i + k * 8 + 4)) }
    }

    private func emf(_ type: Int, _ r: ConverterMetafileBytes, _ i: Int, _ size: Int) {
        switch type {
        case 2, 3, 4, 5, 6, 85, 86, 87, 88, 89:
            let short = type >= 85
            let pts = points(r, at: i + 28, count: r.u32(i + 24), short: short)
            let base = short ? type - 83 : type
            switch base {
            case 2: paint(poly(pts, closed: false, bezier: true), fill: false, stroke: true)
            case 3: paint(poly(pts, closed: true), fill: true, stroke: true)
            case 4: paint(poly(pts, closed: false), fill: false, stroke: true)
            case 5, 6:
                if let path {
                    if path.isEmpty { path.move(to: s.position.applying(transform)) }
                    if base == 5 {
                        var k = 0
                        while k + 2 < pts.count { path.addCurve(to: pts[k + 2], control1: pts[k], control2: pts[k + 1]); k += 3 }
                    } else {
                        for q in pts { path.addLine(to: q) }
                    }
                } else {
                    paint(poly(pts, closed: false, bezier: base == 5, from: true), fill: false, stroke: true)
                }
                if let last = pts.last { s.position = last.applying(transform.inverted()) }
            default: break
            }
        case 7, 8, 90, 91:
            let short = type >= 90
            let polys = r.u32(i + 24)
            var offset = i + 32 + polys * 4
            let p = CGMutablePath()
            for k in 0..<min(polys, 10_000) {
                let n = r.u32(i + 32 + k * 4)
                let pts = points(r, at: offset, count: n, short: short)
                offset += n * (short ? 4 : 8)
                if let first = pts.first {
                    p.move(to: first)
                    for q in pts.dropFirst() { p.addLine(to: q) }
                    if type == 8 || type == 91 { p.closeSubpath() }
                }
            }
            paint(p, fill: type == 8 || type == 91, stroke: true)
        case 9: s.windowExt = CGSize(width: r.i32(i + 8), height: r.i32(i + 12))
        case 10: s.windowOrg = CGPoint(x: r.i32(i + 8), y: r.i32(i + 12))
        case 11: s.viewportExt = CGSize(width: r.i32(i + 8), height: r.i32(i + 12))
        case 12: s.viewportOrg = CGPoint(x: r.i32(i + 8), y: r.i32(i + 12))
        case 17: s.mapMode = r.u32(i + 8)
        case 18: s.opaqueText = r.u32(i + 8) == 2
        case 19: s.evenOdd = r.u32(i + 8) == 1
        case 22: s.align = r.u32(i + 8)
        case 24: s.textColor = color(r.u32(i + 8))
        case 25: s.backColor = color(r.u32(i + 8))
        case 27: s.position = CGPoint(x: r.i32(i + 8), y: r.i32(i + 12))
            if let path { path.move(to: pt(r.i32(i + 8), r.i32(i + 12))) }
        case 54:
            let to = CGPoint(x: r.i32(i + 8), y: r.i32(i + 12))
            if let path {
                if path.isEmpty { path.move(to: s.position.applying(transform)) }
                path.addLine(to: to.applying(transform))
            } else {
                let p = CGMutablePath()
                p.move(to: s.position.applying(transform))
                p.addLine(to: to.applying(transform))
                paint(p, fill: false, stroke: true)
            }
            s.position = to
        case 30: intersect(CGRect(x: r.i32(i + 8), y: r.i32(i + 12), width: r.i32(i + 16) - r.i32(i + 8), height: r.i32(i + 20) - r.i32(i + 12)))
        case 33: stack.append(s)
        case 34:
            let n = r.i32(i + 8)
            let target = n < 0 ? stack.count + n : n - 1
            if target >= 0, target < stack.count {
                s = stack[target]
                stack.removeSubrange(target...)
            }
        case 35:
            s.world = CGAffineTransform(a: r.f32(i + 8), b: r.f32(i + 12), c: r.f32(i + 16), d: r.f32(i + 20), tx: r.f32(i + 24), ty: r.f32(i + 28))
        case 36:
            let x = CGAffineTransform(a: r.f32(i + 8), b: r.f32(i + 12), c: r.f32(i + 16), d: r.f32(i + 20), tx: r.f32(i + 24), ty: r.f32(i + 28))
            switch r.u32(i + 32) {
            case 1: s.world = .identity
            case 2: s.world = x.concatenating(s.world)
            case 3: s.world = s.world.concatenating(x)
            case 4: s.world = x
            default: break
            }
        case 37: select(r.u32(i + 8))
        case 38: objects[r.u32(i + 8)] = .pen(pen(style: r.u32(i + 12), width: r.i32(i + 16), color: r.u32(i + 24)))
        case 95:
            let style = r.u32(i + 28)
            var p = pen(style: style, width: r.u32(i + 32), color: r.u32(i + 40))
            if r.u32(i + 36) == 1 { p.color = nil }
            objects[r.u32(i + 8)] = .pen(p)
        case 39: objects[r.u32(i + 8)] = .brush(brush(style: r.u32(i + 12), color: r.u32(i + 16)))
        case 93, 94: objects[r.u32(i + 8)] = .brush(CGColor(gray: 0.5, alpha: 1))
        case 82: objects[r.u32(i + 8)] = .font(font(r, at: i + 12, wide: true))
        case 40: objects[r.u32(i + 8)] = nil
        case 42: paint(CGPath(ellipseIn: rect(r.i32(i + 8), r.i32(i + 12), r.i32(i + 16), r.i32(i + 20)), transform: nil), fill: true, stroke: true)
        case 43: paint(CGPath(rect: rect(r.i32(i + 8), r.i32(i + 12), r.i32(i + 16), r.i32(i + 20)), transform: nil), fill: true, stroke: true)
        case 44:
            let box = rect(r.i32(i + 8), r.i32(i + 12), r.i32(i + 16), r.i32(i + 20))
            let k = scale(transform)
            let rx = min(box.width / 2, CGFloat(r.i32(i + 24)) * k / 2), ry = min(box.height / 2, CGFloat(r.i32(i + 28)) * k / 2)
            paint(CGPath(roundedRect: box, cornerWidth: max(0, rx), cornerHeight: max(0, ry), transform: nil), fill: true, stroke: true)
        case 45, 46, 47, 55:
            arc(rect(r.i32(i + 8), r.i32(i + 12), r.i32(i + 16), r.i32(i + 20)), start: pt(r.i32(i + 24), r.i32(i + 28)), end: pt(r.i32(i + 32), r.i32(i + 36)), kind: type)
        case 59: path = CGMutablePath()
        case 60: break
        case 61: path?.closeSubpath()
        case 62, 63, 64:
            if let p = path {
                path = nil
                paint(p, fill: type != 64, stroke: type != 62)
            }
        case 68: path = nil
        case 75: region(r, at: i + 16, size: r.u32(i + 8), mode: r.u32(i + 12))
        case 81:
            let img = image(r, bmi: i + r.u32(i + 48), bmiSize: r.u32(i + 52), bits: i + r.u32(i + 56), bitsSize: r.u32(i + 60))
            blit(img, dest: rect(r.i32(i + 24), r.i32(i + 28), r.i32(i + 24) + r.i32(i + 72), r.i32(i + 28) + r.i32(i + 76)),
                 src: CGRect(x: r.i32(i + 32), y: r.i32(i + 36), width: r.i32(i + 40), height: r.i32(i + 44)))
        case 76, 77, 114:
            let dest = rect(r.i32(i + 24), r.i32(i + 28), r.i32(i + 24) + r.i32(i + 32), r.i32(i + 28) + r.i32(i + 36))
            let rop = r.u32(i + 40)
            let bmiSize = r.u32(i + 88)
            if bmiSize > 0 {
                let img = image(r, bmi: i + r.u32(i + 84), bmiSize: bmiSize, bits: i + r.u32(i + 92), bitsSize: r.u32(i + 96))
                let src = type == 76 ? CGRect(x: r.i32(i + 44), y: r.i32(i + 48), width: r.i32(i + 32), height: r.i32(i + 36))
                    : CGRect(x: r.i32(i + 44), y: r.i32(i + 48), width: r.i32(i + 100), height: r.i32(i + 104))
                if type == 114 || rop == 0xCC0020 || rop == 0x8800C6 { blit(img, dest: dest, src: src) }
            } else if type != 114 {
                let fill: CGColor? = rop == 0xFF0062 ? CGColor(gray: 1, alpha: 1) : (rop == 0x000042 ? CGColor(gray: 0, alpha: 1) : (rop == 0xF00021 ? s.brush : nil))
                if let fill { clipped { ctx.setFillColor(fill); ctx.fill(dest) } }
            }
        case 80:
            let img = image(r, bmi: i + r.u32(i + 48), bmiSize: r.u32(i + 52), bits: i + r.u32(i + 56), bitsSize: r.u32(i + 60))
            blit(img, dest: rect(r.i32(i + 24), r.i32(i + 28), r.i32(i + 24) + r.i32(i + 40), r.i32(i + 28) + r.i32(i + 44)), src: nil)
        case 83, 84:
            let ref = CGPoint(x: r.i32(i + 36), y: r.i32(i + 40))
            let n = r.u32(i + 44)
            let off = i + r.u32(i + 48)
            let dxOff = r.u32(i + 72)
            var str: String
            if type == 84 {
                var units: [UInt16] = []
                for k in 0..<min(n, 8192) { units.append(UInt16(r.u16(off + 2 * k))) }
                str = String(decoding: units, as: UTF16.self)
            } else {
                str = decode(r.slice(off, min(n, 8192)), charset: s.font.charset, face: s.font.face)
            }
            let options = r.u32(i + 52)
            if options & 0x10 != 0 { str = "" } // ETO_GLYPH_INDEX: glyph numbers of an unknown font
            var dx: [Int] = []
            if dxOff > 0 { for k in 0..<min(n, 8192) { dx.append(r.i32(i + dxOff + 4 * k)) } }
            if options & 0x2000 != 0 { dx = stride(from: 0, to: dx.count, by: 2).map { dx[$0] } } // ETO_PDY: pairs
            let at = s.align & 1 != 0 ? s.position : ref
            text(str, at: at, dx: dx)
        default: break
        }
    }

    private func arc(_ box: CGRect, start: CGPoint, end: CGPoint, kind: Int) {
        guard box.width > 0, box.height > 0 else { return }
        let c = CGPoint(x: box.midX, y: box.midY)
        func angle(_ p: CGPoint) -> CGFloat { atan2((p.y - c.y) / box.height, (p.x - c.x) / box.width) }
        let a0 = angle(start), a1 = angle(end)
        let p = CGMutablePath()
        let t = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: box.width / 2, y: box.height / 2)
        // GDI arcs run counterclockwise on screen (y down): decreasing angles here.
        p.addArc(center: .zero, radius: 1, startAngle: a0, endAngle: a1, clockwise: true, transform: t)
        if kind == 47 { p.addLine(to: c) }
        if kind == 46 || kind == 47 { p.closeSubpath() }
        paint(p, fill: kind == 46 || kind == 47, stroke: true)
    }

    // MARK: WMF

    func playWMF(_ r: ConverterMetafileBytes, start: Int) {
        wmf = true
        s.mapMode = 1
        var i = start + r.u16(start + 2) * 2
        var guardCount = 0
        while i + 6 <= r.count, guardCount < 2_000_000 {
            guardCount += 1
            let size = r.u32(i) * 2
            let fn = r.u16(i + 4)
            guard size >= 6, i + size <= r.count else { break }
            if fn == 0 { break }
            wmfRecord(fn, r, i + 6, size - 6)
            i += size
        }
    }

    private func slot(_ o: Object) {
        var k = 0
        while objects[k] != nil { k += 1 }
        objects[k] = o
    }

    private func wmfRecord(_ fn: Int, _ r: ConverterMetafileBytes, _ p: Int, _ n: Int) {
        func w(_ k: Int) -> Int { r.i16(p + 2 * k) }
        switch fn {
        case 0x020B: s.windowOrg = CGPoint(x: w(1), y: w(0))
        case 0x020C: s.windowExt = CGSize(width: w(1), height: w(0))
        case 0x020D: s.viewportOrg = CGPoint(x: w(1), y: w(0))
        case 0x020E: s.viewportExt = CGSize(width: w(1), height: w(0))
        case 0x0103: s.mapMode = w(0)
        case 0x0102: s.opaqueText = w(0) == 2
        case 0x0106: s.evenOdd = w(0) == 1
        case 0x012E: s.align = r.u16(p)
        case 0x0209: s.textColor = color(r.u32(p))
        case 0x0201: s.backColor = color(r.u32(p))
        case 0x001E: stack.append(s)
        case 0x0127:
            let k = w(0)
            let target = k < 0 ? stack.count + k : k - 1
            if target >= 0, target < stack.count {
                s = stack[target]
                stack.removeSubrange(target...)
            }
        case 0x02FA: slot(.pen(pen(style: r.u16(p), width: w(1), color: r.u32(p + 6))))
        case 0x02FC: slot(.brush(brush(style: r.u16(p), color: r.u32(p + 2))))
        case 0x02FB: slot(.font(font(r, at: p, wide: false)))
        case 0x00F7, 0x01F9, 0x0142, 0x06FF: slot(fn == 0x0142 || fn == 0x01F9 ? .brush(CGColor(gray: 0.5, alpha: 1)) : .other)
        case 0x012D: select(r.u16(p))
        case 0x01F0: objects[r.u16(p)] = nil
        case 0x0214: s.position = CGPoint(x: w(1), y: w(0))
        case 0x0213:
            let to = CGPoint(x: w(1), y: w(0))
            let path = CGMutablePath()
            path.move(to: s.position.applying(transform))
            path.addLine(to: to.applying(transform))
            paint(path, fill: false, stroke: true)
            s.position = to
        case 0x0325, 0x0324:
            let count = w(0)
            let pts = (0..<max(0, min(count, (n - 2) / 4))).map { k in pt(w(1 + 2 * k), w(2 + 2 * k)) }
            paint(poly(pts, closed: fn == 0x0324), fill: fn == 0x0324, stroke: true)
        case 0x0538:
            let polys = w(0)
            var offset = 1 + polys
            let path = CGMutablePath()
            for k in 0..<max(0, polys) {
                let count = w(1 + k)
                let pts = (0..<max(0, count)).map { j in pt(w(offset + 2 * j), w(offset + 2 * j + 1)) }
                offset += 2 * count
                if let first = pts.first {
                    path.move(to: first)
                    for q in pts.dropFirst() { path.addLine(to: q) }
                    path.closeSubpath()
                }
            }
            paint(path, fill: true, stroke: true)
        case 0x041B: paint(CGPath(rect: rect(w(3), w(2), w(1), w(0)), transform: nil), fill: true, stroke: true)
        case 0x0418: paint(CGPath(ellipseIn: rect(w(3), w(2), w(1), w(0)), transform: nil), fill: true, stroke: true)
        case 0x061C:
            let box = rect(w(5), w(4), w(3), w(2))
            let k = scale(transform)
            paint(CGPath(roundedRect: box, cornerWidth: min(box.width / 2, CGFloat(abs(w(1))) * k / 2),
                         cornerHeight: min(box.height / 2, CGFloat(abs(w(0))) * k / 2), transform: nil), fill: true, stroke: true)
        case 0x0817, 0x081A, 0x0830:
            arc(rect(w(7), w(6), w(5), w(4)), start: pt(w(3), w(2)), end: pt(w(1), w(0)), kind: fn == 0x0817 ? 45 : (fn == 0x081A ? 47 : 46))
        case 0x0416: intersect(CGRect(x: w(3), y: w(2), width: w(1) - w(3), height: w(0) - w(2)))
        case 0x0521:
            let len = w(0)
            let bytes = r.slice(p + 2, max(0, len))
            let padded = (len + 1) / 2 * 2
            let y = r.i16(p + 2 + padded), x = r.i16(p + 4 + padded)
            text(decode(bytes, charset: s.font.charset, face: s.font.face), at: s.align & 1 != 0 ? s.position : CGPoint(x: x, y: y), dx: [])
        case 0x0A32:
            let y = w(0), x = w(1), len = w(2), opts = r.u16(p + 6)
            var o = p + 8
            if opts & 0x0006 != 0 { o += 8 }
            let bytes = r.slice(o, max(0, len))
            let padded = (len + 1) / 2 * 2
            var dx: [Int] = []
            if n >= (o - p) + padded + len * 2 { dx = (0..<len).map { r.i16(o + padded + 2 * $0) } }
            text(decode(bytes, charset: s.font.charset, face: s.font.face), at: s.align & 1 != 0 ? s.position : CGPoint(x: x, y: y), dx: dx)
        case 0x0F43:
            // StretchDIB: rop(4) usage(2) srcH srcW ySrc xSrc destH destW yDst xDst, then the bitmap.
            let bmi = p + 22
            let header = ConverterMetafileBytes(r.slice(bmi, 40))
            let bmiSize = wmfHeaderSize(header)
            let img = image(r, bmi: bmi, bmiSize: bmiSize, bits: bmi + bmiSize, bitsSize: max(0, n - 22 - bmiSize))
            blit(img, dest: rect(w(10), w(9), w(10) + w(8), w(9) + w(7)), src: CGRect(x: w(6), y: w(5), width: w(4), height: w(3)))
        case 0x0B41, 0x0940:
            let stretch = fn == 0x0B41
            let fields = stretch ? 10 : 8
            let bmi = p + 2 * fields
            guard n > 2 * fields + 12 else {
                let dest = stretch ? rect(w(9), w(8), w(9) + w(7), w(8) + w(6)) : rect(w(7), w(6), w(7) + w(5), w(6) + w(4))
                let rop = r.u32(p)
                if rop == 0xF00021, let b = s.brush { clipped { ctx.setFillColor(b); ctx.fill(dest) } }
                return
            }
            let header = ConverterMetafileBytes(r.slice(bmi, 40))
            let bmiSize = wmfHeaderSize(header)
            let img = image(r, bmi: bmi, bmiSize: bmiSize, bits: bmi + bmiSize, bitsSize: max(0, n - 2 * fields - bmiSize))
            if stretch {
                blit(img, dest: rect(w(9), w(8), w(9) + w(7), w(8) + w(6)), src: CGRect(x: w(5), y: w(4), width: w(3), height: w(2)))
            } else {
                blit(img, dest: rect(w(7), w(6), w(7) + w(5), w(6) + w(4)), src: CGRect(x: w(3), y: w(2), width: w(5), height: w(4)))
            }
        default: break
        }
    }

    /// Size of a bitmap header and its color table.
    private func wmfHeaderSize(_ h: ConverterMetafileBytes) -> Int {
        let size = h.u32(0)
        guard size >= 12 else { return 40 }
        if size == 12 {
            let bits = h.u16(10)
            return 12 + (bits <= 8 ? (1 << bits) * 3 : 0)
        }
        let bits = h.u16(14)
        let used = h.u32(32)
        let compression = h.u32(16)
        var colors = used > 0 ? used : (bits <= 8 ? 1 << bits : 0)
        if compression == 3 && size == 40 { colors = 3 }
        return size + colors * 4
    }
}
