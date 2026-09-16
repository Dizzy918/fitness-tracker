import XCTest
@testable import FitnessTracker

final class ReadinessTests: XCTestCase {

    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000)) }
    private func day(_ offset: Int) -> Date {
        cal.date(byAdding: .day, value: offset, to: today)!
    }

    /// A steady baseline: 7 prior days of identical values.
    private func flatHistory(hrv: Double = 60, rhr: Double = 50) -> [MetricSnapshot] {
        (1...7).map { MetricSnapshot(date: day(-$0), hrvSDNN: hrv, restingHR: rhr) }
    }

    // MARK: - Baselines

    func testAtBaselineScoresAsNormalTraining() {
        let result = Readiness.score(
            day: MetricSnapshot(date: today, hrvSDNN: 60, restingHR: 50, sleepHours: 8),
            history: flatHistory()
        )
        // Everything at baseline with full sleep should read "train as planned".
        XCTAssertGreaterThanOrEqual(result.score, 70)
        XCTAssertLessThanOrEqual(result.score, 95)
        XCTAssertTrue(result.isReliable)
    }

    func testSuppressedHRVLowersScore() {
        let history = (1...7).map {
            MetricSnapshot(date: day(-$0), hrvSDNN: 60 + Double($0 % 3) * 2, restingHR: 50)
        }
        let normal = Readiness.score(
            day: MetricSnapshot(date: today, hrvSDNN: 61, restingHR: 50, sleepHours: 8),
            history: history
        )
        let suppressed = Readiness.score(
            day: MetricSnapshot(date: today, hrvSDNN: 40, restingHR: 50, sleepHours: 8),
            history: history
        )
        XCTAssertLessThan(suppressed.score, normal.score)
    }

    func testElevatedRestingHRLowersScore() {
        let baseline = Readiness.score(
            day: MetricSnapshot(date: today, hrvSDNN: 60, restingHR: 50, sleepHours: 8),
            history: flatHistory()
        )
        let sick = Readiness.score(
            day: MetricSnapshot(date: today, hrvSDNN: 60, restingHR: 62, sleepHours: 8),
            history: flatHistory()
        )
        XCTAssertLessThan(sick.score, baseline.score,
                          "a raised resting HR should read as less ready")
    }

    func testShortSleepLowersScore() {
        let rested = Readiness.score(
            day: MetricSnapshot(date: today, hrvSDNN: 60, restingHR: 50, sleepHours: 8),
            history: flatHistory()
        )
        let tired = Readiness.score(
            day: MetricSnapshot(date: today, hrvSDNN: 60, restingHR: 50, sleepHours: 4),
            history: flatHistory()
        )
        XCTAssertLessThan(tired.score, rested.score)
    }

    // MARK: - Missing data

    func testBaselineNeedsMinimumSamples() {
        // Two prior days is not enough to call anything a baseline.
        let thin = [MetricSnapshot(date: day(-1), hrvSDNN: 60),
                    MetricSnapshot(date: day(-2), hrvSDNN: 61)]
        let result = Readiness.score(
            day: MetricSnapshot(date: today, hrvSDNN: 60), history: thin
        )
        XCTAssertFalse(result.contributions.contains { $0.component == .hrv })
        XCTAssertTrue(result.missing.contains(.hrv))
    }

    func testNoDataIsUnreliableRatherThanZeroScore() {
        let result = Readiness.score(day: MetricSnapshot(date: today), history: [])
        XCTAssertFalse(result.isReliable)
        XCTAssertEqual(result.confidence, 0)
        XCTAssertEqual(result.missing.count, Readiness.Component.allCases.count)
    }

    func testWeightsRenormalizeSoMissingInputsDontDrag() {
        // Sleep alone, at target: should score high, not be diluted toward zero
        // by the four absent components.
        let result = Readiness.score(
            day: MetricSnapshot(date: today, sleepHours: 8), history: []
        )
        XCTAssertGreaterThan(result.score, 90)
        XCTAssertEqual(result.confidence, Readiness.Component.sleep.weight, accuracy: 0.001)
    }

    func testConfidenceGrowsWithMoreInputs() {
        let sparse = Readiness.score(
            day: MetricSnapshot(date: today, sleepHours: 7), history: []
        )
        let full = Readiness.score(
            day: MetricSnapshot(date: today, hrvSDNN: 60, restingHR: 50, sleepHours: 7,
                                sleepQuality: 4, soreness: 2, mood: 4, motivation: 4),
            history: flatHistory(),
            loadRatio: 1.0
        )
        XCTAssertGreaterThan(full.confidence, sparse.confidence)
        XCTAssertEqual(full.confidence, 1.0, accuracy: 0.001)
        XCTAssertTrue(full.missing.isEmpty)
    }

    // MARK: - Isolation

    func testFutureAndSameDayHistoryIsIgnored() {
        var history = flatHistory()
        // A wildly different "tomorrow" must not affect today's baseline.
        history.append(MetricSnapshot(date: day(1), hrvSDNN: 200, restingHR: 90))
        history.append(MetricSnapshot(date: today, hrvSDNN: 200, restingHR: 90))

        let withFuture = Readiness.score(
            day: MetricSnapshot(date: today, hrvSDNN: 60, restingHR: 50, sleepHours: 8),
            history: history
        )
        let without = Readiness.score(
            day: MetricSnapshot(date: today, hrvSDNN: 60, restingHR: 50, sleepHours: 8),
            history: flatHistory()
        )
        XCTAssertEqual(withFuture.score, without.score,
                       "a score must never see same-day or future data")
    }

    func testFlatBaselineDoesNotDivideByZero() {
        // Zero standard deviation would blow up a naive z-score.
        let result = Readiness.score(
            day: MetricSnapshot(date: today, hrvSDNN: 60, restingHR: 50, sleepHours: 8),
            history: flatHistory(hrv: 60, rhr: 50)
        )
        XCTAssertTrue(result.score >= 0 && result.score <= 100)
        for c in result.contributions {
            XCTAssertFalse(c.subscore.isNaN, "\(c.component) produced NaN")
        }
    }

    // MARK: - Load

    func testLoadSubscorePenalizesSpikes()  {
        XCTAssertEqual(Readiness.loadSubscore(1.0), 1.0)
        XCTAssertLessThan(Readiness.loadSubscore(1.4), Readiness.loadSubscore(1.0))
        XCTAssertLessThan(Readiness.loadSubscore(2.0), Readiness.loadSubscore(1.4))
        // Being fresh is good but doesn't beat being well-loaded.
        XCTAssertLessThan(Readiness.loadSubscore(0.5), Readiness.loadSubscore(1.0))
    }

    func testTrainingSpikeLowersScore() {
        let steady = Readiness.score(
            day: MetricSnapshot(date: today, hrvSDNN: 60, restingHR: 50, sleepHours: 8),
            history: flatHistory(), loadRatio: 1.0
        )
        let spiked = Readiness.score(
            day: MetricSnapshot(date: today, hrvSDNN: 60, restingHR: 50, sleepHours: 8),
            history: flatHistory(), loadRatio: 1.9
        )
        XCTAssertLessThan(spiked.score, steady.score)
    }

    // MARK: - Subjective

    func testSorenessIsInverted() {
        let fresh = Readiness.score(
            day: MetricSnapshot(date: today, sleepHours: 8, soreness: 1), history: []
        )
        let wrecked = Readiness.score(
            day: MetricSnapshot(date: today, sleepHours: 8, soreness: 5), history: []
        )
        XCTAssertLessThan(wrecked.score, fresh.score,
                          "higher soreness must mean lower readiness")
    }

    func testCheckInAloneProducesAScore() {
        let result = Readiness.score(
            day: MetricSnapshot(date: today, sleepQuality: 5, soreness: 1, mood: 5, motivation: 5),
            history: []
        )
        XCTAssertTrue(result.isReliable)
        XCTAssertGreaterThan(result.score, 70)
    }

    // MARK: - Bands

    func testBandBoundaries() {
        XCTAssertEqual(Readiness.band(for: 0), .rest)
        XCTAssertEqual(Readiness.band(for: 39), .rest)
        XCTAssertEqual(Readiness.band(for: 40), .easy)
        XCTAssertEqual(Readiness.band(for: 59), .easy)
        XCTAssertEqual(Readiness.band(for: 60), .moderate)
        XCTAssertEqual(Readiness.band(for: 79), .moderate)
        XCTAssertEqual(Readiness.band(for: 80), .primed)
        XCTAssertEqual(Readiness.band(for: 100), .primed)
    }

    func testScoreStaysInRangeAcrossExtremes() {
        for hrv in [1.0, 30, 60, 300] {
            for rhr in [30.0, 50, 120] {
                for sleep in [0.0, 4, 8, 14] {
                    let r = Readiness.score(
                        day: MetricSnapshot(date: today, hrvSDNN: hrv,
                                            restingHR: rhr, sleepHours: sleep),
                        history: flatHistory(), loadRatio: 3.0
                    )
                    XCTAssertTrue((0...100).contains(r.score),
                                  "score \(r.score) out of range")
                }
            }
        }
    }
}

final class HRZonesTests: XCTestCase {

    private let zones = HRZones(maxHR: 190)

    func testZoneBoundaries() {
        XCTAssertNil(zones.zone(for: 90), "below 50% of max is not a zone")
        XCTAssertEqual(zones.zone(for: 95), 1)    // 50%
        XCTAssertEqual(zones.zone(for: 114), 2)   // 60%
        XCTAssertEqual(zones.zone(for: 133), 3)   // 70%
        XCTAssertEqual(zones.zone(for: 152), 4)   // 80%
        XCTAssertEqual(zones.zone(for: 171), 5)   // 90%
        XCTAssertEqual(zones.zone(for: 200), 5, "above max still counts as zone 5")
    }

    func testRangesAreContiguousAndOrdered() {
        var previousUpper = 0
        for zone in 1...5 {
            let range = zones.range(for: zone)!
            XCTAssertGreaterThan(range.lowerBound, previousUpper)
            previousUpper = range.upperBound
        }
        XCTAssertNil(zones.range(for: 0))
        XCTAssertNil(zones.range(for: 6))
    }

    func testTimeInZonesSumsIntervals() {
        // 10 samples, 10 s apart, all at 140 bpm (~74% of 190 → zone 3).
        let samples = (0..<10).map {
            FITSample(t: Double($0) * 10, lat: nil, lon: nil, hr: 140,
                      alt: nil, speed: nil, cadence: nil, dist: nil)
        }
        let totals = zones.timeInZones(samples)
        XCTAssertEqual(totals[3] ?? 0, 90, accuracy: 1, "9 intervals of 10 s")
        XCTAssertNil(totals[1])
    }

    /// The core invariant: time in zones can never exceed the workout's elapsed
    /// time, whatever the sampling rate.
    func testZoneTotalsNeverExceedElapsedTime() {
        for step in [1.0, 5.0, 10.0, 30.0] {
            let count = 20
            let samples = (0..<count).map {
                FITSample(t: Double($0) * step, lat: nil, lon: nil, hr: 150,
                          alt: nil, speed: nil, cadence: nil, dist: nil)
            }
            let elapsed = Double(count - 1) * step
            let total = zones.timeInZones(samples).values.reduce(0, +)
            XCTAssertLessThanOrEqual(total, elapsed + 0.001,
                                     "step \(step): \(total) s in zones vs \(elapsed) s elapsed")
        }
    }

    func testDropoutGapsAreNotCounted() {
        // A 30-minute gap must not be credited as time at that heart rate.
        let samples = [
            FITSample(t: 0, lat: nil, lon: nil, hr: 140, alt: nil, speed: nil, cadence: nil, dist: nil),
            FITSample(t: 1800, lat: nil, lon: nil, hr: 140, alt: nil, speed: nil, cadence: nil, dist: nil),
            FITSample(t: 1810, lat: nil, lon: nil, hr: 140, alt: nil, speed: nil, cadence: nil, dist: nil),
        ]
        let totals = zones.timeInZones(samples)
        // The 1800 s gap is discarded; only the single 10 s interval counts.
        XCTAssertEqual(totals[3] ?? 0, 10, accuracy: 1)
    }

    func testSamplesWithoutHRAreSkipped() {
        let samples = (0..<5).map {
            FITSample(t: Double($0) * 10, lat: nil, lon: nil, hr: nil,
                      alt: nil, speed: nil, cadence: nil, dist: nil)
        }
        XCTAssertTrue(zones.timeInZones(samples).isEmpty)
    }

    /// Using a single workout's peak as max HR would put every easy run deep
    /// in Z5. The season-wide max keeps zones meaningful.
    func testSeasonMaxKeepsEasyRunsOutOfZone5() {
        let easyRunPeak = 167
        let seasonMax = 195

        let naive = HRZones(maxHR: easyRunPeak)
        let correct = HRZones(maxHR: seasonMax)

        // A steady 150 bpm effort.
        XCTAssertEqual(naive.zone(for: 150), 4, "per-workout max inflates the zone")
        XCTAssertEqual(correct.zone(for: 150), 3, "season max reads it as aerobic")
    }

    func testObservedMaxFromHistory() {
        let a = Workout(sport: .run, startedAt: .now, duration: 60, distance: 100, source: "t")
        a.maxHeartRate = 178
        let b = Workout(sport: .run, startedAt: .now, duration: 60, distance: 100, source: "t")
        b.maxHeartRate = 186
        let c = Workout(sport: .run, startedAt: .now, duration: 60, distance: 100, source: "t")
        XCTAssertEqual(HRZones.observedMax(in: [a, b, c]), 186)
        XCTAssertNil(HRZones.observedMax(in: [c]))
    }
}

final class BestEffortTests: XCTestCase {

    /// Constant-pace stream: `paceSecPerKm` over `meters`, sampled every 5 s.
    private func stream(meters: Double, paceSecPerKm: Double) -> [FITSample] {
        let speed = 1000 / paceSecPerKm
        let total = meters / speed
        var out: [FITSample] = []
        var t = 0.0
        while t < total {
            out.append(FITSample(t: t, lat: nil, lon: nil, hr: nil, alt: nil,
                                 speed: speed, cadence: nil, dist: t * speed))
            t += 5
        }
        out.append(FITSample(t: total, lat: nil, lon: nil, hr: nil, alt: nil,
                             speed: speed, cadence: nil, dist: meters))
        return out
    }

    func testConstantPaceGivesExpectedTime() throws {
        // 10 km at 5:00/km → the fastest 5 km is 1500 s.
        let samples = stream(meters: 10_000, paceSecPerKm: 300)
        let time = try XCTUnwrap(BestEffort.fastestTime(forDistance: 5_000, in: samples))
        XCTAssertEqual(time, 1500, accuracy: 5)
    }

    func testInterpolatesBetweenSamples() throws {
        // 1 km at 4:00/km, sampled coarsely; the answer should still be ~240 s
        // rather than snapping to a sample boundary.
        let samples = stream(meters: 1_000, paceSecPerKm: 240)
        let time = try XCTUnwrap(BestEffort.fastestTime(forDistance: 1_000, in: samples))
        XCTAssertEqual(time, 240, accuracy: 2)
    }

    func testFindsTheFastSegmentNotTheAverage() throws {
        // 2 km easy at 6:00/km, then 1 km hard at 3:30/km.
        var samples = stream(meters: 2_000, paceSecPerKm: 360)
        let lastT = samples.last!.t
        let hardSpeed = 1000.0 / 210.0
        var t = lastT, d = 2_000.0
        while d < 3_000 {
            t += 5
            d += hardSpeed * 5
            samples.append(FITSample(t: t, lat: nil, lon: nil, hr: nil, alt: nil,
                                     speed: hardSpeed, cadence: nil, dist: min(d, 3_000)))
        }

        let best1k = try XCTUnwrap(BestEffort.fastestTime(forDistance: 1_000, in: samples))
        XCTAssertEqual(best1k, 210, accuracy: 8, "should find the hard kilometer")
    }

    func testReturnsNilWhenDistanceNeverReached() {
        let samples = stream(meters: 3_000, paceSecPerKm: 300)
        XCTAssertNil(BestEffort.fastestTime(forDistance: 5_000, in: samples))
    }

    func testHandlesEmptyAndDegenerateInput() {
        XCTAssertNil(BestEffort.fastestTime(forDistance: 1_000, in: []))
        XCTAssertNil(BestEffort.fastestTime(forDistance: 0, in: stream(meters: 5_000, paceSecPerKm: 300)))

        // Samples with no cumulative distance can't be measured.
        let noDist = (0..<10).map {
            FITSample(t: Double($0), lat: nil, lon: nil, hr: nil, alt: nil,
                      speed: nil, cadence: nil, dist: nil)
        }
        XCTAssertNil(BestEffort.fastestTime(forDistance: 100, in: noDist))
    }

    func testStationaryStreamDoesNotHang() {
        // Distance never increases — the pointer sweep must still terminate.
        let stalled = (0..<50).map {
            FITSample(t: Double($0) * 5, lat: nil, lon: nil, hr: nil, alt: nil,
                      speed: 0, cadence: nil, dist: 0)
        }
        XCTAssertNil(BestEffort.fastestTime(forDistance: 1_000, in: stalled))
    }
}

final class PersonalRecordsTests: XCTestCase {

    private func runWorkout(km: Double, paceSecPerKm: Double, daysAgo: Int) -> Workout {
        let speed = 1000 / paceSecPerKm
        let meters = km * 1000
        let duration = meters / speed
        let w = Workout(
            sport: .run,
            startedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!,
            duration: duration, distance: meters, source: "test"
        )
        var samples: [FITSample] = []
        var t = 0.0
        while t < duration {
            samples.append(FITSample(t: t, lat: nil, lon: nil, hr: nil, alt: nil,
                                     speed: speed, cadence: nil, dist: t * speed))
            t += 5
        }
        samples.append(FITSample(t: duration, lat: nil, lon: nil, hr: nil, alt: nil,
                                 speed: speed, cadence: nil, dist: meters))
        w.streamsData = try? JSONEncoder().encode(samples)
        return w
    }

    func testPicksFastestPerDistance() throws {
        let slow5k = runWorkout(km: 6, paceSecPerKm: 330, daysAgo: 10)
        let fast5k = runWorkout(km: 6, paceSecPerKm: 280, daysAgo: 3)
        let records = PersonalRecords.compute(from: [slow5k, fast5k].map(\.snapshot))

        let fiveK = try XCTUnwrap(records.first { $0.label == "5 km" })
        XCTAssertEqual(fiveK.time, 1400, accuracy: 15, "5 km at 4:40/km")
        XCTAssertEqual(fiveK.workoutID, fast5k.id)
    }

    func testShorterDistancesAlsoRecorded() {
        let records = PersonalRecords.compute(from: [runWorkout(km: 11, paceSecPerKm: 300, daysAgo: 1).snapshot])
        let labels = records.map(\.label)
        XCTAssertTrue(labels.contains("1 km"))
        XCTAssertTrue(labels.contains("5 km"))
        XCTAssertTrue(labels.contains("10 km"))
        XCTAssertFalse(labels.contains("Half marathon"), "never ran that far")
    }

    func testNonRunSportsExcluded() {
        let ride = runWorkout(km: 40, paceSecPerKm: 120, daysAgo: 2)
        ride.sport = .bike
        XCTAssertTrue(PersonalRecords.compute(from: [ride.snapshot]).isEmpty,
                      "bike splits shouldn't become running PRs")
    }

    func testWorkoutsWithoutStreamsIgnored() {
        let bare = Workout(sport: .run, startedAt: .now, duration: 3600,
                           distance: 12_000, source: "manual")
        XCTAssertTrue(PersonalRecords.compute(from: [bare.snapshot]).isEmpty)
    }

    func testMilestones() throws {
        let workouts = [
            runWorkout(km: 21, paceSecPerKm: 300, daysAgo: 5),
            runWorkout(km: 10, paceSecPerKm: 290, daysAgo: 4),
            runWorkout(km: 5, paceSecPerKm: 280, daysAgo: 3),
        ]
        workouts[1].elevationGain = 640

        let m = PersonalRecords.milestones(from: workouts.map(\.snapshot))
        XCTAssertEqual(m.totalWorkouts, 3)
        XCTAssertEqual(m.totalDistance, 36_000, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(m.longestRun).distance, 21_000, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(m.mostElevation).gain, 640, accuracy: 1)
        XCTAssertNotNil(m.biggestWeek)
    }

    /// Records must be computable off the main actor. Passing SwiftData
    /// models across that boundary crashed the app; snapshots must not.
    func testSnapshotsAreUsableOffTheMainActor() async throws {
        let workouts = [runWorkout(km: 6, paceSecPerKm: 300, daysAgo: 2)]
        let snapshots = workouts.map(\.snapshot)

        let records = await Task.detached(priority: .userInitiated) {
            PersonalRecords.compute(from: snapshots)
        }.value

        XCTAssertFalse(records.isEmpty)
    }

    func testSnapshotCarriesStreamsUndecoded() throws {
        let workout = runWorkout(km: 6, paceSecPerKm: 300, daysAgo: 1)
        let snapshot = workout.snapshot
        XCTAssertNotNil(snapshot.streamsData)
        XCTAssertEqual(snapshot.id, workout.id)
        XCTAssertFalse(snapshot.samples.isEmpty, "decoding happens lazily")
    }

    func testMilestonesOnEmptyHistory() {
        let m = PersonalRecords.milestones(from: [WorkoutSnapshot]())
        XCTAssertEqual(m.totalWorkouts, 0)
        XCTAssertNil(m.longestRun)
        XCTAssertNil(m.biggestWeek)
        XCTAssertNil(m.mostElevation)
    }
}
