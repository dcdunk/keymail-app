// Keymail icon concepts. Run: swift icon/keymail/make_keymail_options.swift icon/keymail
import AppKit

let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a) }
func stroke(_ p: NSBezierPath, _ col: NSColor, _ w: CGFloat) { p.lineWidth = w; p.lineCapStyle = .round; p.lineJoinStyle = .round; col.setStroke(); p.stroke() }
func rr(_ r: NSRect, _ rad: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad) }

func render(_ name: String, top: NSColor, bottom: NSColor, draw: () -> Void) -> NSImage {
    let img = NSImage(size: NSSize(width: S, height: S)); img.lockFocus()
    let sq = rr(body, 185)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.25); sh.shadowBlurRadius = 24; sh.shadowOffset = NSSize(width: 0, height: -10); sh.set()
    bottom.setFill(); sq.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); sq.addClip()
    NSGradient(starting: top, ending: bottom)!.draw(in: sq, angle: -90)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    img.unlockFocus()
    try! NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    return img
}

/// A 3D keyboard key: darker base "skirt", lighter top face. Returns the top face rect.
@discardableResult
func keycap(_ r: NSRect, face: NSColor, side: NSColor, radius: CGFloat = 90, depth: CGFloat = 46) -> NSRect {
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.35); sh.shadowBlurRadius = 40; sh.shadowOffset = NSSize(width: 0, height: -24); sh.set()
    side.setFill(); rr(r, radius).fill()
    NSGraphicsContext.restoreGraphicsState()
    let topR = NSRect(x: r.minX + 34, y: r.minY + depth + 20, width: r.width - 68, height: r.height - depth - 54)
    NSGradient(starting: face, ending: face.blended(withFraction: 0.12, of: .black)!)!.draw(in: rr(topR, radius - 26), angle: -90)
    return topR
}

func envelope(in r: NSRect, fill: NSColor?, line: NSColor, w: CGFloat) {
    let p = rr(r, r.height * 0.14)
    if let fill { fill.setFill(); p.fill() } else { stroke(p, line, w) }
    let f = NSBezierPath()
    f.move(to: NSPoint(x: r.minX + r.width * 0.1, y: r.maxY - r.height * 0.14))
    f.line(to: NSPoint(x: r.midX, y: r.midY - r.height * 0.06))
    f.line(to: NSPoint(x: r.maxX - r.width * 0.1, y: r.maxY - r.height * 0.14))
    stroke(f, line, w)
}

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ col: NSColor, center: NSPoint, design: NSFontDescriptor.SystemDesign = .rounded) {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if let d = font.fontDescriptor.withDesign(design) { font = NSFont(descriptor: d, size: size) ?? font }
    let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: col]
    let sz = (s as NSString).size(withAttributes: a)
    (s as NSString).draw(at: NSPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2), withAttributes: a)
}

var imgs: [NSImage] = []

// 1. Mail Key: a white keycap with an envelope on it, on Keymail blue. Literal and instantly readable.
imgs.append(render("1-mail-key", top: c(88, 112, 245), bottom: c(52, 70, 205)) {
    let face = keycap(NSRect(x: 232, y: 250, width: 560, height: 540), face: c(255, 255, 255), side: c(205, 212, 235))
    envelope(in: face.insetBy(dx: 92, dy: 120), fill: nil, line: c(64, 86, 225), w: 30)
})

// 2. K Key: a dark keycap with a big rounded K. Monogram, reads like a keyboard shortcut.
imgs.append(render("2-k-key", top: c(46, 48, 56), bottom: c(18, 19, 24)) {
    let face = keycap(NSRect(x: 232, y: 250, width: 560, height: 540), face: c(66, 68, 80), side: c(30, 31, 38))
    text("K", 330, .bold, c(244, 245, 250), center: NSPoint(x: face.midX, y: face.midY + 6))
    c(110, 140, 255).setFill(); NSBezierPath(ovalIn: NSRect(x: face.maxX - 92, y: face.maxY - 92, width: 44, height: 44)).fill()
})

// 3. Command Mail: the ⌘ symbol whose loops are drawn inside an envelope. "Mail, by keyboard."
imgs.append(render("3-command-envelope", top: c(255, 255, 255), bottom: c(232, 234, 240)) {
    let r = NSRect(x: 222, y: 300, width: 580, height: 424)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.18); sh.shadowBlurRadius = 30; sh.shadowOffset = NSSize(width: 0, height: -14); sh.set()
    c(64, 86, 225).setFill(); rr(r, 64).fill()
    NSGraphicsContext.restoreGraphicsState()
    text("⌘", 300, .semibold, .white, center: NSPoint(x: r.midX, y: r.midY + 4), design: .default)
})

// 4. Keycap Plane: a keycap whose legend is the paper plane, keeping the current icon's DNA.
imgs.append(render("4-plane-key", top: c(36, 46, 104), bottom: c(14, 18, 46)) {
    let face = keycap(NSRect(x: 232, y: 250, width: 560, height: 540), face: c(250, 251, 255), side: c(182, 192, 226))
    // Bolder plane (about 1.35x), nudged so its visual weight sits in the middle of the key face.
    let cx = face.midX + 6, cy = face.midY + 4, k: CGFloat = 1.35
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: cx + x * k, y: cy + y * k) }
    let pl = NSBezierPath()
    pl.move(to: pt(150, 110)); pl.line(to: pt(-150, -5)); pl.line(to: pt(-20, -30)); pl.line(to: pt(10, -140)); pl.close()
    pl.lineJoinStyle = .round; pl.lineWidth = 10
    c(40, 52, 120).setFill(); c(40, 52, 120).setStroke(); pl.fill(); pl.stroke()
    let fold = NSBezierPath(); fold.move(to: pt(150, 110)); fold.line(to: pt(-20, -30)); fold.line(to: pt(10, -140)); fold.close()
    c(96, 118, 230).setFill(); fold.fill()
})

// 5. Key Row: three small keys spelling the shortcut feel (E · J · K), the middle one lit in blue.
imgs.append(render("5-key-row", top: c(244, 245, 248), bottom: c(222, 225, 232)) {
    let w: CGFloat = 228, gap: CGFloat = 26, x0 = (S - (w * 3 + gap * 2)) / 2
    for (i, l) in ["E", "J", "K"].enumerated() {
        let lit = i == 1
        let face = keycap(NSRect(x: x0 + CGFloat(i) * (w + gap), y: 390, width: w, height: 250),
                          face: lit ? c(92, 116, 248) : .white, side: lit ? c(50, 68, 196) : c(196, 200, 212), radius: 46, depth: 30)
        text(l, 120, .bold, lit ? .white : c(48, 50, 62), center: NSPoint(x: face.midX, y: face.midY + 2))
    }
})

let W: CGFloat = 5 * 340 + 40, H: CGFloat = 420
let sheet = NSImage(size: NSSize(width: W, height: H)); sheet.lockFocus()
NSColor(white: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
for (i, (im, n)) in zip(imgs, ["1 Mail Key", "2 K Key", "3 Command Mail", "4 Plane Key", "5 Key Row"]).enumerated() {
    let x = 20 + CGFloat(i) * 340
    im.draw(in: NSRect(x: x + 10, y: 80, width: 320, height: 320))
    (n as NSString).draw(at: NSPoint(x: x + 30, y: 36), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor(white: 0.15, alpha: 1)])
}
sheet.unlockFocus()
try! NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/all-options.png"))
