// Draws the DMG window background: a night sky with a gold lasso arrow from the app to Applications.
// The icon positions here must match the ones in package_release.sh.
//
// Usage: swift Scripts/make_dmg_background.swift <out dir>
// Writes background.png and background@2x.png.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 2 else {
    print("usage: swift make_dmg_background.swift <out dir>")
    exit(1)
}

let width = 660.0, height = 400.0
let appIcon = CGPoint(x: 180, y: 180), appsIcon = CGPoint(x: 480, y: 180) // top-left origin, like Finder

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.1) as CFArray,
               locations: stops.map(\.0))!
}

func text(_ ctx: CGContext, _ s: String, size: CGFloat, weight: NSFont.Weight, color c: CGColor, centerY: CGFloat) {
    let attr = NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(cgColor: c)!,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1) // undo the flipped context for glyphs
    ctx.textPosition = CGPoint(x: (width - w) / 2, y: centerY + size * 0.35)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func draw(scale: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1, y: -1)

    // Sky, matching the icon's background.
    ctx.drawLinearGradient(gradient([(0, color(0x0A1430)), (1, color(0x24427A))]),
                           start: .zero, end: CGPoint(x: 0, y: height), options: [])
    var seed: UInt64 = 7
    func rand() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(seed >> 33) / CGFloat(1 << 31)
    }
    for _ in 0..<120 {
        let r = 0.4 + rand() * 1.1
        ctx.setFillColor(color(0xFFFFFF, 0.15 + rand() * 0.45))
        ctx.fillEllipse(in: CGRect(x: rand() * width, y: rand() * height, width: r, height: r))
    }

    // Glow behind each icon so they sit on a lit spot.
    for p in [appIcon, appsIcon] {
        ctx.drawRadialGradient(gradient([(0, color(0x4FB3FF, 0.28)), (1, color(0x4FB3FF, 0))]),
                               startCenter: p, startRadius: 0, endCenter: p, endRadius: 110, options: [])
    }

    // Finder draws icon labels in black over a background picture, so give them a light pill.
    for p in [appIcon, appsIcon] {
        let pill = CGRect(x: p.x - 66, y: p.y + 70, width: 132, height: 24)
        ctx.setFillColor(color(0xFFE8A3, 0.92))
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()
    }

    // Gold lasso arrow, styled like the icon's lasso.
    let start = CGPoint(x: appIcon.x + 82, y: appIcon.y - 4), end = CGPoint(x: appsIcon.x - 86, y: appsIcon.y - 4)
    let arc = CGMutablePath()
    arc.move(to: start)
    arc.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) / 2, y: start.y - 60))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for (w, c, dash) in [(10.0, color(0x6B3E00), [CGFloat]()), (6.0, color(0xFFC24A), []),
                         (2.0, color(0xFFE8A3, 0.9), [5, 6])] {
        ctx.setLineWidth(w)
        ctx.setStrokeColor(c)
        ctx.setLineDash(phase: 0, lengths: dash)
        ctx.addPath(arc)
        ctx.strokePath()
    }
    ctx.setLineDash(phase: 0, lengths: [])
    // Head points along the curve's final direction (from the control point to the end).
    let dir = atan2(end.y - (start.y - 60), end.x - (start.x + end.x) / 2)
    let head = CGMutablePath()
    head.move(to: CGPoint(x: end.x + 14 * cos(dir), y: end.y + 14 * sin(dir)))
    head.addLine(to: CGPoint(x: end.x + 12 * cos(dir + 2.3), y: end.y + 12 * sin(dir + 2.3)))
    head.addLine(to: CGPoint(x: end.x + 12 * cos(dir - 2.3), y: end.y + 12 * sin(dir - 2.3)))
    head.closeSubpath()
    ctx.setStrokeColor(color(0x6B3E00))
    ctx.setLineWidth(4)
    ctx.addPath(head)
    ctx.strokePath()
    ctx.setFillColor(color(0xFFC24A))
    ctx.addPath(head)
    ctx.fillPath()

    text(ctx, "Drag Populus into Applications", size: 22, weight: .semibold, color: color(0xFFE08A), centerY: 48)
    text(ctx, "First time opening it? See the install steps on the download page.", size: 12,
         weight: .regular, color: color(0xFFFFFF, 0.7), centerY: 350)
    return ctx.makeImage()!
}

for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    let url = URL(fileURLWithPath: args[1]).appendingPathComponent(name) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, draw(scale: scale), [kCGImagePropertyDPIWidth: 72 * scale,
                                                          kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
    CGImageDestinationFinalize(dest)
}
