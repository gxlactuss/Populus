import XCTest
@testable import Populus

final class PopulationGridTests: XCTestCase {
    private var grid: PopulationGrid { PopulationGrid.shared! }

    private func box(lat: ClosedRange<Double>, lon: ClosedRange<Double>) -> [GeoPoint] {
        [GeoPoint(lat: lat.upperBound, lon: lon.lowerBound), GeoPoint(lat: lat.upperBound, lon: lon.upperBound),
         GeoPoint(lat: lat.lowerBound, lon: lon.upperBound), GeoPoint(lat: lat.lowerBound, lon: lon.lowerBound)]
    }

    func testDataLoads() {
        XCTAssertNotNil(PopulationGrid.shared)
        XCTAssertEqual(grid.levels.first?.width, 43200)
    }

    func testWorldTotal() {
        let r = grid.population(in: box(lat: -89.99...89.99, lon: -179.999...179.999))
        XCTAssert((8.0e9...8.4e9).contains(r.total), "\(r.total)")
    }

    func testIceland() {
        let r = grid.population(in: box(lat: 63.2...66.6, lon: -24.6 ... -13.4))
        XCTAssert((3.0e5...4.5e5).contains(r.total), "\(r.total)")
    }

    func testTokyo() {
        let r = grid.population(in: box(lat: 35.3...36.0, lon: 139.3...140.1))
        XCTAssertEqual(r.levelIndex, 0)
        XCTAssert((2.0e7...4.0e7).contains(r.total), "\(r.total)")
        XCTAssert(r.peakDensity > 10_000, "\(r.peakDensity)")
    }

    func testLevelsAgree() {
        let france = box(lat: 42...51, lon: -5...8)
        let fine = grid.population(in: france, level: 0).total
        let coarse = grid.population(in: france, level: 1).total
        XCTAssertEqual(coarse / fine, 1, accuracy: 0.02)
    }

    func testAntimeridianWraps() {
        // Fiji straddles 180°; an unwrapped box should match the two halves added together.
        let wrapped = grid.population(in: box(lat: -19.5 ... -15.5, lon: 176...182), level: 0).total
        let west = grid.population(in: box(lat: -19.5 ... -15.5, lon: 176...180), level: 0).total
        let east = grid.population(in: box(lat: -19.5 ... -15.5, lon: -180 ... -178), level: 0).total
        XCTAssertGreaterThan(wrapped, 5e5)
        XCTAssertEqual(wrapped, west + east, accuracy: wrapped * 0.01)
    }

    func testTinyShapeUsesDensity() {
        let r = grid.population(in: box(lat: 35.6895...35.6905, lon: 139.6995...139.7005))
        XCTAssertGreaterThan(r.total, 0)
    }

    func testSphericalArea() {
        let a = PopulationGrid.sphericalAreaKm2(box(lat: 0...1, lon: 0...1))
        XCTAssertEqual(a, 12_364, accuracy: 50)
    }

    func testRasterizerSquare() {
        let sq: [SIMD2<Double>] = [[0, 0], [10, 0], [10, 10], [0, 10]]
        var cells = 0
        PolygonRasterizer.forEachSpan(sq, rowCount: 100) { _, c0, c1 in cells += c1 - c0 }
        XCTAssertEqual(cells, 100)
    }

    func testRasterizerCircle() {
        let r = 200.0
        let circle = (0..<720).map { i -> SIMD2<Double> in
            let t = Double(i) / 720 * 2 * .pi
            return [500 + r * cos(t), 500 + r * sin(t)]
        }
        var cells = 0
        PolygonRasterizer.forEachSpan(circle, rowCount: 1000) { _, c0, c1 in cells += c1 - c0 }
        XCTAssertEqual(Double(cells), .pi * r * r, accuracy: .pi * r * r * 0.01)
    }

    func testFreehandLoopEndingAtStartIsKept() {
        // A stroke that ends on the exact point it started from.
        let loop = (0...60).map { i -> CGPoint in
            let t = Double(i) / 60 * 2 * .pi
            return CGPoint(x: 100 + 90 * cos(t), y: 100 + 90 * sin(t))
        }
        XCTAssert(ShapeTools.isUsable(ShapeTools.smoothFreehand(loop)))
    }

    func testCities() {
        let hits = Cities.largest(in: box(lat: 35.3...36.0, lon: 139.3...140.1))
        XCTAssertEqual(hits.first?.name, "Tokyo")
    }


    func testNumberGroupingIgnoresRegion() {
        XCTAssertEqual(Format.integer(2_831_874), "2,831,874")
    }

    func testContinentFilter() {
        // A box over the Strait of Gibraltar holds parts of Spain and Morocco.
        let gibraltar = box(lat: 34...37.5, lon: -7 ... -4)
        let all = grid.population(in: gibraltar).total
        let europe = grid.population(in: gibraltar, region: .continent(.europe)).total
        let africa = grid.population(in: gibraltar, region: .continent(.africa)).total
        XCTAssertGreaterThan(europe, 1e6)
        XCTAssertGreaterThan(africa, 1e6)
        XCTAssertEqual(europe + africa, all, accuracy: all * 0.02)
    }

    private func country(_ name: String) -> Region {
        .country(RegionMask.countries!.entries.first { $0.name == name }!.id)
    }

    private func city(_ name: String) -> Region {
        .city(Metros.shared!.entries.first { $0.name == name }!.id)
    }

    func testRegionTotalsAreFair() {
        XCTAssert((4e9...5.5e9).contains(Region.continent(.asia).population))
        XCTAssert((1.3e9...1.6e9).contains(country("India").population))
        XCTAssert((4e6...7e6).contains(country("Norway").population))
        XCTAssertEqual(RegionMask.countries!.entries.count, 31)
        XCTAssertTrue(country("France").contains(lat: 48.85, lon: 2.35))
        XCTAssertFalse(country("France").contains(lat: 50.85, lon: 4.35)) // Brussels
        XCTAssertTrue(Region.continent(.oceania).contains(lat: -33.87, lon: 151.2))
    }

    func testOutlines() {
        for c in Continent.allCases { XCTAssertNotNil(Region.continent(c).outline, c.name) }
        for e in RegionMask.countries!.entries { XCTAssertNotNil(Region.country(e.id).outline, e.name) }
        XCTAssertGreaterThan(country("Japan").outline!.count, 50) // islands
        let poland = country("Poland").outline!.joined().joined()
        XCTAssertEqual(poland.map(\.lat).max()!, 54.8, accuracy: 0.1)
        XCTAssertEqual(poland.map(\.lon).min()!, 14.1, accuracy: 0.1)
        XCTAssertNil(Region.world.outline)
    }

    func testDensityBlockMatchesCells() {
        // Fiji, straddling the antimeridian.
        let level = grid.levels[1]
        let col0 = level.width - 6, row0 = 2120, cols = 12, rows = 20
        let block = level.densities(col0: col0, row0: row0, cols: cols, rows: rows)
        XCTAssertGreaterThan(block.reduce(0, +), 0)
        for r in 0..<rows {
            for c in 0..<cols {
                let expected = Double(level.value(col: col0 + c, row: row0 + r)) / level.cellArea(row: row0 + r)
                XCTAssertEqual(Double(block[r * cols + c]), expected, accuracy: expected * 1e-5 + 1e-9)
            }
        }
    }

    func testCountryFilterExcludesNeighbours() {
        // Box over the India / Bangladesh border around Kolkata and Dhaka.
        let b = box(lat: 21.5...25, lon: 87...91.5)
        let all = grid.population(in: b).total
        let india = grid.population(in: b, region: country("India")).total
        let bangladesh = grid.population(in: b, region: country("Bangladesh")).total
        XCTAssertGreaterThan(india, 2e7)
        XCTAssertGreaterThan(bangladesh, 5e7)
        XCTAssertEqual(india + bangladesh, all, accuracy: all * 0.03)
    }

    func testCityUsesFineGrid() {
        let manhattan = [GeoPoint(lat: 40.80, lon: -73.97), GeoPoint(lat: 40.80, lon: -73.93),
                         GeoPoint(lat: 40.70, lon: -74.00), GeoPoint(lat: 40.70, lon: -74.02)]
        let fine = grid.population(in: manhattan, region: city("New York"))
        XCTAssertEqual(fine.levelIndex, -1)
        XCTAssert((5e5...2.5e6).contains(fine.total), "\(fine.total)")
        // Outside the city's box nothing counts.
        XCTAssertEqual(grid.population(in: box(lat: 10...11, lon: 10...11), region: city("New York")).total, 0)
        // The whole box roughly matches the 1 km grid over the same area.
        let b = RegionBounds(Metros.shared!.entry(city("New York").cityID)!.bounds)!
        let whole = box(lat: b.minLat...b.maxLat, lon: b.minLon...b.maxLon)
        XCTAssertEqual(grid.population(in: whole, region: city("New York")).total,
                       grid.population(in: whole, level: 0).total, accuracy: 2e6)
    }

    @MainActor func testWorldTargetsSpreadAcrossMagnitudes() {
        var decades = Set<Int>()
        for _ in 0..<500 {
            let t = GameState.randomTarget(in: GameState.worldRange, avoiding: nil)
            XCTAssert(GameState.worldRange.contains(t), "\(t)")
            decades.insert(Int(log10(t)))
        }
        XCTAssertEqual(decades, [5, 6, 7, 8, 9])
    }

    func testRandomRegionsCoverAllKinds() {
        var kinds = Set<String>()
        var recent: [Region] = []
        for _ in 0..<300 {
            let r = Region.random(after: recent)
            XCTAssertNotEqual(r, recent.last)
            kinds.insert(r.kind)
            recent.append(r)
        }
        XCTAssertEqual(kinds, ["World", "Continent", "Country", "City"])
    }

    func testCountriesAndCitiesDontRepeatSoon() {
        var recent: [Region] = []
        for _ in 0..<1000 {
            let r = Region.random(after: recent)
            switch r {
            case .country, .city: XCTAssertFalse(recent.suffix(Region.repeatGap).contains(r), "\(r.name) came back too soon")
            case .world, .continent: break
            }
            recent.append(r)
        }
    }
}

private extension Region {
    var cityID: Int {
        if case .city(let id) = self { return id }
        return 0
    }
}
