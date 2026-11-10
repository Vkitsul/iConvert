#!/usr/bin/env swift
// Draws the app icon into the asset catalog.
// Run from the project root: swift scripts/make-icon.swift
import AppKit

let folder = URL(filePath: "iConvert/Assets.xcassets/AppIcon.appiconset", directoryHint: .isDirectory)
let sizes: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let unit = CGFloat(pixels) / 1024

    // Apple's macOS icon grid: an 824pt rounded square centred on a 1024pt canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        .applying(.init(scaleX: unit, y: unit))
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * unit, yRadius: 185 * unit)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24 * unit
    shadow.shadowOffset = NSSize(width: 0, height: -10 * unit)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(
        starting: NSColor(srgbRed: 0.10, green: 0.62, blue: 0.62, alpha: 1),
        ending: NSColor(srgbRed: 0.09, green: 0.24, blue: 0.47, alpha: 1)
    )!.draw(in: shape, angle: -90)

    let configuration = NSImage.SymbolConfiguration(pointSize: 460 * unit, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "arrow.trianglehead.2.clockwise", accessibilityDescription: nil)!
        .withSymbolConfiguration(configuration)!
    let origin = NSPoint(x: tile.midX - symbol.size.width / 2, y: tile.midY - symbol.size.height / 2)
    symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (points, scale) in sizes {
    let name = "icon_\(points)x\(points)@\(scale)x.png"
    try render(pixels: points * scale).write(to: folder.appending(path: name))
    images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: folder.appending(path: "Contents.json"))
