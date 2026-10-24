import Foundation
import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// The copied images: a full PNG (to copy it again) and a small thumbnail, in the module's own data folder
/// (~/Library/Application Support/Heartware/Clipboard). These are internal files of the app, like its JSON stores:
/// they are written and deleted here, by name only, and never outside that folder. Nothing is written in demo mode.
enum ClipboardStorage {
    static let folderName = "Clipboard"
    /// Images bigger than this are not kept (a 40 Mo screenshot of a 6K screen, a RAW photo…).
    static let maxImageBytes = 40_000_000

    static var folder: URL { DataStore.url(folderName) }

    struct Prepared: Sendable {
        var id: UUID
        var digest: String
        var width: Int
        var height: Int
        var file: String
        var thumb: String
        var bytes: Int
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes the pasteboard data, writes a PNG and a thumbnail (off the main thread). Nil if it is not an image.
    static func prepare(_ data: Data) -> Prepared? {
        guard !DemoData.isEnabled, let dir = DataStore.ensureFolder(folderName, excludeFromBackup: true),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let id = UUID()
        let file = id.uuidString + ".png", thumb = id.uuidString + "-thumb.png"
        let isPNG = (CGImageSourceGetType(source) as String?) == UTType.png.identifier
        guard let full = isPNG ? data : png(image), let small = thumbnail(source).flatMap(png) else { return nil }
        do {
            try full.write(to: dir.appendingPathComponent(file), options: .atomic)
            try small.write(to: dir.appendingPathComponent(thumb), options: .atomic)
            DataStore.protect(dir.appendingPathComponent(file))
            DataStore.protect(dir.appendingPathComponent(thumb))
        } catch {
            remove(file)
            remove(thumb)
            return nil
        }
        return Prepared(id: id, digest: digest(data), width: image.width, height: image.height, file: file, thumb: thumb, bytes: full.count + small.count)
    }

    private static func thumbnail(_ source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func png(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func read(_ name: String) -> Data? {
        guard isPlainName(name), !DemoData.isEnabled else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent(name))
    }

    /// A sharper copy of a kept image for the history window (1 400 px at most), read off the main thread.
    static func previewImage(_ name: String) -> CGImage? {
        guard isPlainName(name), !DemoData.isEnabled,
              let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1400
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Deletes one of the module's own files. Only a bare file name is accepted: nothing outside the folder can be reached.
    static func remove(_ name: String) {
        guard isPlainName(name), !DemoData.isEnabled, !Snapshot.isActive else { return }
        Remover.removeInternal(folder.appendingPathComponent(name).path)
    }

    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && name.count <= 80
    }

    /// Files of the folder that no item refers to any more (after a crash, or a history cleared elsewhere).
    static func removeOrphans(keeping names: Set<String>) -> Int {
        guard !DemoData.isEnabled, !Snapshot.isActive,
              let list = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var n = 0
        for name in list where name.hasSuffix(".png") && !names.contains(name) {
            remove(name)
            n += 1
        }
        return n
    }

    static func folderSize() -> Int {
        guard !DemoData.isEnabled, let list = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        return list.reduce(0) { total, name in
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            return total + size
        }
    }
}

/// Thumbnails, decoded once into bitmaps (they render well in lists and in `--snapshot`).
@MainActor
enum ClipboardThumbs {
    private static var cache: [String: CGImage] = [:]
    private static var order: [String] = []

    static func image(_ info: ClipboardImageInfo) -> CGImage? {
        if let cg = cache[info.thumb] { return cg }
        guard !DemoData.isEnabled, ClipboardStorage.isPlainName(info.thumb),
              let source = CGImageSourceCreateWithURL(ClipboardStorage.folder.appendingPathComponent(info.thumb) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        put(info.thumb, cg)
        return cg
    }

    static func put(_ key: String, _ image: CGImage) {
        cache[key] = image
        order.append(key)
        // About 120 thumbnails in memory at most.
        while order.count > 120 {
            cache[order.removeFirst()] = nil
        }
    }

    /// Drawn pictures for the demo history: no real image is ever read.
    static func demoImage(kind: Int, width: Int = 640, height: Int = 400) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        }
        func gradient(_ top: UInt32, _ bottom: UInt32) {
            let g = CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        }
        if kind == 0 {
            // A screenshot: a window on a blue desktop.
            gradient(0x5BA3E6, 0x2C4F8C)
            let win = CGRect(x: w * 0.12, y: h * 0.12, width: w * 0.76, height: h * 0.72)
            ctx.setFillColor(color(0xFCFBF9))
            ctx.addPath(CGPath(roundedRect: win, cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.fillPath()
            ctx.setFillColor(color(0xEBE9E2))
            ctx.fill(CGRect(x: win.minX, y: win.maxY - 34, width: win.width, height: 20))
            ctx.addPath(CGPath(roundedRect: CGRect(x: win.minX, y: win.maxY - 34, width: win.width, height: 34), cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.fillPath()
            for (i, c) in [0xEC6A5E, 0xF4BF4F, 0x61C554].enumerated() {
                ctx.setFillColor(color(UInt32(c)))
                ctx.fillEllipse(in: CGRect(x: win.minX + 16 + CGFloat(i) * 20, y: win.maxY - 24, width: 12, height: 12))
            }
            ctx.setFillColor(color(0xD97757))
            ctx.fill(CGRect(x: win.minX + 24, y: win.maxY - 80, width: win.width * 0.38, height: 18))
            for row in 0..<5 {
                ctx.setFillColor(color(0xCCC8BC))
                ctx.fill(CGRect(x: win.minX + 24, y: win.maxY - 120 - CGFloat(row) * 28, width: win.width * (row % 2 == 0 ? 0.8 : 0.62), height: 10))
            }
        } else {
            // A landscape: sunset, sun and hills.
            gradient(0xF6B26B, 0xC2556E)
            ctx.setFillColor(color(0xFFE6A8, 0.95))
            ctx.fillEllipse(in: CGRect(x: w * 0.58, y: h * 0.42, width: h * 0.32, height: h * 0.32))
            for (i, c) in [0x7A3E62, 0x4F2A4F, 0x2E1D3A].enumerated() {
                let path = CGMutablePath()
                let base = h * (0.42 - CGFloat(i) * 0.12)
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: base))
                path.addCurve(to: CGPoint(x: w, y: base * 0.8), control1: CGPoint(x: w * (0.3 + CGFloat(i) * 0.1), y: base + h * 0.22),
                              control2: CGPoint(x: w * 0.6, y: base - h * 0.12))
                path.addLine(to: CGPoint(x: w, y: 0))
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setFillColor(color(UInt32(c)))
                ctx.fillPath()
            }
        }
        return ctx.makeImage()
    }
}
