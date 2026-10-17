import Foundation

enum PolygonRasterizer {
    /// Scanline fill in grid space (x = column, y = row). Calls `body(row, startCol, endCol)`
    /// for every run of cells whose centre lies inside the polygon (even-odd rule).
    /// Columns may fall outside the grid width; callers wrap them.
    static func forEachSpan(_ pts: [SIMD2<Double>], rowCount: Int, _ body: (Int, Int, Int) -> Void) {
        guard pts.count >= 3 else { return }
        let ys = pts.map(\.y)
        let r0 = max(0, Int((ys.min()! - 0.5).rounded(.up)))
        let r1 = min(rowCount - 1, Int((ys.max()! - 0.5).rounded(.down)))
        guard r0 <= r1 else { return }
        var xs: [Double] = []
        for r in r0...r1 {
            let yc = Double(r) + 0.5
            xs.removeAll(keepingCapacity: true)
            var j = pts.count - 1
            for i in 0..<pts.count {
                let a = pts[j], b = pts[i]
                if (a.y <= yc) != (b.y <= yc) {
                    xs.append(a.x + (yc - a.y) * (b.x - a.x) / (b.y - a.y))
                }
                j = i
            }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                let c0 = Int((xs[k] - 0.5).rounded(.up))
                let c1 = Int((xs[k + 1] - 0.5).rounded(.up))
                if c1 > c0 { body(r, c0, c1) }
                k += 2
            }
        }
    }
}
