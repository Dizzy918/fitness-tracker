import XCTest
import SwiftData
@testable import FitnessTracker

@MainActor
final class DailyMetricTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    func testDatesNormalizeToStartOfDay() {
        let noon = Date(timeIntervalSince1970: 1_700_000_000)
        let metric = DailyMetric(date: noon)
        XCTAssertEqual(metric.date, Calendar.current.startOfDay(for: noon))
    }

    func testUpsertReturnsSameRowForSameDay() throws {
        let context = try makeContext()
        let morning = Date(timeIntervalSince1970: 1_700_000_000)
        let evening = morning.addingTimeInterval(8 * 3600)

        let first = try HealthKitReader.upsert(day: morning, in: context)
        first.hrvSDNN = 60
        try context.save()

        let second = try HealthKitReader.upsert(day: evening, in: context)
        second.restingHR = 50
        try context.save()

        let all = try context.fetch(FetchDescriptor<DailyMetric>())
        XCTAssertEqual(all.count, 1, "one row per calendar day")
        XCTAssertEqual(all[0].hrvSDNN, 60, "existing values survive a second upsert")
        XCTAssertEqual(all[0].restingHR, 50)
    }

    func testUpsertCreatesDistinctRowsForDistinctDays() throws {
        let context = try makeContext()
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try HealthKitReader.upsert(day: day1, in: context)
        _ = try HealthKitReader.upsert(day: day1.addingTimeInterval(86400), in: context)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<DailyMetric>()).count, 2)
    }

    func testDataPresenceFlags() {
        let metric = DailyMetric(date: .now)
        XCTAssertFalse(metric.hasObjectiveData)
        XCTAssertFalse(metric.hasCheckIn)

        metric.hrvSDNN = 55
        XCTAssertTrue(metric.hasObjectiveData)

        metric.mood = 4
        XCTAssertTrue(metric.hasCheckIn)
    }

    func testSnapshotCarriesValuesToScoring() {
        let metric = DailyMetric(date: .now)
        metric.hrvSDNN = 61
        metric.restingHR = 49
        metric.sleepHours = 7.5
        metric.soreness = 2

        let snapshot = metric.snapshot
        XCTAssertEqual(snapshot.hrvSDNN, 61)
        XCTAssertEqual(snapshot.restingHR, 49)
        XCTAssertEqual(snapshot.sleepHours, 7.5)
        XCTAssertEqual(snapshot.soreness, 2)
    }

    /// HealthKit is iOS-only; the Mac build must report that rather than crash.
    func testHealthKitUnavailableOnMac() async {
        #if os(macOS)
        XCTAssertFalse(HealthKitReader.isAvailable)
        let context = try? makeContext()
        do {
            _ = try await HealthKitReader().importMetrics(into: context!)
            XCTFail("expected unavailable on macOS")
        } catch let error as HealthKitReader.HealthError {
            guard case .unavailable = error else { return XCTFail("wrong case") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        #endif
    }

    func testDemoDataSeedsScorableMetrics() throws {
        let context = try makeContext()
        DemoData.seed(into: context, weeks: 4)
        try context.save()

        let metrics = try context.fetch(FetchDescriptor<DailyMetric>())
        XCTAssertGreaterThan(metrics.count, 20)
        XCTAssertTrue(metrics.contains { $0.hrvSDNN != nil })
        XCTAssertTrue(metrics.contains { $0.hasCheckIn }, "some days should have check-ins")

        // Ranges must be physiologically plausible, not just non-nil.
        for m in metrics {
            if let hrv = m.hrvSDNN { XCTAssertTrue((20...150).contains(hrv), "hrv \(hrv)") }
            if let rhr = m.restingHR { XCTAssertTrue((35...70).contains(rhr), "rhr \(rhr)") }
            if let sleep = m.sleepHours { XCTAssertTrue((0...14).contains(sleep)) }
            if let s = m.soreness { XCTAssertTrue((1...5).contains(s), "soreness \(s)") }
            if let q = m.sleepQuality { XCTAssertTrue((1...5).contains(q), "quality \(q)") }
        }

        // The seeded history should produce a usable score for the latest day.
        let snapshots = metrics.map(\.snapshot)
        let latest = try XCTUnwrap(snapshots.max { $0.date < $1.date })
        let result = Readiness.score(day: latest, history: snapshots, loadRatio: 1.0)
        XCTAssertTrue(result.isReliable, "demo data should be enough to score")
        XCTAssertTrue((0...100).contains(result.score))
    }

    /// One row per day even when both HealthKit and a check-in write.
    func testCheckInAndObjectiveDataShareOneRow() throws {
        let context = try makeContext()
        let metric = try HealthKitReader.upsert(day: .now, in: context)
        metric.hrvSDNN = 58
        metric.source = "healthkit"

        let again = try HealthKitReader.upsert(day: .now, in: context)
        again.mood = 4
        again.source = again.hasObjectiveData ? "mixed" : "manual"
        try context.save()

        let all = try context.fetch(FetchDescriptor<DailyMetric>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].source, "mixed")
    }
}

@MainActor
final class WorkoutFilteringTests: XCTestCase {

    /// Mirrors the list view's filter so the behavior is pinned by a test
    /// rather than only existing inside a SwiftUI body.
    private func filter(_ workouts: [Workout], sport: WorkoutSport?, query: String) -> [Workout] {
        var result = workouts
        if let sport { result = result.filter { $0.sport == sport } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            result = result.filter { w in
                w.sport.displayName.lowercased().contains(q)
                    || w.source.lowercased().contains(q)
                    || (w.notes ?? "").lowercased().contains(q)
                    || (w.shoe?.displayName ?? "").lowercased().contains(q)
            }
        }
        return result
    }

    private func make(_ sport: WorkoutSport, source: String, notes: String? = nil) -> Workout {
        let w = Workout(sport: sport, startedAt: .now, duration: 1800,
                        distance: 5000, source: source)
        w.notes = notes
        return w
    }

    func testFilterBySport() {
        let all = [make(.run, source: "fit"), make(.bike, source: "strava"),
                   make(.trailRun, source: "fit")]
        XCTAssertEqual(filter(all, sport: .run, query: "").count, 1)
        XCTAssertEqual(filter(all, sport: .bike, query: "").count, 1)
        XCTAssertEqual(filter(all, sport: nil, query: "").count, 3)
    }

    func testSearchMatchesSourceAndNotes() {
        let all = [
            make(.run, source: "strava", notes: "Morning tempo"),
            make(.run, source: "fit", notes: "Recovery jog"),
        ]
        XCTAssertEqual(filter(all, sport: nil, query: "strava").count, 1)
        XCTAssertEqual(filter(all, sport: nil, query: "tempo").count, 1)
        XCTAssertEqual(filter(all, sport: nil, query: "TEMPO").count, 1, "search is case-insensitive")
        XCTAssertEqual(filter(all, sport: nil, query: "  ").count, 2, "blank query filters nothing")
        XCTAssertEqual(filter(all, sport: nil, query: "swim").count, 0)
    }

    func testSportAndSearchCombine() {
        let all = [
            make(.run, source: "strava", notes: "hills"),
            make(.bike, source: "strava", notes: "hills"),
        ]
        XCTAssertEqual(filter(all, sport: .run, query: "hills").count, 1)
    }
}
