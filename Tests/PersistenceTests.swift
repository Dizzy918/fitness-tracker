import XCTest
import SwiftData
import FitDataProtocol
import AntMessageProtocol
@testable import FitnessTracker

final class PersistenceTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Workout.self, Shoe.self, StrengthSession.self, SetEntry.self, Exercise.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func makeFITData(distance: Double = 5000) throws -> Data {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let fileId = FileIdMessage(
            deviceSerialNumber: 1,
            fileCreationDate: FitTime(date: start),
            manufacturer: .suunto,
            fileType: FileType.activity
        )
        let session = SessionMessage(
            startTime: FitTime(date: start),
            sport: .running,
            totalElapsedTime: Measurement(value: 1800, unit: UnitDuration.seconds),
            totalDistance: Measurement(value: distance, unit: UnitLength.meters),
            averageHeartRate: 150
        )
        let record = RecordMessage(
            timeStamp: FitTime(date: start),
            position: Position(latitude: Measurement(value: 42.7, unit: UnitAngle.degrees),
                               longitude: Measurement(value: 23.3, unit: UnitAngle.degrees)),
            distance: Measurement(value: 0, unit: UnitLength.meters),
            heartRate: 145
        )
        switch FitFileEncoder(dataValidityStrategy: .none)
            .encode(fildIdMessage: fileId, messages: [session, record]) {
        case .success(let d): return d
        case .failure(let e): throw e
        }
    }

    func testPersistInsertsWorkout() throws {
        let context = try makeContext()
        let importer = FITImporter()
        let decoded = try importer.decode(data: try makeFITData())

        let workout = try importer.persist(decoded, in: context)

        XCTAssertEqual(workout.source, "fit")
        XCTAssertEqual(workout.sport, .run)
        XCTAssertEqual(workout.distance, 5000, accuracy: 1)
        XCTAssertNotNil(workout.externalID)

        let all = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(all.count, 1)
    }

    func testReimportingSameFileThrowsDuplicate() throws {
        let context = try makeContext()
        let importer = FITImporter()
        let data = try makeFITData()

        _ = try importer.persist(try importer.decode(data: data), in: context)
        try context.save()

        XCTAssertThrowsError(
            try importer.persist(try importer.decode(data: data), in: context)
        ) { error in
            guard case FITPersistError.duplicate = error else {
                return XCTFail("expected .duplicate, got \(error)")
            }
        }

        let all = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(all.count, 1, "duplicate must not be inserted")
    }

    func testDifferentFilesBothImport() throws {
        let context = try makeContext()
        let importer = FITImporter()

        _ = try importer.persist(try importer.decode(data: try makeFITData(distance: 5000)), in: context)
        _ = try importer.persist(try importer.decode(data: try makeFITData(distance: 8000)), in: context)
        try context.save()

        let all = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(all.count, 2)
    }

    func testPersistedBlobsRoundTrip() throws {
        let context = try makeContext()
        let importer = FITImporter()
        let workout = try importer.persist(try importer.decode(data: try makeFITData()), in: context)

        XCTAssertTrue(workout.hasRoute)
        XCTAssertEqual(workout.coordinates.count, 1)
        XCTAssertEqual(workout.coordinates[0][0], 42.7, accuracy: 0.001)
        XCTAssertEqual(workout.samples.count, 1)
        XCTAssertEqual(workout.samples[0].hr, 145)
    }

    // MARK: - Shoe rollups

    func testShoeMileageRollup() throws {
        let context = try makeContext()
        let shoe = Shoe(brand: "Nike", model: "Pegasus", maxDistance: 800_000)
        context.insert(shoe)

        for km in [10.0, 15.0, 21.1] {
            let w = Workout(sport: .run, startedAt: .now, duration: 3600,
                            distance: km * 1000, source: "manual")
            context.insert(w)
            w.shoe = shoe
        }
        try context.save()

        XCTAssertEqual(shoe.totalDistanceKm, 46.1, accuracy: 0.01)
        XCTAssertEqual(shoe.wearFraction, 46_100 / 800_000, accuracy: 0.0001)
        XCTAssertFalse(shoe.isRetired)
    }

    func testWearFractionCapsAtOne() throws {
        let context = try makeContext()
        let shoe = Shoe(brand: "Old", model: "Pair", maxDistance: 100_000)
        context.insert(shoe)
        let w = Workout(sport: .run, startedAt: .now, duration: 3600,
                        distance: 250_000, source: "manual")
        context.insert(w)
        w.shoe = shoe
        try context.save()

        XCTAssertEqual(shoe.wearFraction, 1.0, "wear must clamp so progress bars stay valid")
    }

    func testDeletingWorkoutUpdatesShoeMileage() throws {
        let context = try makeContext()
        let shoe = Shoe(brand: "Nike", model: "Pegasus")
        context.insert(shoe)
        let w = Workout(sport: .run, startedAt: .now, duration: 3600,
                        distance: 10_000, source: "manual")
        context.insert(w)
        w.shoe = shoe
        try context.save()
        XCTAssertEqual(shoe.totalDistanceKm, 10, accuracy: 0.01)

        context.delete(w)
        try context.save()
        XCTAssertEqual(shoe.totalDistanceKm, 0, accuracy: 0.01)
    }

    func testShoeDisplayNamePrefersNickname() {
        let named = Shoe(brand: "Nike", model: "Pegasus 41", nickname: "Daily")
        XCTAssertEqual(named.displayName, "Daily")
        let unnamed = Shoe(brand: "Nike", model: "Pegasus 41")
        XCTAssertEqual(unnamed.displayName, "Nike Pegasus 41")
    }

    // MARK: - Model behavior

    func testSportRawRoundTrip() {
        let w = Workout(sport: .trailRun, startedAt: .now, duration: 60,
                        distance: 100, source: "manual")
        XCTAssertEqual(w.sportRaw, "trailRun")
        XCTAssertEqual(w.sport, .trailRun)
        w.sport = .bike
        XCTAssertEqual(w.sportRaw, "bike")
    }

    func testUnknownSportRawFallsBackToOther() {
        let w = Workout(sport: .run, startedAt: .now, duration: 60,
                        distance: 100, source: "manual")
        w.sportRaw = "kitesurfing"   // e.g. written by a newer app version
        XCTAssertEqual(w.sport, .other, "unknown raw values must not crash")
    }

    func testPaceGuardsAgainstZero() {
        let zero = Workout(sport: .run, startedAt: .now, duration: 0,
                           distance: 0, source: "manual")
        XCTAssertNil(zero.paceSecPerKm)
    }

    func testEstimated1RM() {
        // Epley: 100 kg × 5 reps → 100 × (1 + 5/30) ≈ 116.7
        let set = SetEntry(order: 0, reps: 5, weightKg: 100)
        XCTAssertEqual(set.estimated1RM, 116.67, accuracy: 0.01)
    }

    func testDemoDataSeeds() throws {
        let context = try makeContext()
        let count = DemoData.seed(into: context, weeks: 4)
        try context.save()

        XCTAssertGreaterThan(count, 0)
        let workouts = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(workouts.count, count)
        XCTAssertTrue(workouts.allSatisfy { $0.distance > 0 })
        XCTAssertTrue(workouts.contains { $0.hasRoute }, "demo runs should carry routes")

        let shoes = try context.fetch(FetchDescriptor<Shoe>())
        XCTAssertEqual(shoes.count, 2)
        XCTAssertTrue(shoes.contains { $0.totalDistance > 0 }, "demo runs must be assigned to shoes")

        // Seeded streams must be split-able end to end.
        let withRoute = try XCTUnwrap(workouts.first { $0.hasRoute })
        let splits = SplitCalculator.splits(from: withRoute.samples)
        XCTAssertFalse(splits.isEmpty, "demo samples should produce splits")
    }
}
