import CoreGraphics
import Foundation

enum Tool: String, CaseIterable, Identifiable {
    case freehand, circle, ellipse, rectangle, polygon, pan

    var id: Self { self }

    var title: String {
        switch self {
        case .freehand: "Freehand"
        case .circle: "Circle"
        case .ellipse: "Ellipse"
        case .rectangle: "Rectangle"
        case .polygon: "Polygon"
        case .pan: "Pan"
        }
    }

    var symbol: String {
        switch self {
        case .freehand: "scribble.variable"
        case .circle: "circle"
        case .ellipse: "oval"
        case .rectangle: "rectangle"
        case .polygon: "pentagon"
        case .pan: "hand.raised"
        }
    }

    var key: Character {
        switch self {
        case .freehand: "f"
        case .circle: "c"
        case .ellipse: "e"
        case .rectangle: "r"
        case .polygon: "p"
        case .pan: "h"
        }
    }

    var hint: String {
        switch self {
        case .freehand: "Click and drag to draw around an area"
        case .circle: "Drag from the centre outwards"
        case .ellipse: "Drag corner to corner · ⇧ for a circle · ⌥ from centre"
        case .rectangle: "Drag corner to corner · ⇧ for a square · ⌥ from centre"
        case .polygon: "Click to place points · double-click or ↩ to close"
        case .pan: "Drag to move the map"
        }
    }
}

/// Shapes are built in screen space, densely enough that converting each vertex to
/// a coordinate keeps the edges where the player drew them on the Mercator map.
enum ShapeTools {
    static func shape(_ tool: Tool, from a: CGPoint, to b: CGPoint, shift: Bool, alt: Bool) -> [CGPoint] {
        switch tool {
        case .circle:
            let r = hypot(b.x - a.x, b.y - a.y)
            return ellipse(center: a, rx: r, ry: r)
        case .ellipse, .rectangle:
            var dx = b.x - a.x, dy = b.y - a.y
            if shift {
                let m = max(abs(dx), abs(dy))
                dx = dx < 0 ? -m : m
                dy = dy < 0 ? -m : m
            }
            let rect = alt
                ? CGRect(x: a.x - abs(dx), y: a.y - abs(dy), width: 2 * abs(dx), height: 2 * abs(dy))
                : CGRect(x: min(a.x, a.x + dx), y: min(a.y, a.y + dy), width: abs(dx), height: abs(dy))
            if tool == .ellipse {
                return ellipse(center: CGPoint(x: rect.midX, y: rect.midY), rx: rect.width / 2, ry: rect.height / 2)
            }
            return densify([
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
            ])
        default:
            return []
        }
    }

    static func ellipse(center c: CGPoint, rx: CGFloat, ry: CGFloat, count: Int = 180) -> [CGPoint] {
        (0..<count).map { i in
            let t = Double(i) / Double(count) * 2 * .pi
            return CGPoint(x: c.x + rx * cos(t), y: c.y + ry * sin(t))
        }
    }

    /// Inserts points so no edge of the closed ring is longer than `step`.
    static func densify(_ ring: [CGPoint], step: CGFloat = 8) -> [CGPoint] {
        guard ring.count >= 2 else { return ring }
        var out: [CGPoint] = []
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let n = max(1, Int((hypot(b.x - a.x, b.y - a.y) / step).rounded(.up)))
            for k in 0..<n {
                let t = CGFloat(k) / CGFloat(n)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return out
    }

    /// Cleans up a raw mouse stroke into a smooth closed ring.
    static func smoothFreehand(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count >= 3 else { return pts }
        var ring = simplify(pts, tolerance: 1.2)
        for _ in 0..<2 { ring = chaikin(ring) }
        return densify(ring, step: 10)
    }

    static func isUsable(_ pts: [CGPoint]) -> Bool {
        guard pts.count >= 3 else { return false }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return xs.max()! - xs.min()! >= 4 && ys.max()! - ys.min()! >= 4 && abs(signedArea(pts)) >= 30
    }

    static func path(_ pts: [CGPoint], closed: Bool) -> CGPath {
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        p.addLines(between: pts)
        if closed { p.closeSubpath() }
        return p
    }

    private static func signedArea(_ p: [CGPoint]) -> CGFloat {
        var s: CGFloat = 0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    private static func chaikin(_ ring: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        out.reserveCapacity(ring.count * 2)
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            out.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
            out.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
        }
        return out
    }

    /// Douglas-Peucker.
    private static func simplify(_ pts: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            let a = pts[s], b = pts[e]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = hypot(dx, dy)
            var maxD: CGFloat = 0, index = s
            for i in (s + 1)..<e {
                // A closed stroke can end on its start point, so measure from that point instead.
                let d = len < 0.0001
                    ? hypot(pts[i].x - a.x, pts[i].y - a.y)
                    : abs(dy * pts[i].x - dx * pts[i].y + b.x * a.y - b.y * a.x) / len
                if d > maxD { maxD = d; index = i }
            }
            if maxD > tolerance {
                keep[index] = true
                if index - s > 1 { stack.append((s, index)) }
                if e - index > 1 { stack.append((index, e)) }
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }
}
