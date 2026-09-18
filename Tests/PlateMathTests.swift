import XCTest
@testable import FitnessTracker

final class PlateMathTests: XCTestCase {

    private func perSide(_ loading: PlateMath.Loading) -> [Double] {
        loading.perSide.flatMap { Array(repeating: $0.kilograms, count: $0.count) }
    }

    func testSimpleExactLoad() {
        let loading = PlateMath.load(target: 100, bar: 20)
        XCTAssertTrue(loading.isExact)
        XCTAssertEqual(loading.total, 100, accuracy: 0.001)
        // 25+15 and 20+20 both make 40 a side in two plates. The search settles
        // on the one denomination, which is also what a gym actually loads —
        // and settles on it deterministically, which matters more: an answer
        // that flickers between two right answers is a bad answer.
        XCTAssertEqual(perSide(loading), [20, 20])
    }

    /// The case a greedy heaviest-first walk gets wrong.
    ///
    /// 30 kg a side: greedy takes the 25, can't place the remaining 5 from
    /// 25/20/15/10, and reports 25 with a 10 kg shortfall. 20 + 10 is exact.
    func testGreedyFailureCaseIsSolvedExactly() {
        let inventory = [
            PlateMath.Plate(25, countPerSide: 2),
            PlateMath.Plate(20, countPerSide: 2),
            PlateMath.Plate(15, countPerSide: 2),
            PlateMath.Plate(10, countPerSide: 2),
        ]
        let loading = PlateMath.load(target: 80, bar: 20, inventory: inventory)
        XCTAssertTrue(loading.isExact, "expected an exact 30 kg a side, got \(perSide(loading))")
        XCTAssertEqual(perSide(loading).reduce(0, +), 30, accuracy: 0.001)
        XCTAssertEqual(loading.plateCountPerSide, 2)
    }

    func testPrefersFewerPlatesForTheSameWeight() {
        // 20 a side is reachable as 20, or 10+10, or 5+5+5+5.
        let loading = PlateMath.load(target: 60, bar: 20)
        XCTAssertTrue(loading.isExact)
        XCTAssertEqual(loading.plateCountPerSide, 1)
        XCTAssertEqual(perSide(loading), [20])
    }

    func testRespectsPlateCounts() {
        // 50 a side. With two 25s it would be 25+25; there's only one, so the
        // best available is 25+20+5.
        let inventory = [
            PlateMath.Plate(25, countPerSide: 1),
            PlateMath.Plate(20, countPerSide: 4),
            PlateMath.Plate(5, countPerSide: 4),
        ]
        let loading = PlateMath.load(target: 120, bar: 20, inventory: inventory)
        XCTAssertTrue(loading.isExact)
        XCTAssertEqual(perSide(loading), [25, 20, 5])
    }

    func testNeverExceedsTheTarget() {
        // 101 kg is not reachable on a 1.25 kg grid; 100 is the closest under.
        let loading = PlateMath.load(target: 101, bar: 20)
        XCTAssertFalse(loading.isExact)
        XCTAssertLessThanOrEqual(loading.total, 101)
        XCTAssertEqual(loading.total, 100, accuracy: 0.001)
        XCTAssertEqual(loading.shortfall, 1, accuracy: 0.001)
    }

    func testTargetBelowBarIsBarOnly() {
        let loading = PlateMath.load(target: 15, bar: 20)
        XCTAssertTrue(loading.isBarOnly)
        XCTAssertEqual(loading.total, 20, accuracy: 0.001)
        XCTAssertEqual(loading.shortfall, 0, accuracy: 0.001)
    }

    func testTargetEqualToBarIsBarOnly() {
        let loading = PlateMath.load(target: 20, bar: 20)
        XCTAssertTrue(loading.isBarOnly)
        XCTAssertTrue(loading.isExact)
    }

    func testSmallestIncrementIsReachable() {
        // Bar plus one 1.25 a side.
        let loading = PlateMath.load(target: 22.5, bar: 20)
        XCTAssertTrue(loading.isExact)
        XCTAssertEqual(perSide(loading), [1.25])
    }

    func testEmptyInventoryDegradesToBarOnly() {
        let loading = PlateMath.load(target: 100, bar: 20, inventory: [])
        XCTAssertTrue(loading.isBarOnly)
        XCTAssertEqual(loading.shortfall, 80, accuracy: 0.001)
    }

    func testPlatesWithZeroCountAreIgnored() {
        let inventory = [PlateMath.Plate(25, countPerSide: 0), PlateMath.Plate(10, countPerSide: 4)]
        let loading = PlateMath.load(target: 60, bar: 20, inventory: inventory)
        XCTAssertEqual(perSide(loading), [10, 10])
    }

    func testImperialSetLoadsWholePoundTargets() {
        let bar = PlateMath.bar(metric: false)
        // 225 lb: bar plus 45+45 a side.
        let target = 225 * UnitConversion.kilogramsPerPound
        let loading = PlateMath.load(target: target, bar: bar,
                                     inventory: PlateMath.inventory(metric: false))
        XCTAssertTrue(loading.isExact, "shortfall was \(loading.shortfall) kg")
        XCTAssertEqual(loading.plateCountPerSide, 2)
    }

    func testHeaviestFirstIsLoadingOrder() {
        let loading = PlateMath.load(target: 142.5, bar: 20)
        let weights = loading.perSide.map(\.kilograms)
        XCTAssertEqual(weights, weights.sorted(by: >))
    }

    /// The search runs between sets, so it has to be quick even for a loaded bar.
    func testHeavyTargetStaysFast() {
        let started = Date()
        let loading = PlateMath.load(target: 300, bar: 20)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        XCTAssertLessThanOrEqual(loading.total, 300)
    }
}
