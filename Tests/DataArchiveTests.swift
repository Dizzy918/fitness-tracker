import XCTest
import SwiftData
@testable import FitnessTracker

/// Backup and restore.
///
/// The bar for a backup is that a full round trip loses nothing and a partial
/// restore duplicates nothing, so that's what these test — against a real
/// seeded store, not a hand-built fixture.
@MainActor
final class DataArchiveTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Workout.self, Shoe.self, StrengthSession.self, SetEntry.self,
            Exercise.self, DailyMetric.self, Route.self, PlannedWorkout.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func seeded() throws -> ModelContext {
        let context = ModelContext(try makeContainer())
        DemoData.seed(into: context, weeks: 4)
        let route = Route(name: "River loop", sport: .run)
        route.setGeometry(coordinates: [
            .init(latitude: 42.70, longitude: 23.32),
            .init(latitude: 42.71, longitude: 23.33),
        ])
        context.insert(route)
        try context.save()
        return context
    }

    // MARK: - Round trip

    /// The one that matters: export a full store, restore into an empty one,
    /// and every count — and the stream bytes — must match.
    func testFullRoundTripLosesNothing() throws {
        let source = try seeded()
        let archive = try DataArchive.archive(from: source)
        let data = try DataArchive.encoder().encode(archive)

        let restored = ModelContext(try makeContainer())
        let report = try DataArchive.restore(try DataArchive.read(data), into: restored)
        try restored.save()

        XCTAssertEqual(try restored.fetch(FetchDescriptor<Workout>()).count,
                       try source.fetch(FetchDescriptor<Workout>()).count)
        XCTAssertEqual(try restored.fetch(FetchDescriptor<Shoe>()).count,
                       try source.fetch(FetchDescriptor<Shoe>()).count)
        XCTAssertEqual(try restored.fetch(FetchDescriptor<StrengthSession>()).count,
                       try source.fetch(FetchDescriptor<StrengthSession>()).count)
        XCTAssertEqual(try restored.fetch(FetchDescriptor<DailyMetric>()).count,
                       try source.fetch(FetchDescriptor<DailyMetric>()).count)
        XCTAssertEqual(try restored.fetch(FetchDescriptor<Route>()).count,
                       try source.fetch(FetchDescriptor<Route>()).count)
        XCTAssertGreaterThan(report.total, 0)
    }

    func testStreamsAndRoutesSurviveTheRoundTrip() throws {
        let source = try seeded()
        let original = try XCTUnwrap(
            try source.fetch(FetchDescriptor<Workout>()).first { !$0.samples.isEmpty })
        let originalSampleCount = original.samples.count
        let originalCoordinates = original.coordinates.count

        let data = try DataArchive.exportData(from: source)
        let restored = ModelContext(try makeContainer())
        try DataArchive.restore(try DataArchive.read(data), into: restored)

        let copy = try XCTUnwrap(
            try restored.fetch(FetchDescriptor<Workout>()).first { $0.id == original.id })
        XCTAssertEqual(copy.samples.count, originalSampleCount)
        XCTAssertEqual(copy.coordinates.count, originalCoordinates)
        XCTAssertEqual(copy.externalID, original.externalID)
    }

    func testLapsSurviveTheRoundTrip() throws {
        let source = try seeded()
        let lapped = try source.fetch(FetchDescriptor<Workout>()).first { !$0.laps.isEmpty }
        let original = try XCTUnwrap(lapped, "demo data should include a lapped session")

        let data = try DataArchive.exportData(from: source)
        let restored = ModelContext(try makeContainer())
        try DataArchive.restore(try DataArchive.read(data), into: restored)

        let copy = try XCTUnwrap(
            try restored.fetch(FetchDescriptor<Workout>()).first { $0.id == original.id })
        XCTAssertEqual(copy.laps.count, original.laps.count)
        XCTAssertEqual(copy.laps.first?.intensity, original.laps.first?.intensity)
    }

    func testShoeAssignmentsAreRelinked() throws {
        let source = try seeded()
        let withShoe = try XCTUnwrap(
            try source.fetch(FetchDescriptor<Workout>()).first { $0.shoe != nil })
        let shoeName = try XCTUnwrap(withShoe.shoe?.displayName)

        let data = try DataArchive.exportData(from: source)
        let restored = ModelContext(try makeContainer())
        try DataArchive.restore(try DataArchive.read(data), into: restored)

        let copy = try XCTUnwrap(
            try restored.fetch(FetchDescriptor<Workout>()).first { $0.id == withShoe.id })
        XCTAssertEqual(copy.shoe?.displayName, shoeName,
                       "a restored workout must point at the restored shoe")
    }

    func testStrengthSetsKeepTheirExerciseAndOrder() throws {
        let source = try seeded()
        let original = try XCTUnwrap(
            try source.fetch(FetchDescriptor<StrengthSession>())
                .first { !$0.sets.isEmpty })
        let names = original.exerciseNames
        let volume = original.totalVolume

        let data = try DataArchive.exportData(from: source)
        let restored = ModelContext(try makeContainer())
        try DataArchive.restore(try DataArchive.read(data), into: restored)

        let copy = try XCTUnwrap(
            try restored.fetch(FetchDescriptor<StrengthSession>())
                .first { $0.id == original.id })
        XCTAssertEqual(copy.exerciseNames, names)
        XCTAssertEqual(copy.totalVolume, volume, accuracy: 0.001)
    }

    // MARK: - Idempotence

    /// Restoring the same archive twice must not double the library.
    func testRestoringTwiceChangesNothingTheSecondTime() throws {
        let source = try seeded()
        let data = try DataArchive.exportData(from: source)

        let target = ModelContext(try makeContainer())
        let first = try DataArchive.restore(try DataArchive.read(data), into: target)
        try target.save()
        let countAfterFirst = try target.fetch(FetchDescriptor<Workout>()).count

        let second = try DataArchive.restore(try DataArchive.read(data), into: target)
        try target.save()

        XCTAssertEqual(try target.fetch(FetchDescriptor<Workout>()).count, countAfterFirst)
        XCTAssertGreaterThan(first.total, 0)
        XCTAssertEqual(second.total, 0)
        XCTAssertGreaterThan(second.skipped, 0)
    }

    /// An activity already synced from Strava must not come back as a second
    /// copy just because the archive also contains it.
    func testExternalIDDedupesEvenWithADifferentRowID() throws {
        let target = ModelContext(try makeContainer())
        let existing = Workout(sport: .run, startedAt: .now, duration: 1800,
                               distance: 5000, source: "strava",
                               externalID: "strava:999")
        target.insert(existing)
        try target.save()

        var archive = DataArchive.Archive()
        archive.workouts = [DataArchive.WorkoutRecord(
            id: UUID(), sport: "run", startedAt: .now, duration: 1800,
            distance: 5000, source: "strava", externalID: "strava:999")]

        let report = try DataArchive.restore(archive, into: target)
        XCTAssertEqual(report.workouts, 0)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(try target.fetch(FetchDescriptor<Workout>()).count, 1)
    }

    /// Two devices can write a different row id for the same calendar day.
    /// Keying metrics on the date is what stops a restore creating a duplicate
    /// day, which would corrupt every readiness baseline.
    func testMetricsMergeByDayNotByRowID() throws {
        let target = ModelContext(try makeContainer())
        let today = Calendar.current.startOfDay(for: .now)
        let existing = DailyMetric(date: today)
        existing.hrvSDNN = 62
        target.insert(existing)
        try target.save()

        var archive = DataArchive.Archive()
        archive.dailyMetrics = [DataArchive.DailyMetricRecord(
            id: UUID(), date: today, hrvSDNN: 99, restingHR: 48,
            sleepHours: 7.5, source: "healthkit")]

        try DataArchive.restore(archive, into: target)
        let rows = try target.fetch(FetchDescriptor<DailyMetric>())
        XCTAssertEqual(rows.count, 1, "one row per day, always")
        XCTAssertEqual(rows[0].hrvSDNN, 62, "the value already here wins")
        XCTAssertEqual(rows[0].restingHR, 48, "but blanks are filled from the archive")
    }

    func testRestoreNeverDeletes() throws {
        let target = ModelContext(try makeContainer())
        let keeper = Workout(sport: .bike, startedAt: .now, duration: 3600,
                             distance: 30000, source: "manual",
                             externalID: "manual:keep")
        target.insert(keeper)
        try target.save()

        try DataArchive.restore(DataArchive.Archive(), into: target)
        XCTAssertEqual(try target.fetch(FetchDescriptor<Workout>()).count, 1)
    }

    // MARK: - Format

    func testSummaryExportOmitsTheBulk() throws {
        let source = try seeded()
        let full = try DataArchive.exportData(from: source, includeStreams: true)
        let summary = try DataArchive.exportData(from: source, includeStreams: false)

        XCTAssertLessThan(summary.count, full.count / 4,
                          "streams are most of the file; dropping them should show")
        let archive = try DataArchive.read(summary)
        XCTAssertFalse(archive.workouts.isEmpty)
        XCTAssertTrue(archive.workouts.allSatisfy { $0.streamsData == nil })
        // The summary still carries every workout's numbers.
        XCTAssertTrue(archive.workouts.contains { $0.distance > 0 })
    }

    func testDatesAreISO8601SoTheFileIsLegible() throws {
        let source = try seeded()
        let data = try DataArchive.exportData(from: source, includeStreams: false)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"exportedAt\":\""),
                      "dates must be strings, not epoch doubles")
        XCTAssertTrue(text.contains("T"), "ISO-8601 has a T separator")
    }

    func testGarbageAndFutureArchivesAreRejectedClearly() throws {
        XCTAssertThrowsError(try DataArchive.read(Data("not json".utf8)))

        var future = DataArchive.Archive()
        future.version = DataArchive.currentVersion + 1
        let data = try DataArchive.encoder().encode(future)
        XCTAssertThrowsError(try DataArchive.read(data)) { error in
            XCTAssertTrue(error.localizedDescription.contains("newer version"))
        }
    }

    func testFilenameCarriesTheDateAndKind() {
        let date = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01 UTC
        XCTAssertTrue(DataArchive.filename(for: date).hasSuffix(".json"))
        XCTAssertTrue(DataArchive.filename(for: date, includeStreams: false)
            .contains("summary"))
        XCTAssertFalse(DataArchive.filename(for: date, includeStreams: true)
            .contains("summary"))
    }

    // MARK: - CSV

    func testCSVHasAHeaderAndARowPerWorkout() throws {
        let source = try seeded()
        let archive = try DataArchive.archive(from: source, includeStreams: false)
        let csv = DataArchive.workoutsCSV(archive.workouts)
        let lines = csv.split(separator: "\n")

        XCTAssertEqual(lines.count, archive.workouts.count + 1)
        XCTAssertTrue(lines[0].hasPrefix("date,sport,duration_s"))
        // Oldest first, so a spreadsheet chart reads left to right.
        XCTAssertLessThan(String(lines[1]).prefix(10), String(lines[2]).prefix(10))
    }

    /// A note containing a comma would otherwise shift every later column.
    func testCSVEscapingFollowsRFC4180() {
        XCTAssertEqual(DataArchive.escapeCSV("plain"), "plain")
        XCTAssertEqual(DataArchive.escapeCSV("a,b"), "\"a,b\"")
        XCTAssertEqual(DataArchive.escapeCSV("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(DataArchive.escapeCSV("line\nbreak"), "\"line\nbreak\"")
    }

    func testCSVRowSurvivesAWeaponizedNote() {
        let record = DataArchive.WorkoutRecord(
            id: UUID(), sport: "run", startedAt: .now, duration: 1800,
            distance: 5000, source: "manual",
            notes: "felt \"great\", 3rd rep\nwas hard")
        let csv = DataArchive.workoutsCSV([record])
        let header = csv.split(separator: "\n")[0].split(separator: ",").count
        // The quoted note keeps its comma out of the column count.
        XCTAssertEqual(header, 13)
        XCTAssertTrue(csv.contains("\"felt \"\"great\"\", 3rd rep\nwas hard\""))
    }

    func testEmptyStoreExportsAnEmptyArchive() throws {
        let context = ModelContext(try makeContainer())
        let archive = try DataArchive.archive(from: context)
        XCTAssertTrue(archive.isEmpty)
        XCTAssertEqual(archive.itemCount, 0)
        // And it still round-trips.
        let data = try DataArchive.encoder().encode(archive)
        XCTAssertTrue(try DataArchive.read(data).isEmpty)
    }
}
