import XCTest
@testable import FitnessTracker

/// The critical power / critical speed fit.
///
/// A least-squares line always returns two numbers. The job of these tests is
/// to check that the two numbers mean what the labels say, and that a curve
/// which isn't a hyperbola is refused instead of being rounded into one.
final class CriticalPowerTests: XCTestCase {

    // MARK: - Builders

    /// A duration curve generated from a known model, so the fit has a right
    /// answer to recover.
    private func powerCurve(
        criticalPower: Double,
        wPrime: Double,
        durations: [TimeInterval] = [120, 300, 600, 1_200]
    ) -> [DurationCurve.Point] {
        durations.map { duration in
            DurationCurve.Point(duration: duration,
                                value: criticalPower + wPrime / duration,
                                workoutID: UUID(),
                                date: .now)
        }
    }

    private func paceCurve(
        criticalSpeed: Double,
        dPrime: Double,
        durations: [TimeInterval] = [120, 300, 600, 1_200]
    ) -> [DurationCurve.Point] {
        durations.map { duration in
            let speed = criticalSpeed + dPrime / duration
            return DurationCurve.Point(duration: duration,
                                       value: 1000 / speed,          // sec per km
                                       workoutID: UUID(),
                                       date: .now)
        }
    }

    // MARK: - Recovering the model

    func testAPerfectHyperbolaRecoversItsOwnParameters() throws {
        let model = try XCTUnwrap(
            CriticalPower.fit(powerCurve(criticalPower: 270, wPrime: 20_000),
                              metric: .power))

        XCTAssertEqual(model.critical, 270, accuracy: 0.5)
        XCTAssertEqual(model.reserve, 20_000, accuracy: 50)
        XCTAssertEqual(model.fitQuality, 1.0, accuracy: 0.0001)
        XCTAssertEqual(model.pointsUsed, 4)
        XCTAssertTrue(model.reserveIsEnergy)
    }

    func testAPaceCurveRecoversCriticalSpeedInMetresPerSecond() throws {
        // 4.2 m/s is about 3:58/km; 220 m of distance reserve is a typical D′.
        let model = try XCTUnwrap(
            CriticalPower.fit(paceCurve(criticalSpeed: 4.2, dPrime: 220),
                              metric: .pace))

        XCTAssertEqual(model.critical, 4.2, accuracy: 0.01)
        XCTAssertEqual(model.reserve, 220, accuracy: 2)
        XCTAssertFalse(model.reserveIsEnergy)
    }

    func testTheFitIgnoresPointsOutsideItsWindow() throws {
        // A five-second sprint sits far above the hyperbola. Including it would
        // drag critical power up and W′ down; the window exists to exclude it.
        var curve = powerCurve(criticalPower: 270, wPrime: 20_000)
        curve.append(DurationCurve.Point(duration: 5, value: 1_100,
                                         workoutID: UUID(), date: .now))

        let model = try XCTUnwrap(CriticalPower.fit(curve, metric: .power))

        XCTAssertEqual(model.critical, 270, accuracy: 0.5)
        XCTAssertEqual(model.pointsUsed, 4)
        XCTAssertEqual(model.span.lowerBound, 120)
        XCTAssertEqual(model.span.upperBound, 1_200)
    }

    // MARK: - Predictions

    func testThePredictionMatchesTheCurveItWasFittedTo() throws {
        let model = try XCTUnwrap(
            CriticalPower.fit(powerCurve(criticalPower: 270, wPrime: 20_000),
                              metric: .power))

        // 20 000 J spent over 300 s is 66.7 W above critical.
        XCTAssertEqual(try XCTUnwrap(model.predicted(at: 300)), 336.7, accuracy: 1)
    }

    func testTimeToExhaustionSpendsTheReserve() throws {
        let model = try XCTUnwrap(
            CriticalPower.fit(powerCurve(criticalPower: 270, wPrime: 20_000),
                              metric: .power))

        // 50 W above critical burns 20 kJ in 400 seconds.
        XCTAssertEqual(try XCTUnwrap(model.timeToExhaustion(at: 320)), 400, accuracy: 2)
    }

    func testThereIsNoTimeToExhaustionAtOrBelowCritical() throws {
        let model = try XCTUnwrap(
            CriticalPower.fit(powerCurve(criticalPower: 270, wPrime: 20_000),
                              metric: .power))

        XCTAssertNil(model.timeToExhaustion(at: 270))
        XCTAssertNil(model.timeToExhaustion(at: 200))
    }

    // MARK: - Refusals

    func testTwoPointsAreNotEnough() {
        let curve = powerCurve(criticalPower: 270, wPrime: 20_000, durations: [300, 1_200])
        XCTAssertNil(CriticalPower.fit(curve, metric: .power))
    }

    func testEffortsBunchedTogetherAreRefused() {
        // 300 s to 600 s is only a 2× span — the intercept from a line through
        // those is mostly noise, whatever its R².
        let curve = powerCurve(criticalPower: 270, wPrime: 20_000,
                               durations: [300, 420, 600])
        XCTAssertNil(CriticalPower.fit(curve, metric: .power))
    }

    func testACurveThatIsNotAHyperbolaIsRefused() {
        // Best efforts that rise with duration: the athlete never went hard on
        // the short ones. A line still fits *something*; it shouldn't be sold
        // as critical power.
        let curve: [DurationCurve.Point] = [
            (120.0, 200.0), (300.0, 260.0), (600.0, 250.0), (1_200.0, 320.0),
        ].map { DurationCurve.Point(duration: $0.0, value: $0.1,
                                    workoutID: UUID(), date: .now) }

        XCTAssertNil(CriticalPower.fit(curve, metric: .power))
    }

    func testAFlatCurveGivesNoReserveAndIsRefused() {
        // Identical power at every duration means W′ is zero: nothing was ever
        // spent above threshold, so there is no tank to measure.
        let curve = [120.0, 300.0, 600.0, 1_200.0].map {
            DurationCurve.Point(duration: $0, value: 250, workoutID: UUID(), date: .now)
        }
        XCTAssertNil(CriticalPower.fit(curve, metric: .power))
    }

    func testAnEmptyCurveIsRefused() {
        XCTAssertNil(CriticalPower.fit([], metric: .power))
    }

    // MARK: - Tolerance to real data

    func testASlightlyNoisyCurveStillFits() throws {
        // ±2% scatter, which is about what honest maximal efforts from separate
        // days look like. The model should survive that.
        let jitter = [1.02, 0.985, 1.01, 0.99]
        let curve = zip([120.0, 300.0, 600.0, 1_200.0], jitter).map { duration, scale in
            DurationCurve.Point(duration: duration,
                                value: (270 + 20_000 / duration) * scale,
                                workoutID: UUID(), date: .now)
        }
        let model = try XCTUnwrap(CriticalPower.fit(curve, metric: .power))

        XCTAssertEqual(model.critical, 270, accuracy: 15)
        XCTAssertGreaterThan(model.fitQuality, CriticalPower.minimumFitQuality)
    }
}
