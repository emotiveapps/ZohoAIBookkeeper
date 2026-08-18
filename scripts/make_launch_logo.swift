// Regenerates the launch-screen logo: the LFB circular badge masked to a
// transparent-background PNG. Source: the site logo (circle on white).
// Usage: swift scripts/make_launch_logo.swift <input.jpg> <output.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]) else {
    fatalError("usage: make_launch_logo.swift <input.jpg> <output.png>")
}

let side = 450
let size = NSSize(width: side, height: side)
let image = NSImage(size: size)
image.lockFocus()
// Inset slightly so no white corner pixels survive at the circle's edge.
let clip = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: side - 4, height: side - 4))
clip.addClip()
source.draw(in: NSRect(origin: .zero, size: size))
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to render PNG")
}
try! png.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
