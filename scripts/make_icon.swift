// Renders the app icon (1024×1024 PNG) for the .icns: the light layer of design/icone/AppIcon.icon, an atom around a
// glass heart, cut into the rounded square of the macOS icon grid, with its shadow. From macOS 26 on, the system reads
// AppIcon.icon itself (compiled by actool), with its dark version; this .icns serves older systems.
// The drawing comes from design/icone/dessiner.py.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let layerURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("design/icone/AppIcon.icon/Assets/clair.png")
guard let layer = NSImage(contentsOf: layerURL) else {
    FileHandle.standardError.write("make_icon: \(layerURL.path) introuvable\n".data(using: .utf8)!)
    exit(1)
}
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let box = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: box, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
shadow.set()
NSColor(srgbRed: 0.84, green: 0.86, blue: 0.89, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shape.addClip()
layer.draw(in: box)
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: out)) } catch { exit(1) }
