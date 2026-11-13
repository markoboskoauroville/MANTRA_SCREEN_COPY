import AppKit
// six letters over one picture (SCR / COP over a phone), amber "Mac tools" tile. Usage: make_icon <iconset dir>
let dir = CommandLine.arguments[1]
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let tile = NSRect(x: s * 0.0977, y: s * 0.0977, width: s * 0.8047, height: s * 0.8047)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(red: 1.0, green: 0.72, blue: 0.2, alpha: 1), ending: NSColor(red: 0.85, green: 0.45, blue: 0.05, alpha: 1))!.draw(in: path, angle: -90)
    if let img = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.62, weight: .thin)
        let sym = img.withSymbolConfiguration(cfg) ?? img
        let t = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r); NSColor.white.withAlphaComponent(0.46).set(); r.fill(using: .sourceAtop); return true }
        let w = t.size.width, h = t.size.height
        t.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
    }
    let font = NSFont.systemFont(ofSize: s * 0.2, weight: .black)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .kern: s * 0.01]
    for (i, word) in ["SCR", "COP"].enumerated() {
        let a = NSAttributedString(string: word, attributes: attrs)
        let sz = a.size()
        let cy = i == 0 ? s * 0.60 : s * 0.38
        a.draw(at: NSPoint(x: (s - sz.width) / 2, y: cy - sz.height / 2))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16", 16), ("16@2x", 32), ("32", 32), ("32@2x", 64), ("128", 128), ("128@2x", 256), ("256", 256), ("256@2x", 512), ("512", 512), ("512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name == "16" ? "16x16" : name.replacingOccurrences(of: "@2x", with: "") + "x" + name.replacingOccurrences(of: "@2x", with: ""))\(name.contains("@2x") ? "@2x" : "").png"))
}
