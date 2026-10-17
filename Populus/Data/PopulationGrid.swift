import Compression
import Foundation

struct GeoPoint: Codable, Hashable, Sendable {
    var lat: Double
    var lon: Double
}

struct PopulationResult: Codable, Hashable, Sendable {
    var total: Double
    var areaKm2: Double
    var peakDensity: Double
    var levelIndex: Int

    var averageDensity: Double { areaKm2 > 0 ? total / areaKm2 : 0 }
}

private let earthRadiusKm = 6371.0088

private extension Double {
    var radians: Double { self * .pi / 180 }
}

/// One resolution level of the population pyramid, read from a `pop_L*.pack` file
/// produced by `Scripts/build_data.py`. Values are people per cell.
final class PopulationLevel: @unchecked Sendable {
    let width: Int
    let height: Int
    let tileSize: Int
    let tilesX: Int
    let tilesY: Int
    let originLon: Double
    let originLat: Double
    let cellDeg: Double
    /// Global grids wrap around the antimeridian; city boxes don't.
    let wraps: Bool

    private static let headerSize = 52
    private final class Tile {
        let values: [Float]
        init(_ values: [Float]) { self.values = values }
    }

    private let data: Data
    private let cache = NSCache<NSNumber, Tile>()
    private let rowAreas: [Double]

    init(url: URL) throws {
        let d = try Data(contentsOf: url, options: .alwaysMapped)
        guard d.count >= Self.headerSize, d.prefix(4) == Data("POPG".utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func u32(_ o: Int) -> Int { Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }) }
        func f64(_ o: Int) -> Double { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Double.self) } }
        data = d
        width = u32(8)
        height = u32(12)
        tileSize = u32(16)
        tilesX = u32(20)
        tilesY = u32(24)
        originLon = f64(28)
        originLat = f64(36)
        cellDeg = f64(44)
        wraps = abs(Double(width) * cellDeg - 360) < 0.01
        // Each level and city grid has its own cache, so keep each one modest. A guess reads
        // at most 30M cells (120 MB), which still fits.
        cache.totalCostLimit = 192 * 1024 * 1024

        let dLon = cellDeg.radians
        let originLat = originLat, cellDeg = cellDeg
        rowAreas = (0..<height).map { row in
            let top = (originLat - Double(row) * cellDeg).radians
            let bottom = (originLat - Double(row + 1) * cellDeg).radians
            return earthRadiusKm * earthRadiusKm * dLon * abs(sin(top) - sin(bottom))
        }
    }

    /// Area of one cell in the given row, in km².
    func cellArea(row: Int) -> Double {
        rowAreas[min(max(row, 0), height - 1)]
    }

    /// People per km² at a point.
    func density(lat: Double, lon: Double) -> Double {
        let row = Int(((originLat - lat) / cellDeg).rounded(.down))
        let col = Int(((lon - originLon) / cellDeg).rounded(.down))
        guard row >= 0, row < height else { return 0 }
        return Double(value(col: col, row: row)) / cellArea(row: row)
    }

    /// Decompressed tile values, or nil for an all-zero tile.
    func tile(_ tx: Int, _ ty: Int) -> [Float]? {
        let index = ty * tilesX + tx
        let key = NSNumber(value: index)
        if let cached = cache.object(forKey: key) {
            return cached.values.isEmpty ? nil : cached.values
        }
        let entry = Self.headerSize + index * 12
        let (offset, length) = data.withUnsafeBytes {
            (Int($0.loadUnaligned(fromByteOffset: entry, as: UInt64.self)),
             Int($0.loadUnaligned(fromByteOffset: entry + 8, as: UInt32.self)))
        }
        guard length > 0 else {
            cache.setObject(Tile([]), forKey: key, cost: 1)
            return nil
        }
        let count = tileSize * tileSize
        var values = [Float](repeating: 0, count: count)
        let decoded = values.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.baseAddress!.assumingMemoryBound(to: UInt8.self), dst.count,
                    src.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self), length,
                    nil, COMPRESSION_ZLIB)
            }
        }
        if decoded != count * 4 { values = [] }
        cache.setObject(Tile(values), forKey: key, cost: max(1, values.count * 4))
        return values.isEmpty ? nil : values
    }

    func value(col: Int, row: Int) -> Float {
        guard row >= 0, row < height, wraps || (col >= 0 && col < width) else { return 0 }
        let c = ((col % width) + width) % width
        guard let t = tile(c / tileSize, row / tileSize) else { return 0 }
        return t[(row % tileSize) * tileSize + c % tileSize]
    }

    /// People per km² for a block of cells, row major. Reads each tile once per row instead of
    /// once per cell. Cells off the grid are 0; columns wrap around the antimeridian on global grids.
    func densities(col0: Int, row0: Int, cols: Int, rows: Int) -> [Float] {
        var out = [Float](repeating: 0, count: cols * rows)
        out.withUnsafeMutableBufferPointer { out in
            for r in 0..<rows {
                let row = row0 + r
                guard row >= 0, row < height else { continue }
                let perKm2 = Float(1 / cellArea(row: row))
                let ty = row / tileSize, ry = row % tileSize
                var c = 0
                while c < cols {
                    let col = col0 + c
                    if !wraps && col < 0 { c = -col0; continue }
                    if !wraps && col >= width { break }
                    let wc = ((col % width) + width) % width
                    let cx = wc % tileSize
                    let len = min(cols - c, tileSize - cx, width - wc)
                    if let t = tile(wc / tileSize, ty) {
                        t.withUnsafeBufferPointer { t in
                            let src = ry * tileSize + cx, dst = r * cols + c
                            for i in 0..<len { out[dst + i] = t[src + i] * perKm2 }
                        }
                    }
                    c += len
                }
            }
        }
        return out
    }

    /// Sums `count` cells of a row starting at column `start`, wrapping around the antimeridian.
    func sum(row: Int, start: Int, count: Int) -> (total: Double, peak: Float) {
        guard row >= 0, row < height else { return (0, 0) }
        var start = start, count = count
        if !wraps {
            let end = min(width, start + count)
            start = max(0, start)
            guard end > start else { return (0, 0) }
            count = end - start
        }
        var remaining = min(count, width)
        var c = ((start % width) + width) % width
        let ty = row / tileSize, ry = row % tileSize
        var total = 0.0
        var peak: Float = 0
        while remaining > 0 {
            let cx = c % tileSize
            let len = min(remaining, tileSize - cx, width - c)
            if let t = tile(c / tileSize, ty) {
                t.withUnsafeBufferPointer { buf in
                    let base = ry * tileSize + cx
                    for i in base..<(base + len) {
                        let v = buf[i]
                        total += Double(v)
                        if v > peak { peak = v }
                    }
                }
            }
            c = (c + len) % width
            remaining -= len
        }
        return (total, peak)
    }
}

final class PopulationGrid: @unchecked Sendable {
    static let shared: PopulationGrid? = {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Data") else { return nil }
        return try? PopulationGrid(directory: dir)
    }()

    /// Finest first.
    let levels: [PopulationLevel]

    init(directory: URL) throws {
        levels = try (0..<4).map { try PopulationLevel(url: directory.appendingPathComponent("pop_L\($0).pack")) }
    }

    /// Finest level whose cells covering the bounding box stay under `maxCells`.
    func levelIndex(for polygon: [GeoPoint], maxCells: Int) -> Int {
        let lats = polygon.map(\.lat), lons = polygon.map(\.lon)
        let latSpan = (lats.max()! - lats.min()!), lonSpan = (lons.max()! - lons.min()!)
        for (i, level) in levels.enumerated() where (latSpan / level.cellDeg) * (lonSpan / level.cellDeg) <= Double(maxCells) {
            return i
        }
        return levels.count - 1
    }

    /// With a `region`, only people inside it are counted. City regions use their 100 m grid.
    func population(in polygon: [GeoPoint], maxCells: Int = 30_000_000, region: Region? = nil) -> PopulationResult {
        guard polygon.count >= 3 else { return PopulationResult(total: 0, areaKm2: 0, peakDensity: 0, levelIndex: 0) }
        if case .city(let id)? = region, let level = Metros.shared?.level(id) {
            return population(in: polygon, level: level, levelIndex: -1, mask: nil)
        }
        return population(in: polygon, level: levelIndex(for: polygon, maxCells: maxCells), region: region)
    }

    func population(in polygon: [GeoPoint], level li: Int, region: Region? = nil) -> PopulationResult {
        population(in: polygon, level: levels[li], levelIndex: li, mask: region?.mask)
    }

    private func population(in polygon: [GeoPoint], level: PopulationLevel, levelIndex li: Int,
                            mask: (RegionMask, UInt8)?) -> PopulationResult {
        let pts = polygon.map {
            SIMD2(($0.lon - level.originLon) / level.cellDeg, (level.originLat - $0.lat) / level.cellDeg)
        }
        var total = 0.0, peak = 0.0, cells = 0
        func add(row: Int, start: Int, end: Int) {
            let s = level.sum(row: row, start: start, count: end - start)
            total += s.total
            cells += end - start
            peak = max(peak, Double(s.peak) / level.cellArea(row: row))
        }
        PolygonRasterizer.forEachSpan(pts, rowCount: level.height) { row, c0, c1 in
            guard let (mask, id) = mask else {
                add(row: row, start: c0, end: c1)
                return
            }
            // Split the span into runs of cells whose centre lies in the region,
            // stepping one mask cell at a time.
            let maskRow = mask.row(lat: level.originLat - (Double(row) + 0.5) * level.cellDeg)
            var c = c0
            var runStart: Int?
            while c < c1 {
                let lon = level.originLon + (Double(c) + 0.5) * level.cellDeg
                let inside = mask.id(row: maskRow, col: mask.col(lon: lon)) == id
                let nextLon = ((lon + 180) / mask.cellDeg).rounded(.down) * mask.cellDeg - 180 + mask.cellDeg
                let next = min(c1, max(c + 1, Int(((nextLon - level.originLon) / level.cellDeg - 0.5).rounded(.up))))
                if inside {
                    if runStart == nil { runStart = c }
                } else if let s = runStart {
                    add(row: row, start: s, end: c)
                    runStart = nil
                }
                c = next
            }
            if let s = runStart { add(row: row, start: s, end: c1) }
        }
        let area = Self.sphericalAreaKm2(polygon)
        if cells == 0 {
            // Shape is smaller than one cell: use the density under its centre.
            let lat = polygon.map(\.lat).reduce(0, +) / Double(polygon.count)
            let lon = polygon.map(\.lon).reduce(0, +) / Double(polygon.count)
            let inside = mask.map { $0.0.id(lat: lat, lon: lon) == $0.1 } ?? true
            let d = inside ? level.density(lat: lat, lon: lon) : 0
            total = d * area
            peak = d
        }
        return PopulationResult(total: total, areaKm2: area, peakDensity: peak, levelIndex: li)
    }

    static func sphericalAreaKm2(_ p: [GeoPoint]) -> Double {
        guard p.count >= 3 else { return 0 }
        var s = 0.0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            s += (b.lon - a.lon).radians * (2 + sin(a.lat.radians) + sin(b.lat.radians))
        }
        return abs(s) * earthRadiusKm * earthRadiusKm / 2
    }
}
