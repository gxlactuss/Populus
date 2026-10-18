import XCTest
@testable import Populus

final class LaunchFeatureTests: XCTestCase {
    func testRandomRegionKeepsToAllowedTypes() {
        for allowed: Set<RoundType> in [[.world], [.continent], [.country], [.city], [.country, .city]] {
            var recent: [Region] = []
            for _ in 0..<100 {
                let r = Region.random(after: recent, allowed: allowed)
                XCTAssert(allowed.contains(r.type), "\(r) not in \(allowed)")
                recent = Array((recent + [r]).suffix(Region.repeatGap))
            }
        }
    }

    private func release(_ tag: String, prerelease: Bool = false) -> UpdateChecker.Release {
        UpdateChecker.Release(tagName: tag, htmlURL: URL(string: "https://example.com/\(tag)")!,
                              draft: false, prerelease: prerelease)
    }

    func testNewestReleaseSkipsDataAndPrereleases() {
        let releases = [release("data-v1"), release("v1.0.0"), release("v1.1.0"), release("v2.0.0", prerelease: true)]
        XCTAssertEqual(UpdateChecker.newest(in: releases, newerThan: "1.0.0")?.tagName, "v1.1.0")
        XCTAssertNil(UpdateChecker.newest(in: releases, newerThan: "1.1.0"))
    }

    func testVersionsCompareNumerically() {
        XCTAssertEqual(UpdateChecker.newest(in: [release("v1.9.0"), release("v1.10.0")], newerThan: "1.2")?.tagName, "v1.10.0")
    }
}
