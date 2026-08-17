// Regenerates the app icon ("Frog Brick": green LEGO brick + check badge on navy).
// Usage: swift scripts/make_app_icon.swift
//        (writes Projects/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png)
import AppKit

let out = "Projects/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let full = NSRect(x: 0, y: 0, width: 1024, height: 1024)
let image = NSImage(size: full.size)
image.lockFocus()

NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.28, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.15, alpha: 1)])!
    .draw(in: full, angle: 90)

let brickGreen = NSColor(calibratedRed: 0.42, green: 0.74, blue: 0.36, alpha: 1)
let brickDark = NSColor(calibratedRed: 0.30, green: 0.58, blue: 0.26, alpha: 1)

let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.35)
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 36
shadow.set()
brickGreen.setFill()
NSBezierPath(roundedRect: NSRect(x: 192, y: 280, width: 640, height: 340), xRadius: 36, yRadius: 36).fill()
NSShadow().set()

for x: CGFloat in [292, 592] {
    brickGreen.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: 596, width: 140, height: 84), xRadius: 24, yRadius: 24).fill()
    NSColor(white: 1, alpha: 0.25).setFill()
    NSBezierPath(roundedRect: NSRect(x: x + 14, y: 646, width: 112, height: 22), xRadius: 11, yRadius: 11).fill()
}
brickDark.setFill()
NSBezierPath(roundedRect: NSRect(x: 192, y: 280, width: 640, height: 70), xRadius: 36, yRadius: 36).fill()

let badgeCenter = NSPoint(x: 790, y: 660)
shadow.set()
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - 120, y: badgeCenter.y - 120, width: 240, height: 240)).fill()
NSShadow().set()

let config = NSImage.SymbolConfiguration(pointSize: 200, weight: .bold)
if let symbol = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
    brickDark.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let aspect = symbol.size.height / symbol.size.width
    let width: CGFloat = 140
    tinted.draw(in: NSRect(x: badgeCenter.x - width/2, y: badgeCenter.y - width*aspect/2,
                           width: width, height: width * aspect))
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { fatalError() }
let final: NSBitmapImageRep
if rep.pixelsWide != 1024 {
    final = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: final)
    image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    NSGraphicsContext.restoreGraphicsState()
} else { final = rep }
try! final.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
