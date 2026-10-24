import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images with ImageIO: format, size, quality, metadata. Never touches the original.
enum ConverterImageEngine {
    /// What this Mac's ImageIO can write (read once).
    static let writable: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    /// The formats offered, in order. WebP only when ffmpeg can encode it.
    static func formats(webp: Bool) -> [ConverterImageFormat] {
        ConverterImageFormat.catalog.filter { $0.viaFFmpeg ? webp : writable.contains($0.uti) }
    }

    /// What "même format" writes: the source's own format when this Mac can write it, JPEG otherwise.
    static func sameFormat(uti: String?) -> ConverterImageFormat {
        ConverterImageFormat.matching(uti: uti).flatMap { writable.contains($0.uti) ? $0 : nil } ?? .jpeg
    }

    /// The same, guessed from the file name (the interface decides from it whether the quality applies).
    static func sameFormat(for url: URL) -> ConverterImageFormat {
        sameFormat(uti: UTType(filenameExtension: url.pathExtension.lowercased())?.identifier)
    }

    static func source(_ url: URL) throws -> CGImageSource {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { throw ConverterError.unreadable(url.lastPathComponent) }
        return src
    }

    /// Pixel size before orientation.
    static func pixelSize(_ src: CGImageSource, index: Int = 0) -> (Int, Int)? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// The image upright (EXIF orientation applied), its longest side at most `maxSide` pixels (0 = full size).
    static func uprightImage(_ src: CGImageSource, index: Int, maxSide: Int) -> CGImage? {
        let full = pixelSize(src, index: index).map { max($0.0, $0.1) } ?? 0
        let target = maxSide > 0 ? min(maxSide, full > 0 ? full : maxSide) : full
        guard target > 0 else { return CGImageSourceCreateImageAtIndex(src, index, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, index, options as CFDictionary)
    }

    /// Keeps only what playback needs (animation delays) when the metadata goes.
    private static func essentials(_ props: [CFString: Any]) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary] {
            guard let dict = props[key] as? [CFString: Any] else { continue }
            var keep: [CFString: Any] = [:]
            for k in [kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime,
                      kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGUnclampedDelayTime] where dict[k] != nil {
                keep[k] = dict[k]
            }
            if !keep.isEmpty { out[key] = keep }
        }
        return out
    }

    /// Re-encodes one image. `format` nil keeps the source format (or JPEG when it cannot be written).
    /// `strip`: nil keeps the metadata, `.gps` drops the position only, `.all` everything but what playback needs.
    static func convert(_ input: URL, format: ConverterImageFormat?, maxSide: Int, quality: Double, strip: ConverterStripMode?,
                        suffix: String?, folder: URL?, control: ConverterControl) throws -> URL {
        let src = try source(input)
        let target = format ?? sameFormat(uti: CGImageSourceGetType(src) as String?)
        if target.viaFFmpeg {
            throw ConverterError.unsupported("Le WebP passe par ffmpeg.")
        }
        let count = CGImageSourceGetCount(src)
        let keepsFrames = count > 1 && (target.uti == ConverterImageFormat.gif.uti || target.uti == ConverterImageFormat.tiff.uti)
        let frames = keepsFrames ? Array(0..<count) : [CGImageSourceGetPrimaryImageIndex(src)]
        let out = FileOps.outputURL(for: input, extension: target.ext, suffix: suffix, folder: folder)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, target.uti as CFString, frames.count, nil) else {
            throw ConverterError.unsupported("Ce Mac ne sait pas écrire le format \(target.name).")
        }
        if keepsFrames, let props = CGImageSourceCopyProperties(src, nil) {
            CGImageDestinationSetProperties(dest, props)
        }
        for (n, index) in frames.enumerated() {
            try control.check()
            guard let image = uprightImage(src, index: index, maxSide: maxSide) else {
                throw ConverterError.unreadable(input.lastPathComponent)
            }
            let original = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]) ?? [:]
            var props = strip == .all ? essentials(original) : original
            if strip == .gps { props[kCGImagePropertyGPSDictionary] = nil }
            // The pixels are already upright.
            props[kCGImagePropertyOrientation] = 1
            if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
            if target.lossy { props[kCGImageDestinationLossyCompressionQuality] = quality }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            control.progress(Double(n + 1) / Double(frames.count))
        }
        guard CGImageDestinationFinalize(dest) else {
            ConverterOutputs.discard(out)
            throw ConverterError.failed("L'écriture en \(target.name) a échoué.")
        }
        FileOps.didCreate(out)
        return out
    }

    /// Removes the GPS position (or all metadata) without recompressing the pixels.
    /// ImageIO needs the metadata spelled out (a JPEG copied with only "exclude GPS" loses everything, orientation included,
    /// and a HEIC keeps everything), so the copy gets the source metadata minus what goes. The result is read back:
    /// when something survived (the shooting date of a HEIC), the image is re-encoded at maximum quality instead.
    static func stripMetadata(_ input: URL, mode: ConverterStripMode, folder: URL?, control: ConverterControl) throws -> (url: URL, lossless: Bool) {
        let src = try source(input)
        guard let type = CGImageSourceGetType(src) else { throw ConverterError.unreadable(input.lastPathComponent) }
        let ext = input.pathExtension.isEmpty ? (UTType(type as String)?.preferredFilenameExtension ?? "jpg") : input.pathExtension
        let suffix = mode == .gps ? "sans GPS" : "sans métadonnées"
        let out = FileOps.outputURL(for: input, extension: ext, suffix: suffix, folder: folder)
        let count = CGImageSourceGetCount(src)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, count, nil) else {
            throw ConverterError.unsupported("Ce format ne peut pas être réécrit.")
        }
        let primary = CGImageSourceGetPrimaryImageIndex(src)
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: keptMetadata(src, index: primary, mode: mode),
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true
        ]
        try control.check()
        var error: Unmanaged<CFError>?
        if CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &error), !metadataLeft(out, mode: mode) {
            FileOps.didCreate(out)
            control.progress(1)
            return (out, true)
        }
        error?.release()
        ConverterOutputs.discard(out)
        // Re-encoded, dropping only what the mode removes (the shooting date stays with "Seulement la localisation").
        let url = try convert(input, format: sameFormat(uti: type as String), maxSide: 0, quality: 1, strip: mode, suffix: suffix,
                              folder: folder, control: control)
        if metadataLeft(url, mode: .gps) {
            ConverterOutputs.discard(url)
            throw ConverterError.failed("Je n'arrive pas à retirer la localisation de « \(input.lastPathComponent) ».")
        }
        return (url, false)
    }

    /// The source's metadata without its GPS tags, or (mode .all) nothing but the orientation.
    private static func keptMetadata(_ src: CGImageSource, index: Int, mode: ConverterStripMode) -> CGMutableImageMetadata {
        if mode == .all {
            let meta = CGImageMetadataCreateMutable()
            let props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]) ?? [:]
            if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation != 1 {
                _ = CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation,
                                                                 orientation as CFNumber)
            }
            return meta
        }
        guard let meta = CGImageSourceCopyMetadataAtIndex(src, index, nil), let copy = CGImageMetadataCreateMutableCopy(meta) else {
            return CGImageMetadataCreateMutable()
        }
        for tag in (CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag]) ?? [] {
            guard let name = CGImageMetadataTagCopyName(tag) as String?, name.hasPrefix("GPS"),
                  let prefix = CGImageMetadataTagCopyPrefix(tag) as String? else { continue }
            _ = CGImageMetadataRemoveTagWithPath(copy, nil, "\(prefix):\(name)" as CFString)
        }
        return copy
    }

    /// True when the written file still holds what should have gone.
    static func metadataLeft(_ url: URL, mode: ConverterStripMode) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [CFString: Any] else { return true }
        if p[kCGImagePropertyGPSDictionary] != nil { return true }
        guard mode == .all else { return false }
        let exif = (p[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        let tiff = (p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        let personal = [exif[kCGImagePropertyExifDateTimeOriginal], exif[kCGImagePropertyExifDateTimeDigitized], exif[kCGImagePropertyExifBodySerialNumber],
                        exif[kCGImagePropertyExifLensModel], tiff[kCGImagePropertyTIFFMake], tiff[kCGImagePropertyTIFFModel],
                        tiff[kCGImagePropertyTIFFDateTime], tiff[kCGImagePropertyTIFFSoftware], p[kCGImagePropertyIPTCDictionary]]
        return personal.contains { $0 != nil }
    }

    /// PNG data of an image (QR codes, temporary files for ffmpeg).
    static func pngData(_ image: CGImage) -> Data? {
        encode(image, uti: ConverterImageFormat.png.uti, quality: nil)
    }

    static func encode(_ image: CGImage, uti: String, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, uti as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// "4 032 × 3 024" for the file list.
    static func describe(_ url: URL) -> (detail: String?, date: Date?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (nil, nil) }
        var detail: String?
        if var w = p[kCGImagePropertyPixelWidth] as? Int, var h = p[kCGImagePropertyPixelHeight] as? Int {
            if let o = p[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
            detail = "\(Fmt.int(w)) × \(Fmt.int(h))"
            let frames = CGImageSourceGetCount(src)
            if frames > 1 { detail! += " · \(frames) images" }
        }
        var date: Date?
        if let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any], let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            date = exifDate.date(from: s)
        }
        return (detail, date)
    }

    private static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    /// True when the file holds a GPS position (used by the self-test on generated data and by `--dump`).
    static func hasGPS(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        return p[kCGImagePropertyGPSDictionary] != nil
    }
}

/// Where outputs go, and the clean-up of a half-written output after a failure or a cancel.
enum ConverterOutputs {
    /// Removes a partial output this job wrote itself, external disks included (logged by `Remover`).
    static func discard(_ url: URL) {
        Remover.discardOutput(url)
    }

    static func size(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey])
        if values?.isDirectory == true { return FileSizer.size(of: url.path) }
        return Int64(values?.fileSize ?? 0)
    }
}
