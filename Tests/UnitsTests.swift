import XCTest
import SwiftUI
@testable import FitnessTracker

/// Unit conversion is display-only, and the tests are written to hold that line:
/// stored values stay SI, conversions are checked against known equivalences,
/// and a round trip through the imperial path must come back unchanged.
final class UnitsTests: XCTestCase {

    private let metric = UnitFormatter(.metric)
    private let imperial = UnitFormatter(.imperial)

    // MARK: - Distance

    func testDistanceInBothSystems() {
        XCTAssertEqual(metric.distance(8_240), "8.24 km")
        // 8240 m = 5.1201… mi
        XCTAssertEqual(imperial.distance(8_240), "5.12 mi")
        XCTAssertEqual(metric.distance(42_195, decimals: 1), "42.2 km")
        XCTAssertEqual(imperial.distance(42_195, decimals: 1), "26.2 mi")
    }

    /// A marathon is 26.2 miles. If this drifts, the conversion constant is wrong.
    func testMarathonIsTwentySixPointTwoMiles() {
        XCTAssertEqual(imperial.distance(42_195, decimals: 1), "26.2 mi")
        XCTAssertEqual(imperial.distance(21_097.5, decimals: 1), "13.1 mi")
    }

    func testShortDistanceUsesYards() {
        XCTAssertEqual(metric.shortDistance(400), "400 m")
        // 400 m = 437.4 yd
        XCTAssertEqual(imperial.shortDistance(400), "437 yd")
    }

    /// A 400 m rep should read in metres, a 10 km run in kilometres.
    func testAutoDistancePicksTheScale() {
        XCTAssertEqual(metric.autoDistance(400), "400 m")
        XCTAssertEqual(metric.autoDistance(10_000), "10.00 km")
        XCTAssertEqual(imperial.autoDistance(400), "437 yd")
        XCTAssertEqual(imperial.autoDistance(10_000), "6.21 mi")
        // Just under a mile still reads short in imperial.
        XCTAssertEqual(imperial.autoDistance(1_500), "1640 yd")
    }

    func testElevationUsesFeetNotYards() {
        XCTAssertEqual(metric.elevation(1_092), "1092 m")
        // 1092 m = 3582.7 ft
        XCTAssertEqual(imperial.elevation(1_092), "3583 ft")
        XCTAssertEqual(imperial.elevation(nil), "–")
    }

    // MARK: - Pace

    func testPaceConvertsPerMile() {
        // 4:35/km → 4:35 × 1.609344 = 442.8 s/mi = 7:23/mi
        XCTAssertEqual(metric.pace(275), "4:35/km")
        XCTAssertEqual(imperial.pace(275), "7:23/mi")
    }

    /// Faster per kilometre must stay faster per mile — the ordering the whole
    /// splits table depends on.
    func testPaceOrderingSurvivesConversion() {
        let fast = try? XCTUnwrap(imperial.paceValue(240))
        let slow = try? XCTUnwrap(imperial.paceValue(300))
        XCTAssertLessThan(fast ?? 0, slow ?? 0)
    }

    func testSwimPaceUsesHundredYards() {
        // 1:45/100 m → ×0.9144 = 96.0 s = 1:36/100 yd
        XCTAssertEqual(metric.swimPace(105), "1:45/100 m")
        XCTAssertEqual(imperial.swimPace(105), "1:36/100 yd")
    }

    func testInvalidPaceIsADash() {
        for formatter in [metric, imperial] {
            XCTAssertEqual(formatter.pace(nil), "–")
            XCTAssertEqual(formatter.pace(0), "–")
            XCTAssertEqual(formatter.pace(.nan), "–")
            XCTAssertEqual(formatter.pace(.infinity), "–")
            XCTAssertEqual(formatter.swimPace(-5), "–")
        }
    }

    func testNonFiniteDistancesDoNotPrintNaN() {
        for formatter in [metric, imperial] {
            XCTAssertEqual(formatter.distance(.nan), "–")
            XCTAssertEqual(formatter.shortDistance(.infinity), "–")
            XCTAssertEqual(formatter.elevation(.nan), "–")
            XCTAssertEqual(formatter.weight(.nan), "–")
        }
        XCTAssertEqual(Fmt.km(.nan), "–")
        XCTAssertEqual(Fmt.meters(.infinity), "–")
    }

    // MARK: - Mass

    func testWeightConvertsToPounds() {
        // 82.5 kg = 181.88 lb
        XCTAssertEqual(metric.weight(82.5), "82.5 kg")
        XCTAssertEqual(imperial.weight(82.5), "181.9 lb")
        XCTAssertEqual(metric.volume(12_450), "12450 kg")
        XCTAssertEqual(imperial.volume(12_450), "27448 lb")
    }

    /// Input fields edit in the displayed unit and store kilograms. Anything
    /// typed must survive the trip.
    func testWeightInputRoundTripsThroughTheStoredUnit() {
        for kilograms in [0.0, 2.5, 60.0, 82.5, 137.3] {
            for formatter in [metric, imperial] {
                let displayed = formatter.displayedWeight(fromKilograms: kilograms)
                let back = formatter.kilograms(fromDisplayed: displayed)
                XCTAssertEqual(back, kilograms, accuracy: 1e-9,
                               "\(kilograms) kg via \(formatter.system)")
            }
        }
    }

    func testTwoTwentyPoundsIsAHundredKilos() {
        // The plate-math sanity check every lifter does in their head.
        XCTAssertEqual(imperial.kilograms(fromDisplayed: 220.462), 100, accuracy: 0.001)
        XCTAssertEqual(imperial.displayedWeight(fromKilograms: 100), 220.462, accuracy: 0.001)
    }

    // MARK: - Preference storage

    func testStoredPreferenceDefaultsToMetric() {
        let defaults = UserDefaults(suiteName: "UnitsTests.pref")!
        defaults.removePersistentDomain(forName: "UnitsTests.pref")
        XCTAssertEqual(UnitSystem.current(defaults), .metric)

        defaults.set("imperial", forKey: UnitSystem.defaultsKey)
        XCTAssertEqual(UnitSystem.current(defaults), .imperial)

        // A value written by a future version must not crash the app.
        defaults.set("nautical", forKey: UnitSystem.defaultsKey)
        XCTAssertEqual(UnitSystem.current(defaults), .metric)
        defaults.removePersistentDomain(forName: "UnitsTests.pref")
    }

    func testEnvironmentDefaultsToMetric() {
        XCTAssertEqual(EnvironmentValues().units.system, .metric)
    }

    // MARK: - The invariant that matters

    /// Switching units must never change a stored value or an analysis result.
    /// Load, records and thresholds are all derived in SI; only the label moves.
    func testAnalysisIsIndependentOfTheDisplayPreference() {
        let samples = (0...600).map { FITSample(t: Double($0), hr: 160,
                                                dist: Double($0) * 3.3) }
        let snapshot = WorkoutSnapshot(
            id: UUID(), sport: .run, startedAt: .now,
            distance: 1_980, duration: 600,
            streamsData: try? JSONEncoder().encode(samples))
        let athlete = TrainingLoad.Athlete(maxHR: 190, restingHR: 50)

        let before = TrainingLoad.score(for: snapshot, athlete: athlete)
        let defaults = UserDefaults(suiteName: "UnitsTests.invariant")!
        defaults.set("imperial", forKey: UnitSystem.defaultsKey)
        let after = TrainingLoad.score(for: snapshot, athlete: athlete)

        XCTAssertEqual(before?.value ?? 0, after?.value ?? 0, accuracy: 1e-9)
        XCTAssertEqual(SplitCalculator.splits(from: samples).count,
                       SplitCalculator.splits(from: samples).count)
        defaults.removePersistentDomain(forName: "UnitsTests.invariant")
    }

    /// Both systems must render every value type without producing an empty
    /// string — a blank cell in a table is worse than a dash.
    func testNoFormatterEverReturnsAnEmptyString() {
        for formatter in [metric, imperial] {
            let outputs = [
                formatter.distance(5_000), formatter.shortDistance(400),
                formatter.autoDistance(800), formatter.elevation(120),
                formatter.pace(300), formatter.swimPace(100),
                formatter.weight(70), formatter.volume(5_000),
                formatter.duration(3_661), formatter.bpm(150), formatter.kcal(620),
                formatter.distanceUnit, formatter.shortDistanceUnit,
                formatter.elevationUnit, formatter.paceUnit,
                formatter.swimPaceUnit, formatter.weightUnit,
            ]
            XCTAssertTrue(outputs.allSatisfy { !$0.isEmpty }, "\(formatter.system)")
        }
    }
}

/// Signed number formatting.
///
/// Every signed figure in the app went through `String(format: "%+.0f", …)`,
/// which prints "-0" for anything in (-0.5, 0). The Recovery screen read
/// "Form -0 — neutral", which looks like a defect because it is one.
final class SignedFormattingTests: XCTestCase {

    func testNegativeZeroIsJustZero() {
        XCTAssertEqual(Fmt.signed(-0.4), "0")
        XCTAssertEqual(Fmt.signed(-0.0), "0")
        XCTAssertEqual(Fmt.signed(0), "0")
        XCTAssertEqual(Fmt.signed(0.4), "0")
        XCTAssertEqual(Fmt.signed(-0.04, decimals: 1), "0.0")
    }

    func testRealValuesKeepTheirSign() {
        XCTAssertEqual(Fmt.signed(5), "+5")
        XCTAssertEqual(Fmt.signed(-5), "-5")
        XCTAssertEqual(Fmt.signed(0.6), "+1")
        XCTAssertEqual(Fmt.signed(-0.6), "-1")
        XCTAssertEqual(Fmt.signed(-12.34, decimals: 1), "-12.3")
        XCTAssertEqual(Fmt.signed(12.36, decimals: 2), "+12.36")
    }

    func testNonFiniteDegradesRatherThanPrintingInf() {
        XCTAssertEqual(Fmt.signed(.nan), "–")
        XCTAssertEqual(Fmt.signed(.infinity), "–")
    }

    /// The measurement delta formatter is built on it, so it inherits the fix.
    func testMeasurementDeltaNeverShowsNegativeZero() {
        let metric = UnitFormatter(.metric)
        XCTAssertEqual(metric.bodyMeasurementDelta(-0.02, site: .waist), "0.0 cm")
        XCTAssertEqual(metric.bodyMeasurementDelta(-3, site: .waist), "-3.0 cm")
        XCTAssertEqual(metric.bodyMeasurementDelta(-1.2, site: .bodyFat), "-1.2%")

        let imperial = UnitFormatter(.imperial)
        XCTAssertEqual(imperial.bodyMeasurementDelta(-0.01, site: .waist), "0.0 in")
        // Body fat is a percentage in both systems and must not be converted.
        XCTAssertEqual(imperial.bodyMeasurementDelta(-1.2, site: .bodyFat), "-1.2%")
    }
}
