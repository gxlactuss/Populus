import AppKit
import ImageIO
import MapKit
import UniformTypeIdentifiers

/// Renders the population grid as a log-scale heatmap, one 256 px Mercator tile at a time.
final class DensityTileOverlay: MKTileOverlay {
    private let grid: PopulationGrid
    private let cache = NSCache<NSString, NSData>()
    private let queue = DispatchQueue(label: "density.tiles", qos: .userInitiated, attributes: .concurrent)

    /// Premultiplied RGBA for log10(density) mapped onto 0...255.
    private static let palette: [UInt32] = {
        let stops: [(Double, Double, Double, Double)] = [
            (0.00, 40, 11, 84),
            (0.25, 120, 28, 109),
            (0.50, 212, 72, 66),
            (0.75, 250, 150, 30),
            (1.00, 252, 255, 164),
        ]
        return (0..<256).map { i in
            let t = Double(i) / 255
            var k = 0
            while k < stops.count - 2 && t > stops[k + 1].0 { k += 1 }
            let a = stops[k], b = stops[k + 1]
            let f = (t - a.0) / (b.0 - a.0)
            let alpha = t < 0.08 ? 0.15 + t / 0.08 * 0.35 : 0.5 + 0.4 * t
            let r = (a.1 + (b.1 - a.1) * f) * alpha
            let g = (a.2 + (b.2 - a.2) * f) * alpha
            let bl = (a.3 + (b.3 - a.3) * f) * alpha
            let bytes = [UInt8(r), UInt8(g), UInt8(bl), UInt8(alpha * 255)]
            return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
    }()

    init(grid: PopulationGrid) {
        self.grid = grid
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 22
        cache.totalCostLimit = 96 << 20
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        // Retina screens get 512 px tiles so the heatmap is as sharp as the map under it.
        let scale = max(1, Int(path.contentScaleFactor.rounded()))
        let key = "\(path.z)/\(path.x)/\(path.y)@\(scale)" as NSString
        if let data = cache.object(forKey: key) {
            result(data as Data, nil)
            return
        }
        queue.async { [self] in
            let data = render(path, size: 256 * scale)
            if let data { cache.setObject(data as NSData, forKey: key, cost: data.count) }
            result(data, nil)
        }
    }

    /// One level's cells around a tile, as people per km², sampled with bilinear filtering.
    private struct Sampler {
        let level: PopulationLevel
        let col0: Int, row0: Int, cols: Int, rows: Int
        let values: [Float]

        init?(_ level: PopulationLevel, lons: ClosedRange<Double>, lats: ClosedRange<Double>) {
            // Cell centres sit on whole numbers, so a point needs the cells either side of it.
            var c0 = Int(((lons.lowerBound - level.originLon) / level.cellDeg - 0.5).rounded(.down))
            var c1 = Int(((lons.upperBound - level.originLon) / level.cellDeg - 0.5).rounded(.down)) + 1
            let r0 = max(0, Int(((level.originLat - lats.upperBound) / level.cellDeg - 0.5).rounded(.down)))
            let r1 = min(level.height - 1, Int(((level.originLat - lats.lowerBound) / level.cellDeg - 0.5).rounded(.down)) + 1)
            if !level.wraps {
                c0 = max(0, c0)
                c1 = min(level.width - 1, c1)
            }
            guard c1 > c0, r1 > r0 else { return nil }
            self.level = level
            (col0, row0, cols, rows) = (c0, r0, c1 - c0 + 1, r1 - r0 + 1)
            values = level.densities(col0: c0, row0: r0, cols: cols, rows: rows)
        }

        /// Density and how much it should count: 1, fading to 0 over the last `featherCells`
        /// of a city box so its sharper data blends into the global grid without a hard edge.
        /// nil when the point is outside this block.
        func density(lat: Double, lon: Double) -> (value: Float, weight: Float)? {
            let x = (lon - level.originLon) / level.cellDeg - 0.5 - Double(col0)
            let y = (level.originLat - lat) / level.cellDeg - 0.5 - Double(row0)
            guard x >= 0, y >= 0, x <= Double(cols - 1), y <= Double(rows - 1) else { return nil }
            let i = min(Int(x), cols - 2), j = min(Int(y), rows - 2)
            let fx = Float(x - Double(i)), fy = Float(y - Double(j))
            let k = j * cols + i
            let top = values[k] + (values[k + 1] - values[k]) * fx
            let bottom = values[k + cols] + (values[k + cols + 1] - values[k + cols]) * fx
            var weight: Float = 1
            if !level.wraps {
                let ax = x + Double(col0), ay = y + Double(row0)
                let edge = min(ax, Double(level.width - 1) - ax, ay, Double(level.height - 1) - ay)
                weight = Float(min(1, edge / Self.featherCells))
            }
            return (top + (bottom - top) * fy, weight)
        }

        private static let featherCells = 48.0
    }

    private func render(_ path: MKTileOverlayPath, size: Int) -> Data? {
        let n = Double(1 << path.z)
        let pixelDeg = 360 / (n * Double(size))
        func lat(_ yNorm: Double) -> Double { atan(sinh(.pi * (1 - 2 * yNorm))) * 180 / .pi }
        let lons = (Double(path.x) / n * 360 - 180)...(Double(path.x + 1) / n * 360 - 180)
        let lats = lat(Double(path.y + 1) / n)...lat(Double(path.y) / n)

        // Like mipmapping: the level whose cells are closest to the pixel size, then
        // the 100 m city grids once they match better, so deep zooms show real detail.
        func mismatch(_ l: PopulationLevel) -> Double { abs(log(l.cellDeg / pixelDeg)) }
        let base = grid.levels.min { mismatch($0) < mismatch($1) }!
        var samplers: [Sampler] = []
        if let metros = Metros.shared {
            for e in metros.entries where e.bounds[0] < lats.upperBound && e.bounds[1] > lats.lowerBound
                && e.bounds[2] < lons.upperBound && e.bounds[3] > lons.lowerBound {
                if let level = metros.level(e.id), mismatch(level) < mismatch(base),
                   let s = Sampler(level, lons: lons, lats: lats) {
                    samplers.append(s)
                }
            }
        }
        if let s = Sampler(base, lons: lons, lats: lats) { samplers.append(s) }

        let lonOf = (0..<size).map { lons.lowerBound + (Double($0) + 0.5) * pixelDeg }
        var pixels = [UInt32](repeating: 0, count: size * size)
        var any = false
        for py in 0..<size {
            let la = lat((Double(path.y) + (Double(py) + 0.5) / Double(size)) / n)
            for px in 0..<size {
                var d: Float = 0, remaining: Float = 1
                for s in samplers {
                    guard let (v, w) = s.density(lat: la, lon: lonOf[px]) else { continue }
                    d += v * w * remaining
                    remaining *= 1 - w
                    if remaining <= 0 { break }
                }
                guard d > 0 else { continue }
                let t = (log10(Double(d)) + 0.3) / 4.6 // ~0.5 to ~20,000 people/km²
                guard t > 0 else { continue }
                pixels[py * size + px] = Self.palette[Int(min(1, t) * 255)]
                any = true
            }
        }
        guard any else { return Self.emptyTile }
        return Self.png(pixels: &pixels, size: size)
    }

    private static let emptyTile: Data? = {
        var p = [UInt32](repeating: 0, count: 1)
        return png(pixels: &p, size: 1)
    }()

    static func png(pixels: inout [UInt32], size: Int) -> Data? {
        let image: CGImage? = pixels.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let image else { return nil }
        return encode(image)
    }

    static func encode(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

/// NASA VIIRS Black Marble city lights. GIBS only serves up to zoom 8, so deeper tiles
/// are cut out of their level-8 ancestor and scaled up.
final class NightLightsOverlay: MKTileOverlay {
    private static let maxNativeZ = 8
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()
    private let upscaled = NSCache<NSString, NSData>()
    /// Decoded level-8 images, so each one is decoded once rather than once per deeper tile.
    private let ancestors = NSCache<NSString, CGImage>()
    private let queue = DispatchQueue(label: "night.tiles", qos: .userInitiated, attributes: .concurrent)

    init() {
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 22
        upscaled.totalCostLimit = 32 << 20
        ancestors.countLimit = 48
    }

    private func url(z: Int, x: Int, y: Int) -> URL {
        URL(string: "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/VIIRS_Black_Marble/default/2016-01-01/GoogleMapsCompatible_Level8/\(z)/\(y)/\(x).png")!
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        if path.z <= Self.maxNativeZ {
            session.dataTask(with: url(z: path.z, x: path.x, y: path.y)) { data, _, error in
                result(data, error)
            }.resume()
            return
        }
        let key = "\(path.z)/\(path.x)/\(path.y)" as NSString
        if let cached = upscaled.object(forKey: key) {
            result(cached as Data, nil)
            return
        }
        let d = path.z - Self.maxNativeZ
        let ax = path.x >> d, ay = path.y >> d
        let ancestorKey = "\(ax)/\(ay)" as NSString
        let finish = { [weak self] (image: CGImage) in
            guard let self else { return }
            let out = Self.upscale(image, x: path.x - (ax << d), y: path.y - (ay << d), depth: d)
            if let out { self.upscaled.setObject(out as NSData, forKey: key, cost: out.count) }
            result(out, nil)
        }
        if let image = ancestors.object(forKey: ancestorKey) {
            queue.async { finish(image) }
            return
        }
        session.dataTask(with: url(z: Self.maxNativeZ, x: ax, y: ay)) { [weak self] data, _, error in
            guard let data, let self,
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                result(nil, error)
                return
            }
            self.ancestors.setObject(image, forKey: ancestorKey)
            // Scale off the session's serial callback queue so tiles render in parallel.
            self.queue.async { finish(image) }
        }.resume()
    }

    /// Cuts sub-tile (x, y) of a `depth`-levels-up ancestor and scales it to 256 px.
    private static func upscale(_ image: CGImage, x: Int, y: Int, depth: Int) -> Data? {
        let span = Double(image.width) / Double(1 << depth)
        let crop = CGRect(x: Double(x) * span, y: Double(y) * span, width: span, height: span)
        guard let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // Draw the whole ancestor scaled so the wanted sub-square fills the tile.
        let scale = 256 / span
        ctx.draw(image, in: CGRect(x: -crop.minX * scale,
                                   y: -(Double(image.height) - crop.maxY) * scale,
                                   width: Double(image.width) * scale,
                                   height: Double(image.height) * scale))
        return ctx.makeImage().flatMap(DensityTileOverlay.encode)
    }
}
