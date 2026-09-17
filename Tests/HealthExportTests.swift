import XCTest
import SwiftData
@testable import FitnessTracker

/// Apple Health export.
///
/// The HealthKit calls themselves can't run here — the test bundle targets
/// macOS, where HealthKit doesn't exist — so these cover the parts that decide
/// *what* gets written: the selection rules, the dedupe marker, and the sport
/// mapping. The write path itself is verified in the iOS Simulator.
@MainActor
final class HealthExportTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Workout.self, Shoe.self, StrengthSession.self, SetEntry.self,
            Exercise.self, DailyMetric.self, Route.self, PlannedWorkout.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @discardableResult
    private func insert(_ source: String, in context: ModelContext,
                        duration: TimeInterval = 1800,
                        exported: Date? = nil) -> Workout {
        let w = Workout(sport: .run, startedAt: .now, duration: duration,
                        distance: 5000, source: source,
                        externalID: "\(source):\(UUID().uuidString)")
        w.healthKitExportedAt = exported
        context.insert(w)
        return w
    }

    // MARK: - What gets written

    /// Demo data has no business in someone's real health record, and a workout
    /// that came *from* Health would be duplicated straight back into it.
    func testDemoAndHealthKitSourcedWorkoutsAreNeverExported() throws {
        let context = try makeContext()
        insert("fit", in: context)
        insert("strava", in: context)
        insert("pdf", in: context)
        insert("manual", in: context)
        insert("demo", in: context)
        insert("healthkit", in: context)
        try context.save()

        let pending = HealthKitWriter.pendingExport(in: context)
        let sources = Set(pending.map(\.source))
        XCTAssertEqual(sources, ["fit", "strava", "pdf", "manual"])
        XCTAssertFalse(sources.contains("demo"))
        XCTAssertFalse(sources.contains("healthkit"))
    }

    func testAlreadyExportedWorkoutsAreNotOfferedAgain() throws {
        let context = try makeContext()
        insert("fit", in: context)
        insert("fit", in: context, exported: .now)
        try context.save()

        XCTAssertEqual(HealthKitWriter.pendingExport(in: context).count, 1)
    }

    /// A zero-length row is a stub, not a workout; Health rejects it anyway.
    func testZeroDurationWorkoutsAreSkipped() throws {
        let context = try makeContext()
        insert("fit", in: context, duration: 0)
        insert("fit", in: context, duration: 60)
        try context.save()

        XCTAssertEqual(HealthKitWriter.pendingExport(in: context).count, 1)
    }

    func testNewestFirst() throws {
        let context = try makeContext()
        for day in 0..<5 {
            let w = Workout(sport: .run,
                            startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86400),
                            duration: 1800, distance: 5000, source: "fit",
                            externalID: "fit:\(day)")
            context.insert(w)
        }
        try context.save()

        let pending = HealthKitWriter.pendingExport(in: context)
        XCTAssertEqual(pending.first?.externalID, "fit:4")
        XCTAssertEqual(pending.last?.externalID, "fit:0")
    }

    func testEmptyStoreHasNothingPending() throws {
        XCTAssertTrue(HealthKitWriter.pendingExport(in: try makeContext()).isEmpty)
    }

    // MARK: - Reporting

    func testReportSummaryReadsNaturally() {
        var report = HealthKitWriter.Report(written: 1)
        XCTAssertEqual(report.summary, "Wrote 1 workout to Apple Health.")

        report = HealthKitWriter.Report(written: 12, skipped: 3,
                                        failures: ["one exploded"])
        XCTAssertTrue(report.summary.contains("12 workouts"))
        XCTAssertTrue(report.summary.contains("skipped 3"))
        XCTAssertTrue(report.summary.contains("1 failed"))
    }

    func testErrorsExplainWhatToDo() {
        XCTAssertTrue(HealthKitWriter.WriteError.denied.errorDescription?
            .contains("Data Access") ?? false,
            "a denial must say where to turn it back on")
        XCTAssertNotNil(HealthKitWriter.WriteError.unavailable.errorDescription)
        XCTAssertNotNil(HealthKitWriter.WriteError.nothingToWrite.errorDescription)
    }

    /// HealthKit is iOS-only, so the macOS build must report that rather than
    /// pretending to export.
    func testExportIsUnavailableOnMac() async throws {
        let context = try makeContext()
        insert("fit", in: context)
        try context.save()

        XCTAssertFalse(HealthKitWriter.isAvailable)
        do {
            _ = try await HealthKitWriter.exportPending(in: context)
            XCTFail("expected unavailable")
        } catch {
            XCTAssertTrue(error is HealthKitWriter.WriteError)
        }
    }

    // MARK: - Sport mapping
    //
    // Compiled only where HealthKit exists; the mapping table is the part most
    // likely to go wrong when a sport is added.

    #if canImport(HealthKit) && !os(macOS)
    func testEverySportMapsToAnActivityAndDistanceType() {
        for sport in WorkoutSport.allCases {
            let activity = HealthKitWriter.activityType(for: sport)
            if sport == .other {
                XCTAssertEqual(activity, .other)
                XCTAssertNil(HealthKitWriter.distanceIdentifier(for: sport))
            } else {
                XCTAssertNotEqual(activity, .other, "\(sport) needs a real activity type")
                XCTAssertNotNil(HealthKitWriter.distanceIdentifier(for: sport))
            }
        }
        XCTAssertEqual(HealthKitWriter.distanceIdentifier(for: .bike), .distanceCycling)
        XCTAssertEqual(HealthKitWriter.distanceIdentifier(for: .swim), .distanceSwimming)
        XCTAssertEqual(HealthKitWriter.distanceIdentifier(for: .trailRun), .distanceWalkingRunning)
    }
    #endif
}
