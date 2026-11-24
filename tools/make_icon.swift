// Renders the megabass app icon (macOS Big Sur+ grid) and packs Resources/AppIcon.icns.
// Usage: swift tools/make_icon.swift            (from the repo root)
//
// Concept: the squircle is the trackpad (dark glass); on it one glowing bass pulse, the "thump".
// Without Icon Composer (needs Xcode) the glass look is drawn here: squircle body on the 824/1024
// grid, sheen, machined rim, glow. Rules from the app-icon skill: one idea, no SF Symbols, no text, glyph about half
// the canvas, filled shapes, readable at 16 px.
import AppKit

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)       // Apple's macOS icon grid
let radius: CGFloat = 185.4

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    cg.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    cg.interpolationQuality = .high
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func draw(_ cg: CGContext) {
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // Drop shadow under the body (the system grid's shadow).
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.4))
    cg.addPath(squircle); cg.setFillColor(color(0x1A1020)); cg.fillPath()
    cg.restoreGState()

    // The body IS the trackpad: dark glass, a touch of plum.
    cg.saveGState()
    cg.addPath(squircle); cg.clip()
    let ground = CGGradient(colorsSpace: srgb, colors: [color(0x2E2236), color(0x17111C), color(0x0E0A12)] as CFArray, locations: [0, 0.6, 1])!
    cg.drawLinearGradient(ground, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // The felt glow under the pulse.
    let glow = CGGradient(colorsSpace: srgb, colors: [color(0xFF3D7F, 0.55), color(0xFF6A3D, 0.18), color(0xFF6A3D, 0)] as CFArray, locations: [0, 0.45, 1])!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 500), startRadius: 0, endCenter: CGPoint(x: 512, y: 500), endRadius: 400, options: [])

    // One glyph: a single fat bass pulse (one period), about half the canvas wide.
    let pulse = CGMutablePath()
    let x0: CGFloat = 262, x1: CGFloat = 762, mid: CGFloat = 512, amp: CGFloat = 165
    for i in 0...240 {
        let t = CGFloat(i) / 240
        let y = mid + amp * sin(2 * .pi * t)
        let x = x0 + (x1 - x0) * t
        if i == 0 { pulse.move(to: CGPoint(x: x, y: y)) } else { pulse.addLine(to: CGPoint(x: x, y: y)) }
    }
    let band = pulse.copy(strokingWithWidth: 124, lineCap: .round, lineJoin: .round, miterLimit: 10)
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 60, color: color(0xFF3D7F, 0.9))
    cg.addPath(band); cg.setFillColor(color(0xFF4F7A)); cg.fillPath()
    cg.restoreGState()
    // Fill: magenta to orange across the whole glyph (one gradient, no seams), lit from above.
    cg.saveGState()
    cg.addPath(band); cg.clip()
    let fill = CGGradient(colorsSpace: srgb, colors: [color(0xFF2E78), color(0xFF5A55), color(0xFF8A2E)] as CFArray, locations: [0, 0.5, 1])!
    let box = band.boundingBox
    cg.drawLinearGradient(fill, start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.maxX, y: box.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let lit = CGGradient(colorsSpace: srgb, colors: [color(0xFFFFFF, 0.45), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(lit, start: CGPoint(x: 512, y: box.maxY), end: CGPoint(x: 512, y: box.midY), options: [.drawsBeforeStartLocation])
    cg.restoreGState()

    // Glass: a soft sheen over the top of the pad.
    let sheen = CGGradient(colorsSpace: srgb, colors: [color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    cg.restoreGState()

    // Inner edge: the pad's machined rim catching light.
    cg.saveGState()
    cg.addPath(squircle); cg.clip()
    let inset = CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: radius - 3, cornerHeight: radius - 3, transform: nil)
    cg.addPath(inset); cg.setStrokeColor(color(0xFFFFFF, 0.16)); cg.setLineWidth(6); cg.strokePath()
    cg.restoreGState()
}

// Write the iconset and pack it.
let fm = FileManager.default
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for s in scales {
        let name = s == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        let png = render(size: pt * s).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try render(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns and Resources/AppIcon-1024.png" : "iconutil failed")
