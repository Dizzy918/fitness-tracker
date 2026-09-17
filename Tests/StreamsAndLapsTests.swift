import XCTest
import SwiftData
@testable import FitnessTracker

/// Strava stream ingestion and watch-lap handling.
@MainActor
final class StreamsAndLapsTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Workout.self, Shoe.self, StrengthSession.self, SetEntry.self,
            Exercise.self, DailyMetric.self, Route.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    // MARK: - Strava stream parsing

    private let fullStreams = Data(#"""
    {
      "time":      {"data": [0, 1, 2, 3]},
      "distance":  {"data": [0.0, 3.2, 6.5, 9.9]},
      "latlng":    {"data": [[42.70, 23.32], [42.71, 23.33], [42.72, 23.34], [42.73, 23.35]]},
      "altitude":  {"data": [550.0, 551.0, 552.5, 553.0]},
      "heartrate": {"data": [120, 128, 134, 141]},
      "cadence":   {"data": [82, 84, 85, 86]},
      "watts":     {"data": [210, 225, 240, 233]},
      "velocity_smooth": {"data": [3.1, 3.2, 3.3, 3.4]}
    }
    """#.utf8)

    func testEveryChannelLandsOnTheSample() throws {
        let detail = try StravaProvider.parseStreams(fullStreams)
        XCTAssertEqual(detail.samples.count, 4)

        let third = detail.samples[2]
        XCTAssertEqual(third.t, 2)
        XCTAssertEqual(third.dist ?? 0, 6.5, accuracy: 0.001)
        XCTAssertEqual(third.lat ?? 0, 42.72, accuracy: 0.0001)
        XCTAssertEqual(third.lon ?? 0, 23.34, accuracy: 0.0001)
        XCTAssertEqual(third.alt ?? 0, 552.5, accuracy: 0.001)
        XCTAssertEqual(third.hr, 134)
        XCTAssertEqual(third.cadence, 85)
        XCTAssertEqual(third.power, 240)
        XCTAssertEqual(third.speed ?? 0, 3.3, accuracy: 0.001)
    }

    /// The whole point of fetching streams: they feed the analysis that a
    /// summary-only activity can't support.
    func testStreamsFeedSplitsZonesAndLoad() throws {
        let detail = try StravaProvider.parseStreams(Data(#"""
        {
          "time":      {"data": [\#(stride(from: 0, to: 1200, by: 1).map(String.init).joined(separator: ","))]},
          "distance":  {"data": [\#(stride(from: 0, to: 1200, by: 1).map { String(Double($0) * 3.5) }.joined(separator: ","))]},
          "heartrate": {"data": [\#(Array(repeating: "165", count: 1200).joined(separator: ","))]}
        }
        """#.utf8))

        XCTAssertEqual(detail.samples.count, 1200)

        // 4.2 km covered at 3.5 m/s → four full km splits.
        let splits = SplitCalculator.splits(from: detail.samples)
        XCTAssertEqual(splits.filter { !$0.isPartial }.count, 4)

        // Time in zones, which a summary-only activity cannot produce at all.
        let zones = HRZones(maxHR: 190).timeInZones(detail.samples)
        XCTAssertFalse(zones.isEmpty)

        // And a heart-rate-stream load rather than a duration guess.
        let snapshot = WorkoutSnapshot(
            id: UUID(), sport: .run, startedAt: .now,
            distance: 4_200, duration: 1_200,
            streamsData: try JSONEncoder().encode(detail.samples))
        let score = TrainingLoad.score(
            for: snapshot, athlete: .init(maxHR: 190, restingHR: 50))
        XCTAssertEqual(score?.method, .heartRateStream)
    }

    /// Strava omits a key entirely when the channel wasn't recorded. A ride
    /// without a power meter must still import everything else.
    func testMissingChannelsCostOnlyThoseFields() throws {
        let detail = try StravaProvider.parseStreams(Data(#"""
        {"time": {"data": [0, 1]}, "distance": {"data": [0.0, 3.0]}}
        """#.utf8))
        XCTAssertEqual(detail.samples.count, 2)
        XCTAssertNil(detail.samples[0].hr)
        XCTAssertNil(detail.samples[0].power)
        XCTAssertNil(detail.samples[0].lat)
        XCTAssertTrue(detail.coordinates.isEmpty)
    }

    /// A ragged channel must truncate itself, not the activity.
    func testShortChannelDoesNotTruncateTheRest() throws {
        let detail = try StravaProvider.parseStreams(Data(#"""
        {
          "time":      {"data": [0, 1, 2, 3]},
          "heartrate": {"data": [120, 128]}
        }
        """#.utf8))
        XCTAssertEqual(detail.samples.count, 4)
        XCTAssertEqual(detail.samples[1].hr, 128)
        XCTAssertNil(detail.samples[3].hr, "past the end of a short channel")
    }

    func testNoTimeChannelFallsBackToOneHertz() throws {
        let detail = try StravaProvider.parseStreams(Data(#"""
        {"heartrate": {"data": [120, 128, 134]}}
        """#.utf8))
        XCTAssertEqual(detail.samples.map(\.t), [0, 1, 2])
    }

    func testFullResolutionTrackReplacesTheSummaryPolyline() throws {
        let detail = try StravaProvider.parseStreams(fullStreams)
        XCTAssertEqual(detail.coordinates.count, 4)
        XCTAssertEqual(detail.coordinates[0][0], 42.70, accuracy: 0.0001)
    }

    func testImpossibleCoordinatesAreDropped() throws {
        let detail = try StravaProvider.parseStreams(Data(#"""
        {"latlng": {"data": [[42.7, 23.3], [999.0, 23.3], [42.8, 23.4]]}}
        """#.utf8))
        XCTAssertEqual(detail.coordinates.count, 2)
    }

    func testEmptyAndMalformedStreams() throws {
        XCTAssertTrue(try StravaProvider.parseStreams(Data("{}".utf8)).isEmpty)
        XCTAssertThrowsError(try StravaProvider.parseStreams(Data("not json".utf8)))
    }

    func testExternalIDIsStrippedToTheNumericID() {
        XCTAssertEqual(StravaProvider.numericID(from: "strava:14237788123"), "14237788123")
        XCTAssertEqual(StravaProvider.numericID(from: "14237788123"), "14237788123")
    }

    // MARK: - Rate limiting

    func testBudgetIsReadFromStravaHeaders() throws {
        let budget = try XCTUnwrap(RateLimitBudget.strava(from: [
            "X-RateLimit-Limit": "200,2000",
            "X-RateLimit-Usage": "45,310",
        ]))
        XCTAssertEqual(budget.shortTermRemaining, 155)
        XCTAssertEqual(budget.dailyRemaining, 1690)
        // Short-term is the binding constraint, minus a reserve.
        XCTAssertEqual(budget.affordableRequests(reserve: 10), 145)
    }

    func testBudgetHandlesMissingAndMalformedHeaders() {
        XCTAssertNil(RateLimitBudget.strava(from: nil))
        XCTAssertNil(RateLimitBudget.strava(from: ["X-RateLimit-Limit": "200,2000"]))
        XCTAssertNil(RateLimitBudget.strava(from: [
            "X-RateLimit-Limit": "nonsense", "X-RateLimit-Usage": "45,310",
        ]))
    }

    /// An exhausted budget must report zero rather than a negative allowance.
    func testExhaustedBudgetAffordsNothing() {
        let budget = RateLimitBudget(shortTermUsed: 200, shortTermLimit: 200,
                                     dailyUsed: 1990, dailyLimit: 2000)
        XCTAssertEqual(budget.affordableRequests(), 0)
        XCTAssertEqual(budget.shortTermRemaining, 0)
    }

    // MARK: - Backfill

    /// A stub provider that counts requests and can be told to fail.
    private struct StubProvider: ActivityProvider {
        let kind: ProviderKind = .strava
        var isConfigured: Bool { true }
        var supportsStreams: Bool { true }
        let counter: Counter
        var failWith: ProviderError?
        var detail: ActivityDetail

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            var count: Int { lock.withLock { value } }
            func increment() { lock.withLock { value += 1 } }
        }

        func fetchActivities(since: Date?) async throws -> [RemoteActivity] { [] }

        func fetchDetail(externalID: String) async throws -> ActivityDetail {
            counter.increment()
            if let failWith { throw failWith }
            return detail
        }
    }

    private func insertSyncedWorkouts(_ count: Int, in context: ModelContext) throws {
        for i in 0..<count {
            let w = Workout(
                sport: .run,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86400),
                duration: 1800, distance: 5000, source: "strava",
                externalID: "strava:\(i)")
            context.insert(w)
        }
        try context.save()
    }

    func testBackfillStoresStreamsAndMarksTheWorkout() async throws {
        let context = try makeContext()
        try insertSyncedWorkouts(1, in: context)

        let samples = [FITSample(t: 0, hr: 120, dist: 0), FITSample(t: 1, hr: 122, dist: 3)]
        let provider = StubProvider(
            counter: .init(),
            detail: ActivityDetail(samples: samples, coordinates: [[42.7, 23.3]]))

        let report = await SyncEngine(context: context).backfillDetail(from: provider)
        XCTAssertEqual(report.detailsFetched, 1)

        let workout = try XCTUnwrap(try context.fetch(FetchDescriptor<Workout>()).first)
        XCTAssertEqual(workout.samples.count, 2)
        XCTAssertTrue(workout.hasRoute)
        XCTAssertNotNil(workout.detailFetchedAt)
        XCTAssertFalse(workout.needsDetailFetch)
    }

    /// The marker's whole purpose: an activity with genuinely no streams — a
    /// manual entry, a treadmill run logged by hand — must not be asked about
    /// again on every future sync.
    func testActivityWithNoStreamsIsNotRetried() async throws {
        let context = try makeContext()
        try insertSyncedWorkouts(1, in: context)
        let provider = StubProvider(counter: .init(), detail: ActivityDetail())

        let engine = SyncEngine(context: context)
        _ = await engine.backfillDetail(from: provider)
        XCTAssertEqual(provider.counter.count, 1)

        _ = await engine.backfillDetail(from: provider)
        XCTAssertEqual(provider.counter.count, 1, "must not ask a second time")
        XCTAssertTrue(engine.workoutsNeedingDetail(source: "strava").isEmpty)
    }

    /// One request per activity against a 200-per-15-minutes budget: a first
    /// sync of hundreds of activities has to be capped or it dies at a 429.
    func testBackfillIsCappedPerRun() async throws {
        let context = try makeContext()
        try insertSyncedWorkouts(60, in: context)
        let provider = StubProvider(
            counter: .init(),
            detail: ActivityDetail(samples: [FITSample(t: 0, hr: 120)]))

        let report = await SyncEngine(context: context).backfillDetail(from: provider, limit: 25)
        XCTAssertEqual(provider.counter.count, 25)
        XCTAssertEqual(report.detailsFetched, 25)
        XCTAssertEqual(report.detailsPending, 35)
        XCTAssertTrue(report.summary.contains("35 more"))
    }

    /// Newest first: a partial backfill that covers this month beats one that
    /// starts a year ago and never reaches the present.
    func testBackfillTakesTheNewestFirst() async throws {
        let context = try makeContext()
        try insertSyncedWorkouts(5, in: context)
        let provider = StubProvider(
            counter: .init(),
            detail: ActivityDetail(samples: [FITSample(t: 0, hr: 120)]))

        _ = await SyncEngine(context: context).backfillDetail(from: provider, limit: 2)

        let fetched = try context.fetch(FetchDescriptor<Workout>())
            .filter { $0.detailFetchedAt != nil }
            .compactMap(\.externalID)
            .sorted()
        XCTAssertEqual(fetched, ["strava:3", "strava:4"])
    }

    func testRateLimitStopsTheBatchAndReportsWhatIsLeft() async throws {
        let context = try makeContext()
        try insertSyncedWorkouts(10, in: context)
        let provider = StubProvider(counter: .init(), failWith: .rateLimited,
                                    detail: ActivityDetail())

        let report = await SyncEngine(context: context).backfillDetail(from: provider)
        XCTAssertEqual(provider.counter.count, 1, "stop at the first 429")
        XCTAssertTrue(report.hitRateLimit)
        XCTAssertGreaterThan(report.detailsPending, 0)
        XCTAssertTrue(report.summary.contains("15 minutes"))
    }

    /// A deleted or private activity is a 404. It must cost that one activity,
    /// not the rest of the batch.
    func testOneFailingActivityDoesNotStopTheBatch() async throws {
        let context = try makeContext()
        try insertSyncedWorkouts(4, in: context)
        let provider = StubProvider(counter: .init(),
                                    failWith: .httpStatus(404, body: "Not found"),
                                    detail: ActivityDetail())

        let report = await SyncEngine(context: context).backfillDetail(from: provider)
        XCTAssertEqual(provider.counter.count, 4, "every activity was attempted")
        XCTAssertEqual(report.failures.count, 4)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Workout>())
            .allSatisfy { $0.detailFetchedAt != nil },
            "failures are marked too, or they retry forever")
    }

    func testProvidersWithoutStreamSupportAreSkipped() async {
        XCTAssertFalse(IntervalsICUProvider().supportsStreams)
        await XCTAssertThrowsErrorAsync(
            try await IntervalsICUProvider().fetchDetail(externalID: "intervals:1"))
    }

    // MARK: - Lap analysis

    private func lap(_ index: Int, _ distance: Double, _ duration: TimeInterval,
                     intensity: String? = nil, trigger: String? = nil) -> FITLap {
        var l = FITLap(index: index, duration: duration, distance: distance, avgHR: 150)
        l.intensity = intensity
        l.trigger = trigger
        return l
    }

    /// An auto-lap every kilometre says nothing the computed splits don't say
    /// better, so the UI shouldn't default to it.
    func testDistanceTriggeredLapsAreRecognizedAsAutoLaps() {
        let laps = (0..<5).map { lap($0, 1000, 300, trigger: "distance") }
        XCTAssertTrue(LapAnalysis.areAutoLaps(laps))
    }

    func testManualTriggerMeansTheAthleteStructuredIt() {
        let laps = (0..<5).map { lap($0, 1000, 300, trigger: "manual") }
        XCTAssertFalse(LapAnalysis.areAutoLaps(laps))
    }

    func testIntensityMarkingsAlwaysMeanStructure() {
        // Even a distance trigger, if the watch marked recovery.
        let laps = [
            lap(0, 400, 80, intensity: "active", trigger: "distance"),
            lap(1, 200, 90, intensity: "rest", trigger: "distance"),
        ]
        XCTAssertFalse(LapAnalysis.areAutoLaps(laps))
        XCTAssertTrue(LapAnalysis.hasStructure(laps))
    }

    /// Older files carry no trigger, so fall back to the geometry.
    func testUniformRoundDistancesReadAsAutoLapsWithoutATrigger() {
        let kilometres = (0..<6).map { lap($0, 1000 + Double($0) * 3, 300) }
        XCTAssertTrue(LapAnalysis.areAutoLaps(kilometres), "within 3% of 1 km")

        let miles = (0..<4).map { lap($0, 1609.34, 480) }
        XCTAssertTrue(LapAnalysis.areAutoLaps(miles))

        let intervals = [lap(0, 2400, 800), lap(1, 400, 80), lap(2, 200, 90),
                         lap(3, 400, 79), lap(4, 1500, 500)]
        XCTAssertFalse(LapAnalysis.areAutoLaps(intervals))
    }

    func testTrailingPartialLapDoesNotBreakAutoLapDetection() {
        // Four clean kilometres plus a 320 m remainder is still an auto-lap.
        var laps = (0..<4).map { lap($0, 1000, 300) }
        laps.append(lap(4, 320, 96))
        XCTAssertTrue(LapAnalysis.areAutoLaps(laps))
    }

    func testTooFewLapsIsNeverAnAutoLap() {
        XCTAssertFalse(LapAnalysis.areAutoLaps([]))
        XCTAssertFalse(LapAnalysis.areAutoLaps([lap(0, 1000, 300)]))
    }

    /// A recovery jog must never be reported as the fastest lap.
    func testFastestLapIgnoresRecovery() throws {
        let laps = [
            lap(0, 2000, 700, intensity: "warmup"),
            lap(1, 400, 80, intensity: "active"),
            lap(2, 200, 90, intensity: "rest"),
            lap(3, 400, 78, intensity: "active"),
        ]
        XCTAssertEqual(LapAnalysis.fastest(laps)?.index, 3)
        XCTAssertEqual(LapAnalysis.workingLaps(laps).count, 2)
    }

    func testWorkingLapsFallsBackWhenNothingIsMarked() {
        let laps = (0..<3).map { lap($0, 1000, 300) }
        XCTAssertEqual(LapAnalysis.workingLaps(laps).count, 3)
    }

    // MARK: - Lap model

    func testLapPaceAndBadges() {
        var rest = FITLap(index: 1, duration: 90, distance: 200, avgHR: 140)
        rest.intensity = "rest"
        XCTAssertTrue(rest.isRecovery)
        XCTAssertEqual(rest.intensityBadge, "rest")

        let rep = FITLap(index: 2, duration: 80, distance: 400, avgHR: 170)
        XCTAssertFalse(rep.isRecovery)
        XCTAssertNil(rep.intensityBadge, "a plain working lap needs no label")
        XCTAssertEqual(rep.paceSecPerKm ?? 0, 200, accuracy: 0.1)
        XCTAssertEqual(rep.pacePer100m ?? 0, 20, accuracy: 0.1)

        let empty = FITLap(index: 3, duration: 0, distance: 0)
        XCTAssertNil(empty.paceSecPerKm)
        XCTAssertNil(empty.pacePer100m)
    }

    /// Blobs written before the lap model gained its extra fields must still
    /// decode — the four original keys are all a stored lap is guaranteed to
    /// have.
    func testOldFourFieldLapBlobsStillDecode() throws {
        let legacy = Data(#"""
        [{"index": 0, "duration": 300.0, "distance": 1000.0, "avgHR": 148}]
        """#.utf8)
        let laps = try JSONDecoder().decode([FITLap].self, from: legacy)
        XCTAssertEqual(laps.count, 1)
        XCTAssertEqual(laps[0].avgHR, 148)
        XCTAssertNil(laps[0].intensity)
        XCTAssertNil(laps[0].trigger)
        XCTAssertNil(laps[0].avgPower)
    }

    func testLapRoundTripsThroughJSON() throws {
        var lap = FITLap(index: 3, duration: 80, distance: 400, avgHR: 170)
        lap.startOffset = 900
        lap.avgPower = 320
        lap.intensity = "active"
        lap.trigger = "manual"

        let data = try JSONEncoder().encode([lap])
        let decoded = try JSONDecoder().decode([FITLap].self, from: data)
        XCTAssertEqual(decoded[0].startOffset, 900)
        XCTAssertEqual(decoded[0].avgPower, 320)
        XCTAssertEqual(decoded[0].trigger, "manual")
    }

    // MARK: - Demo data

    /// The lap view can't be judged without a structured session to show it.
    func testDemoDataIncludesAStructuredIntervalSession() throws {
        let context = try makeContext()
        DemoData.seed(into: context, weeks: 12)
        try context.save()

        let sessions = try context.fetch(FetchDescriptor<Workout>())
            .filter { !$0.laps.isEmpty }
        XCTAssertFalse(sessions.isEmpty, "no lapped workouts were seeded")

        let laps = try XCTUnwrap(sessions.first?.laps)
        XCTAssertFalse(LapAnalysis.areAutoLaps(laps))
        XCTAssertTrue(LapAnalysis.hasStructure(laps))
        XCTAssertEqual(laps.filter { $0.intensity == "active" }.count, 8)
        XCTAssertEqual(laps.filter { $0.intensity == "rest" }.count, 7)

        // The reps have to be genuinely faster than the floats, or the view is
        // showing nothing worth looking at.
        let reps = laps.filter { $0.intensity == "active" }
        let floats = laps.filter { $0.intensity == "rest" }
        let repPace = reps.compactMap(\.paceSecPerKm).reduce(0, +) / Double(reps.count)
        let floatPace = floats.compactMap(\.paceSecPerKm).reduce(0, +) / Double(floats.count)
        XCTAssertLessThan(repPace, floatPace * 0.6)
    }
}

/// XCTest has no async `XCTAssertThrowsError`.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
