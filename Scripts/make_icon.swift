// Draws the app icon: a globe with real coastlines and a gold lasso around it.
//
// Usage: swift Scripts/make_icon.swift <continents.outline> <AppIcon.appiconset dir>

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: swift make_icon.swift <continents.outline> <AppIcon.appiconset>")
    exit(1)
}

// MARK: Outline file (same format as RegionOutlines in the app)

typealias Ring = [(lat: Double, lon: Double)]

func readOutline(_ path: String) -> [Ring] {
    let compressed = try! Data(contentsOf: URL(fileURLWithPath: path))
    let raw = try! (compressed as NSData).decompressed(using: .zlib) as Data
    var rings: [Ring] = []
    raw.withUnsafeBytes { buf in
        var o = 0
        func u32() -> Int {
            defer { o += 4 }
            return Int(buf.loadUnaligned(fromByteOffset: o, as: UInt32.self))
        }
        for _ in 0..<u32() {
            _ = u32()
            for _ in 0..<u32() {
                for r in 0..<u32() {
                    let ring: Ring = (0..<u32()).map { _ in
                        defer { o += 8 }
                        return (Double(buf.loadUnaligned(fromByteOffset: o + 4, as: Float.self)),
                                Double(buf.loadUnaligned(fromByteOffset: o, as: Float.self)))
                    }
                    if r == 0 { rings.append(ring) } // exteriors only; lakes are too small to see
                }
            }
        }
    }
    return rings
}

// MARK: Drawing

let size = 1024.0
let center = CGPoint(x: 512, y: 506)
let radius = 262.0
let lat0 = 28.0 * .pi / 180, lon0 = 18.0 * .pi / 180

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Orthographic projection; points on the far side are pushed onto the rim.
func project(lat: Double, lon: Double) -> (CGPoint, Bool) {
    let p = lat * .pi / 180, l = lon * .pi / 180 - lon0
    let x = cos(p) * sin(l)
    let y = cos(lat0) * sin(p) - sin(lat0) * cos(p) * cos(l)
    let visible = sin(lat0) * sin(p) + cos(lat0) * cos(p) * cos(l) >= 0
    var v = CGPoint(x: x, y: y)
    if !visible {
        let n = max(hypot(x, y), 1e-9)
        v = CGPoint(x: x / n, y: y / n)
    }
    return (CGPoint(x: center.x + v.x * radius, y: center.y + v.y * radius), visible)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.1) as CFArray,
               locations: stops.map(\.0))!
}

func lasso(_ ctx: CGContext, front: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: -0.3)
    let ellipse = CGRect(x: -372, y: -118, width: 744, height: 236)
    if front { ctx.clip(to: CGRect(x: -400, y: -200, width: 800, height: 200)) }
    ctx.setLineCap(.round)
    for (width, c, dash) in [(36.0, color(0x6B3E00), [CGFloat]()), (26.0, color(0xFFC24A), []),
                             (8.0, color(0xFFE8A3, 0.9), [16, 18])] {
        ctx.addEllipse(in: ellipse)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(c)
        ctx.setLineDash(phase: 0, lengths: dash)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func drawIcon(rings: [Ring]) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Rounded square on the standard macOS icon grid.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185,
                      transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(color(0x0B1630))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0x24427A)), (1, color(0x0A1430))]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    var seed: UInt64 = 7
    func rand() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 33) / Double(1 << 31)
    }
    for _ in 0..<60 {
        let p = CGPoint(x: 110 + rand() * 804, y: 110 + rand() * 804)
        let r = 1.5 + rand() * 2.5
        ctx.setFillColor(color(0xFFFFFF, 0.25 + rand() * 0.45))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    // Back half of the lasso, then the globe over it.
    lasso(ctx, front: false)

    let globe = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: color(0x4FB3FF, 0.45))
    ctx.setFillColor(color(0x0E3C8C))
    ctx.fillEllipse(in: globe)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: globe)
    ctx.clip()
    ctx.drawRadialGradient(gradient([(0, color(0x5CC0FF)), (0.55, color(0x1D6FD1)), (1, color(0x0A2D6E))]),
                           startCenter: CGPoint(x: center.x - 90, y: center.y + 110), startRadius: 0,
                           endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])

    // Land
    let land = CGMutablePath()
    for ring in rings where ring.count > 2 {
        let pts = ring.map { project(lat: $0.lat, lon: $0.lon) }
        guard pts.contains(where: \.1) else { continue }
        land.addLines(between: pts.map(\.0))
        land.closeSubpath()
    }
    ctx.saveGState()
    ctx.addPath(land)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0x9BE38A)), (0.6, color(0x3FA35F)), (1, color(0x1F6B45))]),
                           start: CGPoint(x: center.x - radius, y: center.y + radius),
                           end: CGPoint(x: center.x + radius, y: center.y - radius), options: [])
    ctx.restoreGState()
    ctx.addPath(land)
    ctx.setStrokeColor(color(0xFFFFFF, 0.35))
    ctx.setLineWidth(2)
    ctx.strokePath()

    // Graticule
    ctx.setStrokeColor(color(0xFFFFFF, 0.16))
    ctx.setLineWidth(2.5)
    for lat in stride(from: -60.0, through: 60, by: 30) {
        let line = stride(from: -180.0, through: 180, by: 2).map { project(lat: lat, lon: $0) }
        for (a, b) in zip(line, line.dropFirst()) where a.1 && b.1 {
            ctx.move(to: a.0)
            ctx.addLine(to: b.0)
        }
    }
    for lon in stride(from: -180.0, to: 180, by: 30) {
        let line = stride(from: -90.0, through: 90, by: 2).map { project(lat: $0, lon: lon) }
        for (a, b) in zip(line, line.dropFirst()) where a.1 && b.1 {
            ctx.move(to: a.0)
            ctx.addLine(to: b.0)
        }
    }
    ctx.strokePath()

    // City lights
    for (lat, lon) in [(51.5, -0.1), (48.9, 2.4), (30.0, 31.2), (6.5, 3.4), (41.0, 29.0), (55.8, 37.6),
                       (40.4, -3.7), (25.2, 55.3), (-26.2, 28.0), (52.5, 13.4), (41.9, 12.5)] {
        let (p, visible) = project(lat: lat, lon: lon)
        guard visible else { continue }
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 14, color: color(0xFFD25A, 0.95))
        ctx.setFillColor(color(0xFFE08A))
        ctx.fillEllipse(in: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16))
        ctx.restoreGState()
    }

    // Shading: dark rim bottom right, soft shine top left.
    ctx.drawRadialGradient(gradient([(0, color(0x000000, 0)), (0.7, color(0x000000, 0)), (1, color(0x000820, 0.55))]),
                           startCenter: CGPoint(x: center.x - 60, y: center.y + 70), startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
    ctx.drawRadialGradient(gradient([(0, color(0xFFFFFF, 0.35)), (1, color(0xFFFFFF, 0))]),
                           startCenter: CGPoint(x: center.x - 110, y: center.y + 140), startRadius: 0,
                           endCenter: CGPoint(x: center.x - 110, y: center.y + 140), endRadius: 150, options: [])
    ctx.restoreGState()

    lasso(ctx, front: true)
    ctx.restoreGState()
    return ctx.makeImage()!
}

func scaled(_ image: CGImage, to px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest))
}

let icon = drawIcon(rings: readOutline(args[1]))
let out = URL(fileURLWithPath: args[2])
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        writePNG(scaled(icon, to: points * scale), to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(out.path)")
