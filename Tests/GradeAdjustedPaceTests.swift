import XCTest
@testable import FitnessTracker

/// Grade-adjusted pace.
///
/// The cost curve is easy to get backwards — an uphill kilometre has to make
/// the flat-equivalent pace *faster*, not slower — and the gradient is easy to
/// compute from noise. Both failures produce a number rather than an error.
final class GradeAdjustedPaceTests: XCTestCase {

    /// A run at a constant speed on a constant gradient, sampled every second.
    private func run(
        seconds: Int,
        metresPerSecond: Double,
        gradient: Double
    ) -> [FITSample] {
        (0..<seconds).map { t in
            let distance = Double(t) * metresPerSecond
            return FITSample(t: TimeInterval(t),
                             alt: 100 + distance * gradient,
                             speed: metresPerSecond,
                             dist: distance)
        }
    }

    // MARK: - The cost curve

    func testFlatCostMatchesThePolynomialConstant() {
        XCTAssertEqual(GradeAdjustedPace.costOfRunning(gradient: 0),
                       GradeAdjustedPace.flatCost, accuracy: 0.0001)
    }

    func testUphillCostsMoreThanFlat() {
        XCTAssertGreaterThan(GradeAdjustedPace.costOfRunning(gradient: 0.10),
                             GradeAdjustedPace.costOfRunning(gradient: 0))
    }

    func testAGentleDownhillCostsLessThanFlat() {
        XCTAssertLessThan(GradeAdjustedPace.costOfRunning(gradient: -0.10),
                          GradeAdjustedPace.costOfRunning(gradient: 0))
    }

    func testAVerySteepDownhillCostsMoreThanAGentleOne() {
        // The curve turns back up: braking on a wall is expensive. Getting this
        // wrong would hand runners free speed on every steep descent.
        XCTAssertGreaterThan(GradeAdjustedPace.costOfRunning(gradient: -0.30),
                             GradeAdjustedPace.costOfRunning(gradient: -0.15))
    }

    func testExtremeGradientsAreClampedRatherThanExtrapolated() {
        XCTAssertEqual(GradeAdjustedPace.costOfRunning(gradient: 0.9),
                       GradeAdjustedPace.costOfRunning(gradient: GradeAdjustedPace.clamp.upperBound),
                       accuracy: 0.0001)
        XCTAssertEqual(GradeAdjustedPace.costOfRunning(gradient: -0.9),
                       GradeAdjustedPace.costOfRunning(gradient: GradeAdjustedPace.clamp.lowerBound),
                       accuracy: 0.0001)
    }

    // MARK: - The adjustment

    func testFlatRunningIsNotAdjusted() throws {
        let samples = run(seconds: 1_200, metresPerSecond: 3.0, gradient: 0)
        let result = try XCTUnwrap(GradeAdjustedPace.analyse(samples: samples, sport: .run))

        XCTAssertEqual(result.adjustedPaceSecPerKm, result.actualPaceSecPerKm, accuracy: 0.01)
        XCTAssertFalse(result.isWorthShowing)
    }

    func testClimbingMakesTheFlatEquivalentPaceFaster() throws {
        // 3 m/s up a steady 8% is 5:33/km on the clock and a much better run
        // than that number suggests.
        let samples = run(seconds: 1_200, metresPerSecond: 3.0, gradient: 0.08)
        let result = try XCTUnwrap(GradeAdjustedPace.analyse(samples: samples, sport: .run))

        XCTAssertLessThan(result.adjustedPaceSecPerKm, result.actualPaceSecPerKm)
        XCTAssertTrue(result.isWorthShowing)
        XCTAssertEqual(result.actualPaceSecPerKm, 1000.0 / 3.0, accuracy: 1)
        XCTAssertEqual(result.gradientPerKm, 80, accuracy: 1)
    }

    func testAGentleDescentMakesTheFlatEquivalentPaceSlower() throws {
        let samples = run(seconds: 1_200, metresPerSecond: 3.0, gradient: -0.08)
        let result = try XCTUnwrap(GradeAdjustedPace.analyse(samples: samples, sport: .run))

        XCTAssertGreaterThan(result.adjustedPaceSecPerKm, result.actualPaceSecPerKm)
        XCTAssertEqual(result.gradientPerKm, 0, accuracy: 0.01)
    }

    func testAnOutAndBackIsNearlyUnadjusted() throws {
        // Up for ten minutes, down the same slope for ten. The two adjustments
        // don't cancel exactly — the curve isn't symmetric — but they should
        // land far closer to flat than either half alone.
        let up = run(seconds: 600, metresPerSecond: 3.0, gradient: 0.08)
        let downStart = up.last!
        let down = (1...600).map { t -> FITSample in
            let distance = (downStart.dist ?? 0) + Double(t) * 3.0
            return FITSample(t: downStart.t + TimeInterval(t),
                             alt: (downStart.alt ?? 0) - Double(t) * 3.0 * 0.08,
                             speed: 3.0, dist: distance)
        }
        let result = try XCTUnwrap(GradeAdjustedPace.analyse(samples: up + down, sport: .run))

        let drift = abs(result.differenceSeconds) / result.actualPaceSecPerKm
        XCTAssertLessThan(drift, 0.12)
    }

    // MARK: - Refusals

    func testWalkingAndHikingAreNotAdjusted() {
        // Minetti measured runners. The walking curve is a different shape, and
        // running costs applied to a hike overstate the climb badly.
        let samples = run(seconds: 1_200, metresPerSecond: 1.4, gradient: 0.10)
        XCTAssertNil(GradeAdjustedPace.analyse(samples: samples, sport: .hike))
        XCTAssertNil(GradeAdjustedPace.analyse(samples: samples, sport: .walk))
    }

    func testAStreamWithoutAltitudeIsNotAdjusted() {
        let samples = (0..<1_200).map { t in
            FITSample(t: TimeInterval(t), speed: 3.0, dist: Double(t) * 3.0)
        }
        XCTAssertNil(GradeAdjustedPace.analyse(samples: samples, sport: .run))
    }

    func testAStreamWithoutDistanceIsNotAdjusted() {
        let samples = (0..<1_200).map { t in
            FITSample(t: TimeInterval(t), alt: 100, speed: 3.0)
        }
        XCTAssertNil(GradeAdjustedPace.analyse(samples: samples, sport: .run))
    }

    func testAVeryShortRunIsNotAdjusted() {
        let samples = run(seconds: 20, metresPerSecond: 3.0, gradient: 0.05)
        XCTAssertNil(GradeAdjustedPace.analyse(samples: samples, sport: .run))
    }

    // MARK: - Altitude noise

    func testAltitudeNoiseOnAFlatRunDoesNotInventAnAdjustment() throws {
        // ±1.5 m of jitter every second on a flat route. Read per-sample, that
        // is a 50% gradient; read over 30 m chunks it is nothing.
        var generator = SystemRandomNumberGenerator()
        let samples = (0..<1_800).map { t -> FITSample in
            let jitter = Double.random(in: -1.5...1.5, using: &generator)
            return FITSample(t: TimeInterval(t),
                             alt: 100 + jitter,
                             speed: 3.0,
                             dist: Double(t) * 3.0)
        }
        let result = try XCTUnwrap(GradeAdjustedPace.analyse(samples: samples, sport: .run))

        let drift = abs(result.differenceSeconds) / result.actualPaceSecPerKm
        XCTAssertLessThan(drift, 0.05, "altitude noise moved the pace by \(Int(drift * 100))%")
    }
}
