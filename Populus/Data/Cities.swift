import Foundation

struct CityHit: Codable, Hashable, Sendable {
    var name: String
    var country: String
    var population: Int
}

enum Cities {
    private struct City: Decodable {
        let n: String
        let c: String
        let lat: Double
        let lon: Double
        let p: Int
    }

    /// Sorted by population, largest first.
    private static let all: [City] = {
        guard let url = Bundle.main.url(forResource: "cities", withExtension: "json", subdirectory: "Data"),
              let data = try? Data(contentsOf: url),
              let cities = try? JSONDecoder().decode([City].self, from: data) else { return [] }
        return cities
    }()

    static func largest(in polygon: [GeoPoint], limit: Int = 4, region: Region? = nil) -> [CityHit] {
        guard polygon.count >= 3 else { return [] }
        let lats = polygon.map(\.lat), lons = polygon.map(\.lon)
        let minLat = lats.min()!, maxLat = lats.max()!, minLon = lons.min()!, maxLon = lons.max()!
        var hits: [CityHit] = []
        for city in all where city.lat >= minLat && city.lat <= maxLat {
            if let region, !region.contains(lat: city.lat, lon: city.lon) { continue }
            // Longitudes in the polygon may be unwrapped past ±180.
            let inside = [city.lon, city.lon + 360, city.lon - 360].contains { lon in
                lon >= minLon && lon <= maxLon && contains(polygon, lat: city.lat, lon: lon)
            }
            if inside {
                hits.append(CityHit(name: city.n, country: city.c, population: city.p))
                if hits.count == limit { break }
            }
        }
        return hits
    }

    private static func contains(_ p: [GeoPoint], lat: Double, lon: Double) -> Bool {
        var inside = false
        var j = p.count - 1
        for i in p.indices {
            let a = p[j], b = p[i]
            if (a.lat <= lat) != (b.lat <= lat),
               lon < a.lon + (lat - a.lat) * (b.lon - a.lon) / (b.lat - a.lat) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
