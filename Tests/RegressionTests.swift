import XCTest
import SwiftData
@testable import FitnessTracker

/// One test per bug found in the September 2026 audit, each named for the wrong
/// behaviour it pins down. These exist to stop the same mistake coming back, so
/// they assert the *user-visible* consequence rather than the implementation.
///
/// Main-actor isolated: the day-row helpers are, because they touch a
/// `ModelContext` that belongs to the UI.
@MainActor
final class RegressionTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func snapshot(_ sport: WorkoutSport, _ km: Double,
                          daysAgo: Int = 0) -> WorkoutSnapshot {
        WorkoutSnapshot(
            id: UUID(), sport: sport,
            startedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!,
            distance: km * 1000, duration: km * 300
        )
    }

    // MARK: - "Longest run" reported the longest ride

    /// Milestones were computed over every sport, so the demo data's 85 km ride
    /// was displayed under the heading "Longest run".
    func testLongestRunIgnoresRidesAndSwims() throws {
        let milestones = PersonalRecords.milestones(from: [
            snapshot(.bike, 85),
            snapshot(.run, 21),
            snapshot(.swim, 3),
            snapshot(.trailRun, 18),
        ])
        XCTAssertEqual(try XCTUnwrap(milestones.longestRun).distance, 21_000, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(milestones.longestRide).distance, 85_000, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(milestones.longestSwim).distance, 3_000, accuracy: 1)
    }

    /// Trail runs are still runs — the filter must not be `.run` alone.
    func testLongestRunCountsTrailRuns() throws {
        let milestones = PersonalRecords.milestones(from: [
            snapshot(.run, 10), snapshot(.trailRun, 32),
        ])
        XCTAssertEqual(try XCTUnwrap(milestones.longestRun).distance, 32_000, accuracy: 1)
    }

    /// "Biggest week" is a running number. Adding a 200 km cycling week to it
    /// made the figure meaningless.
    func testBiggestWeekCountsRunningOnly() throws {
        let milestones = PersonalRecords.milestones(from: [
            snapshot(.bike, 120, daysAgo: 1),
            snapshot(.bike, 100, daysAgo: 2),
            snapshot(.run, 12, daysAgo: 1),
            snapshot(.run, 15, daysAgo: 2),
        ])
        let week = try XCTUnwrap(milestones.biggestWeek)
        XCTAssertEqual(week.distance, 27_000, accuracy: 1)
    }

    /// Lifetime distance is the one figure that *should* span every sport.
    func testLifetimeTotalsStillSpanEverySport() {
        let milestones = PersonalRecords.milestones(from: [
            snapshot(.bike, 50), snapshot(.run, 10), snapshot(.swim, 2),
        ])
        XCTAssertEqual(milestones.totalDistance, 62_000, accuracy: 1)
        XCTAssertEqual(milestones.totalWorkouts, 3)
    }

    func testMilestonesOnEmptyInputAreAllNil() {
        let milestones = PersonalRecords.milestones(from: [])
        XCTAssertNil(milestones.longestRun)
        XCTAssertNil(milestones.longestRide)
        XCTAssertNil(milestones.longestSwim)
        XCTAssertNil(milestones.biggestWeek)
        XCTAssertEqual(milestones.totalDistance, 0)
    }

    // MARK: - Opening the check-in sheet created an empty row

    /// The sheet called `upsert` just to read today's values, so opening it and
    /// tapping Cancel left a blank `DailyMetric` behind — which then counted as
    /// a day of history for baseline purposes.
    func testReadingTodaysMetricDoesNotCreateARow() throws {
        let context = try makeContext()
        XCTAssertNil(try HealthKitReader.metric(for: .now, in: context))
        XCTAssertTrue(try context.fetch(FetchDescriptor<DailyMetric>()).isEmpty,
                      "a read must not insert")
    }

    func testUpsertStillCreatesAndThenReuses() throws {
        let context = try makeContext()
        let first = try HealthKitReader.upsert(day: .now, in: context)
        try context.save()
        let second = try HealthKitReader.upsert(day: .now, in: context)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DailyMetric>()).count, 1)

        // And a read now finds the row that exists.
        XCTAssertEqual(try HealthKitReader.metric(for: .now, in: context)?.id, first.id)
    }

    /// Rows are stored as start-of-day *in whatever zone wrote them*. An exact
    /// `date == start` predicate missed them after a time-zone change, so a
    /// second row got created for the same calendar day.
    func testDayLookupMatchesARowStoredAtAnotherZoneOffset() throws {
        let context = try makeContext()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        // What "start of day" looks like written 9 hours away.
        let shifted = DailyMetric(date: today)
        shifted.date = today.addingTimeInterval(9 * 3600)
        shifted.hrvSDNN = 55
        context.insert(shifted)
        try context.save()

        let found = try HealthKitReader.metric(for: .now, in: context)
        XCTAssertEqual(found?.hrvSDNN, 55, "the existing row for today must be found")

        _ = try HealthKitReader.upsert(day: .now, in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DailyMetric>()).count, 1,
                       "upsert must reuse it rather than adding a duplicate")
    }

    func testDayLookupDoesNotReachIntoNeighbouringDays() throws {
        let context = try makeContext()
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: .now)!
        let row = DailyMetric(date: yesterday)
        row.hrvSDNN = 40
        context.insert(row)
        try context.save()

        XCTAssertNil(try HealthKitReader.metric(for: .now, in: context))
        XCTAssertEqual(try HealthKitReader.metric(for: yesterday, in: context)?.hrvSDNN, 40)
    }

    // MARK: - Readiness now reads multi-sport load

    /// Readiness took an acute:chronic ratio built from raw distance. A week of
    /// hard riding read as a ramp; a week of hard swimming read as a taper.
    /// It now takes the ratio off the training-stress curve instead.
    func testReadinessRespondsToLoadFromAnySport() {
        let today = Calendar.current.startOfDay(for: .now)
        let history = (1...7).map { day in
            MetricSnapshot(date: Calendar.current.date(byAdding: .day, value: -day, to: today)!,
                           hrvSDNN: 60, restingHR: 50)
        }
        let day = MetricSnapshot(date: today, hrvSDNN: 60, restingHR: 50, sleepHours: 8)

        let steady = Readiness.score(day: day, history: history, loadRatio: 1.0)
        let spiking = Readiness.score(day: day, history: history, loadRatio: 1.9)
        XCTAssertGreaterThan(steady.score, spiking.score,
                             "a load spike must cost readiness whatever sport caused it")
    }

    // MARK: - Provider watermarks

    /// A provider's `source` string and the value it stamps on rows have to be
    /// the same, or the incremental window silently reaches back a year forever.
    func testEveryProviderSourceIdentifierIsDistinct() {
        let identifiers = ProviderKind.allCases.map(\.sourceIdentifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertFalse(identifiers.contains("manual"))
        XCTAssertFalse(identifiers.contains("fit"))
        XCTAssertFalse(identifiers.contains("demo"))
    }

    // MARK: - Credentials

    /// A pasted API key usually carries a trailing newline. Storing it verbatim
    /// produced a bare 401 with nothing to diagnose.
    func testPastedCredentialsAreTrimmed() {
        CredentialStore.set("  sk-test-key\n", for: .anthropicAPIKey)
        XCTAssertEqual(CredentialStore.get(.anthropicAPIKey), "sk-test-key")

        // Whitespace-only is the same as clearing it.
        CredentialStore.set("   \n ", for: .anthropicAPIKey)
        XCTAssertFalse(CredentialStore.has(.anthropicAPIKey))
        CredentialStore.remove(.anthropicAPIKey)
    }
}

/// Demo data is the first thing a new install shows, and every derived number
/// on that screen is only as sane as the data under it.
@MainActor
final class DemoDataPlausibilityTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// A misplaced paren seeded a 7 kg athlete, so the Recovery weight chart
    /// read "16.8 lb" and watts-per-kilo would have been off by a factor of ten.
    func testSeededBodyWeightIsAHumanWeight() throws {
        let context = try makeContext()
        _ = DemoData.seed(into: context)
        try context.save()

        let weights = try context.fetch(FetchDescriptor<DailyMetric>())
            .compactMap(\.weightKg)
        XCTAssertFalse(weights.isEmpty, "demo data seeds no weight at all")
        for weight in weights {
            XCTAssertTrue((40...200).contains(weight),
                          "seeded body weight of \(weight) kg is not a person")
        }
        // And it varies day to day rather than being a constant.
        XCTAssertGreaterThan(Set(weights).count, 1)
    }

    /// The same class of error in the other seeded series.
    func testOtherSeededMetricsAreInPlausibleRanges() throws {
        let context = try makeContext()
        _ = DemoData.seed(into: context)
        try context.save()
        let metrics = try context.fetch(FetchDescriptor<DailyMetric>())

        for value in metrics.compactMap(\.sleepHours) {
            XCTAssertTrue((3...12).contains(value), "sleep of \(value) h")
        }
        for value in metrics.compactMap(\.restingHR) {
            XCTAssertTrue((35...90).contains(value), "resting HR of \(value) bpm")
        }
        for value in metrics.compactMap(\.hrvSDNN) {
            XCTAssertTrue((10...200).contains(value), "HRV of \(value) ms")
        }
        for value in metrics.compactMap(\.vo2Max) {
            XCTAssertTrue((20...90).contains(value), "VO2max of \(value)")
        }
    }
}
