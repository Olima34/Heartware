import Foundation
import CoreGraphics
import CoreText
import ImageIO
import AppKit

/// The shapes of what is added, shared by the editor (SwiftUI paths) and the saved PDF (Core Graphics), so that both look
/// the same. Coordinates go downwards from the top left corner, like the page on screen.
enum FillSignDraw {
    // MARK: Signatures

    /// A smooth line through the points of each stroke (quadratic curves through the midpoints), fitted into `rect`.
    static func strokesPath(_ strokes: [[CGPoint]], natural: CGSize, in rect: CGRect) -> CGPath {
        let sx = rect.width / max(1, natural.width), sy = rect.height / max(1, natural.height)
        let path = CGMutablePath()
        for stroke in strokes {
            let pts = stroke.map { CGPoint(x: rect.minX + $0.x * sx, y: rect.minY + $0.y * sy) }
            guard let first = pts.first else { continue }
            path.move(to: first)
            if pts.count == 1 {
                // A dot: a tiny line, drawn round by the pen.
                path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
                continue
            }
            for i in 1..<pts.count {
                let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
                if i == 1 { path.addLine(to: mid) } else { path.addQuadCurve(to: mid, control: pts[i - 1]) }
            }
            path.addLine(to: pts[pts.count - 1])
        }
        return path
    }

    /// The pen's width once the signature is drawn at `rect`'s size.
    static func penWidth(_ width: CGFloat, natural: CGSize, in rect: CGRect) -> CGFloat {
        max(0.5, width * rect.width / max(1, natural.width))
    }

    /// Strokes moved so that they start at (0, 0), with room for the pen: the signature's natural size. Nil when too small.
    static func normalized(_ strokes: [[CGPoint]], pen: CGFloat) -> (strokes: [[CGPoint]], size: CGSize)? {
        let all = strokes.flatMap { $0 }
        guard all.count >= 2, let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max(), max(maxX - minX, maxY - minY) >= 12 else { return nil }
        let margin = pen / 2 + 1
        let moved = strokes.filter { !$0.isEmpty }.map { $0.map { CGPoint(x: $0.x - minX + margin, y: $0.y - minY + margin) } }
        return (moved, CGSize(width: (maxX - minX + 2 * margin).rounded(.up), height: (maxY - minY + 2 * margin).rounded(.up)))
    }

    /// Fewer points for a stroke: the ones closer than `spacing` to the last kept one go (a trackpad sends a lot of them).
    static func thinned(_ points: [CGPoint], spacing: CGFloat = 1.5) -> [CGPoint] {
        guard var last = points.first else { return [] }
        var out = [last]
        for p in points.dropFirst() where hypot(p.x - last.x, p.y - last.y) >= spacing {
            out.append(p)
            last = p
        }
        if let end = points.last, end != out.last { out.append(end) }
        return out
    }

    // MARK: Typed signatures

    /// The script fonts of macOS a name can be typed in, those installed on this Mac.
    static let scriptFonts: [(name: String, title: String)] = [
        ("SnellRoundhand", "Snell Roundhand"), ("SavoyeLetPlain", "Savoye"), ("Zapfino", "Zapfino"),
        ("BradleyHandITCTT-Bold", "Bradley Hand"), ("Apple-Chancery", "Chancery"), ("Noteworthy-Light", "Noteworthy")
    ].filter { NSFont(name: $0.0, size: 12) != nil }

    static let typedSize: CGFloat = 48

    /// Margin, ascent and size of a typed signature at `typedSize` points.
    static func typedLayout(_ text: String, font name: String) -> (size: CGSize, ascent: CGFloat, margin: CGFloat) {
        let font = CTFontCreateWithName(name as CFString, typedSize, nil)
        let width = FillSignText.width(text, font: font)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let margin = typedSize * 0.12
        return (CGSize(width: (width + 2 * margin).rounded(.up), height: (ascent + descent + 2 * margin).rounded(.up)), ascent, margin)
    }

    // MARK: Marks

    /// A tick, a cross or a dot filling `r`.
    static func markPath(_ mark: FillSignMark, in r: CGRect) -> CGPath {
        let path = CGMutablePath()
        switch mark {
        case .check:
            path.move(to: CGPoint(x: r.minX + r.width * 0.14, y: r.minY + r.height * 0.55))
            path.addLine(to: CGPoint(x: r.minX + r.width * 0.4, y: r.maxY - r.height * 0.16))
            path.addLine(to: CGPoint(x: r.maxX - r.width * 0.12, y: r.minY + r.height * 0.16))
        case .cross:
            let i = r.insetBy(dx: r.width * 0.18, dy: r.height * 0.18)
            path.move(to: CGPoint(x: i.minX, y: i.minY))
            path.addLine(to: CGPoint(x: i.maxX, y: i.maxY))
            path.move(to: CGPoint(x: i.maxX, y: i.minY))
            path.addLine(to: CGPoint(x: i.minX, y: i.maxY))
        case .dot:
            path.addEllipse(in: r.insetBy(dx: r.width * 0.22, dy: r.height * 0.22))
        }
        return path
    }

    static func markWidth(_ r: CGRect) -> CGFloat {
        max(0.8, min(r.width, r.height) * 0.13)
    }

    // MARK: Into a PDF page

    /// Draws an item into a context whose coordinates go downwards from the top left corner of the page.
    static func draw(_ item: FillSignItem, in ctx: CGContext) {
        let r = item.rect
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(item.ink.cgColor)
        ctx.setFillColor(item.ink.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch item.content {
        case .text(let text):
            drawText(text, size: item.fontSize, ink: item.ink.cgColor, at: r.origin, in: ctx)
        case .mark(let mark):
            ctx.addPath(markPath(mark, in: r))
            if mark == .dot {
                ctx.fillPath()
            } else {
                ctx.setLineWidth(markWidth(r))
                ctx.strokePath()
            }
        case .signature(let s):
            switch s.style {
            case .drawn(let strokes, let width):
                ctx.setStrokeColor(s.ink.cgColor)
                ctx.setLineWidth(penWidth(width, natural: s.size, in: r))
                ctx.addPath(strokesPath(strokes, natural: s.size, in: r))
                ctx.strokePath()
            case .typed(let text, let fontName):
                let layout = typedLayout(text, font: fontName)
                let k = r.width / max(1, layout.size.width)
                let font = CTFontCreateWithName(fontName as CFString, typedSize * k, nil)
                line(text, font: font, ink: s.ink.cgColor, baseline: CGPoint(x: r.minX + layout.margin * k, y: r.minY + (layout.margin + layout.ascent) * k), in: ctx)
            case .image(let png):
                guard let src = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
                // Images are drawn upwards: flipped back inside their own box.
                ctx.translateBy(x: r.minX, y: r.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(origin: .zero, size: r.size))
            }
        }
    }

    /// Lines of text from `origin` (top left of the first line).
    static func drawText(_ text: String, size: CGFloat, ink: CGColor, at origin: CGPoint, in ctx: CGContext) {
        let font = FillSignText.font(size)
        let ascent = CTFontGetAscent(font)
        let step = FillSignText.lineHeight(size)
        for (i, l) in FillSignText.lines(text).enumerated() where !l.isEmpty {
            line(l, font: font, ink: ink, baseline: CGPoint(x: origin.x, y: origin.y + ascent + CGFloat(i) * step), in: ctx)
        }
    }

    private static func line(_ text: String, font: CTFont, ink: CGColor, baseline: CGPoint, in ctx: CGContext) {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink
        ])
        ctx.saveGState()
        // The context goes downwards: the glyphs are flipped back up.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = baseline
        CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        ctx.restoreGState()
    }
}

/// A picture of a signature on paper: the paper becomes transparent, the picture is cropped to the ink.
enum FillSignImageImport {
    static func signature(from url: URL) -> (png: Data, size: CGSize)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return cleaned(image)
    }

    /// Light pixels fade out (paper), dark ones stay (ink); the result is cropped to what is left, with a small margin.
    static func cleaned(_ image: CGImage) -> (png: Data, size: CGSize)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let raw = ctx.data else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = raw.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
                let luminance = 0.299 * r + 0.587 * g + 0.114 * b
                // Paper above 0.82, ink under 0.55, a soft edge in between.
                let keep = min(1, max(0, (0.82 - luminance) / 0.27))
                px[i] = UInt8(Double(px[i]) * keep)
                px[i + 1] = UInt8(Double(px[i + 1]) * keep)
                px[i + 2] = UInt8(Double(px[i + 2]) * keep)
                px[i + 3] = UInt8(255 * keep)
                if keep > 0.15 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX > minX + 4, maxY > minY + 4, let full = ctx.makeImage() else { return nil }
        let pad = 6
        let crop = CGRect(x: max(0, minX - pad), y: max(0, minY - pad),
                          width: min(w, maxX + pad + 1) - max(0, minX - pad), height: min(h, maxY + pad + 1) - max(0, minY - pad))
        guard let cut = full.cropping(to: crop) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cut, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        // About 200 pixels per inch: a signature a few centimetres wide.
        let k: CGFloat = 72 / 200
        return (data as Data, CGSize(width: (CGFloat(cut.width) * k).rounded(), height: (CGFloat(cut.height) * k).rounded()))
    }
}
