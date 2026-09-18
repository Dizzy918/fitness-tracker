import XCTest
@testable import FitnessTracker

/// The mean-maximal curve.
///
/// Two things make this easy to get subtly wrong: pace and power are read in
/// opposite directions (lower pace is better, higher power is better), and the
/// curve has to take the best effort at each duration from *across* workouts
/// rather than from whichever one happened to be longest.
final class DurationCurveTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    /// A ride held at one power for `minutes`.
    private func ride(power: Int, minutes: Int, on date: Date? = nil) -> WorkoutSnapshot {
        let samples = (0...(minutes * 60)).map { FITSample(t: Double($0), power: power) }
        return WorkoutSnapshot(
            id: UUID(), sport: .bike, startedAt: date ?? day,
            distance: 30_000, duration: TimeInterval(minutes * 60),
            streamsData: try? JSONEncoder().encode(samples))
    }

    /// A run held at one speed for `minutes`.
    private func run(metresPerSecond: Double, minutes: Int,
                     on date: Date? = nil) -> WorkoutSnapshot {
        let samples = (0...(minutes * 60)).map {
            FITSample(t: Double($0), dist: Double($0) * metresPerSecond)
        }
        return WorkoutSnapshot(
            id: UUID(), sport: .run, startedAt: date ?? day,
            distance: metresPerSecond * Double(minutes * 60),
            duration: TimeInterval(minutes * 60),
            streamsData: try? JSONEncoder().encode(samples))
    }

    // MARK: - Power

    func testPowerCurveTakesTheBestAtEachDuration() throws {
        let curve = DurationCurve.power(from: [ride(power: 250, minutes: 70)])

        // A 70-minute steady ride can fill every window up to an hour.
        XCTAssertFalse(curve.isEmpty)
        for point in curve {
            XCTAssertEqual(point.value, 250, accuracy: 5,
                           "steady power should read flat at \(point.label)")
        }
        XCTAssertNil(curve.first { $0.duration > 3_600 },
                     "nothing longer than the ride itself")
    }

    /// The point of a *curve*: a short hard effort and a long steady one each
    /// own the part of the range they're best at.
    func testDifferentWorkoutsOwnDifferentDurations() throws {
        let curve = DurationCurve.power(from: [
            ride(power: 600, minutes: 2),     // a sprint
            ride(power: 240, minutes: 90),    // a long steady ride
        ])

        let short = try XCTUnwrap(curve.first { $0.duration == 60 })
        let long = try XCTUnwrap(curve.first { $0.duration == 3_600 })
        XCTAssertEqual(short.value, 600, accuracy: 10)
        XCTAssertEqual(long.value, 240, accuracy: 10)
        XCTAssertNotEqual(short.workoutID, long.workoutID)
    }

    /// Only cycling contributes power. Running power is a different quantity.
    func testOnlyRidesContributeToThePowerCurve() {
        let samples = (0...1200).map { FITSample(t: Double($0), power: 400) }
        let runWithPower = WorkoutSnapshot(
            id: UUID(), sport: .run, startedAt: day, distance: 10_000, duration: 1200,
            streamsData: try? JSONEncoder().encode(samples))

        XCTAssertTrue(DurationCurve.power(from: [runWithPower]).isEmpty)
    }

    // MARK: - Pace

    /// Pace is derived from distance covered and inverted: the furthest you went
    /// in 20 minutes is the fastest pace you held for 20 minutes.
    func testPaceCurveIsDerivedFromDistanceCovered() throws {
        // 4 m/s is 250 s/km — a 4:10/km pace.
        let curve = DurationCurve.pace(from: [run(metresPerSecond: 4, minutes: 40)])

        let twentyMinute = try XCTUnwrap(curve.first { $0.duration == 1_200 })
        XCTAssertEqual(twentyMinute.value, 250, accuracy: 3)
    }

    /// Lower is better for pace, so the *fastest* effort must win — taking the
    /// max would return the slowest and quietly invert the whole chart.
    func testFastestPaceWinsNotLargestNumber() throws {
        let curve = DurationCurve.pace(from: [
            run(metresPerSecond: 3.0, minutes: 40),   // 333 s/km, slower
            run(metresPerSecond: 4.5, minutes: 40),   // 222 s/km, faster
        ])

        let point = try XCTUnwrap(curve.first { $0.duration == 1_200 })
        XCTAssertEqual(point.value, 1000 / 4.5, accuracy: 3,
                       "the faster run owns this duration")
    }

    func testOnlyFootSportsContributeToThePaceCurve() {
        let samples = (0...2400).map { FITSample(t: Double($0), dist: Double($0) * 8) }
        let ride = WorkoutSnapshot(
            id: UUID(), sport: .bike, startedAt: day, distance: 19_200, duration: 2400,
            streamsData: try? JSONEncoder().encode(samples))

        XCTAssertTrue(DurationCurve.pace(from: [ride]).isEmpty,
                      "a bike's pace curve would dwarf every run")
    }

    // MARK: - Windows

    /// A workout shorter than the window can't contribute to it.
    func testShortWorkoutsDoNotFillLongDurations() {
        let curve = DurationCurve.power(from: [ride(power: 300, minutes: 8)])

        XCTAssertNotNil(curve.first { $0.duration == 300 })
        XCTAssertNil(curve.first { $0.duration == 1_200 },
                     "an eight-minute ride has no twenty-minute effort in it")
    }

    func testEmptyInputGivesAnEmptyCurve() {
        XCTAssertTrue(DurationCurve.power(from: []).isEmpty)
        XCTAssertTrue(DurationCurve.pace(from: []).isEmpty)
    }

    func testCurveIsOrderedByDuration() {
        let curve = DurationCurve.power(from: [ride(power: 250, minutes: 70)])
        XCTAssertEqual(curve.map(\.duration), curve.map(\.duration).sorted())
    }

    // MARK: - Comparison

    func testComparisonSplitsTheWindowsCorrectly() {
        let now = day
        let recent = Calendar.current.date(byAdding: .day, value: -10, to: now)!
        let older = Calendar.current.date(byAdding: .day, value: -50, to: now)!

        let comparison = DurationCurve.compare(
            workouts: [ride(power: 300, minutes: 40, on: recent),
                       ride(power: 250, minutes: 40, on: older)],
            metric: .power, days: 30, now: now)

        XCTAssertEqual(comparison.current.first?.value ?? 0, 300, accuracy: 10)
        XCTAssertEqual(comparison.previous.first?.value ?? 0, 250, accuracy: 10)
    }

    /// Improvement, not arithmetic. A pace that dropped from 4:00 to 3:50 is a
    /// gain, and reporting it as −4% would read as a loss at a glance.
    func testPaceImprovementIsReportedAsPositive() throws {
        let now = day
        let recent = Calendar.current.date(byAdding: .day, value: -5, to: now)!
        let older = Calendar.current.date(byAdding: .day, value: -40, to: now)!

        let comparison = DurationCurve.compare(
            workouts: [run(metresPerSecond: 4.4, minutes: 40, on: recent),  // faster now
                       run(metresPerSecond: 4.0, minutes: 40, on: older)],
            metric: .pace, days: 30, now: now)

        let change = try XCTUnwrap(comparison.change(at: 1_200))
        XCTAssertGreaterThan(change, 0, "getting faster is a positive change")
    }

    func testPowerImprovementIsAlsoPositive() throws {
        let now = day
        let comparison = DurationCurve.compare(
            workouts: [ride(power: 300, minutes: 40,
                            on: Calendar.current.date(byAdding: .day, value: -5, to: now)!),
                       ride(power: 270, minutes: 40,
                            on: Calendar.current.date(byAdding: .day, value: -40, to: now)!)],
            metric: .power, days: 30, now: now)

        let change = try XCTUnwrap(comparison.change(at: 1_200))
        XCTAssertGreaterThan(change, 0.09, "300 over 270 is about 11%")
    }

    func testGettingSlowerIsReportedAsNegative() throws {
        let now = day
        let comparison = DurationCurve.compare(
            workouts: [run(metresPerSecond: 3.6, minutes: 40,
                           on: Calendar.current.date(byAdding: .day, value: -5, to: now)!),
                       run(metresPerSecond: 4.0, minutes: 40,
                           on: Calendar.current.date(byAdding: .day, value: -40, to: now)!)],
            metric: .pace, days: 30, now: now)

        XCTAssertLessThan(try XCTUnwrap(comparison.change(at: 1_200)), 0)
    }

    func testNoChangeWithoutBothSides() {
        let comparison = DurationCurve.compare(
            workouts: [ride(power: 300, minutes: 40, on: day)],
            metric: .power, days: 30, now: day)
        XCTAssertNil(comparison.change(at: 1_200), "nothing to compare against")
        XCTAssertNil(comparison.largestGain)
    }

    /// The question the whole comparison exists to answer: *which part* of the
    /// range moved.
    func testLargestGainFindsWhereTheWorkWent() throws {
        let now = day
        let recent = Calendar.current.date(byAdding: .day, value: -5, to: now)!
        let older = Calendar.current.date(byAdding: .day, value: -40, to: now)!

        let comparison = DurationCurve.compare(
            workouts: [
                // Sprint improved a lot; the long effort barely moved.
                ride(power: 700, minutes: 2, on: recent),
                ride(power: 252, minutes: 70, on: recent),
                ride(power: 500, minutes: 2, on: older),
                ride(power: 250, minutes: 70, on: older),
            ],
            metric: .power, days: 30, now: now)

        let gain = try XCTUnwrap(comparison.largestGain)
        XCTAssertLessThanOrEqual(gain.duration, 120,
                                 "the sprint end is where it moved")
        XCTAssertGreaterThan(gain.change, 0.3)
    }

    // MARK: - Labels

    func testDurationLabelsReadNaturally() {
        XCTAssertEqual(DurationCurve.label(for: 5), "5s")
        XCTAssertEqual(DurationCurve.label(for: 30), "30s")
        XCTAssertEqual(DurationCurve.label(for: 60), "1m")
        XCTAssertEqual(DurationCurve.label(for: 1_200), "20m")
        XCTAssertEqual(DurationCurve.label(for: 3_600), "1h")
        XCTAssertEqual(DurationCurve.label(for: 5_400), "1.5h")
    }

    func testMetricsKnowWhichDirectionIsBetter() {
        XCTAssertTrue(DurationCurve.Metric.power.higherIsBetter)
        XCTAssertFalse(DurationCurve.Metric.pace.higherIsBetter)
        XCTAssertEqual(DurationCurve.Metric.power.sports, [.bike])
        XCTAssertTrue(DurationCurve.Metric.pace.sports.contains(.trailRun))
    }

    // MARK: - The distance sweep

    func testBestDistanceFindsTheFastestStretch()  throws {
        // Ten minutes at 3 m/s, five at 5 m/s, ten at 3 m/s.
        var samples: [FITSample] = []
        var distance = 0.0
        for second in 0..<1_500 {
            let speed: Double = (600..<900).contains(second) ? 5 : 3
            distance += speed
            samples.append(FITSample(t: Double(second), dist: distance))
        }

        let best = try XCTUnwrap(StreamStatistics.bestDistance(seconds: 300, in: samples))
        XCTAssertEqual(best, 1_500, accuracy: 20, "the five-minute surge at 5 m/s")
    }

    func testBestDistanceRefusesAWindowLongerThanTheStream() {
        let samples = (0..<60).map { FITSample(t: Double($0), dist: Double($0) * 3) }
        XCTAssertNil(StreamStatistics.bestDistance(seconds: 600, in: samples))
    }

    /// A distance reset mid-file is a recording artefact, not a teleport
    /// backwards, and must not produce a negative or nonsense window.
    func testBestDistanceIgnoresADistanceReset() throws {
        var samples = (0..<600).map { FITSample(t: Double($0), dist: Double($0) * 3) }
        samples += (600..<1_200).map { FITSample(t: Double($0), dist: Double($0 - 600) * 3) }

        let best = StreamStatistics.bestDistance(seconds: 300, in: samples)
        XCTAssertNotNil(best)
        XCTAssertGreaterThan(best ?? 0, 0)
    }
}
