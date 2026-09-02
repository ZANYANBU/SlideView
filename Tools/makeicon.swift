import AppKit

// SlideView icon: a squircle holding one slide shown twice over —
// light on the left, smart-inverted on the right.
func draw(_ px: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    let s = px / 1024.0                       // design on a 1024 grid
    c.scaleBy(x: s, y: s)
    c.setAllowsAntialiasing(true)

    // ── squircle plate ──────────────────────────────────────────
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

    c.saveGState()
    c.addPath(squircle); c.clip()
    let sp = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: sp, colors: [
        CGColor(red: 0.267, green: 0.482, blue: 1.0,   alpha: 1),   // #448BFF
        CGColor(red: 0.129, green: 0.271, blue: 0.784, alpha: 1),   // #2145C8
        CGColor(red: 0.075, green: 0.129, blue: 0.400, alpha: 1)    // #132166
    ] as CFArray, locations: [0, 0.55, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: 180, y: 924), end: CGPoint(x: 844, y: 100), options: [])

    // top gloss
    let gloss = CGGradient(colorsSpace: sp, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
    ] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    c.restoreGState()

    // ── the slide card, 16:9 ────────────────────────────────────
    let card = CGRect(x: 212, y: 330, width: 600, height: 338)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 34, cornerHeight: 34, transform: nil)

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 40,
                color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.42))
    c.addPath(cardPath); c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fillPath()
    c.restoreGState()

    // right half inverted
    c.saveGState()
    c.addPath(cardPath); c.clip()
    c.setFillColor(CGColor(red: 0.086, green: 0.086, blue: 0.098, alpha: 1))   // #161619
    c.fill(CGRect(x: card.midX, y: card.minY, width: card.width / 2, height: card.height))

    // text lines: dark on the light half, light on the dark half
    func lines(originX: CGFloat, dark: Bool) {
        let widths: [CGFloat] = [212, 168, 190, 140]
        c.setFillColor(dark ? CGColor(gray: 0.13, alpha: 1) : CGColor(gray: 0.93, alpha: 1))
        // heading
        c.addPath(CGPath(roundedRect: CGRect(x: originX, y: card.maxY - 96, width: 150, height: 26),
                         cornerWidth: 13, cornerHeight: 13, transform: nil))
        c.fillPath()
        c.setFillColor(dark ? CGColor(gray: 0.42, alpha: 1) : CGColor(gray: 0.70, alpha: 1))
        for (i, w) in widths.enumerated() {
            let y = card.maxY - 150 - CGFloat(i) * 42
            c.addPath(CGPath(roundedRect: CGRect(x: originX, y: y, width: w, height: 18),
                             cornerWidth: 9, cornerHeight: 9, transform: nil))
            c.fillPath()
        }
    }
    lines(originX: card.minX + 46, dark: true)
    lines(originX: card.midX + 46, dark: false)

    // seam
    c.setFillColor(CGColor(gray: 0, alpha: 0.16))
    c.fill(CGRect(x: card.midX - 1.5, y: card.minY, width: 3, height: card.height))
    c.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
                   ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let rep = draw(CGFloat(px))
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("iconset written to \(out)")
