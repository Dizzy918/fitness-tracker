import XCTest
import SwiftData
@testable import FitnessTracker

/// The exercise library.
///
/// Before this existed, `Exercise` rows could only come from the demo seeder or
/// a restore — so a real user's set picker was empty and no strength set could
/// be logged at all. These pin the behaviour that makes it usable and the rules
/// that stop it corrupting strength history.
@MainActor
final class ExerciseLibraryTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Workout.self, Shoe.self, StrengthSession.self, SetEntry.self,
            Exercise.self, DailyMetric.self, Route.self, PlannedWorkout.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    // MARK: - The starter catalogue

    func testSeedingAnEmptyStoreCreatesTheWholeStarterList() throws {
        let context = try makeContext()
        XCTAssertTrue(ExerciseLibrary.isEmpty(in: context))

        let added = try ExerciseLibrary.seedStarter(into: context)
        try context.save()

        XCTAssertEqual(added, ExerciseLibrary.starter.count)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Exercise>()).count,
                       ExerciseLibrary.starter.count)
        XCTAssertFalse(ExerciseLibrary.isEmpty(in: context))
    }

    /// Seeding twice — or seeding after a restore — must not create a second
    /// "Back Squat", which would split that lift's progress history in two.
    func testSeedingIsIdempotent() throws {
        let context = try makeContext()
        _ = try ExerciseLibrary.seedStarter(into: context)
        try context.save()

        let second = try ExerciseLibrary.seedStarter(into: context)
        try context.save()

        XCTAssertEqual(second, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Exercise>()).count,
                       ExerciseLibrary.starter.count)
    }

    /// The demo seeder writes "Back Squat" too, with different capitalisation
    /// risk. Matching has to be case-insensitive or both end up in the list.
    func testSeedingSkipsExistingNamesRegardlessOfCase() throws {
        let context = try makeContext()
        context.insert(Exercise(name: "BACK SQUAT", category: "squat"))
        context.insert(Exercise(name: "bench press", category: "push"))
        try context.save()

        let added = try ExerciseLibrary.seedStarter(into: context)
        try context.save()

        XCTAssertEqual(added, ExerciseLibrary.starter.count - 2)
        let names = try context.fetch(FetchDescriptor<Exercise>())
            .map { $0.name.lowercased() }
        XCTAssertEqual(names.filter { $0 == "back squat" }.count, 1)
    }

    func testSeedingAfterDemoDataDoesNotDuplicate() throws {
        let context = try makeContext()
        DemoData.seed(into: context, weeks: 2)
        try context.save()

        try ExerciseLibrary.seedStarter(into: context)
        try context.save()

        let names = try context.fetch(FetchDescriptor<Exercise>()).map { $0.name.lowercased() }
        XCTAssertEqual(Set(names).count, names.count, "no duplicate exercise names")
    }

    func testEveryStarterExerciseIsUsable() {
        for seed in ExerciseLibrary.starter {
            XCTAssertFalse(seed.name.isEmpty)
            XCTAssertFalse(seed.formNote.isEmpty, "\(seed.name) has no cue")
            XCTAssertFalse(seed.muscles.isEmpty, "\(seed.name) names no muscles")
        }
        // Names must be unique, or the idempotence check above is meaningless.
        let names = ExerciseLibrary.starter.map { $0.name.lowercased() }
        XCTAssertEqual(Set(names).count, names.count)
    }

    /// The starter list has to cover the patterns a program is built from —
    /// a library with no hinge in it isn't a starting point.
    func testStarterListCoversEveryMovementPattern() {
        let covered = Set(ExerciseLibrary.starter.map { $0.category })
        XCTAssertEqual(covered, Set(ExerciseLibrary.Category.allCases))
    }

    // MARK: - Categories line up with the analysis

    /// Volume is attributed by pattern. A category the analysis doesn't know
    /// becomes "accessory" in every chart, silently.
    func testCategoriesMatchWhatStrengthAnalysisBuckets() {
        XCTAssertEqual(ExerciseLibrary.Category.allCases.map(\.rawValue),
                       StrengthAnalysis.categories)
    }

    func testCategoryAccessorRoundTripsAndFallsBack() {
        let exercise = Exercise(name: "Zercher Squat", category: "squat")
        XCTAssertEqual(exercise.categoryValue, .squat)

        exercise.categoryValue = .carry
        XCTAssertEqual(exercise.category, "carry")

        // A value from a future version, or a typo in a restore, must not trap.
        exercise.category = "plyometric"
        XCTAssertEqual(exercise.categoryValue, .accessory)
    }

    func testEveryCategoryExplainsItself() {
        for category in ExerciseLibrary.Category.allCases {
            XCTAssertFalse(category.displayName.isEmpty)
            XCTAssertFalse(category.detail.isEmpty)
            XCTAssertFalse(category.symbolName.isEmpty)
        }
    }

    // MARK: - Form notes

    func testFormNoteIgnoresBlankAndWhitespaceOnlyNotes() {
        let exercise = Exercise(name: "Plank", category: "core")
        XCTAssertNil(exercise.formNote)

        exercise.notes = "   \n  "
        XCTAssertNil(exercise.formNote, "whitespace isn't a note")

        exercise.notes = "Ribs down, glutes on."
        XCTAssertEqual(exercise.formNote, "Ribs down, glutes on.")
    }

    func testSeededExercisesCarryTheirCues() throws {
        let context = try makeContext()
        try ExerciseLibrary.seedStarter(into: context)
        try context.save()

        let squat = try XCTUnwrap(try context.fetch(FetchDescriptor<Exercise>())
            .first { $0.name == "Back Squat" })
        XCTAssertNotNil(squat.formNote)
        XCTAssertEqual(squat.categoryValue, .squat)
        XCTAssertTrue(squat.primaryMuscles.contains("quads"))
    }

    // MARK: - Deletion safety

    /// `SetEntry.exercise` nullifies on delete, so removing an exercise that has
    /// logged sets leaves them without an identity — quietly wrong
    /// volume-by-pattern and a broken e1RM history, with no visible cause.
    func testLoggedSetCountGuardsDeletion() throws {
        let context = try makeContext()
        let squat = Exercise(name: "Back Squat", category: "squat")
        let unused = Exercise(name: "Zercher Squat", category: "squat")
        context.insert(squat)
        context.insert(unused)

        let session = StrengthSession(startedAt: .now)
        context.insert(session)
        for order in 0..<3 {
            let set = SetEntry(order: order, reps: 5, weightKg: 100, exercise: squat)
            set.session = session
            context.insert(set)
        }
        try context.save()

        XCTAssertEqual(ExerciseLibrary.loggedSetCount(for: squat, in: context), 3)
        XCTAssertEqual(ExerciseLibrary.loggedSetCount(for: unused, in: context), 0)
    }

    func testWarmupSetsStillCountAsUsage() throws {
        let context = try makeContext()
        let bench = Exercise(name: "Bench Press", category: "push")
        context.insert(bench)
        let session = StrengthSession(startedAt: .now)
        context.insert(session)
        let warmup = SetEntry(order: 0, reps: 10, weightKg: 20,
                              isWarmup: true, exercise: bench)
        warmup.session = session
        context.insert(warmup)
        try context.save()

        XCTAssertEqual(ExerciseLibrary.loggedSetCount(for: bench, in: context), 1,
                       "a warmup is still a reference that would be orphaned")
    }

    // MARK: - Renaming keeps history

    /// Editing in place rather than replacing is what keeps a renamed lift's
    /// progress history intact.
    func testRenamingKeepsEveryLoggedSetAttached() throws {
        let context = try makeContext()
        let exercise = Exercise(name: "Bench Press", category: "push")
        context.insert(exercise)
        let session = StrengthSession(startedAt: .now)
        context.insert(session)
        let set = SetEntry(order: 0, reps: 5, weightKg: 80, exercise: exercise)
        set.session = session
        context.insert(set)
        try context.save()

        exercise.name = "Barbell Bench Press"
        exercise.categoryValue = .push
        try context.save()

        let history = StrengthAnalysis.e1RMHistory(
            sessions: try context.fetch(FetchDescriptor<StrengthSession>()).map(\.snapshot),
            exerciseID: exercise.id)
        XCTAssertEqual(history.count, 1, "renaming must not orphan the history")
        XCTAssertEqual(ExerciseLibrary.loggedSetCount(for: exercise, in: context), 1)
    }

    // MARK: - Round trip through backup

    func testExercisesAndTheirNotesSurviveABackup() throws {
        let context = try makeContext()
        try ExerciseLibrary.seedStarter(into: context)
        try context.save()

        let data = try DataArchive.exportData(from: context)
        let restored = ModelContext(try ModelContainer(
            for: Workout.self, Shoe.self, StrengthSession.self, SetEntry.self,
            Exercise.self, DailyMetric.self, Route.self, PlannedWorkout.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        try DataArchive.restore(try DataArchive.read(data), into: restored)

        let exercises = try restored.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(exercises.count, ExerciseLibrary.starter.count)
        let squat = try XCTUnwrap(exercises.first { $0.name == "Back Squat" })
        XCTAssertNotNil(squat.formNote, "form notes must survive a backup")
        XCTAssertFalse(squat.primaryMuscles.isEmpty)
    }
}
