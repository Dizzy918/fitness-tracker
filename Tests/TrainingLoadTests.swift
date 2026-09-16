import XCTest
@testable import FitnessTracker

/// Training load is the number every other judgement now hangs off — readiness,
/// the dashboard verdict, the ramp warning — so it's pinned against the
/// definitions it claims to implement rather than against its own output.
final class TrainingLoadTests: XCTestCase {

    // MARK: - Helpers

    private func snapshot(
        sport: WorkoutSport = .run,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        distance: Double = 10_000,
        duration: TimeInterval = 3600,
        avgHR: Int? = nil,
        samples: [FITSample] = []
    ) -> WorkoutSnapshot {
        WorkoutSnapshot(
            id: UUID(), sport: sport, startedAt: startedAt,
            distance: distance, duration: duration,
            elevationGain: nil, avgHeartRate: avgHR, maxHeartRate: nil,
            streamsData: samples.isEmpty ? nil : try? JSONEncoder().encode(samples)
        )
    }

    /// Steady HR for `seconds`, one sample a second.
    private func hrStream(bpm: Int, seconds: Int, dist: Double? = nil) -> [FITSample] {
        (0...seconds).map { i in
            FITSample(t: Double(i), hr: bpm,
                      dist: dist.map { $0 * Double(i) / Double(seconds) })
        }
    }

    private func powerStream(watts: Int, seconds: Int) -> [FITSample] {
        (0...seconds).map { FITSample(t: Double($0), power: watts) }
    }

    // MARK: - The defining identity

    /// The whole scale rests on this: one hour at threshold is 100.
    func testOneHourAtThresholdIsOneHundred() throws {
        let athlete = TrainingLoad.Athlete(maxHR: 190, restingHR: 50)
        // Threshold sits at 85% of heart-rate reserve: 50 + 0.85 × 140 = 169.
        let thresholdHR = 169

        let score = try XCTUnwrap(TrainingLoad.score(
            for: snapshot(samples: hrStream(bpm: thresholdHR, seconds: 3600)),
            athlete: athlete
        ))
        XCTAssertEqual(score.value, 100, accuracy: 2)
        XCTAssertEqual(score.intensityFactor ?? 0, 1.0, accuracy: 0.02)
        XCTAssertEqual(score.method, .heartRateStream)
    }

    func testOneHourAtFTPIsOneHundred() throws {
        let athlete = TrainingLoad.Athlete(ftp: 250)
        let score = try XCTUnwrap(TrainingLoad.score(
            for: snapshot(sport: .bike, samples: powerStream(watts: 250, seconds: 3600)),
            athlete: athlete
        ))
        XCTAssertEqual(score.value, 100, accuracy: 1)
        XCTAssertEqual(score.method, .power)
    }

    /// Half the intensity for the same hour costs a quarter of the stress —
    /// that squaring is what makes easy volume cheap and intervals expensive.
    func testStressScalesWithTheSquareOfIntensity() throws {
        let athlete = TrainingLoad.Athlete(maxHR: 190, restingHR: 50)
        // 50% of threshold intensity: reserve fraction 0.425 → 50 + 59.5 ≈ 110.
        let easy = try XCTUnwrap(TrainingLoad.score(
            for: snapshot(samples: hrStream(bpm: 110, seconds: 3600)),
            athlete: athlete
        ))
        XCTAssertEqual(easy.value, 25, accuracy: 3)
    }

    // MARK: - Why the stream matters

    /// The point of integrating per sample: an interval session and a steady
    /// session at the same *average* heart rate are not the same training
    /// stress, and only the stream can tell them apart.
    func testIntervalsScoreHigherThanSteadyAtTheSameAverageHR() throws {
        let athlete = TrainingLoad.Athlete(maxHR: 190, restingHR: 50)

        // Alternating 4 minutes hard / 4 minutes easy, averaging 145 bpm.
        var intervals: [FITSample] = []
        for minute in 0..<60 {
            let bpm = (minute / 4) % 2 == 0 ? 175 : 115
            for second in 0..<60 {
                intervals.append(FITSample(t: Double(minute * 60 + second), hr: bpm))
            }
        }
        let steady = hrStream(bpm: 145, seconds: 3599)

        let a = try XCTUnwrap(TrainingLoad.score(for: snapshot(samples: intervals), athlete: athlete))
        let b = try XCTUnwrap(TrainingLoad.score(for: snapshot(samples: steady), athlete: athlete))

        XCTAssertGreaterThan(a.value, b.value * 1.05,
                             "intervals must cost more than steady at the same mean HR")
    }

    func testMethodFallsBackThroughTheChain() throws {
        let full = TrainingLoad.Athlete(ftp: 250, maxHR: 190, restingHR: 50,
                                        thresholdPaceSecPerKm: 240)

        // Power wins when it's there.
        XCTAssertEqual(TrainingLoad.score(
            for: snapshot(sport: .bike, samples: powerStream(watts: 200, seconds: 600)),
            athlete: full)?.method, .power)

        // No power stream, but a HR stream.
        XCTAssertEqual(TrainingLoad.score(
            for: snapshot(samples: hrStream(bpm: 150, seconds: 600)),
            athlete: full)?.method, .heartRateStream)

        // No streams at all, but an average HR from the provider.
        XCTAssertEqual(TrainingLoad.score(
            for: snapshot(avgHR: 150), athlete: full)?.method, .averageHeartRate)

        // No heart rate anywhere: fall to pace.
        let noHR = TrainingLoad.Athlete(thresholdPaceSecPerKm: 240)
        XCTAssertEqual(TrainingLoad.score(for: snapshot(), athlete: noHR)?.method, .pace)

        // Nothing at all.
        XCTAssertEqual(TrainingLoad.score(for: snapshot(), athlete: .init())?.method, .duration)
    }

    func testUnmeasuredSessionsStillCountButAreLabelled() throws {
        let score = try XCTUnwrap(TrainingLoad.score(for: snapshot(), athlete: .init()))
        XCTAssertGreaterThan(score.value, 0)
        XCTAssertFalse(score.method.isMeasured)
    }

    // MARK: - Robustness

    func testDropoutGapsDoNotInflateLoad() throws {
        let athlete = TrainingLoad.Athlete(maxHR: 190, restingHR: 50)
        // Ten minutes recorded, then the watch stops for two hours, then one
        // more sample. The gap must not be charged as two hours at threshold.
        var samples = hrStream(bpm: 169, seconds: 600)
        samples.append(FITSample(t: 600 + 7200, hr: 169))

        let score = try XCTUnwrap(TrainingLoad.score(
            for: snapshot(duration: 7800, samples: samples), athlete: athlete))
        XCTAssertEqual(score.value, 100.0 / 6, accuracy: 2)
    }

    func testAbsurdHeartRateIsClamped() {
        let athlete = TrainingLoad.Athlete(maxHR: 190, restingHR: 50)
        let intensity = TrainingLoad.intensityFactor(forHeartRate: 400, rest: 50, reserve: 140)
        XCTAssertLessThanOrEqual(intensity, 1.5)
        XCTAssertEqual(TrainingLoad.intensityFactor(forHeartRate: 20, rest: 50, reserve: 140), 0)
        XCTAssertNil(TrainingLoad.score(for: snapshot(duration: 0), athlete: athlete))
    }

    func testMissingMaxHRSkipsHeartRateMethodsEntirely() {
        // A resting HR without a max gives no reserve, so HR can't be scaled.
        let athlete = TrainingLoad.Athlete(restingHR: 50)
        let score = TrainingLoad.score(
            for: snapshot(samples: hrStream(bpm: 169, seconds: 3600)), athlete: athlete)
        XCTAssertEqual(score?.method, .duration)
    }

    // MARK: - Multi-sport, which is the entire point

    /// The old model summed metres, so this ride outweighed the run four to one
    /// and the swim vanished. Stress puts them on one scale.
    func testHardSwimOutranksAnEasyLongRideDespiteTheDistance() throws {
        let athlete = TrainingLoad.Athlete(maxHR: 190, restingHR: 50)

        let swim = try XCTUnwrap(TrainingLoad.score(
            for: snapshot(sport: .swim, distance: 2_000, duration: 2700,
                          samples: hrStream(bpm: 172, seconds: 2700)),
            athlete: athlete))
        let ride = try XCTUnwrap(TrainingLoad.score(
            for: snapshot(sport: .bike, distance: 80_000, duration: 10800,
                          samples: hrStream(bpm: 112, seconds: 10800)),
            athlete: athlete))

        XCTAssertGreaterThan(swim.value, 70)
        XCTAssertGreaterThan(ride.value, 0)
        // Distance says the ride is 40× bigger; stress says it's about twice.
        XCTAssertLessThan(ride.value / swim.value, 4)
    }

    func testStrengthSessionsCarryLoad() throws {
        let hard = StrengthSessionSnapshot(
            id: UUID(), startedAt: .now,
            sets: (0..<20).map {
                StrengthSetSnapshot(reps: 5, weightKg: 100, isWarmup: false,
                                    exerciseID: nil, category: "squat",
                                    rpe: $0 < 10 ? 9 : 9.5)
            })
        let easy = StrengthSessionSnapshot(
            id: UUID(), startedAt: .now,
            sets: (0..<20).map { _ in
                StrengthSetSnapshot(reps: 5, weightKg: 40, isWarmup: false,
                                    exerciseID: nil, category: "squat", rpe: 6)
            })

        let hardScore = try XCTUnwrap(TrainingLoad.score(for: hard))
        let easyScore = try XCTUnwrap(TrainingLoad.score(for: easy))
        XCTAssertGreaterThan(hardScore.value, easyScore.value)
        XCTAssertNil(TrainingLoad.score(for: StrengthSessionSnapshot(
            id: UUID(), startedAt: .now, sets: [])))
    }

    func testWarmupSetsDoNotCountTowardLoad() throws {
        let session = StrengthSessionSnapshot(
            id: UUID(), startedAt: .now,
            sets: (0..<10).map { i in
                StrengthSetSnapshot(reps: 5, weightKg: 60, isWarmup: i < 5,
                                    exerciseID: nil, category: "squat", rpe: 8)
            })
        let allWorking = StrengthSessionSnapshot(
            id: UUID(), startedAt: .now,
            sets: (0..<10).map { _ in
                StrengthSetSnapshot(reps: 5, weightKg: 60, isWarmup: false,
                                    exerciseID: nil, category: "squat", rpe: 8)
            })
        XCTAssertLessThan(try XCTUnwrap(TrainingLoad.score(for: session)).value,
                          try XCTUnwrap(TrainingLoad.score(for: allWorking)).value)
    }

    // MARK: - Fitness / fatigue curves

    func testConstantTrainingConvergesOnItsDailyLoad() {
        // Feed 50 TSS a day for a year: both averages must approach 50 and form
        // must settle near zero. That's the definition of an EWMA at steady state.
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_600_000_000))
        var totals: [Date: Double] = [:]
        for day in 0..<365 {
            totals[calendar.date(byAdding: .day, value: day, to: start)!] = 50
        }
        let end = calendar.date(byAdding: .day, value: 364, to: start)!
        let series = TrainingLoad.series(dailyTotals: totals, through: end)

        XCTAssertEqual(series.count, 365)
        let last = series.last!
        XCTAssertEqual(last.fitness, 50, accuracy: 1)
        XCTAssertEqual(last.fatigue, 50, accuracy: 1)
        XCTAssertEqual(last.form, 0, accuracy: 1)
        XCTAssertEqual(last.acuteChronicRatio ?? 0, 1, accuracy: 0.05)
    }

    /// Fatigue has a 7-day constant and fitness a 42-day one, so after a hard
    /// block fatigue must be the one that's higher — that's what "form" measures.
    func testFatigueRisesFasterThanFitness() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_600_000_000))
        var totals: [Date: Double] = [:]
        for day in 0..<14 {
            totals[calendar.date(byAdding: .day, value: day, to: start)!] = 100
        }
        let end = calendar.date(byAdding: .day, value: 13, to: start)!
        let series = TrainingLoad.series(dailyTotals: totals, through: end)

        let last = series.last!
        XCTAssertGreaterThan(last.fatigue, last.fitness)
        XCTAssertLessThan(last.form, 0)
        XCTAssertEqual(TrainingLoad.verdict(for: last), .overreaching)
    }

    /// Rest days must decay the curves, not be skipped. A gap in the dictionary
    /// is a zero-load day, not an absent one.
    func testRestDaysAreEmittedAndDecayTheCurves() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_600_000_000))
        let totals: [Date: Double] = [start: 200]
        let end = calendar.date(byAdding: .day, value: 20, to: start)!
        let series = TrainingLoad.series(dailyTotals: totals, through: end)

        XCTAssertEqual(series.count, 21, "rest days must still appear in the series")
        XCTAssertTrue(series.dropFirst().allSatisfy { $0.load == 0 })
        XCTAssertLessThan(series.last!.fatigue, series.first!.fatigue)
        XCTAssertGreaterThan(series.last!.form, 0, "three weeks off leaves you fresh")
    }

    func testEmptyHistoryProducesNoSeries() {
        XCTAssertTrue(TrainingLoad.series(dailyTotals: [:]).isEmpty)
        XCTAssertNil(TrainingLoad.weeklyRamp([]))
    }

    func testRampMeasuresFitnessChangeOverAWeek() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_600_000_000))
        var totals: [Date: Double] = [:]
        for day in 0..<30 {
            totals[calendar.date(byAdding: .day, value: day, to: start)!] = 80
        }
        let end = calendar.date(byAdding: .day, value: 29, to: start)!
        let series = TrainingLoad.series(dailyTotals: totals, through: end)
        let ramp = try? XCTUnwrap(TrainingLoad.weeklyRamp(series))
        XCTAssertGreaterThan(ramp ?? 0, 0, "fitness is still building at day 30")
    }

    // MARK: - Daily aggregation

    func testTwoSessionsOnOneDaySumIntoOneTotal() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let athlete = TrainingLoad.Athlete(maxHR: 190, restingHR: 50)
        let totals = TrainingLoad.dailyTotals(
            workouts: [
                snapshot(startedAt: day, samples: hrStream(bpm: 169, seconds: 1800)),
                snapshot(startedAt: day.addingTimeInterval(3600),
                         samples: hrStream(bpm: 169, seconds: 1800)),
            ],
            athlete: athlete
        )
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals.values.first ?? 0, 100, accuracy: 3)
    }

    func testStrengthAndCardioLandOnTheSameDayKey() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let totals = TrainingLoad.dailyTotals(
            workouts: [snapshot(startedAt: day)],
            strength: [StrengthSessionSnapshot(
                id: UUID(), startedAt: day.addingTimeInterval(7200),
                sets: [StrengthSetSnapshot(reps: 5, weightKg: 100, isWarmup: false,
                                           exerciseID: nil, category: "squat", rpe: 8)])],
            athlete: .init()
        )
        XCTAssertEqual(totals.count, 1, "both sessions belong to the same day")
    }

    // MARK: - Profile assembly

    func testAthleteProfilePrefersSettingsOverObservedValues() {
        let defaults = UserDefaults(suiteName: "TrainingLoadTests.profile")!
        defaults.removePersistentDomain(forName: "TrainingLoadTests.profile")
        defaults.set(200, forKey: AthleteProfile.Key.maxHeartRate)
        defaults.set(275, forKey: AthleteProfile.Key.ftpWatts)

        let workouts = [WorkoutSnapshot(id: UUID(), sport: .run, startedAt: .now,
                                        distance: 10_000, duration: 3000,
                                        maxHeartRate: 185)]
        let athlete = AthleteProfile.make(workouts: workouts, restingHR: 48, defaults: defaults)
        XCTAssertEqual(athlete.maxHR, 200)
        XCTAssertEqual(athlete.ftp, 275)
        XCTAssertEqual(athlete.restingHR, 48)
        defaults.removePersistentDomain(forName: "TrainingLoadTests.profile")
    }

    func testAthleteProfileFallsBackToObservedMaxHR() {
        let defaults = UserDefaults(suiteName: "TrainingLoadTests.fallback")!
        defaults.removePersistentDomain(forName: "TrainingLoadTests.fallback")

        let workouts = [WorkoutSnapshot(id: UUID(), sport: .run, startedAt: .now,
                                        distance: 10_000, duration: 3000,
                                        maxHeartRate: 188)]
        let athlete = AthleteProfile.make(workouts: workouts, defaults: defaults)
        XCTAssertEqual(athlete.maxHR, 188)
        XCTAssertNil(athlete.ftp)
        defaults.removePersistentDomain(forName: "TrainingLoadTests.fallback")
    }

    func testThresholdPaceIgnoresShortRunsAndOtherSports() {
        let fastShort = WorkoutSnapshot(id: UUID(), sport: .run, startedAt: .now,
                                        distance: 1_000, duration: 180)      // 3:00/km
        let ride = WorkoutSnapshot(id: UUID(), sport: .bike, startedAt: .now,
                                   distance: 40_000, duration: 3600)         // 1:30/km
        let tempo = WorkoutSnapshot(id: UUID(), sport: .run, startedAt: .now,
                                    distance: 10_000, duration: 2400)        // 4:00/km

        let pace = AthleteProfile.thresholdPace(from: [fastShort, ride, tempo])
        XCTAssertEqual(pace ?? 0, 240 * 1.03, accuracy: 1)
        XCTAssertNil(AthleteProfile.thresholdPace(from: [ride]))
    }
}
