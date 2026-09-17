import XCTest
import SwiftData
@testable import FitnessTracker

/// Intensity distribution across a block.
///
/// The app could already break one session into zones, which answers nothing on
/// its own. These pin the aggregation, the three-band collapse, and — most
/// importantly — the honesty about coverage, because a distribution built from a
/// third of your training that doesn't say so is worse than no distribution.
final class IntensityDistributionTests: XCTestCase {

    private let zones = HRZones(maxHR: 200)

    /// A session held at one heart rate for `minutes`, sampled once a second.
    private func session(bpm: Int, minutes: Int, id: UUID = UUID()) -> WorkoutSnapshot {
        let samples = (0...(minutes * 60)).map { FITSample(t: Double($0), hr: bpm) }
        return WorkoutSnapshot(
            id: id, sport: .run, startedAt: .now,
            distance: 10_000, duration: TimeInterval(minutes * 60),
            streamsData: try? JSONEncoder().encode(samples))
    }

    private func sessionWithoutHR(minutes: Int = 60) -> WorkoutSnapshot {
        WorkoutSnapshot(id: UUID(), sport: .run, startedAt: .now,
                        distance: 10_000, duration: TimeInterval(minutes * 60))
    }

    // MARK: - Band mapping

    /// The whole point of the collapse: "80/20" has never meant anything in five
    /// zones, so the five-zone recording folds into the three-zone model at the
    /// two approximated thresholds.
    func testEveryZoneFoldsIntoExactlyOneBand() {
        for zone in 1...5 {
            let matching = IntensityDistribution.Band.allCases
                .filter { $0.zones.contains(zone) }
            XCTAssertEqual(matching.count, 1, "zone \(zone) must land in exactly one band")
        }
        XCTAssertEqual(IntensityDistribution.Band.containing(zone: 2), .easy)
        XCTAssertEqual(IntensityDistribution.Band.containing(zone: 3), .easy)
        XCTAssertEqual(IntensityDistribution.Band.containing(zone: 4), .moderate)
        XCTAssertEqual(IntensityDistribution.Band.containing(zone: 5), .hard)
        XCTAssertNil(IntensityDistribution.Band.containing(zone: 0))
        XCTAssertNil(IntensityDistribution.Band.containing(zone: 6))
    }

    func testBandsExplainThemselves() {
        for band in IntensityDistribution.Band.allCases {
            XCTAssertFalse(band.displayName.isEmpty)
            XCTAssertFalse(band.detail.isEmpty)
            XCTAssertFalse(band.zones.isEmpty)
        }
    }

    // MARK: - Aggregation

    func testTimeIsSummedIntoTheRightBand() {
        // Max 200: easy is below 160, moderate 160–179, hard 180+.
        let summary = IntensityDistribution.summarize(
            workouts: [session(bpm: 130, minutes: 60),   // easy
                       session(bpm: 170, minutes: 20),   // moderate
                       session(bpm: 190, minutes: 20)],  // hard
            zones: zones)

        XCTAssertEqual(summary.seconds(.easy), 3600, accuracy: 5)
        XCTAssertEqual(summary.seconds(.moderate), 1200, accuracy: 5)
        XCTAssertEqual(summary.seconds(.hard), 1200, accuracy: 5)
        XCTAssertEqual(summary.measuredSessions, 3)
        XCTAssertEqual(summary.unmeasuredSessions, 0)
    }

    func testFractionsAreOfMeasuredTimeAndSumToOne() {
        let summary = IntensityDistribution.summarize(
            workouts: [session(bpm: 130, minutes: 80), session(bpm: 190, minutes: 20)],
            zones: zones)

        XCTAssertEqual(summary.fraction(.easy), 0.8, accuracy: 0.01)
        XCTAssertEqual(summary.fraction(.hard), 0.2, accuracy: 0.01)
        XCTAssertEqual(summary.slices.map(\.fraction).reduce(0, +), 1.0, accuracy: 0.001)
    }

    func testAggregatesAcrossManySessions() {
        let easy = (0..<5).map { _ in session(bpm: 130, minutes: 60) }
        let hard = [session(bpm: 190, minutes: 30)]
        let summary = IntensityDistribution.summarize(workouts: easy + hard, zones: zones)

        XCTAssertEqual(summary.measuredSessions, 6)
        XCTAssertGreaterThan(summary.fraction(.easy), 0.8)
    }

    /// Time below zone 1 isn't in any band and mustn't be counted — a long warm
    /// walk would otherwise inflate "easy" and flatter the distribution.
    func testTimeBelowZoneOneIsExcluded() {
        // 80 bpm on a 200 max is 40%, below the zone-1 floor of 50%.
        let summary = IntensityDistribution.summarize(
            workouts: [session(bpm: 80, minutes: 60)], zones: zones)

        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.measuredSessions, 0)
        XCTAssertEqual(summary.unmeasuredSessions, 1,
                       "a session that classified nothing didn't contribute")
    }

    func testEmptyInputProducesAnEmptySummary() {
        let summary = IntensityDistribution.summarize(workouts: [], zones: zones)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.coverage, 0)
        XCTAssertNil(IntensityDistribution.shape(of: summary))
        XCTAssertNil(IntensityDistribution.advice(for: summary))
    }

    // MARK: - Coverage honesty

    /// A distribution built from a third of your training describes that third.
    /// Saying so is the difference between an insight and a confidently wrong
    /// number.
    func testCoverageReportsHowMuchOfTheBlockHadHeartRate() {
        let summary = IntensityDistribution.summarize(
            workouts: [session(bpm: 130, minutes: 60),
                       sessionWithoutHR(), sessionWithoutHR()],
            zones: zones)

        XCTAssertEqual(summary.measuredSessions, 1)
        XCTAssertEqual(summary.unmeasuredSessions, 2)
        XCTAssertEqual(summary.coverage, 1.0 / 3, accuracy: 0.001)
        XCTAssertFalse(summary.isRepresentative)
    }

    func testGoodCoverageIsMarkedRepresentative() {
        let workouts = (0..<8).map { _ in session(bpm: 140, minutes: 60) }
            + [sessionWithoutHR()]
        let summary = IntensityDistribution.summarize(workouts: workouts, zones: zones)

        XCTAssertGreaterThan(summary.coverage, 0.85)
        XCTAssertTrue(summary.isRepresentative)
    }

    /// Three measured sessions is the floor: two easy runs and one interval
    /// session is not a block, whatever percentage it produces.
    func testTooFewSessionsIsNotRepresentativeEvenAtFullCoverage() {
        let summary = IntensityDistribution.summarize(
            workouts: [session(bpm: 140, minutes: 60), session(bpm: 140, minutes: 60)],
            zones: zones)

        XCTAssertEqual(summary.coverage, 1.0)
        XCTAssertFalse(summary.isRepresentative, "two sessions is not a block")
    }

    // MARK: - Reading the shape

    func testTheClassicPolarizedWeekIsRecognized() {
        let summary = IntensityDistribution.summarize(
            workouts: [session(bpm: 130, minutes: 240), session(bpm: 190, minutes: 40)],
            zones: zones)
        XCTAssertEqual(IntensityDistribution.shape(of: summary), .polarized)
    }

    /// Lots of easy volume and nothing hard: fine, but nothing is driving the
    /// top end, and the app should say which of the two it's looking at.
    func testAllEasyIsDistinguishedFromPolarized() {
        let summary = IntensityDistribution.summarize(
            workouts: [session(bpm: 130, minutes: 300)], zones: zones)
        XCTAssertEqual(IntensityDistribution.shape(of: summary), .allEasy)
    }

    /// The grey zone: too hard to recover from, not hard enough to adapt to.
    func testTooMuchTimeInTheMiddleReadsAsGreyZone() {
        let summary = IntensityDistribution.summarize(
            workouts: [session(bpm: 130, minutes: 120), session(bpm: 170, minutes: 60)],
            zones: zones)
        XCTAssertEqual(IntensityDistribution.shape(of: summary), .threshold)
    }

    /// The case the Simulator caught: low easy, high moderate, almost no hard.
    /// Checking "is easy below 60%" first called this "too hard" and advised
    /// cutting intensity the athlete wasn't doing — the problem is the middle.
    func testMostlyModerateIsGreyZoneNotTooHard() {
        let summary = IntensityDistribution.summarize(
            workouts: [session(bpm: 130, minutes: 42),   // easy
                       session(bpm: 170, minutes: 57),   // moderate
                       session(bpm: 190, minutes: 2)],   // a token amount hard
            zones: zones)

        XCTAssertLessThan(summary.fraction(.easy), 0.6)
        XCTAssertLessThan(summary.fraction(.hard), 0.05)
        XCTAssertEqual(IntensityDistribution.shape(of: summary), .threshold,
                       "barely any hard work — the problem is the time in the middle")
    }

    func testNotEnoughEasyWorkReadsAsTooHard() {
        let summary = IntensityDistribution.summarize(
            workouts: [session(bpm: 130, minutes: 40), session(bpm: 190, minutes: 60)],
            zones: zones)
        XCTAssertEqual(IntensityDistribution.shape(of: summary), .tooHard)
    }

    func testEveryShapeExplainsItself() {
        for shape in [IntensityDistribution.Shape.polarized, .allEasy, .threshold, .tooHard] {
            XCTAssertFalse(shape.label.isEmpty)
            XCTAssertFalse(shape.guidance.isEmpty)
        }
    }

    // MARK: - Advice

    func testAdviceNamesTheGapInEitherDirection() throws {
        let tooHard = IntensityDistribution.summarize(
            workouts: [session(bpm: 130, minutes: 60), session(bpm: 190, minutes: 40)],
            zones: zones)
        let short = try XCTUnwrap(IntensityDistribution.advice(for: tooHard))
        XCTAssertTrue(short.contains("short of"))

        let veryEasy = IntensityDistribution.summarize(
            workouts: [session(bpm: 130, minutes: 300)], zones: zones)
        let easier = try XCTUnwrap(IntensityDistribution.advice(for: veryEasy))
        XCTAssertTrue(easier.contains("Easier than"))
    }

    /// No advice when you're already there — a nag that fires at 79% teaches
    /// people to ignore it.
    func testNoAdviceWhenAlreadyNearTheConvention() {
        let summary = IntensityDistribution.summarize(
            workouts: [session(bpm: 130, minutes: 160), session(bpm: 190, minutes: 40)],
            zones: zones)
        XCTAssertEqual(summary.fraction(.easy), 0.8, accuracy: 0.02)
        XCTAssertNil(IntensityDistribution.advice(for: summary))
    }

    // MARK: - Interaction with max HR

    /// The band boundaries scale with max HR, so the same session read against a
    /// different max lands somewhere else. That's the approximation the UI warns
    /// about, and it must actually behave that way rather than silently anchor.
    func testTheDistributionMovesWithMaxHeartRate() {
        let workouts = [session(bpm: 165, minutes: 60)]

        // Max 200: 165 is 82.5% — moderate.
        let high = IntensityDistribution.summarize(workouts: workouts,
                                                   zones: HRZones(maxHR: 200))
        XCTAssertGreaterThan(high.fraction(.moderate), 0.9)

        // Max 180: 165 is 91.7% — hard.
        let low = IntensityDistribution.summarize(workouts: workouts,
                                                  zones: HRZones(maxHR: 180))
        XCTAssertGreaterThan(low.fraction(.hard), 0.9)
    }

    /// Dropouts must not be charged as time at that intensity, exactly as the
    /// per-session zone breakdown already guarantees.
    func testRecordingGapsAreNotCountedAsTimeInZone() {
        var samples = (0...600).map { FITSample(t: Double($0), hr: 130) }
        samples.append(FITSample(t: 600 + 7200, hr: 130))
        let workout = WorkoutSnapshot(
            id: UUID(), sport: .run, startedAt: .now, distance: 10_000,
            duration: 7800, streamsData: try? JSONEncoder().encode(samples))

        let summary = IntensityDistribution.summarize(workouts: [workout], zones: zones)
        XCTAssertEqual(summary.measuredSeconds, 600, accuracy: 5,
                       "the two-hour gap is a dropout, not two hours easy")
    }

    // MARK: - Against the demo data

    /// The seeded season is built to look like real training, so it should read
    /// as a plausible shape rather than something degenerate.
    @MainActor
    func testDemoDataProducesAPlausibleDistribution() throws {
        let context = try FITFixture.makeContext()
        DemoData.seed(into: context, weeks: 8)
        try context.save()

        let snapshots = try context.fetch(FetchDescriptor<Workout>()).map(\.snapshot)
        let observedMax = snapshots.compactMap(\.maxHeartRate).max() ?? 190
        let summary = IntensityDistribution.summarize(
            workouts: snapshots, zones: HRZones(maxHR: observedMax))

        XCTAssertFalse(summary.isEmpty)
        XCTAssertGreaterThan(summary.measuredSessions, 10)
        XCTAssertNotNil(IntensityDistribution.shape(of: summary))
        // Every band fraction is a real proportion.
        for slice in summary.slices {
            XCTAssertGreaterThanOrEqual(slice.fraction, 0)
            XCTAssertLessThanOrEqual(slice.fraction, 1)
        }
    }
}