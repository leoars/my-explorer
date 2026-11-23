// SPDX-License-Identifier: Apache-2.0
import AppKit
import CoreText

// Original icon artwork for My Explorer, drawn in code: every icon is a small object with volume
// (gradients, a light rim, a soft shadow) and several colours, on a 32-unit grid. Nothing here is
// copied from Windows or macOS artwork.

private func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
private let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// Drawing surface for one icon: a 32-unit grid, y down. `u` is device pixels per unit.
struct IconPen {
    let c: CGContext
    let u: CGFloat

    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: min(r, w / 2), cornerHeight: min(r, h / 2), transform: nil)
    }
    func poly(_ p: [(CGFloat, CGFloat)]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: p[0].0, y: p[0].1))
        for q in p.dropFirst() { path.addLine(to: CGPoint(x: q.0, y: q.1)) }
        path.closeSubpath()
        return path
    }
    func grad(_ path: CGPath, _ colors: [CGColor], _ from: CGPoint, _ to: CGPoint, locations: [CGFloat]? = nil) {
        c.saveGState(); c.addPath(path); c.clip()
        let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
        c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }
    func vgrad(_ path: CGPath, _ top: UInt32, _ bottom: UInt32) {
        let b = path.boundingBoxOfPath
        grad(path, [rgb(top), rgb(bottom)], CGPoint(x: b.midX, y: b.minY), CGPoint(x: b.midX, y: b.maxY))
    }
    func solid(_ path: CGPath, _ color: CGColor) { c.addPath(path); c.setFillColor(color); c.fillPath() }
    func stroke(_ path: CGPath, _ color: CGColor, _ width: CGFloat) {
        c.addPath(path); c.setStrokeColor(color); c.setLineWidth(width); c.setLineJoin(.round); c.setLineCap(.round); c.strokePath()
    }
    /// Soft shadow under a shape: gives every icon the same lift off the surface.
    func lifted(_ path: CGPath, _ fillColor: UInt32, dy: CGFloat = 0.9, blur: CGFloat = 1.6, alpha: CGFloat = 0.32) {
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -dy * u), blur: blur * u, color: rgb(0x0A1433, alpha))
        solid(path, rgb(fillColor))
        c.restoreGState()
    }
    /// Glossy sheen over the upper part of a shape.
    func sheen(_ path: CGPath, _ alpha: CGFloat = 0.28) {
        let b = path.boundingBoxOfPath
        grad(path, [rgb(0xFFFFFF, alpha), rgb(0xFFFFFF, 0)], CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.midX, y: b.midY + b.height * 0.15))
    }
    /// A light line just inside the top edge.
    func rim(_ path: CGPath, _ alpha: CGFloat = 0.55) {
        c.saveGState(); c.addPath(path); c.clip()
        let b = path.boundingBoxOfPath
        c.setStrokeColor(rgb(0xFFFFFF, alpha)); c.setLineWidth(0.9)
        c.addPath(path); c.strokePath()
        c.clip(to: CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height))
        c.restoreGState()
    }
    func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, centre: CGFloat, baseline: CGFloat) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(), &glyphs); CTRunGetPositions(run, CFRange(), &pos)
            let f = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
            for i in 0..<n {
                var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: pos[i].x, ty: baseline)
                if let g = CTFontCreatePathForGlyph(f, glyphs[i], &t) { path.addPath(g) }
            }
        }
        var move = CGAffineTransform(translationX: centre - path.boundingBoxOfPath.midX, y: 0)
        solid(path.copy(using: &move) ?? path, color)
    }

    // MARK: Shared bases

    /// A sheet of paper with a folded corner.
    @discardableResult
    func page(top: UInt32 = 0xFFFFFF, bottom: UInt32 = 0xE6ECF5, fold: UInt32 = 0xC9D3E3) -> CGPath {
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 8.5, y: 3)); body.addLine(to: CGPoint(x: 19.5, y: 3)); body.addLine(to: CGPoint(x: 26, y: 9.5))
        body.addLine(to: CGPoint(x: 26, y: 27)); body.addQuadCurve(to: CGPoint(x: 24, y: 29), control: CGPoint(x: 26, y: 29))
        body.addLine(to: CGPoint(x: 8.5, y: 29)); body.addQuadCurve(to: CGPoint(x: 6.5, y: 27), control: CGPoint(x: 6.5, y: 29))
        body.addLine(to: CGPoint(x: 6.5, y: 5)); body.addQuadCurve(to: CGPoint(x: 8.5, y: 3), control: CGPoint(x: 6.5, y: 3))
        body.closeSubpath()
        lifted(body, bottom)
        vgrad(body, top, bottom)
        stroke(body, rgb(0x8E9BB3, 0.55), 0.5)
        let corner = poly([(19.5, 3), (19.5, 8), (21, 9.5), (26, 9.5)])
        c.saveGState()
        c.setShadow(offset: CGSize(width: -0.4 * u, height: -0.5 * u), blur: 1.0 * u, color: rgb(0x0A1433, 0.25))
        solid(corner, rgb(fold))
        c.restoreGState()
        grad(corner, [rgb(0xF4F7FB), rgb(fold)], CGPoint(x: 19.5, y: 3), CGPoint(x: 25, y: 10))
        return body
    }
    /// A rounded tile, the base of the media icons.
    @discardableResult
    func tile(_ top: UInt32, _ bottom: UInt32, y: CGFloat = 5.5, h: CGFloat = 21) -> CGPath {
        let t = rr(3.5, y, 25, h, 4.2)
        lifted(t, bottom)
        vgrad(t, top, bottom)
        return t
    }
}


enum ExplorerIcon: String, CaseIterable {
    case folder, text, document, pdf, sheet, slides, code, image, video, audio, archive, app, disk, file, back, up, refresh, home, downloads, forward, newTab, desktop, computer, search, iphone, cloud, cloudOrange, cloudBlue, cloudGreen, trash,
         newItem, cut, copy, paste, rename, share, sort, view, previewPane, more, delete
}

@MainActor
enum PremiumIcons {
    private static var cache: [String: NSImage] = [:]

    /// The icon as a resolution-independent image of `side` points.
    static func image(_ icon: ExplorerIcon, side: CGFloat, description: String? = nil) -> NSImage {
        let key = "\(icon.rawValue)-\(side)"
        let image: NSImage
        if let cached = cache[key] { image = cached } else {
            image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
                guard let context = NSGraphicsContext.current?.cgContext, let draw = drawings[icon] else { return false }
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.minY)
                context.scaleBy(x: rect.width / 32, y: rect.height / 32)
                draw(IconPen(c: context, u: rect.width / 32))
                context.restoreGState()
                return true
            }
            cache[key] = image
        }
        guard let description else { return image }
        let labelled = image.copy() as! NSImage
        labelled.accessibilityDescription = description
        return labelled
    }

    private static let drawings: [ExplorerIcon: (IconPen) -> Void] = [
        .folder: { p in
        let back = CGMutablePath()
        back.move(to: CGPoint(x: 3, y: 9)); back.addQuadCurve(to: CGPoint(x: 5, y: 7), control: CGPoint(x: 3, y: 7))
        back.addLine(to: CGPoint(x: 11.5, y: 7)); back.addQuadCurve(to: CGPoint(x: 13.2, y: 7.8), control: CGPoint(x: 12.6, y: 7))
        back.addLine(to: CGPoint(x: 15, y: 9.6)); back.addLine(to: CGPoint(x: 27, y: 9.6))
        back.addQuadCurve(to: CGPoint(x: 29, y: 11.6), control: CGPoint(x: 29, y: 9.6))
        back.addLine(to: CGPoint(x: 29, y: 24)); back.addQuadCurve(to: CGPoint(x: 27, y: 26), control: CGPoint(x: 29, y: 26))
        back.addLine(to: CGPoint(x: 5, y: 26)); back.addQuadCurve(to: CGPoint(x: 3, y: 24), control: CGPoint(x: 3, y: 26))
        back.closeSubpath()
        p.lifted(back, 0xD98A0B)
        p.vgrad(back, 0xF2A91E, 0xD27F06)
        let sheet = p.rr(5.5, 10.6, 21, 9, 1.4)
        p.vgrad(sheet, 0xFFFFFF, 0xE9EEF6)
        let front = CGMutablePath()
        front.move(to: CGPoint(x: 4.2, y: 12.4)); front.addLine(to: CGPoint(x: 27.8, y: 12.4))
        front.addQuadCurve(to: CGPoint(x: 29.6, y: 14.4), control: CGPoint(x: 29.9, y: 12.4))
        front.addLine(to: CGPoint(x: 28.6, y: 24.2)); front.addQuadCurve(to: CGPoint(x: 26.6, y: 26), control: CGPoint(x: 28.4, y: 26))
        front.addLine(to: CGPoint(x: 5.4, y: 26)); front.addQuadCurve(to: CGPoint(x: 3.4, y: 24.2), control: CGPoint(x: 3.6, y: 26))
        front.addLine(to: CGPoint(x: 2.4, y: 14.4)); front.addQuadCurve(to: CGPoint(x: 4.2, y: 12.4), control: CGPoint(x: 2.1, y: 12.4))
        front.closeSubpath()
        p.c.saveGState()
        p.c.setShadow(offset: CGSize(width: 0, height: 0.5 * p.u), blur: 1.2 * p.u, color: rgb(0x6B3F00, 0.35))
        p.solid(front, rgb(0xFFC83D))
        p.c.restoreGState()
        p.grad(front, [rgb(0xFFE38A), rgb(0xFFC83D), rgb(0xF5A617)], CGPoint(x: 16, y: 12.4), CGPoint(x: 16, y: 26), locations: [0, 0.45, 1])
        p.sheen(front, 0.30)
        p.c.saveGState(); p.c.addPath(front); p.c.clip()
        p.stroke(p.poly([(3, 12.9), (29, 12.9)]), rgb(0xFFF6D0, 0.9), 0.7)
        p.c.restoreGState()
        },
        .text: { p in
        p.page()
        for (i, w) in [CGFloat(13), 13, 9, 13, 7].enumerated() {
            p.solid(p.rr(9.5, 13 + CGFloat(i) * 3, w, 1.3, 0.65), rgb(0x7B8AA5))
        }
        },
        .document: { p in
        p.page()
        let band = p.rr(9.5, 12.5, 13, 4.2, 1.1)
        p.vgrad(band, 0x5AA2FF, 0x1A56D6)
        for (i, w) in [CGFloat(13), 13, 8].enumerated() {
            p.solid(p.rr(9.5, 19 + CGFloat(i) * 3, w, 1.3, 0.65), rgb(0x8FA6CC))
        }
        },
        .pdf: { p in
        p.page()
        for (i, w) in [CGFloat(10), 13].enumerated() { p.solid(p.rr(9.5, 12.5 + CGFloat(i) * 3, w, 1.3, 0.65), rgb(0xB9C3D6)) }
        let badge = p.rr(3.5, 18.5, 17.5, 8, 1.8)
        p.lifted(badge, 0xC81E1E, dy: 0.6, blur: 1.2)
        p.vgrad(badge, 0xFF6259, 0xD1201C)
        p.sheen(badge, 0.25)
        p.text("PDF", size: 5.6, weight: .heavy, color: rgb(0xFFFFFF), centre: 12.25, baseline: 24.6)
        },
        .sheet: { p in
        p.page()
        let table = p.rr(9.5, 12.5, 13.5, 13, 1.3)
        p.vgrad(table, 0xFFFFFF, 0xEFF8F1)
        p.stroke(table, rgb(0x1F9D48), 0.7)
        let head = p.rr(9.5, 12.5, 13.5, 3.6, 1.3)
        p.vgrad(head, 0x4CD27A, 0x1F9D48)
        p.c.saveGState(); p.c.addPath(table); p.c.clip()
        for y in [CGFloat(19.3), 22.4] { p.stroke(p.poly([(9.5, y), (23, y)]), rgb(0x1F9D48, 0.75), 0.6) }
        for x in [CGFloat(14), 18.5] { p.stroke(p.poly([(x, 12.5), (x, 25.5)]), rgb(0x1F9D48, 0.75), 0.6) }
        p.c.restoreGState()
        },
        .slides: { p in
        p.page()
        let pie = CGMutablePath()
        pie.addArc(center: CGPoint(x: 13.5, y: 19), radius: 4.6, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        p.vgrad(pie, 0xFFB14A, 0xF06A12)
        let slice = CGMutablePath()
        slice.move(to: CGPoint(x: 13.5, y: 19)); slice.addArc(center: CGPoint(x: 13.5, y: 19), radius: 4.6, startAngle: -.pi / 2, endAngle: 0.35, clockwise: false)
        slice.closeSubpath()
        p.vgrad(slice, 0xFFE08A, 0xFFC02E)
        for (i, h) in [CGFloat(3), 5.5, 8].enumerated() {
            p.vgrad(p.rr(19.2 + CGFloat(i) * 2.1, 24.4 - h, 1.5, h, 0.5), 0xFF8A5C, 0xD9480F)
        }
        },
        .code: { p in
        p.page(top: 0x2B3550, bottom: 0x161C2E, fold: 0x4A5878)
        let rows: [(CGFloat, [(CGFloat, UInt32)])] = [
            (13, [(4, 0xFF7EB3), (6, 0x7FD6FF)]), (16, [(2, 0xFFD166), (7, 0xE6ECF5)]),
            (19, [(5, 0x7FE3A8), (3, 0xFF7EB3)]), (22, [(3, 0x7FD6FF), (6, 0xFFD166)]), (25, [(6, 0xE6ECF5)]),
        ]
        for (y, parts) in rows {
            var x: CGFloat = y == 16 || y == 19 ? 11.5 : 9.5
            for (w, color) in parts { p.solid(p.rr(x, y, w, 1.3, 0.65), rgb(color)); x += w + 1.2 }
        }
        },
        .image: { p in
        let frame = p.rr(3.5, 5.5, 25, 21, 3.4)
        p.lifted(frame, 0xE6ECF5)
        p.vgrad(frame, 0xFFFFFF, 0xE3E9F2)
        let sky = p.rr(5.4, 7.4, 21.2, 17.2, 1.9)
        p.vgrad(sky, 0x8AD4FF, 0x2F7FEA)
        p.c.saveGState(); p.c.addPath(sky); p.c.clip()
        let glow = CGPath(ellipseIn: CGRect(x: 17.6, y: 8.6, width: 7.4, height: 7.4), transform: nil)
        p.solid(glow, rgb(0xFFF3B0, 0.45))
        p.vgrad(CGPath(ellipseIn: CGRect(x: 19.2, y: 10.2, width: 4.2, height: 4.2), transform: nil), 0xFFF2A0, 0xFFC02E)
        p.vgrad(p.poly([(4, 25.5), (12.2, 14.6), (19.5, 25.5)]), 0x55D08A, 0x148A4A)
        p.vgrad(p.poly([(12.5, 25.5), (19.6, 17.4), (28, 25.5)]), 0x2FB86A, 0x0E6E3A)
        p.c.restoreGState()
        p.sheen(frame, 0.18)
        },
        .video: { p in
        let t = p.tile(0xB07BFF, 0x5B21C8)
        p.c.saveGState(); p.c.addPath(t); p.c.clip()
        p.solid(CGPath(rect: CGRect(x: 3.5, y: 5.5, width: 25, height: 3.6), transform: nil), rgb(0x2A0F66, 0.55))
        p.solid(CGPath(rect: CGRect(x: 3.5, y: 22.9, width: 25, height: 3.6), transform: nil), rgb(0x2A0F66, 0.55))
        for i in 0..<6 {
            let x = 5.2 + CGFloat(i) * 4
            p.solid(p.rr(x, 6.5, 2.2, 1.6, 0.5), rgb(0xFFFFFF, 0.8))
            p.solid(p.rr(x, 23.9, 2.2, 1.6, 0.5), rgb(0xFFFFFF, 0.8))
        }
        p.c.restoreGState()
        let play = CGMutablePath()
        play.move(to: CGPoint(x: 13.4, y: 11.9)); play.addLine(to: CGPoint(x: 20.6, y: 16)); play.addLine(to: CGPoint(x: 13.4, y: 20.1))
        play.closeSubpath()
        p.c.saveGState()
        p.c.setShadow(offset: CGSize(width: 0, height: -0.5 * p.u), blur: 1.0 * p.u, color: rgb(0x1A0744, 0.5))
        p.c.addPath(play); p.c.setFillColor(rgb(0xFFFFFF)); p.c.setLineJoin(.round); p.c.fillPath()
        p.stroke(play, rgb(0xFFFFFF), 1.2)
        p.c.restoreGState()
        p.sheen(t, 0.22)
        },
        .audio: { p in
        let t = p.tile(0xFF8FB8, 0xF0472F)
        p.grad(t, [rgb(0xFF7EB3), rgb(0xFF5C5C), rgb(0xFF9A3D)], CGPoint(x: 4, y: 6), CGPoint(x: 28, y: 26))
        p.c.saveGState()
        p.c.setShadow(offset: CGSize(width: 0, height: -0.5 * p.u), blur: 1.0 * p.u, color: rgb(0x7A1020, 0.45))
        let note = CGMutablePath()
        note.addEllipse(in: CGRect(x: 10.2, y: 18.6, width: 5, height: 3.8))
        note.addEllipse(in: CGRect(x: 18.4, y: 16.8, width: 5, height: 3.8))
        note.addRect(CGRect(x: 13.9, y: 11.2, width: 1.3, height: 9.4))
        note.addRect(CGRect(x: 22.1, y: 9.4, width: 1.3, height: 9.4))
        note.addPath(p.poly([(13.9, 11.2), (23.4, 9.2), (23.4, 12), (13.9, 14)]))
        p.solid(note, rgb(0xFFFFFF))
        p.c.restoreGState()
        p.sheen(t, 0.22)
        },
        .archive: { p in
        let box = p.rr(5, 4.5, 22, 23.5, 3)
        p.lifted(box, 0xC98A1E)
        p.vgrad(box, 0xFFD777, 0xE9A01F)
        p.sheen(box, 0.25)
        for i in 0..<7 {
            let y = 5.6 + CGFloat(i) * 2.2
            p.solid(p.rr(i % 2 == 0 ? 14.4 : 16, y, 1.6, 1.5, 0.4), rgb(0x5C4A2E, 0.85))
        }
        let pull = p.rr(13.2, 20.4, 5.6, 5.4, 1.5)
        p.lifted(pull, 0x8E99A8, dy: 0.5, blur: 0.9)
        p.vgrad(pull, 0xF5F7FA, 0xA9B3C2)
        p.solid(p.rr(14.9, 22.2, 2.2, 1.9, 0.6), rgb(0x5C4A2E, 0.8))
        },
        .app: { p in
        let s = p.rr(4.5, 4.5, 23, 23, 6)
        p.lifted(s, 0x1243B4)
        p.grad(s, [rgb(0x6DB1FF), rgb(0x2468EC), rgb(0x1243B4)], CGPoint(x: 6, y: 4.5), CGPoint(x: 26, y: 27.5))
        p.sheen(s, 0.3)
        for (x, y) in [(CGFloat(9.6), CGFloat(9.6)), (17, 9.6), (9.6, 17), (17, 17)] {
            let d = p.rr(x, y, 5.4, 5.4, 1.5)
            p.c.saveGState()
            p.c.setShadow(offset: CGSize(width: 0, height: -0.4 * p.u), blur: 0.8 * p.u, color: rgb(0x061340, 0.4))
            p.solid(d, rgb(0xFFFFFF, x == 17 && y == 17 ? 0.55 : 0.96))
            p.c.restoreGState()
        }
        },
        .disk: { p in
        let d = p.rr(3.5, 9.5, 25, 14, 3.2)
        p.lifted(d, 0x8B96A8)
        p.vgrad(d, 0xF7F9FC, 0xB4BECD)
        p.sheen(d, 0.35)
        p.solid(p.rr(3.5, 18.2, 25, 0.6, 0), rgb(0x6F7B8F, 0.45))
        p.vgrad(CGPath(ellipseIn: CGRect(x: 22.6, y: 19.9, width: 2.4, height: 2.4), transform: nil), 0x7FE3FF, 0x1A7BEA)
        for i in 0..<4 { p.solid(p.rr(6.4 + CGFloat(i) * 2.2, 20.5, 1.2, 1.2, 0.4), rgb(0x6F7B8F, 0.7)) }
        },
        .file: { p in
        p.page()
        },
        .back: { p in
        let disc = CGPath(ellipseIn: CGRect(x: 4, y: 4, width: 24, height: 24), transform: nil)
        p.lifted(disc, 0x1243B4)
        p.grad(disc, [rgb(0x6DB1FF), rgb(0x1A56D6)], CGPoint(x: 8, y: 4), CGPoint(x: 24, y: 28))
        p.sheen(disc, 0.3)
        let a = CGMutablePath()
        a.move(to: CGPoint(x: 21.5, y: 16)); a.addLine(to: CGPoint(x: 11, y: 16))
        a.move(to: CGPoint(x: 15.4, y: 11.2)); a.addLine(to: CGPoint(x: 10.6, y: 16)); a.addLine(to: CGPoint(x: 15.4, y: 20.8))
        p.stroke(a, rgb(0xFFFFFF), 2.3)
        },
        .up: { p in
        let disc = CGPath(ellipseIn: CGRect(x: 4, y: 4, width: 24, height: 24), transform: nil)
        p.lifted(disc, 0x1243B4)
        p.grad(disc, [rgb(0x6DB1FF), rgb(0x1A56D6)], CGPoint(x: 8, y: 4), CGPoint(x: 24, y: 28))
        p.sheen(disc, 0.3)
        let a = CGMutablePath()
        a.move(to: CGPoint(x: 16, y: 21.5)); a.addLine(to: CGPoint(x: 16, y: 11))
        a.move(to: CGPoint(x: 11.2, y: 15.4)); a.addLine(to: CGPoint(x: 16, y: 10.6)); a.addLine(to: CGPoint(x: 20.8, y: 15.4))
        p.stroke(a, rgb(0xFFFFFF), 2.3)
        },
        .refresh: { p in
        let disc = CGPath(ellipseIn: CGRect(x: 4, y: 4, width: 24, height: 24), transform: nil)
        p.lifted(disc, 0x0E7A3C)
        p.grad(disc, [rgb(0x6BE39A), rgb(0x12964A)], CGPoint(x: 8, y: 4), CGPoint(x: 24, y: 28))
        p.sheen(disc, 0.3)
        let a = CGMutablePath()
        a.addArc(center: CGPoint(x: 16, y: 16), radius: 6, startAngle: -.pi * 0.25, endAngle: .pi * 1.35, clockwise: false)
        p.stroke(a, rgb(0xFFFFFF), 2.2)
        p.solid(p.poly([(18.3, 8.2), (23.2, 9.4), (19.6, 13.2)]), rgb(0xFFFFFF))
        },
        .home: { p in
        let roof = p.poly([(16, 4.2), (29, 15.4), (26.4, 15.4), (26.4, 17), (5.6, 17), (5.6, 15.4), (3, 15.4)])
        let body = p.rr(6.6, 14, 18.8, 13.5, 1.8)
        p.lifted(body, 0xD8DEE9)
        p.vgrad(body, 0xFFFFFF, 0xDDE4EF)
        p.c.saveGState()
        p.c.setShadow(offset: CGSize(width: 0, height: -0.7 * p.u), blur: 1.2 * p.u, color: rgb(0x5A1E00, 0.4))
        p.solid(roof, rgb(0xF0712A))
        p.c.restoreGState()
        p.vgrad(roof, 0xFFA45C, 0xE4571A)
        p.sheen(roof, 0.25)
        p.vgrad(p.rr(13.6, 19.4, 4.8, 8.1, 1), 0x5AA2FF, 0x1A56D6)
        },
        .downloads: { p in
        let disc = CGPath(ellipseIn: CGRect(x: 4, y: 4, width: 24, height: 24), transform: nil)
        p.lifted(disc, 0x0A6FA8)
        p.grad(disc, [rgb(0x7FE0FF), rgb(0x1489D8)], CGPoint(x: 8, y: 4), CGPoint(x: 24, y: 28))
        p.sheen(disc, 0.3)
        let a = CGMutablePath()
        a.move(to: CGPoint(x: 16, y: 9.6)); a.addLine(to: CGPoint(x: 16, y: 19.4))
        a.move(to: CGPoint(x: 11.4, y: 15.4)); a.addLine(to: CGPoint(x: 16, y: 20)); a.addLine(to: CGPoint(x: 20.6, y: 15.4))
        a.move(to: CGPoint(x: 10.8, y: 23.2)); a.addLine(to: CGPoint(x: 21.2, y: 23.2))
        p.stroke(a, rgb(0xFFFFFF), 2.2)
        },
        .forward: { p in
        let disc = CGPath(ellipseIn: CGRect(x: 4, y: 4, width: 24, height: 24), transform: nil)
        p.lifted(disc, 0x1243B4)
        p.grad(disc, [rgb(0x6DB1FF), rgb(0x1A56D6)], CGPoint(x: 8, y: 4), CGPoint(x: 24, y: 28))
        p.sheen(disc, 0.3)
        let a = CGMutablePath()
        a.move(to: CGPoint(x: 10.5, y: 16)); a.addLine(to: CGPoint(x: 21, y: 16))
        a.move(to: CGPoint(x: 16.6, y: 11.2)); a.addLine(to: CGPoint(x: 21.4, y: 16)); a.addLine(to: CGPoint(x: 16.6, y: 20.8))
        p.stroke(a, rgb(0xFFFFFF), 2.3)
        },
        .newTab: { p in
        let disc = CGPath(ellipseIn: CGRect(x: 4, y: 4, width: 24, height: 24), transform: nil)
        p.lifted(disc, 0x1243B4)
        p.grad(disc, [rgb(0x6DB1FF), rgb(0x1A56D6)], CGPoint(x: 8, y: 4), CGPoint(x: 24, y: 28))
        p.sheen(disc, 0.3)
        let a = CGMutablePath()
        a.move(to: CGPoint(x: 16, y: 10.4)); a.addLine(to: CGPoint(x: 16, y: 21.6))
        a.move(to: CGPoint(x: 10.4, y: 16)); a.addLine(to: CGPoint(x: 21.6, y: 16))
        p.stroke(a, rgb(0xFFFFFF), 2.3)
        },
        .desktop: { p in
        // A display showing a wallpaper, on a metal stand.
        p.vgrad(p.poly([(13.4, 22), (18.6, 22), (19.8, 26.4), (12.2, 26.4)]), 0xDDE3EC, 0x9AA6B8)
        let base = p.rr(10, 26, 12, 2, 1)
        p.lifted(base, 0x8B96A8, dy: 0.5, blur: 0.9)
        p.vgrad(base, 0xF4F7FB, 0xA9B4C5)
        let frame = p.rr(3, 5, 26, 18, 2.6)
        p.lifted(frame, 0x2A3348)
        p.vgrad(frame, 0x4A566F, 0x1E2536)
        let screen = p.rr(4.6, 6.6, 22.8, 14.8, 1.4)
        p.grad(screen, [rgb(0x7FD6FF), rgb(0x2F7FEA), rgb(0x6B3FD6)], CGPoint(x: 5, y: 7), CGPoint(x: 27, y: 21))
        p.c.saveGState(); p.c.addPath(screen); p.c.clip()
        p.solid(CGPath(ellipseIn: CGRect(x: 0, y: 15, width: 22, height: 14), transform: nil), rgb(0xFFFFFF, 0.22))
        p.c.restoreGState()
        p.sheen(screen, 0.22)
        },
        .computer: { p in
        // A laptop, open.
        let lid = p.rr(5.5, 6, 21, 15, 2.2)
        p.lifted(lid, 0x2A3348)
        p.vgrad(lid, 0x4A566F, 0x1E2536)
        let screen = p.rr(7, 7.5, 18, 12, 1.2)
        p.grad(screen, [rgb(0x8AD4FF), rgb(0x2468EC)], CGPoint(x: 7, y: 7.5), CGPoint(x: 25, y: 19.5))
        p.sheen(screen, 0.25)
        let deck = CGMutablePath()
        deck.move(to: CGPoint(x: 5, y: 21)); deck.addLine(to: CGPoint(x: 27, y: 21)); deck.addLine(to: CGPoint(x: 30, y: 25))
        deck.addQuadCurve(to: CGPoint(x: 28.6, y: 26.8), control: CGPoint(x: 30.4, y: 26.8))
        deck.addLine(to: CGPoint(x: 3.4, y: 26.8)); deck.addQuadCurve(to: CGPoint(x: 2, y: 25), control: CGPoint(x: 1.6, y: 26.8))
        deck.closeSubpath()
        p.lifted(deck, 0x8B96A8, dy: 0.6, blur: 1.1)
        p.vgrad(deck, 0xF7F9FC, 0xAEB9C9)
        p.solid(p.rr(13, 24.6, 6, 1.1, 0.55), rgb(0x6F7B8F, 0.55))
        },
        .search: { p in
        let ring = CGMutablePath()
        ring.addEllipse(in: CGRect(x: 4.5, y: 4.5, width: 17, height: 17))
        let handle = CGMutablePath()
        handle.move(to: CGPoint(x: 19.4, y: 19.4)); handle.addLine(to: CGPoint(x: 26.6, y: 26.6))
        p.c.saveGState()
        p.c.setShadow(offset: CGSize(width: 0, height: -0.8 * p.u), blur: 1.4 * p.u, color: rgb(0x0A1433, 0.32))
        p.stroke(handle, rgb(0x1243B4), 4.2)
        p.c.restoreGState()
        p.stroke(handle, rgb(0x2F7FEA), 2.6)
        let glass = CGPath(ellipseIn: CGRect(x: 6.2, y: 6.2, width: 13.6, height: 13.6), transform: nil)
        p.grad(glass, [rgb(0xDFF1FF), rgb(0x9CCBFF)], CGPoint(x: 8, y: 6), CGPoint(x: 18, y: 20))
        p.c.saveGState()
        p.c.setShadow(offset: CGSize(width: 0, height: -0.6 * p.u), blur: 1.2 * p.u, color: rgb(0x0A1433, 0.3))
        p.stroke(ring, rgb(0x1A56D6), 3)
        p.c.restoreGState()
        p.stroke(CGPath(ellipseIn: CGRect(x: 5.4, y: 5.4, width: 15.2, height: 15.2), transform: nil), rgb(0x6DB1FF), 1)
        let glint = CGMutablePath()
        glint.addArc(center: CGPoint(x: 13, y: 13), radius: 4.4, startAngle: .pi * 1.05, endAngle: .pi * 1.45, clockwise: false)
        p.stroke(glint, rgb(0xFFFFFF, 0.9), 1.3)
        },
        .iphone: { p in
        let body = p.rr(9.5, 3, 13, 26, 3.2)
        p.lifted(body, 0x1E2536)
        p.vgrad(body, 0x4A566F, 0x161C2E)
        let screen = p.rr(10.8, 4.4, 10.4, 23.2, 2.2)
        p.grad(screen, [rgb(0x7FD6FF), rgb(0x2468EC), rgb(0x6B3FD6)], CGPoint(x: 11, y: 4.4), CGPoint(x: 21, y: 27.6))
        p.sheen(screen, 0.3)
        p.solid(p.rr(13.6, 5.3, 4.8, 1.5, 0.75), rgb(0x0A0F1E, 0.9))
        p.solid(p.rr(13.4, 25.6, 5.2, 0.9, 0.45), rgb(0xFFFFFF, 0.75))
        },
        .cloud: { p in
        let cloud = CGMutablePath()
        cloud.addEllipse(in: CGRect(x: 3.5, y: 14.5, width: 11.5, height: 11.5))
        cloud.addEllipse(in: CGRect(x: 9, y: 7.5, width: 13.5, height: 13.5))
        cloud.addEllipse(in: CGRect(x: 17.5, y: 12.5, width: 11, height: 11))
        cloud.addPath(p.rr(8.5, 17.5, 16, 8.5, 4.2))
        p.lifted(cloud, 0x1A6FE0)
        p.grad(cloud, [rgb(0xB9E4FF), rgb(0x4DA3FF), rgb(0x1A6FE0)], CGPoint(x: 10, y: 7.5), CGPoint(x: 22, y: 26), locations: [0, 0.5, 1])
        p.grad(cloud, [rgb(0xFFFFFF, 0.45), rgb(0xFFFFFF, 0)], CGPoint(x: 8, y: 8), CGPoint(x: 16, y: 20))
        },
        .cloudOrange: { p in
        let cloud = CGMutablePath()
        cloud.addEllipse(in: CGRect(x: 3.5, y: 14.5, width: 11.5, height: 11.5))
        cloud.addEllipse(in: CGRect(x: 9, y: 7.5, width: 13.5, height: 13.5))
        cloud.addEllipse(in: CGRect(x: 17.5, y: 12.5, width: 11, height: 11))
        cloud.addPath(p.rr(8.5, 17.5, 16, 8.5, 4.2))
        p.lifted(cloud, 0xE06A0C)
        p.grad(cloud, [rgb(0xFFD9A0), rgb(0xFF9F38), rgb(0xE06A0C)], CGPoint(x: 10, y: 7.5), CGPoint(x: 22, y: 26), locations: [0, 0.5, 1])
        p.grad(cloud, [rgb(0xFFFFFF, 0.45), rgb(0xFFFFFF, 0)], CGPoint(x: 8, y: 8), CGPoint(x: 16, y: 20))
        },
        .cloudBlue: { p in
        let cloud = CGMutablePath()
        cloud.addEllipse(in: CGRect(x: 3.5, y: 14.5, width: 11.5, height: 11.5))
        cloud.addEllipse(in: CGRect(x: 9, y: 7.5, width: 13.5, height: 13.5))
        cloud.addEllipse(in: CGRect(x: 17.5, y: 12.5, width: 11, height: 11))
        cloud.addPath(p.rr(8.5, 17.5, 16, 8.5, 4.2))
        p.lifted(cloud, 0x1250C0)
        p.grad(cloud, [rgb(0xA9D4FF), rgb(0x2F86F2), rgb(0x1250C0)], CGPoint(x: 10, y: 7.5), CGPoint(x: 22, y: 26), locations: [0, 0.5, 1])
        p.grad(cloud, [rgb(0xFFFFFF, 0.45), rgb(0xFFFFFF, 0)], CGPoint(x: 8, y: 8), CGPoint(x: 16, y: 20))
        },
        .cloudGreen: { p in
        let cloud = CGMutablePath()
        cloud.addEllipse(in: CGRect(x: 3.5, y: 14.5, width: 11.5, height: 11.5))
        cloud.addEllipse(in: CGRect(x: 9, y: 7.5, width: 13.5, height: 13.5))
        cloud.addEllipse(in: CGRect(x: 17.5, y: 12.5, width: 11, height: 11))
        cloud.addPath(p.rr(8.5, 17.5, 16, 8.5, 4.2))
        p.lifted(cloud, 0x128A42)
        p.grad(cloud, [rgb(0xB6F0C8), rgb(0x3CC46E), rgb(0x128A42)], CGPoint(x: 10, y: 7.5), CGPoint(x: 22, y: 26), locations: [0, 0.5, 1])
        p.grad(cloud, [rgb(0xFFFFFF, 0.45), rgb(0xFFFFFF, 0)], CGPoint(x: 8, y: 8), CGPoint(x: 16, y: 20))
        },
        .trash: { p in
        // A silver wire basket, crossed lines over a soft metal body.
        let bin = CGMutablePath()
        bin.move(to: CGPoint(x: 6, y: 8.6)); bin.addLine(to: CGPoint(x: 26, y: 8.6))
        bin.addLine(to: CGPoint(x: 23.4, y: 26.4)); bin.addQuadCurve(to: CGPoint(x: 21.4, y: 28.2), control: CGPoint(x: 23.2, y: 28.2))
        bin.addLine(to: CGPoint(x: 10.6, y: 28.2)); bin.addQuadCurve(to: CGPoint(x: 8.6, y: 26.4), control: CGPoint(x: 8.8, y: 28.2))
        bin.closeSubpath()
        p.lifted(bin, 0x8B96A8)
        p.grad(bin, [rgb(0x9AA6B8), rgb(0xF4F7FB), rgb(0xA9B4C5)], CGPoint(x: 6, y: 16), CGPoint(x: 26, y: 16), locations: [0, 0.45, 1])
        p.c.saveGState(); p.c.addPath(bin); p.c.clip()
        p.c.setStrokeColor(rgb(0x55617A, 0.55)); p.c.setLineWidth(0.55)
        for i in -8...14 {
            let x = CGFloat(i) * 2.6
            p.c.move(to: CGPoint(x: x, y: 8.6)); p.c.addLine(to: CGPoint(x: x + 20, y: 28.6))
            p.c.move(to: CGPoint(x: x + 20, y: 8.6)); p.c.addLine(to: CGPoint(x: x, y: 28.6))
        }
        p.c.strokePath()
        p.c.restoreGState()
        let rim = p.rr(4.6, 6.4, 22.8, 3.2, 1.6)
        p.lifted(rim, 0x8B96A8, dy: 0.5, blur: 1.0)
        p.vgrad(rim, 0xFFFFFF, 0xB4BECD)
        let foot = p.rr(9.6, 27, 12.8, 1.8, 0.9)
        p.vgrad(foot, 0xC9D2DF, 0x8B96A8)
        },
        .newItem: { p in
        p.page()
        for (i, w) in [CGFloat(9), 6].enumerated() { p.solid(p.rr(9.5, 13 + CGFloat(i) * 3, w, 1.3, 0.65), rgb(0xB9C3D6)) }
        let disc = CGPath(ellipseIn: CGRect(x: 15, y: 15.5, width: 14, height: 14), transform: nil)
        p.lifted(disc, 0x0E7A3C, dy: 0.6, blur: 1.3)
        p.grad(disc, [rgb(0x6BE39A), rgb(0x12964A)], CGPoint(x: 17, y: 15.5), CGPoint(x: 27, y: 29.5))
        p.sheen(disc, 0.3)
        let plus = CGMutablePath()
        plus.move(to: CGPoint(x: 22, y: 18.9)); plus.addLine(to: CGPoint(x: 22, y: 26.1))
        plus.move(to: CGPoint(x: 18.4, y: 22.5)); plus.addLine(to: CGPoint(x: 25.6, y: 22.5))
        p.stroke(plus, rgb(0xFFFFFF), 2.1)
        },
        .cut: { p in
        // Steel blades crossing over two red handles.
        p.c.saveGState()
        p.c.setShadow(offset: CGSize(width: 0, height: -0.8 * p.u), blur: 1.4 * p.u, color: rgb(0x0A1433, 0.3))
        let left = p.poly([(8.2, 3.6), (10.6, 3.2), (19.6, 19.4), (16.6, 20.6)])
        let right = p.poly([(23.8, 3.6), (21.4, 3.2), (12.4, 19.4), (15.4, 20.6)])
        p.solid(left, rgb(0xC5CEDB)); p.solid(right, rgb(0xDCE3EC))
        p.c.restoreGState()
        p.grad(left, [rgb(0xF4F7FB), rgb(0x9AA6B8)], CGPoint(x: 8, y: 4), CGPoint(x: 19, y: 20))
        p.grad(right, [rgb(0xFFFFFF), rgb(0xA9B4C5)], CGPoint(x: 24, y: 4), CGPoint(x: 13, y: 20))
        for x in [CGFloat(10.2), 21.8] {
            let ring = CGPath(ellipseIn: CGRect(x: x - 4.1, y: 19.6, width: 8.2, height: 8.2), transform: nil)
            p.c.saveGState()
            p.c.setShadow(offset: CGSize(width: 0, height: -0.7 * p.u), blur: 1.2 * p.u, color: rgb(0x0A1433, 0.3))
            p.stroke(ring, rgb(0xD1201C), 2.5)
            p.c.restoreGState()
            p.stroke(CGPath(ellipseIn: CGRect(x: x - 4.1, y: 19.2, width: 8.2, height: 8.2), transform: nil), rgb(0xFF7A70, 0.9), 0.9)
        }
        p.vgrad(CGPath(ellipseIn: CGRect(x: 14.7, y: 14.4, width: 2.6, height: 2.6), transform: nil), 0x55617A, 0x2B3550)
        },
        .copy: { p in
        let back = p.rr(11, 3.5, 15.5, 19.5, 2.4)
        p.lifted(back, 0x1A56D6)
        p.vgrad(back, 0x8FC4FF, 0x2F7FEA)
        p.sheen(back, 0.3)
        let front = p.rr(5.5, 9, 15.5, 19.5, 2.4)
        p.lifted(front, 0xE6ECF5, dy: 0.8, blur: 1.8, alpha: 0.4)
        p.vgrad(front, 0xFFFFFF, 0xE3E9F2)
        p.stroke(front, rgb(0x8E9BB3, 0.55), 0.5)
        for (i, w) in [CGFloat(9.5), 9.5, 6].enumerated() { p.solid(p.rr(8.5, 13.5 + CGFloat(i) * 3.4, w, 1.4, 0.7), rgb(0x7B8AA5)) }
        },
        .paste: { p in
        let board = p.rr(5.5, 5.5, 21, 23.5, 3)
        p.lifted(board, 0xA9690A)
        p.vgrad(board, 0xF7C36A, 0xC98212)
        p.sheen(board, 0.25)
        let paper = p.rr(8.4, 10, 15.2, 16.4, 1.3)
        p.vgrad(paper, 0xFFFFFF, 0xE6ECF5)
        for (i, w) in [CGFloat(9.5), 9.5, 6.5].enumerated() { p.solid(p.rr(11.2, 15 + CGFloat(i) * 3.3, w, 1.3, 0.65), rgb(0x8FA0BC)) }
        let clip = p.rr(11, 3, 10, 6, 2)
        p.lifted(clip, 0x8B96A8, dy: 0.5, blur: 1.0)
        p.vgrad(clip, 0xFFFFFF, 0xA9B4C5)
        p.solid(CGPath(ellipseIn: CGRect(x: 14.9, y: 4.5, width: 2.2, height: 2.2), transform: nil), rgb(0x55617A))
        },
        .rename: { p in
        // A text field with its caret, and a pencil writing in it.
        let field = p.rr(3, 17.5, 20.5, 9.5, 2.3)
        p.lifted(field, 0xE6ECF5)
        p.vgrad(field, 0xFFFFFF, 0xE9EEF6)
        p.stroke(field, rgb(0x2F7FEA), 1.1)
        p.solid(p.rr(6, 21.4, 7, 1.5, 0.75), rgb(0x7B8AA5))
        p.solid(p.rr(14.4, 19.8, 1.2, 4.9, 0.6), rgb(0x1A56D6))
        p.c.saveGState()
        p.c.translateBy(x: 20.6, y: 12.2); p.c.rotate(by: .pi / 4)
        let body = p.rr(-2.7, -10.5, 5.4, 15, 0.6)
        p.c.setShadow(offset: CGSize(width: 0, height: -0.8 * p.u), blur: 1.4 * p.u, color: rgb(0x0A1433, 0.32))
        p.solid(body, rgb(0xF5A617))
        p.c.setShadow(offset: .zero, blur: 0, color: nil)
        p.grad(body, [rgb(0xFFE38A), rgb(0xFFC02E), rgb(0xE08E0B)], CGPoint(x: -2.7, y: 0), CGPoint(x: 2.7, y: 0), locations: [0, 0.5, 1])
        p.vgrad(p.rr(-2.7, -13.6, 5.4, 3.6, 1.3), 0xFF9DB6, 0xE8527A)
        p.grad(p.rr(-2.7, -10.6, 5.4, 1.7, 0), [rgb(0xF4F7FB), rgb(0x9AA6B8)], CGPoint(x: -2.7, y: 0), CGPoint(x: 2.7, y: 0))
        p.solid(p.poly([(-2.7, 4.5), (2.7, 4.5), (0, 10)]), rgb(0xF3D3A4))
        p.solid(p.poly([(-1.0, 8), (1.0, 8), (0, 10)]), rgb(0x2B3550))
        p.c.restoreGState()
        },
        .share: { p in
        let t = p.tile(0x6DB1FF, 0x1A56D6, y: 4.5, h: 23)
        p.sheen(t, 0.3)
        let a = CGMutablePath()
        a.move(to: CGPoint(x: 16, y: 18.4)); a.addLine(to: CGPoint(x: 16, y: 8.6))
        a.move(to: CGPoint(x: 11.8, y: 12.4)); a.addLine(to: CGPoint(x: 16, y: 8.2)); a.addLine(to: CGPoint(x: 20.2, y: 12.4))
        a.move(to: CGPoint(x: 10, y: 16.6)); a.addLine(to: CGPoint(x: 10, y: 22.6)); a.addLine(to: CGPoint(x: 22, y: 22.6)); a.addLine(to: CGPoint(x: 22, y: 16.6))
        p.stroke(a, rgb(0xFFFFFF), 2.1)
        },
        .sort: { p in
        func arrow(_ x: CGFloat, up: Bool, _ light: UInt32, _ dark: UInt32) {
            let a = CGMutablePath()
            let tip: CGFloat = up ? 5.5 : 26.5, tail: CGFloat = up ? 26 : 6, head: CGFloat = up ? 11 : 21
            a.move(to: CGPoint(x: x - 1.5, y: tail)); a.addLine(to: CGPoint(x: x + 1.5, y: tail)); a.addLine(to: CGPoint(x: x + 1.5, y: head))
            a.addLine(to: CGPoint(x: x + 5.6, y: head)); a.addLine(to: CGPoint(x: x, y: tip)); a.addLine(to: CGPoint(x: x - 5.6, y: head))
            a.addLine(to: CGPoint(x: x - 1.5, y: head)); a.closeSubpath()
            p.lifted(a, dark, dy: 0.7, blur: 1.4)
            p.vgrad(a, light, dark)
            p.sheen(a, 0.25)
        }
        arrow(10, up: true, 0x6DB1FF, 0x1A56D6)
        arrow(22, up: false, 0xFFB14A, 0xE06A0C)
        },
        .view: { p in
        let cells: [(CGFloat, CGFloat, UInt32, UInt32)] = [(4, 4, 0x6DB1FF, 0x1A56D6), (17.2, 4, 0x6BE39A, 0x12964A),
                                                           (4, 17.2, 0xFFC95C, 0xE08E0B), (17.2, 17.2, 0xC29BFF, 0x6A2FD6)]
        for (x, y, light, dark) in cells {
            let cell = p.rr(x, y, 10.8, 10.8, 2.6)
            p.lifted(cell, dark, dy: 0.7, blur: 1.3)
            p.vgrad(cell, light, dark)
            p.sheen(cell, 0.3)
        }
        },
        .previewPane: { p in
        let frame = p.rr(3, 5.5, 26, 21, 3.2)
        p.lifted(frame, 0xE6ECF5)
        p.vgrad(frame, 0xFFFFFF, 0xDDE4EE)
        p.stroke(frame, rgb(0x8E9BB3, 0.6), 0.5)
        for (i, w) in [CGFloat(8), 8, 5.5].enumerated() { p.solid(p.rr(6, 10 + CGFloat(i) * 3.6, w, 1.5, 0.75), rgb(0x8FA0BC)) }
        let pane = p.rr(17.2, 7.6, 9.6, 16.8, 1.8)
        p.vgrad(pane, 0x8AD4FF, 0x2F7FEA)
        p.sheen(pane, 0.3)
        p.vgrad(p.poly([(17.2, 24.4), (21.4, 17.6), (24, 21), (25.4, 19.4), (26.8, 21.2), (26.8, 24.4)]), 0x55D08A, 0x148A4A)
        },
        .more: { p in
        for x in [CGFloat(7), 16, 25] {
            let dot = CGPath(ellipseIn: CGRect(x: x - 3.1, y: 12.9, width: 6.2, height: 6.2), transform: nil)
            p.lifted(dot, 0x55617A, dy: 0.6, blur: 1.2)
            p.vgrad(dot, 0xC3CEDF, 0x6F7E99)
            p.sheen(dot, 0.35)
        }
        },
        .delete: { p in
        let bin = CGMutablePath()
        bin.move(to: CGPoint(x: 7, y: 10)); bin.addLine(to: CGPoint(x: 25, y: 10))
        bin.addLine(to: CGPoint(x: 23.2, y: 26.4)); bin.addQuadCurve(to: CGPoint(x: 21.2, y: 28.2), control: CGPoint(x: 23, y: 28.2))
        bin.addLine(to: CGPoint(x: 10.8, y: 28.2)); bin.addQuadCurve(to: CGPoint(x: 8.8, y: 26.4), control: CGPoint(x: 9, y: 28.2))
        bin.closeSubpath()
        p.lifted(bin, 0xB01818)
        p.vgrad(bin, 0xFF7A70, 0xD1201C)
        p.sheen(bin, 0.25)
        for x in [CGFloat(12.4), 16, 19.6] { p.solid(p.rr(x - 0.75, 13.6, 1.5, 10.6, 0.75), rgb(0xFFFFFF, 0.85)) }
        let lid = p.rr(5, 6.6, 22, 3.4, 1.7)
        p.lifted(lid, 0xB01818, dy: 0.5, blur: 1.0)
        p.vgrad(lid, 0xFF8F86, 0xC81E1E)
        p.vgrad(p.rr(12.8, 4, 6.4, 3.2, 1.4), 0xFF8F86, 0xD1201C)
        },
    ]
}
