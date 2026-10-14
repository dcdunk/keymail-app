// Draws 5 Lightmail icon concepts. Run: swift icon/options/make_options.swift icon/options
import AppKit

let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a) }

func render(_ name: String, top: NSColor, bottom: NSColor, draw: () -> Void) -> NSImage {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let sq = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.25); sh.shadowBlurRadius = 24; sh.shadowOffset = NSSize(width: 0, height: -10); sh.set()
    bottom.setFill(); sq.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); sq.addClip()
    NSGradient(starting: top, ending: bottom)!.draw(in: sq, angle: -90)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    return img
}

func stroke(_ p: NSBezierPath, _ col: NSColor, _ w: CGFloat) { p.lineWidth = w; p.lineCapStyle = .round; p.lineJoinStyle = .round; col.setStroke(); p.stroke() }

var imgs: [NSImage] = []

// 1. Bolt Envelope: envelope flap is a lightning bolt. Speed + mail.
imgs.append(render("1-bolt-envelope", top: c(255, 196, 61), bottom: c(244, 128, 36)) {
    let e = NSRect(x: 252, y: 322, width: 520, height: 380)
    NSColor.white.setFill(); NSBezierPath(roundedRect: e, xRadius: 54, yRadius: 54).fill()
    let p = NSBezierPath()
    p.move(to: NSPoint(x: e.minX + 46, y: e.maxY - 40))
    p.line(to: NSPoint(x: e.midX - 30, y: e.midY + 10))
    p.line(to: NSPoint(x: e.midX + 30, y: e.midY + 60))
    p.line(to: NSPoint(x: e.maxX - 46, y: e.maxY - 40))
    stroke(p, c(244, 128, 36), 34)
})

// 2. Paper Plane of Light: a white plane leaving a light trail on deep navy.
imgs.append(render("2-light-plane", top: c(40, 52, 110), bottom: c(14, 18, 44)) {
    for (i, a) in [0.5, 0.3, 0.15].enumerated() {
        let t = NSBezierPath(); let y = 420 - CGFloat(i) * 34
        t.move(to: NSPoint(x: 200, y: y - 60)); t.curve(to: NSPoint(x: 470, y: y + 70), controlPoint1: NSPoint(x: 300, y: y - 70), controlPoint2: NSPoint(x: 380, y: y))
        stroke(t, c(140, 200, 255, a), 14 - CGFloat(i) * 3)
    }
    let pl = NSBezierPath()
    pl.move(to: NSPoint(x: 800, y: 760)); pl.line(to: NSPoint(x: 420, y: 560)); pl.line(to: NSPoint(x: 560, y: 520))
    pl.line(to: NSPoint(x: 600, y: 380)); pl.close()
    NSColor.white.setFill(); pl.fill()
    let fold = NSBezierPath(); fold.move(to: NSPoint(x: 800, y: 760)); fold.line(to: NSPoint(x: 560, y: 520)); fold.line(to: NSPoint(x: 600, y: 380)); fold.close()
    c(190, 215, 255).setFill(); fold.fill()
})

// 3. Lowercase "l" beam: a single tall rounded bar with a glow, minimal wordmark-style.
imgs.append(render("3-beam-l", top: c(28, 28, 32), bottom: c(10, 10, 12)) {
    for (r, a) in [(170.0, 0.10), (110.0, 0.18), (70.0, 0.3)] {
        c(120, 255, 200, a).setFill()
        NSBezierPath(roundedRect: NSRect(x: 512 - r, y: 230 - r/3, width: r * 2, height: 564 + r/1.5), xRadius: r, yRadius: r).fill()
    }
    c(150, 255, 210).setFill()
    NSBezierPath(roundedRect: NSRect(x: 466, y: 230, width: 92, height: 564), xRadius: 46, yRadius: 46).fill()
})

// 4. Feather Envelope: open envelope outline with a soft sunrise inside. "Light" as weight + light.
imgs.append(render("4-sunrise-envelope", top: c(250, 246, 240), bottom: c(232, 224, 212)) {
    let e = NSRect(x: 242, y: 300, width: 540, height: 400)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: e, xRadius: 50, yRadius: 50).addClip()
    NSGradient(starting: c(255, 150, 90), ending: c(255, 205, 120))!.draw(in: NSBezierPath(ovalIn: NSRect(x: 352, y: 180, width: 320, height: 320)), angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    stroke(NSBezierPath(roundedRect: e, xRadius: 50, yRadius: 50), c(40, 40, 50), 30)
    let f = NSBezierPath(); f.move(to: NSPoint(x: e.minX + 30, y: e.maxY - 30)); f.line(to: NSPoint(x: e.midX, y: e.midY + 10)); f.line(to: NSPoint(x: e.maxX - 30, y: e.maxY - 30))
    stroke(f, c(40, 40, 50), 30)
})

// 5. Glass Prism: a translucent glass card refracting a rainbow line. Fits Liquid Glass UI.
imgs.append(render("5-glass-prism", top: c(120, 140, 255), bottom: c(170, 90, 230)) {
    let cols = [c(255, 90, 90), c(255, 180, 60), c(250, 240, 90), c(90, 220, 140), c(80, 170, 255)]
    for (i, col) in cols.enumerated() {
        let p = NSBezierPath(); let y = 470 + CGFloat(i - 2) * 26
        p.move(to: NSPoint(x: 512, y: 512)); p.line(to: NSPoint(x: 940, y: y - 120))
        stroke(p, col.withAlphaComponent(0.9), 20)
    }
    let inb = NSBezierPath(); inb.move(to: NSPoint(x: 80, y: 640)); inb.line(to: NSPoint(x: 512, y: 512)); stroke(inb, .white, 20)
    let card = NSBezierPath(roundedRect: NSRect(x: 322, y: 352, width: 380, height: 300), xRadius: 48, yRadius: 48)
    NSColor.white.withAlphaComponent(0.35).setFill(); card.fill()
    stroke(card, NSColor.white.withAlphaComponent(0.85), 10)
    let f = NSBezierPath(); f.move(to: NSPoint(x: 362, y: 612)); f.line(to: NSPoint(x: 512, y: 500)); f.line(to: NSPoint(x: 662, y: 612))
    stroke(f, .white, 18)
})

// Contact sheet with labels
let W: CGFloat = 5 * 340 + 40, H: CGFloat = 420
let sheet = NSImage(size: NSSize(width: W, height: H)); sheet.lockFocus()
NSColor(white: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
let names = ["1 Bolt Envelope", "2 Light Plane", "3 Beam", "4 Sunrise Envelope", "5 Glass Prism"]
for (i, im) in imgs.enumerated() {
    let x = 20 + CGFloat(i) * 340
    im.draw(in: NSRect(x: x + 10, y: 80, width: 320, height: 320))
    (names[i] as NSString).draw(at: NSPoint(x: x + 30, y: 36), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor(white: 0.15, alpha: 1)])
}
sheet.unlockFocus()
try! NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/all-options.png"))
