// SPDX-License-Identifier: Apache-2.0
// Original vector artwork for My Explorer. Run from the repository root:
// swift scripts/generate-app-icon.swift
// iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns
//
// The symmetric folder, leaned like the My Notepad pad, fills the whole canvas (no transparent frame) and uses
// the My Suite palette: suite blue, cream paper and "My" lettering on the front pocket.
import AppKit
import CoreText

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// Core Graphics shadows ignore the CTM, so they are scaled by hand for each output size.
nonisolated(unsafe) var shadowScale: CGFloat = 1
func shadow(_ context: CGContext, x: CGFloat, y: CGFloat, blur: CGFloat, _ tint: CGColor) {
    context.setShadow(offset: CGSize(width: x * shadowScale, height: y * shadowScale), blur: blur * shadowScale, color: tint)
}

func fill(_ context: CGContext, _ path: CGPath, stops: [(UInt32, CGFloat, CGFloat)],
          from start: CGPoint, to end: CGPoint) {
    context.saveGState()
    context.addPath(path); context.clip()
    let gradient = CGGradient(colorsSpace: sRGB, colors: stops.map { color($0.0, alpha: $0.1) } as CFArray,
                              locations: stops.map { $0.2 })!
    context.drawLinearGradient(gradient, start: start, end: end,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func letteringPath(_ text: String, size: CGFloat, baseline: CGPoint) -> CGPath {
    let font = NSFont.systemFont(ofSize: size, weight: .black)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .kern: -size * 0.02]))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(), &glyphs); CTRunGetPositions(run, CFRange(), &positions)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
        for index in 0..<count {
            // Glyph outlines are y-up; flip them into the y-down face space.
            var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: baseline.x + positions[index].x, ty: baseline.y)
            if let glyph = CTFontCreatePathForGlyph(runFont, glyphs[index], &flip) { path.addPath(glyph) }
        }
    }
    let bounds = path.boundingBoxOfPath
    var center = CGAffineTransform(translationX: baseline.x - bounds.midX, y: 0)
    return path.copy(using: &center) ?? path
}

func drawFace(_ context: CGContext) {
    // Rear shell and the familiar raised folder tab.
    let back = CGMutablePath()
    back.move(to: CGPoint(x: 128, y: 308))
    back.addQuadCurve(to: CGPoint(x: 176, y: 260), control: CGPoint(x: 128, y: 260))
    back.addLine(to: CGPoint(x: 350, y: 260))
    back.addQuadCurve(to: CGPoint(x: 388, y: 276), control: CGPoint(x: 374, y: 260))
    back.addLine(to: CGPoint(x: 438, y: 326))
    back.addLine(to: CGPoint(x: 846, y: 326))
    back.addQuadCurve(to: CGPoint(x: 894, y: 374), control: CGPoint(x: 894, y: 326))
    back.addLine(to: CGPoint(x: 894, y: 750))
    back.addQuadCurve(to: CGPoint(x: 844, y: 800), control: CGPoint(x: 894, y: 800))
    back.addLine(to: CGPoint(x: 180, y: 800))
    back.addQuadCurve(to: CGPoint(x: 128, y: 748), control: CGPoint(x: 128, y: 800))
    back.closeSubpath()
    fill(context, back, stops: [(0x4F8BF5, 1, 0), (0x1243B4, 1, 1)], from: CGPoint(x: 512, y: 260), to: CGPoint(x: 512, y: 800))

    // Cream document peeking out of the open folder.
    let paper = CGPath(roundedRect: CGRect(x: 228, y: 308, width: 596, height: 408), cornerWidth: 24, cornerHeight: 24, transform: nil)
    context.saveGState()
    context.addPath(back); context.clip()
    shadow(context, x: 0, y: -6, blur: 18, color(0x06194D, alpha: 0.35))
    context.addPath(paper); context.setFillColor(color(0xE2D6BC)); context.fillPath()
    context.restoreGState()
    fill(context, paper, stops: [(0xEADFC8, 1, 0), (0xD3C6AA, 1, 1)], from: CGPoint(x: 512, y: 308), to: CGPoint(x: 512, y: 716))
    let sheet = CGPath(roundedRect: CGRect(x: 250, y: 337, width: 552, height: 354), cornerWidth: 14, cornerHeight: 14, transform: nil)
    fill(context, sheet, stops: [(0xFFFAEE, 1, 0), (0xF4EBD6, 1, 1)], from: CGPoint(x: 512, y: 337), to: CGPoint(x: 512, y: 691))

    // Front pocket: broad silhouette stays readable at 16 px and carries the suite lettering.
    let front = CGMutablePath()
    front.move(to: CGPoint(x: 151, y: 350))
    front.addLine(to: CGPoint(x: 873, y: 350))
    front.addQuadCurve(to: CGPoint(x: 915, y: 397), control: CGPoint(x: 921, y: 350))
    front.addLine(to: CGPoint(x: 879, y: 754))
    front.addQuadCurve(to: CGPoint(x: 825, y: 802), control: CGPoint(x: 873, y: 802))
    front.addLine(to: CGPoint(x: 199, y: 802))
    front.addQuadCurve(to: CGPoint(x: 145, y: 754), control: CGPoint(x: 151, y: 802))
    front.addLine(to: CGPoint(x: 109, y: 397))
    front.addQuadCurve(to: CGPoint(x: 151, y: 350), control: CGPoint(x: 103, y: 350))
    front.closeSubpath()
    fill(context, front, stops: [(0x6BA2FF, 1, 0), (0x2E6EEB, 1, 0.5), (0x1650D0, 1, 1)],
         from: CGPoint(x: 512, y: 350), to: CGPoint(x: 512, y: 802))
    context.saveGState()
    context.addPath(front); context.clip()
    context.setStrokeColor(color(0xD6E5FF, alpha: 0.8)); context.setLineWidth(6)
    context.move(to: CGPoint(x: 145, y: 354)); context.addLine(to: CGPoint(x: 878, y: 354)); context.strokePath()
    context.restoreGState()

    context.saveGState()
    shadow(context, x: 0, y: -5, blur: 10, color(0x06194D, alpha: 0.45))
    context.addPath(letteringPath("My", size: 300, baseline: CGPoint(x: 512, y: 682)))
    context.setFillColor(color(0xFFFAEE)); context.fillPath()
    context.restoreGState()
}

// The same lean for the whole folder, like the My Notepad pad, so the shape stays consistent.
let tilt = CGAffineTransform(a: 1, b: 0.10, c: -0.30, d: 1, tx: 0, ty: 0)
let edgeDepth = 16

func drawFolder(_ context: CGContext) {
    // Dark copies stepped along the depth direction fake the extruded edge.
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    for step in stride(from: edgeDepth, through: 1, by: -1) {
        context.saveGState()
        context.translateBy(x: CGFloat(step) * 0.55, y: CGFloat(step))
        context.concatenate(tilt)
        drawFace(context)
        context.restoreGState()
    }
    context.setBlendMode(.sourceAtop)
    context.setFillColor(color(0x0B2F8A))
    context.fill(CGRect(x: -2000, y: -2000, width: 6000, height: 6000))
    context.endTransparencyLayer()

    context.saveGState()
    context.concatenate(tilt)
    drawFace(context)
    context.restoreGState()
}

func bitmap(_ pixels: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

/// Renders the artwork with `fit` mapping face space onto a y-down square of `pixels`.
func render(_ pixels: Int, fit: CGAffineTransform) -> NSBitmapImageRep {
    let image = bitmap(pixels)
    let context = NSGraphicsContext(bitmapImageRep: image)!.cgContext
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: 1, y: -1)
    context.concatenate(fit)
    shadowScale = fit.a
    drawFolder(context)
    return image
}

// Measure the opaque bounds once, then scale the artwork edge to edge.
let probeScale: CGFloat = 0.5, probeOffset: CGFloat = 400
let probe = render(1024, fit: CGAffineTransform(a: probeScale, b: 0, c: 0, d: probeScale, tx: probeOffset * probeScale, ty: probeOffset * probeScale))
var minX = 1024, minY = 1024, maxX = -1, maxY = -1
let data = probe.bitmapData!, rowBytes = probe.bytesPerRow
for y in 0..<1024 {
    for x in 0..<1024 where data[y * rowBytes + x * 4 + 3] > 24 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= 0 else { fatalError("Icon artwork rendered empty") }
let bounds = CGRect(x: CGFloat(minX) / probeScale - probeOffset, y: CGFloat(minY) / probeScale - probeOffset,
                    width: CGFloat(maxX - minX + 1) / probeScale, height: CGFloat(maxY - minY + 1) / probeScale)

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let side = CGFloat(pixels), margin = side * 0.012
        let factor = (side - margin * 2) / max(bounds.width, bounds.height)
        let fit = CGAffineTransform(a: factor, b: 0, c: 0, d: factor,
                                    tx: (side - bounds.width * factor) / 2 - bounds.minX * factor,
                                    ty: (side - bounds.height * factor) / 2 - bounds.minY * factor)
        let png = render(pixels, fit: fit).representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        if pixels == 1024 { try png.write(to: root.appendingPathComponent("Resources/AppIcon.png")) }
    }
}
