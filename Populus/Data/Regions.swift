import Compression
import Foundation

struct RegionBounds: Hashable, Sendable {
    var minLat: Double
    var maxLat: Double
    var minLon: Double
    var maxLon: Double

    init(_ minLat: Double, _ maxLat: Double, _ minLon: Double, _ maxLon: Double) {
        (self.minLat, self.maxLat, self.minLon, self.maxLon) = (minLat, maxLat, minLon, maxLon)
    }

    init?(_ v: [Double]?) {
        guard let v, v.count == 4 else { return nil }
        self.init(v[0], v[1], v[2], v[3])
    }

    func contains(lat: Double, lon: Double) -> Bool {
        guard lat >= minLat, lat <= maxLat else { return false }
        return [lon, lon - 360, lon + 360].contains { $0 >= minLon && $0 <= maxLon }
    }
}

/// Raw values match the ids in `continents.mask` built by `Scripts/build_regions.py`.
enum Continent: Int, CaseIterable, Codable, Sendable {
    case africa = 1, asia, europe, northAmerica, oceania, southAmerica

    var name: String {
        switch self {
        case .africa: "Africa"
        case .asia: "Asia"
        case .europe: "Europe"
        case .northAmerica: "North America"
        case .oceania: "Oceania"
        case .southAmerica: "South America"
        }
    }

    var symbol: String {
        switch self {
        case .africa, .europe: "globe.europe.africa.fill"
        case .asia, .oceania: "globe.asia.australia.fill"
        case .northAmerica, .southAmerica: "globe.americas.fill"
        }
    }

    var bounds: RegionBounds {
        switch self {
        case .africa: RegionBounds(-36, 38, -19, 53)
        case .asia: RegionBounds(-11, 56, 25, 150)
        case .europe: RegionBounds(34, 71, -25, 50)
        case .northAmerica: RegionBounds(7, 72, -168, -52)
        case .oceania: RegionBounds(-48, 0, 110, 180)
        case .southAmerica: RegionBounds(-56, 13, -82, -34)
        }
    }
}

/// A uint8 raster (0.05°) labelling each cell with a continent or country id.
final class RegionMask: @unchecked Sendable {
    struct Entry: Decodable, Sendable {
        let id: Int
        let name: String
        let total: Double
        let code: String?
        let bounds: [Double]?
    }

    static let continents = RegionMask(name: "continents")
    static let countries = RegionMask(name: "countries")

    let width: Int
    let height: Int
    let cellDeg: Double
    let entries: [Entry]
    private let ids: [UInt8]

    private struct Meta: Decodable {
        let width: Int
        let height: Int
        let cellDeg: Double
        let entries: [Entry]
    }

    private init?(name: String) {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Data"),
              let json = try? Data(contentsOf: dir.appendingPathComponent("\(name).json")),
              let meta = try? JSONDecoder().decode(Meta.self, from: json),
              let compressed = try? Data(contentsOf: dir.appendingPathComponent("\(name).mask")) else { return nil }
        var ids = [UInt8](repeating: 0, count: meta.width * meta.height)
        let decoded = ids.withUnsafeMutableBufferPointer { dst in
            compressed.withUnsafeBytes { src in
                compression_decode_buffer(dst.baseAddress!, dst.count,
                                          src.baseAddress!.assumingMemoryBound(to: UInt8.self), src.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded == ids.count else { return nil }
        width = meta.width
        height = meta.height
        cellDeg = meta.cellDeg
        entries = meta.entries
        self.ids = ids
    }

    func entry(_ id: Int) -> Entry? { entries.first { $0.id == id } }

    func row(lat: Double) -> Int {
        Int(((90 - lat) / cellDeg).rounded(.down))
    }

    func col(lon: Double) -> Int {
        let c = Int(((lon + 180) / cellDeg).rounded(.down))
        return ((c % width) + width) % width
    }

    func id(row: Int, col: Int) -> UInt8 {
        guard row >= 0, row < height else { return 0 }
        return ids[row * width + col]
    }

    func id(lat: Double, lon: Double) -> UInt8 {
        id(row: row(lat: lat), col: col(lon: lon))
    }
}

/// Vector borders of each continent or country, from the `.outline` files built by `Scripts/build_regions.py`.
final class RegionOutlines: @unchecked Sendable {
    /// Polygons, each a list of rings: the exterior first, then holes.
    typealias Polygons = [[[GeoPoint]]]

    static let continents = RegionOutlines(name: "continents")
    static let countries = RegionOutlines(name: "countries")

    private let regions: [Int: Polygons]

    private init?(name: String) {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Data/\(name).outline"),
              let compressed = try? Data(contentsOf: url),
              let raw = try? (compressed as NSData).decompressed(using: .zlib) as Data else { return nil }
        var regions: [Int: Polygons] = [:]
        raw.withUnsafeBytes { buf in
            var o = 0
            func u32() -> Int {
                defer { o += 4 }
                return Int(buf.loadUnaligned(fromByteOffset: o, as: UInt32.self))
            }
            for _ in 0..<u32() {
                let id = u32()
                regions[id] = (0..<u32()).map { _ in
                    (0..<u32()).map { _ in
                        (0..<u32()).map { _ in
                            defer { o += 8 }
                            return GeoPoint(lat: Double(buf.loadUnaligned(fromByteOffset: o + 4, as: Float.self)),
                                            lon: Double(buf.loadUnaligned(fromByteOffset: o, as: Float.self)))
                        }
                    }
                }
            }
        }
        self.regions = regions
    }

    func polygons(_ id: Int) -> Polygons? { regions[id] }
}

/// 100 m population boxes around big cities, from `Scripts/build_metros.py`.
final class Metros: @unchecked Sendable {
    struct Entry: Decodable, Sendable {
        let id: Int
        let name: String
        let country: String
        let total: Double
        let bounds: [Double]
    }

    static let shared = Metros()

    let entries: [Entry]
    private let directory: URL
    private var levels: [Int: PopulationLevel] = [:]
    private let lock = NSLock()

    private init?() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Data"),
              let json = try? Data(contentsOf: dir.appendingPathComponent("metros.json")),
              let meta = try? JSONDecoder().decode([String: [Entry]].self, from: json),
              let entries = meta["entries"] else { return nil }
        self.entries = entries
        directory = dir
    }

    func entry(_ id: Int) -> Entry? { entries.first { $0.id == id } }

    func level(_ id: Int) -> PopulationLevel? {
        lock.lock()
        defer { lock.unlock() }
        if let level = levels[id] { return level }
        let level = try? PopulationLevel(url: directory.appendingPathComponent("metro_\(id).pack"))
        levels[id] = level
        return level
    }
}

/// The kinds of round a player can turn on or off in Settings.
enum RoundType: String, CaseIterable, Codable, Sendable {
    case world, continent, country, city

    var title: String {
        switch self {
        case .world: "World"
        case .continent: "Continents"
        case .country: "Countries"
        case .city: "Cities"
        }
    }
}

/// What a round is locked to.
enum Region: Hashable, Codable, Sendable {
    case world
    case continent(Continent)
    case country(Int)
    case city(Int)

    var name: String {
        switch self {
        case .world: "the World"
        case .continent(let c): c.name
        case .country(let id): RegionMask.countries?.entry(id)?.name ?? "?"
        case .city(let id): Metros.shared?.entry(id)?.name ?? "?"
        }
    }

    /// Short label for chips and history rows.
    var label: String {
        switch self {
        case .world: "Anywhere on Earth"
        case .continent, .country: "in \(name)"
        case .city(let id): "in \(name), \(Metros.shared?.entry(id)?.country ?? "")"
        }
    }

    var type: RoundType {
        switch self {
        case .world: .world
        case .continent: .continent
        case .country: .country
        case .city: .city
        }
    }

    var kind: String {
        switch self {
        case .world: "World"
        case .continent: "Continent"
        case .country: "Country"
        case .city: "City"
        }
    }

    var symbol: String {
        switch self {
        case .world: "globe"
        case .continent(let c): c.symbol
        case .country: "flag.fill"
        case .city: "building.2.fill"
        }
    }

    /// Flag emoji for countries.
    var flag: String? {
        guard case .country(let id) = self, let code = RegionMask.countries?.entry(id)?.code else { return nil }
        return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }))
    }

    /// Camera area; nil for the whole world.
    var bounds: RegionBounds? {
        switch self {
        case .world: nil
        case .continent(let c): c.bounds
        case .country(let id): RegionBounds(RegionMask.countries?.entry(id)?.bounds)
        case .city(let id): RegionBounds(Metros.shared?.entry(id)?.bounds)
        }
    }

    var population: Double {
        switch self {
        case .world: 8.19e9
        case .continent(let c): RegionMask.continents?.entry(c.rawValue)?.total ?? 0
        case .country(let id): RegionMask.countries?.entry(id)?.total ?? 0
        case .city(let id): Metros.shared?.entry(id)?.total ?? 0
        }
    }

    /// Mask and id for continents and countries.
    var mask: (RegionMask, UInt8)? {
        switch self {
        case .continent(let c): RegionMask.continents.map { ($0, UInt8(c.rawValue)) }
        case .country(let id): RegionMask.countries.map { ($0, UInt8(id)) }
        case .world, .city: nil
        }
    }

    /// Border polygons for drawing the region; nil for the whole world.
    var outline: RegionOutlines.Polygons? {
        switch self {
        case .world: nil
        case .continent(let c): RegionOutlines.continents?.polygons(c.rawValue)
        case .country(let id): RegionOutlines.countries?.polygons(id)
        case .city: bounds.map { b in
            [[[GeoPoint(lat: b.maxLat, lon: b.minLon), GeoPoint(lat: b.maxLat, lon: b.maxLon),
               GeoPoint(lat: b.minLat, lon: b.maxLon), GeoPoint(lat: b.minLat, lon: b.minLon)]]]
        }
        }
    }

    func contains(lat: Double, lon: Double) -> Bool {
        switch self {
        case .world: true
        case .continent, .country: mask.map { $0.0.id(lat: lat, lon: lon) == $0.1 } ?? false
        case .city: bounds?.contains(lat: lat, lon: lon) ?? false
        }
    }

    /// How many rounds a country or city sits out after it's played.
    static let repeatGap = 30

    /// World 25%, continents 25%, countries 37.5%, cities 12.5%, among the `allowed` types. Never repeats the
    /// previous region, and countries and cities never come back while they're in `recent` (oldest first, most recent last).
    static func random(after recent: [Region], allowed: Set<RoundType> = Set(RoundType.allCases)) -> Region {
        let countries = RegionMask.countries?.entries.map { Region.country($0.id) } ?? []
        let cities = Metros.shared?.entries.map { Region.city($0.id) } ?? []
        let pools: [(Double, [Region])] = [
            (0.2, [.world]),
            (0.2, Continent.allCases.map(Region.continent)),
            (0.3, countries),
            (0.1, cities),
        ].filter { !$0.1.isEmpty && $0.1.first.map { allowed.contains($0.type) } == true }
        for _ in 0..<20 {
            var roll = Double.random(in: 0..<pools.map(\.0).reduce(0, +))
            let pool = pools.first { roll -= $0.0; return roll < 0 } ?? pools[0]
            guard let pick = pool.1.randomElement() else { continue }
            switch pick {
            case .country, .city: if !recent.suffix(repeatGap).contains(pick) { return pick }
            case .world, .continent: if pick != recent.last { return pick }
            }
        }
        return pools.first?.1.randomElement() ?? .world
    }
}
