import XCTest
@testable import FitnessTracker

/// Deriving thresholds from recorded efforts.
///
/// These numbers had to be typed in, and the whole load model rests on them — so
/// an athlete who didn't know their FTP silently got duration-estimated load for
/// every ride. The risk in automating it is the opposite one: an estimate read
/// from the wrong effort is worse than no estimate, because it looks authoritative.
final class ThresholdEstimatorTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func ride(power: Int, minutes: Int, hr: Int? = nil,
                      maxHR: Int? = nil, on date: Date? = nil,
                      sport: WorkoutSport = .bike) -> WorkoutSnapshot {
        let samples = (0...(minutes * 60)).map {
            FITSample(t: Double($0), hr: hr, power: power)
        }
        return WorkoutSnapshot(
            id: UUID(), sport: sport, startedAt: date ?? day,
            distance: 30_000, duration: TimeInterval(minutes * 60),
            maxHeartRate: maxHR,
            streamsData: try? JSONEncoder().encode(samples))
    }

    private func run(hr: Int, minutes: Int, maxHR: Int? = nil,
                     on date: Date? = nil) -> WorkoutSnapshot {
        let samples = (0...(minutes * 60)).map { FITSample(t: Double($0), hr: hr) }
        return WorkoutSnapshot(
            id: UUID(), sport: .run, startedAt: date ?? day,
            distance: 10_000, duration: TimeInterval(minutes * 60),
            maxHeartRate: maxHR,
            streamsData: try? JSONEncoder().encode(samples))
    }

    private var epoch: Date { Date(timeIntervalSince1970: 0) }

    // MARK: - FTP

    /// The convention, applied exactly: 95% of the best 20 minutes.
    func testFTPIsNinetyFivePercentOfTheBestTwentyMinutes() throws {
        let result = ThresholdEstimator.estimate(
            from: [ride(power: 300, minutes: 25)], since: epoch)

        let ftp = try XCTUnwrap(result.ftp)
        XCTAssertEqual(ftp.observed, 300)
        XCTAssertEqual(ftp.value, 285)
        XCTAssertEqual(ftp.windowMinutes, 20)
    }

    func testTheBestEffortWinsAcrossManyRides() throws {
        let result = ThresholdEstimator.estimate(
            from: [ride(power: 220, minutes: 60),
                   ride(power: 310, minutes: 22),
                   ride(power: 260, minutes: 45)],
            since: epoch)

        XCTAssertEqual(try XCTUnwrap(result.ftp).observed, 310)
    }

    /// A 15-minute effort can't produce a 20-minute number, and inventing one
    /// by extrapolating would be exactly the confident-but-wrong failure.
    func testAnEffortShorterThanTheWindowProducesNothing() {
        let result = ThresholdEstimator.estimate(
            from: [ride(power: 400, minutes: 15)], since: epoch)
        XCTAssertNil(result.ftp)
    }

    /// Running power is a different quantity on a different scale. Folding the
    /// two together produces an FTP that means nothing for either sport.
    func testRunningPowerIsNotUsedForFTP() {
        let result = ThresholdEstimator.estimate(
            from: [ride(power: 350, minutes: 30, sport: .run)], since: epoch)
        XCTAssertNil(result.ftp)
    }

    // MARK: - Threshold heart rate

    /// No fraction is applied here, unlike power: the best 20 minutes of heart
    /// rate an athlete can hold *is* roughly threshold.
    func testThresholdHRIsTheObservedTwentyMinuteAverage() throws {
        let result = ThresholdEstimator.estimate(
            from: [run(hr: 168, minutes: 25)], since: epoch)

        let lthr = try XCTUnwrap(result.lactateThresholdHR)
        XCTAssertEqual(lthr.value, 168)
        XCTAssertEqual(lthr.value, lthr.observed, "no convention factor for HR")
    }

    /// Heart rate is read from every sport, unlike power — a hard 20 minutes is
    /// a hard 20 minutes whether you were running or riding.
    func testThresholdHRComesFromAnySport() throws {
        let result = ThresholdEstimator.estimate(
            from: [ride(power: 200, minutes: 30, hr: 172)], since: epoch)
        XCTAssertEqual(try XCTUnwrap(result.lactateThresholdHR).value, 172)
    }

    func testHighestSustainedHeartRateWins() throws {
        let result = ThresholdEstimator.estimate(
            from: [run(hr: 150, minutes: 60), run(hr: 175, minutes: 22)],
            since: epoch)
        XCTAssertEqual(try XCTUnwrap(result.lactateThresholdHR).value, 175)
    }

    // MARK: - Max heart rate

    /// Taken from the session maximum the watch reports, which is less noisy
    /// than the highest single sample in a stream.
    func testMaxHeartRateUsesTheRecordedSessionPeak() throws {
        let result = ThresholdEstimator.estimate(
            from: [run(hr: 150, minutes: 30, maxHR: 188),
                   run(hr: 160, minutes: 30, maxHR: 181)],
            since: epoch)
        XCTAssertEqual(try XCTUnwrap(result.maxHeartRate).value, 188)
    }

    /// A stray low figure isn't a maximum; it's a workout where the strap
    /// dropped out.
    func testImplausiblyLowMaximaAreIgnored() {
        let result = ThresholdEstimator.estimate(
            from: [run(hr: 90, minutes: 30, maxHR: 95)], since: epoch)
        XCTAssertNil(result.maxHeartRate)
    }

    // MARK: - The window

    /// Thresholds decay. A personal best from three seasons ago is a memento,
    /// and training against it produces sessions you can't complete.
    func testOldEffortsAreExcluded() {
        let threeYearsAgo = Calendar.current.date(byAdding: .year, value: -3, to: .now)!
        let result = ThresholdEstimator.estimate(
            from: [ride(power: 400, minutes: 30, on: threeYearsAgo)],
            since: ThresholdEstimator.defaultWindowStart())
        XCTAssertTrue(result.isEmpty)
    }

    func testRecentEffortsAreIncluded() throws {
        let lastMonth = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
        let result = ThresholdEstimator.estimate(
            from: [ride(power: 280, minutes: 25, on: lastMonth)],
            since: ThresholdEstimator.defaultWindowStart())
        XCTAssertEqual(try XCTUnwrap(result.ftp).observed, 280)
    }

    func testDefaultWindowIsAYear() {
        let start = ThresholdEstimator.defaultWindowStart(from: day)
        let expected = Calendar.current.date(byAdding: .year, value: -1, to: day)!
        XCTAssertEqual(start.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Empty and degenerate

    func testNoWorkoutsProducesNothing() {
        let result = ThresholdEstimator.estimate(from: [], since: epoch)
        XCTAssertTrue(result.isEmpty)
        XCTAssertNil(result.ftp)
        XCTAssertNil(result.lactateThresholdHR)
        XCTAssertNil(result.maxHeartRate)
    }

    func testWorkoutsWithoutStreamsProduceNothing() {
        let bare = WorkoutSnapshot(id: UUID(), sport: .bike, startedAt: day,
                                   distance: 30_000, duration: 3600)
        let result = ThresholdEstimator.estimate(from: [bare], since: epoch)
        XCTAssertNil(result.ftp)
        XCTAssertNil(result.lactateThresholdHR)
    }

    // MARK: - Presentation

    /// Every estimate has to say what it rests on. A number that looks
    /// authoritative and isn't is worse than no number.
    func testEveryKindHasANameUnitAndCaveat() {
        for kind in ThresholdEstimator.Kind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty)
            XCTAssertFalse(kind.unit.isEmpty)
            XCTAssertFalse(ThresholdEstimator.caveat(for: kind).isEmpty)
        }
        XCTAssertEqual(ThresholdEstimator.Kind.ftp.unit, "W")
        XCTAssertEqual(ThresholdEstimator.Kind.maxHeartRate.unit, "bpm")
    }

    func testLookupReturnsTheMatchingEstimate() throws {
        let result = ThresholdEstimator.estimate(
            from: [ride(power: 300, minutes: 25, hr: 170, maxHR: 185)], since: epoch)

        XCTAssertEqual(ThresholdEstimator.estimate(.ftp, in: result)?.value, 285)
        XCTAssertEqual(ThresholdEstimator.estimate(.lactateThresholdHR, in: result)?.value, 170)
        XCTAssertEqual(ThresholdEstimator.estimate(.maxHeartRate, in: result)?.value, 185)
    }

    // MARK: - Feeding the load model

    /// The point of estimating: a rider with no FTP got duration-guessed load
    /// for every ride. Applying the estimate should change how they're scored.
    func testAnEstimatedFTPUpgradesHowARideIsScored() throws {
        let workout = ride(power: 250, minutes: 60)
        let result = ThresholdEstimator.estimate(from: [workout], since: epoch)
        let ftp = try XCTUnwrap(result.ftp).value

        let guessed = TrainingLoad.score(for: workout, athlete: .init())
        let measured = TrainingLoad.score(for: workout, athlete: .init(ftp: ftp))

        XCTAssertEqual(guessed?.method, .duration)
        XCTAssertEqual(measured?.method, .power)
    }

    // MARK: - The shared window sweep

    func testBestAverageFindsTheHardestWindowInEitherChannel() throws {
        // Ten easy minutes, then five hard, then ten easy.
        var samples: [FITSample] = []
        for second in 0..<(10 * 60) { samples.append(FITSample(t: Double(second), hr: 120, power: 150)) }
        for second in (10 * 60)..<(15 * 60) { samples.append(FITSample(t: Double(second), hr: 180, power: 350)) }
        for second in (15 * 60)..<(25 * 60) { samples.append(FITSample(t: Double(second), hr: 120, power: 150)) }

        let power = try XCTUnwrap(StreamStatistics.bestAveragePower(seconds: 300, in: samples))
        let hr = try XCTUnwrap(StreamStatistics.bestAverageHeartRate(seconds: 300, in: samples))
        XCTAssertEqual(power, 350, accuracy: 5)
        XCTAssertEqual(hr, 180, accuracy: 2)
    }

    func testBestAverageRefusesAWindowLongerThanTheStream() {
        let samples = (0..<60).map { FITSample(t: Double($0), hr: 150, power: 200) }
        XCTAssertNil(StreamStatistics.bestAveragePower(seconds: 1200, in: samples))
        XCTAssertNil(StreamStatistics.bestAverageHeartRate(seconds: 1200, in: samples))
        XCTAssertNil(StreamStatistics.bestAveragePower(seconds: 0, in: samples))
    }

    /// Samples missing the channel are excluded, not counted as zero — a ride
    /// where the meter dropped out shouldn't read as half the power.
    func testMissingChannelSamplesAreExcludedNotZeroed() throws {
        let samples = (0..<600).map { second in
            FITSample(t: Double(second), power: second.isMultiple(of: 2) ? 300 : nil)
        }
        let best = try XCTUnwrap(StreamStatistics.bestAveragePower(seconds: 300, in: samples))
        XCTAssertEqual(best, 300, accuracy: 1, "gaps must not drag the average down")
    }
}
