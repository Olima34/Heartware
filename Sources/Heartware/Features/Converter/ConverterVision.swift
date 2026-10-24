import Foundation
import Vision
import PDFKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// Text recognition (OCR), barcode reading and QR code drawing, all on device.
enum ConverterVision {
    static let languages = ["fr-FR", "en-US"]

    static func recognizeText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func barcodes(_ image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    /// The photo upright, at most 4096 pixels long (plenty for text and codes).
    private static func image(_ input: URL) throws -> CGImage {
        let src = try ConverterImageEngine.source(input)
        guard let image = ConverterImageEngine.uprightImage(src, index: CGImageSourceGetPrimaryImageIndex(src), maxSide: 4096) else {
            throw ConverterError.unreadable(input.lastPathComponent)
        }
        return image
    }

    static func ocr(_ input: URL, kind: ConverterKind, control: ConverterControl) throws -> String {
        var parts: [String] = []
        if kind == .pdf {
            let doc = try ConverterPDFEngine.open(input)
            for i in 0..<doc.pageCount {
                try control.check()
                guard let page = doc.page(at: i) else { continue }
                var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // A scanned page has no text layer (or only a few stray characters): read the picture.
                if text.count < 20, let image = ConverterPDFEngine.render(page, dpi: 200, maxSide: 4000) {
                    text = try recognizeText(image)
                }
                if !text.isEmpty { parts.append(doc.pageCount > 1 ? "— Page \(i + 1) —\n\(text)" : text) }
                control.progress(Double(i + 1) / Double(doc.pageCount))
            }
        } else {
            control.progress(nil)
            let picture = try image(input)
            try control.check()
            parts.append(try recognizeText(picture))
            control.progress(1)
        }
        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readCodes(_ input: URL, kind: ConverterKind, control: ConverterControl) throws -> [String] {
        var found: [String] = []
        if kind == .pdf {
            let doc = try ConverterPDFEngine.open(input)
            for i in 0..<doc.pageCount {
                try control.check()
                if let page = doc.page(at: i), let image = ConverterPDFEngine.render(page, dpi: 200, maxSide: 4000) {
                    found += try barcodes(image)
                }
                control.progress(Double(i + 1) / Double(doc.pageCount))
            }
        } else {
            found = try barcodes(try image(input))
            control.progress(1)
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    // MARK: - QR codes

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// A crisp black on white QR code with its quiet zone, about `size` pixels wide. nil for empty or too long texts.
    static func qrImage(_ text: String, size: Int = 1024) -> CGImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage, code.extent.width > 0 else { return nil }
        // Whole pixels per module (nearest neighbour), plus a 4-module white margin.
        let modules = code.extent.width
        let scale = max(1, (CGFloat(size) / (modules + 8)).rounded(.down))
        let scaled = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let margin = 4 * scale
        let canvas = CGRect(x: -margin, y: -margin, width: scaled.extent.width + 2 * margin, height: scaled.extent.height + 2 * margin)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: canvas)
        let composed = scaled.composited(over: white)
        return context.createCGImage(composed, from: canvas)
    }

    /// Payloads a QR code can hold, roughly (byte mode, correction level M).
    static let qrCapacity = 2331
}
