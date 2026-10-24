import Foundation
import ImageIO
import CoreImage
import Vision
import UniformTypeIdentifiers

/// The wheel's own work on images: crop, quarter turn, background, cut-out, marks and redactions, with ImageIO,
/// Core Graphics, Core Image and Vision, all on this Mac. Always a new file: the original is only read.
enum WheelImageEngine {
    /// An image upright (EXIF orientation applied), its type and its metadata.
    struct Picture: @unchecked Sendable {
        let image: CGImage
        let uti: String?
        let properties: [CFString: Any]
        let hasAlpha: Bool

        var width: Int { image.width }
        var height: Int { image.height }
        var size: CGSize { CGSize(width: width, height: height) }
    }

    static func load(_ url: URL, maxSide: Int = 0) throws -> Picture {
        let src = try ConverterImageEngine.source(url)
        let index = CGImageSourceGetPrimaryImageIndex(src)
        guard let image = ConverterImageEngine.uprightImage(src, index: index, maxSide: maxSide) else {
            throw ConverterError.unreadable(url.lastPathComponent)
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]) ?? [:]
        return Picture(image: image, uti: CGImageSourceGetType(src) as String?, properties: props,
                       hasAlpha: (props[kCGImagePropertyHasAlpha] as? Bool) ?? false)
    }

    /// The size of the original upright, read from its header only.
    static func uprightSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [CFString: Any],
              var w = p[kCGImagePropertyPixelWidth] as? Int, var h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        if let o = p[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        return CGSize(width: w, height: h)
    }

    enum Output {
        /// The original's format (JPEG when this Mac cannot write it).
        case same
        /// PNG: transparency, sharp lines and text.
        case png
    }

    /// Writes `image` as a new file next to `input` (or in `folder`), named "<name> <suffix>". With `keepMetadata`, the
    /// original's metadata comes along (its orientation reset: the pixels are already upright); without, nothing at all.
    static func save(_ image: CGImage, from input: URL, picture: Picture?, suffix: String, as output: Output,
                     keepMetadata: Bool, dropGPS: Bool = false, folder: URL?) throws -> URL {
        guard !DemoData.isEnabled else { throw FileOps.Failure.demo }
        var format: ConverterImageFormat = output == .png ? .png : ConverterImageEngine.sameFormat(uti: picture?.uti)
        // A single image out of an animated GIF reads better as PNG.
        if format.uti == ConverterImageFormat.gif.uti { format = .png }
        let out = FileOps.outputURL(for: input, extension: format.ext, suffix: suffix, folder: folder)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, format.uti as CFString, 1, nil) else {
            throw ConverterError.unsupported("Ce Mac ne sait pas écrire le format \(format.name).")
        }
        var props: [CFString: Any] = keepMetadata ? (picture?.properties ?? [:]) : [:]
        props[kCGImagePropertyOrientation] = 1
        if dropGPS { props[kCGImagePropertyGPSDictionary] = nil }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            props[kCGImagePropertyExifDictionary] = exif
        }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyHasAlpha, kCGImagePropertyDepth] {
            props[key] = nil
        }
        if format.lossy { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            ConverterOutputs.discard(out)
            throw ConverterError.failed("L'écriture en \(format.name) a échoué.")
        }
        FileOps.didCreate(out)
        return out
    }

    // MARK: - Crop and turn

    /// A rectangle given from 0 to 1 (y going down, as on screen) in whole pixels, inside the image, at least 1 × 1.
    static func pixelRect(_ r: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        var x0 = (min(max(r.minX, 0), 1) * w).rounded()
        var y0 = (min(max(r.minY, 0), 1) * h).rounded()
        var x1 = (min(max(r.maxX, 0), 1) * w).rounded()
        var y1 = (min(max(r.maxY, 0), 1) * h).rounded()
        if x1 - x0 < 1 { x1 = min(w, x0 + 1); x0 = x1 - 1 }
        if y1 - y0 < 1 { y1 = min(h, y0 + 1); y0 = y1 - 1 }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func crop(_ input: URL, rect: CGRect, quarterTurns: Int, folder: URL?) throws -> URL {
        let p = try load(input)
        // CGImage's own pixels start at the top left, like the rectangle.
        guard var image = p.image.cropping(to: pixelRect(rect, width: p.width, height: p.height)) else {
            throw ConverterError.failed("Le recadrage a échoué.")
        }
        if quarterTurns % 4 != 0 {
            guard let turned = rotated(image, quarterTurns: quarterTurns) else { throw ConverterError.failed("La rotation a échoué.") }
            image = turned
        }
        return try save(image, from: input, picture: p, suffix: "recadrée", as: .same, keepMetadata: true, folder: folder)
    }

    static func rotate(_ input: URL, folder: URL?) throws -> URL {
        let p = try load(input)
        guard let image = rotated(p.image, quarterTurns: 1) else { throw ConverterError.failed("La rotation a échoué.") }
        return try save(image, from: input, picture: p, suffix: "pivotée", as: .same, keepMetadata: true, folder: folder)
    }

    /// The image turned by quarter turns, clockwise.
    static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let w = image.width, h = image.height
        let (nw, nh) = turns % 2 == 1 ? (h, w) : (w, h)
        guard let ctx = context(width: nw, height: nh, alpha: true) else { return nil }
        // Core Graphics' y goes up: a clockwise turn is a negative angle.
        switch turns {
        case 1:
            ctx.translateBy(x: 0, y: CGFloat(nh))
            ctx.rotate(by: -.pi / 2)
        case 2:
            ctx.translateBy(x: CGFloat(nw), y: CGFloat(nh))
            ctx.rotate(by: .pi)
        default:
            ctx.translateBy(x: CGFloat(nw), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func context(width: Int, height: Int, alpha: Bool) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)
    }

    // MARK: - Background

    /// The size of the picture laid on its background: its margins all around, then widened (or heightened) to the ratio.
    static func backdropSize(image: CGSize, style: WheelBackdropStyle) -> CGSize {
        let pad = CGFloat(style.padding) * max(image.width, image.height)
        var w = image.width + 2 * pad, h = image.height + 2 * pad
        if let r = style.ratio.value {
            if w / h < r { w = h * r } else { h = w / r }
        }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    /// The picture on its background. `blurred`: the picture already blurred (the « Flou » background), drawn to fill.
    /// At most `maxSide` pixels long.
    static func backdrop(_ image: CGImage, hasAlpha: Bool, style: WheelBackdropStyle, blurred: CGImage?, maxSide: CGFloat = 6000) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let canvas = backdropSize(image: size, style: style)
        let scale = min(1, maxSide / max(canvas.width, canvas.height))
        guard let ctx = context(width: Int(canvas.width * scale), height: Int(canvas.height * scale), alpha: true) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .high
        let full = CGRect(origin: .zero, size: canvas)
        drawFill(style.fill, in: ctx, rect: full, blurred: blurred)
        let frame = CGRect(x: ((canvas.width - size.width) / 2).rounded(), y: ((canvas.height - size.height) / 2).rounded(),
                           width: size.width, height: size.height)
        let radius = CGFloat(style.corner) * min(size.width, size.height)
        let rounded = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if style.shadow > 0 {
            let s = CGFloat(style.shadow)
            let reach = max(size.width, size.height)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -reach * 0.018 * s), blur: reach * 0.06 * s,
                          color: CGColor(gray: 0, alpha: 0.22 + 0.33 * s))
            if hasAlpha {
                // A cut-out casts the shadow of its own outline.
                ctx.addPath(rounded)
                ctx.clip()
                ctx.draw(image, in: frame)
            } else {
                ctx.addPath(rounded)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(rounded)
        ctx.clip()
        ctx.draw(image, in: frame)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    private static func drawFill(_ fill: WheelBackdropFill, in ctx: CGContext, rect: CGRect, blurred: CGImage?) {
        switch fill {
        case .clear:
            break
        case .solid(let i):
            ctx.setFillColor(WheelBackdropPalette.solid(i).cg)
            ctx.fill(rect)
        case .gradient(let i):
            let g = WheelBackdropPalette.gradient(i)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let gradient = CGGradient(colorsSpace: space, colors: g.colors.map(\.cg) as CFArray, locations: nil) else { return }
            // From the top left to the bottom right (Core Graphics' y goes up).
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .blur:
            guard let blurred else {
                ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
                ctx.fill(rect)
                return
            }
            // Fills the whole background, cut to fit, then a little darker so that the picture stands out.
            let s = max(rect.width / CGFloat(blurred.width), rect.height / CGFloat(blurred.height))
            let w = CGFloat(blurred.width) * s, h = CGFloat(blurred.height) * s
            ctx.draw(blurred, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.12))
            ctx.fill(rect)
        }
    }

    /// The picture very blurred, small: the « Flou » background (blurring a small copy is quick and looks the same).
    static func blurredBackground(_ image: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let side = max(ci.extent.width, ci.extent.height)
        let shrink = min(1, 480 / max(1, side))
        let small = ci.transformed(by: CGAffineTransform(scaleX: shrink, y: shrink))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 22).cropped(to: small.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.25])
        return render(blurred)
    }

    static func render(_ image: CIImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space)
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Cut-out

    /// The subject (a person, an animal, an object) alone on a transparent background, cropped around it.
    static func cutout(_ input: URL, folder: URL?, control: ConverterControl) throws -> URL {
        control.progress(nil)
        let p = try load(input)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: p.image, options: [:])
        try handler.perform([request])
        try control.check()
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw ConverterError.failed("Je ne trouve pas de sujet à détourer sur cette image.")
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
        guard let image = render(CIImage(cvPixelBuffer: buffer)) else { throw ConverterError.failed("Le détourage a échoué.") }
        return try save(image, from: input, picture: p, suffix: "détourée", as: .png, keepMetadata: false, folder: folder)
    }

    // MARK: - Marks and redactions

    /// The blurred and the pixelated versions of the whole picture: a redaction shows the one it asks for inside its box.
    static func redactionLayers(_ image: CGImage) -> WheelRedactionLayers {
        let ci = CIImage(cgImage: image)
        let side = max(ci.extent.width, ci.extent.height)
        let blur = ci.clampedToExtent().applyingGaussianBlur(sigma: max(6, side * 0.018)).cropped(to: ci.extent)
        let pixels = ci.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, side / 48),
                                                                    kCIInputCenterKey: CIVector(x: 0, y: 0)]).cropped(to: ci.extent)
        return WheelRedactionLayers(blur: render(blur), pixels: render(pixels))
    }

    /// The picture with its marks drawn in, at its full size.
    static func marked(_ picture: Picture, marks: [WheelMark], layers: WheelRedactionLayers?) -> CGImage? {
        guard let ctx = context(width: picture.width, height: picture.height, alpha: picture.hasAlpha) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(picture.image, in: CGRect(origin: .zero, size: picture.size))
        // The marks are drawn as on screen, y going down.
        ctx.translateBy(x: 0, y: CGFloat(picture.height))
        ctx.scaleBy(x: 1, y: -1)
        WheelMarkRenderer.draw(marks, in: ctx, size: picture.size, layers: layers)
        return ctx.makeImage()
    }

    /// Faces, a little enlarged (rectangles from 0 to 1, y going down).
    static func faces(_ image: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).map { flip($0.boundingBox).insetBy(dx: -$0.boundingBox.width * 0.12, dy: -$0.boundingBox.height * 0.18) }
    }

    /// E-mail addresses, phone numbers, IBAN and card numbers read in the picture.
    static func sensitiveText(_ image: CGImage) -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var boxes: [CGRect] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            for range in WheelSensitive.ranges(in: candidate.string) {
                if let box = try? candidate.boundingBox(for: range)?.boundingBox {
                    boxes.append(flip(box).insetBy(dx: -0.004, dy: -box.height * 0.18))
                }
            }
        }
        return boxes
    }

    /// Vision's rectangles (y going up) as on screen.
    private static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }
}

/// What a redaction by blur or pixels shows inside its box.
struct WheelRedactionLayers: @unchecked Sendable {
    var blur: CGImage?
    var pixels: CGImage?
}

/// The text worth hiding before sharing a picture.
enum WheelSensitive {
    private static let patterns: [NSRegularExpression] = [
        // E-mail addresses.
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
        // IBAN (FR76 3000 6000 …).
        #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,4})?\b"#,
        // Card numbers (16 digits, in groups or not).
        #"\b(?:\d{4}[ -]?){3}\d{4}\b"#,
        // Phone numbers: French ones (06 12 34 56 78, +33 6 12 34 56 78) and international ones.
        #"(?:\+\d{1,3}[ .-]?)?\(?0?\d\)?(?:[ .-]?\d{2}){4}\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func ranges(in text: String) -> [Range<String.Index>] {
        let ns = NSRange(text.startIndex..., in: text)
        var found: [Range<String.Index>] = []
        for p in patterns {
            for m in p.matches(in: text, range: ns) {
                guard let r = Range(m.range, in: text), !found.contains(where: { $0.overlaps(r) }) else { continue }
                found.append(r)
            }
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }
    }
}
