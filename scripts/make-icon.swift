// Draws the app icon and writes Resources/AppIcon.icns.  Run: swift scripts/make-icon.swift
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
// macOS icon grid: an 824 pt rounded square centred on a 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.30, blue: 0.95, alpha: 1),
                    NSColor(srgbRed: 0.66, green: 0.25, blue: 0.86, alpha: 1)])!.draw(in: shape, angle: -60)
NSGraphicsContext.current?.restoreGraphicsState()
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold).applying(.init(paletteColors: [NSColor(srgbRed: 0.5, green: 0.27, blue: 0.9, alpha: 1), .white]))
let symbol = NSImage(systemSymbolName: "play.tv.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let s = symbol.size
symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + 10, width: s.width, height: s.height))
image.unlockFocus()

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    for (name, scale) in [("icon_\(px)x\(px).png", 1), ("icon_\(px / 2)x\(px / 2)@2x.png", 2)] where scale == 1 ? px <= 512 : px >= 32 {
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
let run = Process()
run.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
run.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try run.run()
run.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
