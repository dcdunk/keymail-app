import AppKit
// Full-bleed 1024 square of the Keymail tile: macOS applies its own rounded mask.
let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
let (x0, x1) = (320, 1720)   // a square around the key in the 2048 artwork, so the key fills most of the icon
let top = src.colorAt(x: 1024, y: x0 + 8)!, bottom = src.colorAt(x: 1024, y: x1 - 8)!
let n = 1024
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSGradient(starting: bottom, ending: top)!.draw(in: NSRect(x: 0, y: 0, width: n, height: n), angle: 90)
let img = NSImage(size: NSSize(width: 2048, height: 2048)); img.addRepresentation(src)
let w = CGFloat(x1 - x0)
img.draw(in: NSRect(x: 0, y: 0, width: n, height: n), from: NSRect(x: CGFloat(x0), y: CGFloat(2048 - x1), width: w, height: w), operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
