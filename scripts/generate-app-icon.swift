// SPDX-License-Identifier: Apache-2.0
// Original vector artwork for My Explorer. Run from the repository root:
// swift scripts/generate-app-icon.swift
// iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func gradient(_ context: CGContext, path: CGPath, top: UInt32, bottom: UInt32, y1: CGFloat, y2: CGFloat) {
    context.saveGState()
    context.addPath(path); context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: y1), end: CGPoint(x: 512, y: y2), options: [])
    context.restoreGState()
}

func drawFolder(_ context: CGContext) {
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
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: color(0x423011, alpha: 0.24))
    context.addPath(back); context.setFillColor(color(0xEBA51A)); context.fillPath()
    context.restoreGState()
    gradient(context, path: back, top: 0xFFD55C, bottom: 0xDC8B0D, y1: 260, y2: 800)

    // Blue document peeking out of the open folder.
    let paper = CGPath(roundedRect: CGRect(x: 228, y: 308, width: 596, height: 408), cornerWidth: 24, cornerHeight: 24, transform: nil)
    gradient(context, path: paper, top: 0x55C5F3, bottom: 0x147AC5, y1: 308, y2: 716)
    let sheet = CGPath(roundedRect: CGRect(x: 250, y: 337, width: 552, height: 354), cornerWidth: 14, cornerHeight: 14, transform: nil)
    gradient(context, path: sheet, top: 0xF2FBFF, bottom: 0xB9E3F7, y1: 337, y2: 691)

    // Front pocket: broad yellow silhouette remains readable at 16 px.
    let front = CGMutablePath()
    front.move(to: CGPoint(x: 151, y: 418))
    front.addLine(to: CGPoint(x: 873, y: 418))
    front.addQuadCurve(to: CGPoint(x: 915, y: 465), control: CGPoint(x: 921, y: 418))
    front.addLine(to: CGPoint(x: 879, y: 754))
    front.addQuadCurve(to: CGPoint(x: 825, y: 802), control: CGPoint(x: 873, y: 802))
    front.addLine(to: CGPoint(x: 199, y: 802))
    front.addQuadCurve(to: CGPoint(x: 145, y: 754), control: CGPoint(x: 151, y: 802))
    front.addLine(to: CGPoint(x: 109, y: 465))
    front.addQuadCurve(to: CGPoint(x: 151, y: 418), control: CGPoint(x: 103, y: 418))
    front.closeSubpath()
    gradient(context, path: front, top: 0xFFE078, bottom: 0xF4B321, y1: 418, y2: 802)
    context.saveGState()
    context.addPath(front); context.clip()
    context.setStrokeColor(color(0xFFF5CF, alpha: 0.75)); context.setLineWidth(6)
    context.move(to: CGPoint(x: 145, y: 422)); context.addLine(to: CGPoint(x: 878, y: 422)); context.strokePath()
    context.restoreGState()

    // Small blue grip echoes the familiar Explorer palette with original geometry.
    let grip = CGPath(roundedRect: CGRect(x: 424, y: 692, width: 176, height: 48), cornerWidth: 15, cornerHeight: 15, transform: nil)
    gradient(context, path: grip, top: 0x279DE2, bottom: 0x126DB8, y1: 692, y2: 740)
    context.setFillColor(color(0x91D9F5))
    context.addPath(CGPath(roundedRect: CGRect(x: 450, y: 700, width: 124, height: 8), cornerWidth: 4, cornerHeight: 4, transform: nil))
    context.fillPath()
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
        drawFolder(context)
        let png = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        if pixels == 1024 { try png.write(to: root.appendingPathComponent("Resources/AppIcon.png")) }
    }
}
