import XCTest
import SwiftData
@testable import FitnessTracker

/// How the training-load curve scales.
///
/// The dashboard computes this on every appearance, and it walks every workout
/// ever recorded. With demo data that's 62 sessions; a real athlete four years
/// in has closer to a thousand, each carrying a few thousand samples — so the
/// cost per workout is the whole story, and the cheapest place to get it wrong
/// is decoding the same stream more than once.
final class LoadPerformanceTests: XCTestCase {

    private let athlete = TrainingLoad.Athlete(
        ftp: 250, maxHR: 190, restingHR: 45, thresholdPaceSecPerKm: 240)

    /// A workout with a realistic per-second stream.
    private func workout(index: Int, sport: WorkoutSport, samples sampleCount: Int)
    -> WorkoutSnapshot {
        let samples = (0..<sampleCount).map { second in
            FITSample(t: Double(second), lat: nil, lon: nil,
                      hr: 140 + (second % 25),
                      alt: nil, speed: 3.2,
                      cadence: 85, dist: Double(second) * 3.2,
                      power: sport == .bike ? 210 + (second % 40) : nil)
        }
        return WorkoutSnapshot(
            id: UUID(), sport: sport,
            startedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 86_400),
            distance: Double(sampleCount) * 3.2,
            duration: Double(sampleCount),
            elevationGain: 120, avgHeartRate: 150, maxHeartRate: 175,
            streamsData: try? JSONEncoder().encode(samples))
    }

    private func season(_ count: Int, samples: Int = 2_700) -> [WorkoutSnapshot] {
        (0..<count).map {
            workout(index: $0, sport: $0 % 3 == 0 ? .bike : .run, samples: samples)
        }
    }

    /// Four years of training, built the way the dashboard builds it.
    ///
    /// The budget is deliberately loose — this is a regression guard against an
    /// order-of-magnitude mistake, not a benchmark. Decoding each stream twice
    /// instead of once is exactly that kind of mistake.
    /// The first build of a full history, with nothing cached.
    func testAFullHistoryBuildsInReasonableTime() throws {
        let workouts = season(400)
        let started = Date()
        let totals = TrainingLoad.dailyTotals(workouts: workouts, athlete: athlete,
                                              cache: nil)
        let series = TrainingLoad.series(dailyTotals: totals,
                                         through: workouts.last!.startedAt)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(totals.count, 400)
        XCTAssertGreaterThan(series.count, 390)
        print("  cold, 400 workouts × 2700 samples: \(String(format: "%.2f", elapsed))s")
        XCTAssertLessThan(elapsed, 20, "took \(elapsed)s")
    }

    /// The build that actually matters: every dashboard appearance after the
    /// first. Nothing has changed, so nothing should be recomputed.
    func testRebuildingAnUnchangedHistoryIsNearlyFree() throws {
        let workouts = season(400)
        let cache = TrainingLoad.ScoreCache()

        let coldStart = Date()
        _ = TrainingLoad.dailyTotals(workouts: workouts, athlete: athlete, cache: cache)
        let cold = Date().timeIntervalSince(coldStart)

        let warmStart = Date()
        let totals = TrainingLoad.dailyTotals(workouts: workouts, athlete: athlete,
                                              cache: cache)
        let warm = Date().timeIntervalSince(warmStart)

        XCTAssertEqual(totals.count, 400)
        print("  cold \(String(format: "%.2f", cold))s → "
              + "warm \(String(format: "%.3f", warm))s")
        XCTAssertLessThan(warm, cold / 20,
                          "a rebuild with nothing changed cost \(warm)s against \(cold)s cold")
        XCTAssertLessThan(warm, 0.5)
    }

    /// The same numbers, cached or not. A faster wrong answer is no use.
    func testCachingDoesNotChangeTheAnswer() throws {
        let workouts = season(40, samples: 900)
        let direct = TrainingLoad.dailyTotals(workouts: workouts, athlete: athlete,
                                              cache: nil)
        let cache = TrainingLoad.ScoreCache()
        _ = TrainingLoad.dailyTotals(workouts: workouts, athlete: athlete, cache: cache)
        let cached = TrainingLoad.dailyTotals(workouts: workouts, athlete: athlete,
                                              cache: cache)

        XCTAssertEqual(direct.count, cached.count)
        for (day, value) in direct {
            XCTAssertEqual(cached[day] ?? -1, value, accuracy: 0.000_001)
        }
    }

    /// Changing the profile changes every score, so the cache must not serve
    /// the old ones.
    func testChangingTheAthleteInvalidatesTheCache() throws {
        let workouts = season(20, samples: 900)
        let cache = TrainingLoad.ScoreCache()

        let first = TrainingLoad.dailyTotals(workouts: workouts, athlete: athlete,
                                             cache: cache)
        // A much lower max HR makes every session read as harder.
        let fitter = TrainingLoad.Athlete(ftp: nil, maxHR: 165, restingHR: 45)
        let second = TrainingLoad.dailyTotals(workouts: workouts, athlete: fitter,
                                              cache: cache)

        XCTAssertEqual(first.count, second.count)
        XCTAssertNotEqual(first.values.reduce(0, +), second.values.reduce(0, +),
                          accuracy: 0.001)
    }

    /// Editing a workout's duration changes its load, cache or no cache.
    func testEditingAWorkoutInvalidatesItsEntry() throws {
        let cache = TrainingLoad.ScoreCache()
        let original = workout(index: 0, sport: .run, samples: 600)
        _ = TrainingLoad.dailyTotals(workouts: [original], athlete: athlete, cache: cache)

        var edited = original
        edited = WorkoutSnapshot(
            id: original.id, sport: original.sport, startedAt: original.startedAt,
            distance: original.distance, duration: original.duration * 2,
            elevationGain: original.elevationGain,
            avgHeartRate: original.avgHeartRate, maxHeartRate: original.maxHeartRate,
            streamsData: nil)
        let after = TrainingLoad.dailyTotals(workouts: [edited], athlete: athlete,
                                             cache: cache)
        let before = TrainingLoad.dailyTotals(workouts: [original], athlete: athlete,
                                              cache: TrainingLoad.ScoreCache())

        XCTAssertNotEqual(after.values.first ?? 0, before.values.first ?? 0,
                          accuracy: 0.001)
    }

    /// Deleted workouts must not accumulate in the cache forever.
    func testDeletedWorkoutsArePrunedFromTheCache() throws {
        let cache = TrainingLoad.ScoreCache()
        let workouts = season(30, samples: 300)
        _ = TrainingLoad.dailyTotals(workouts: workouts, athlete: athlete, cache: cache)
        XCTAssertEqual(cache.count, 30)

        _ = TrainingLoad.dailyTotals(workouts: Array(workouts.prefix(5)),
                                     athlete: athlete, cache: cache)
        XCTAssertEqual(cache.count, 5)
    }

    /// A workout with no streams must not pay for machinery it can't use.
    func testStreamlessWorkoutsAreCheap() {
        let bare = (0..<2_000).map { index in
            WorkoutSnapshot(
                id: UUID(), sport: .run,
                startedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 3_600),
                distance: 10_000, duration: 2_700,
                elevationGain: nil, avgHeartRate: 150, maxHeartRate: nil,
                streamsData: nil)
        }
        let started = Date()
        _ = TrainingLoad.dailyTotals(workouts: bare, athlete: athlete)
        let elapsed = Date().timeIntervalSince(started)
        print("  2000 streamless workouts: \(String(format: "%.3f", elapsed))s")
        XCTAssertLessThan(elapsed, 0.5, "took \(elapsed)s")
    }
}

/// What building snapshots costs on the main actor.
///
/// `Workout.streamsData` is `@Attribute(.externalStorage)`: SwiftData keeps the
/// blob in a file and reads it when the property is touched. Mapping every
/// workout to a snapshot therefore faults in every stream — on the main actor,
/// before any of the work is handed off — and that is what leaves the dashboard
/// blank rather than slow.
@MainActor
final class SnapshotFaultingTests: XCTestCase {

    /// A store of this test's own, on disk and thrown away afterwards.
    ///
    /// On disk because that is the whole point: `.externalStorage` only faults
    /// when there is a file to fault from, so an in-memory store would make the
    /// test measure nothing. Its *own* file because the default configuration
    /// resolves to the app's real database — the test host is the app — so this
    /// used to insert 200 workouts into the user's training history on every
    /// run, and then skip itself, because the re-fetch below found the
    /// accumulated rows instead of the 200 it had just written.
    private var storeURL: URL!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotFaulting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("faulting.store")
    }

    override func tearDownWithError() throws {
        if let directory = storeURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: directory)
        }
        storeURL = nil
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(url: storeURL)
        )
        return ModelContext(container)
    }

    private func stream(seconds: Int) -> Data {
        let samples = (0..<seconds).map {
            FITSample(t: Double($0), lat: 42.7, lon: 23.3, hr: 150, alt: 600,
                      speed: 3.2, cadence: 85, dist: Double($0) * 3.2, power: 220)
        }
        return (try? JSONEncoder().encode(samples)) ?? Data()
    }

    func testFullSnapshotsFaultInEveryStreamAndLightOnesDoNot() throws {
        let context = try makeContext()
        let blob = stream(seconds: 2_000)
        for index in 0..<200 {
            let workout = Workout(
                sport: .run,
                startedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 86_400),
                duration: 2_000, distance: 6_400, source: "test",
                externalID: "perf-\(index)")
            workout.avgHeartRate = 150
            workout.streamsData = blob
            context.insert(workout)
        }
        try context.save()

        // Re-fetch so nothing is already faulted in.
        let fresh = try makeContext()
        let stored = try fresh.fetch(FetchDescriptor<Workout>())
        // A fresh store makes this exact. It used to be a skip, which is how it
        // went unnoticed that the test had stopped running at all.
        XCTAssertEqual(stored.count, 200, "the store should hold exactly what this test wrote")

        let lightStart = Date()
        let light = stored.map(\.lightSnapshot)
        let lightCost = Date().timeIntervalSince(lightStart)

        let fullStart = Date()
        let full = stored.map(\.snapshot)
        let fullCost = Date().timeIntervalSince(fullStart)

        XCTAssertEqual(light.count, 200)
        XCTAssertTrue(light.allSatisfy { $0.streamsData == nil })
        XCTAssertTrue(full.allSatisfy { $0.streamsData != nil })
        print("  200 snapshots — light \(String(format: "%.3f", lightCost))s, "
              + "full \(String(format: "%.3f", fullCost))s")
        XCTAssertLessThan(lightCost, max(fullCost, 0.001),
                          "a snapshot without streams should not cost what one with them does")
    }
}

/// The dashboard's own path: light snapshots for anything the cache knows,
/// full ones only for what it doesn't.
final class CacheMissFaultingTests: XCTestCase {

    private let athlete = TrainingLoad.Athlete(
        ftp: 250, maxHR: 190, restingHR: 45, thresholdPaceSecPerKm: 240)

    private func snapshot(index: Int, streams: Bool) -> WorkoutSnapshot {
        let samples = (0..<600).map {
            FITSample(t: Double($0), lat: nil, lon: nil, hr: 150, alt: nil,
                      speed: 3.2, cadence: 85, dist: Double($0) * 3.2, power: nil)
        }
        return WorkoutSnapshot(
            id: UUID(), sport: .run,
            startedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 86_400),
            distance: 1_920, duration: 600,
            elevationGain: nil, avgHeartRate: 150, maxHeartRate: 175,
            streamsData: streams ? try? JSONEncoder().encode(samples) : nil)
    }

    func testCacheAnswersWithoutNeedingTheStream() {
        let cache = TrainingLoad.ScoreCache()
        let full = snapshot(index: 0, streams: true)

        XCTAssertFalse(cache.canAnswer(full, athlete: athlete),
                       "nothing is known before the first score")
        _ = cache.score(for: full, athlete: athlete)

        // The same workout, minus its stream: the key is scalars only, so this
        // is the same entry.
        let light = WorkoutSnapshot(
            id: full.id, sport: full.sport, startedAt: full.startedAt,
            distance: full.distance, duration: full.duration,
            elevationGain: full.elevationGain, avgHeartRate: full.avgHeartRate,
            maxHeartRate: full.maxHeartRate, streamsData: nil)

        XCTAssertTrue(cache.canAnswer(light, athlete: athlete))
        XCTAssertEqual(cache.score(for: light, athlete: athlete)?.value ?? -1,
                       cache.score(for: full, athlete: athlete)?.value ?? -2,
                       accuracy: 0.000_001,
                       "answering from a light snapshot must give the stream's answer")
    }

    /// A stream arriving later changes the score without changing any scalar,
    /// so the writer has to say so. This is the contract `SyncEngine` relies on.
    func testForgettingLetsALaterStreamChangeTheScore() {
        let cache = TrainingLoad.ScoreCache()
        let bare = snapshot(index: 0, streams: false)
        let withStream = WorkoutSnapshot(
            id: bare.id, sport: bare.sport, startedAt: bare.startedAt,
            distance: bare.distance, duration: bare.duration,
            elevationGain: bare.elevationGain, avgHeartRate: bare.avgHeartRate,
            maxHeartRate: bare.maxHeartRate,
            streamsData: snapshot(index: 0, streams: true).streamsData)

        let fromAverage = cache.score(for: bare, athlete: athlete)
        XCTAssertEqual(fromAverage?.method, .averageHeartRate)

        // Without forgetting, the cache keeps serving the average-HR answer.
        XCTAssertEqual(cache.score(for: withStream, athlete: athlete)?.method,
                       .averageHeartRate)

        cache.forget(bare.id)
        XCTAssertEqual(cache.score(for: withStream, athlete: athlete)?.method,
                       .heartRateStream,
                       "after forgetting, the stream is used")
    }

    /// Concurrent readers must not corrupt the cache or each other's answers.
    func testCacheIsSafeUnderConcurrentUse() {
        let cache = TrainingLoad.ScoreCache()
        let workouts = (0..<50).map { snapshot(index: $0, streams: false) }
        let expected = workouts.map {
            TrainingLoad.score(for: $0, athlete: athlete)?.value ?? -1
        }

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for (index, workout) in workouts.enumerated() {
                let value = cache.score(for: workout, athlete: athlete)?.value ?? -1
                XCTAssertEqual(value, expected[index], accuracy: 0.000_001)
            }
        }
        XCTAssertEqual(cache.count, 50)
    }
}
