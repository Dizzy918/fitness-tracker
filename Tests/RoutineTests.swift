import XCTest
import SwiftData
@testable import FitnessTracker

/// Saved routines, and the sets they write out.
@MainActor
final class RoutineTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func exercise(_ name: String, in context: ModelContext) -> Exercise {
        let exercise = Exercise(name: name, category: "push")
        context.insert(exercise)
        return exercise
    }

    /// A routine with the given items, wired up both ways.
    private func routine(_ name: String, items: [RoutineItem],
                         in context: ModelContext) -> Routine {
        let routine = Routine(name: name)
        context.insert(routine)
        for item in items {
            context.insert(item)
            item.routine = routine
        }
        return routine
    }

    // MARK: - Shape

    func testOrderedItemsSortsByOrderNotInsertion() throws {
        let context = try makeContext()
        let a = RoutineItem(order: 2, exercise: exercise("Row", in: context))
        let b = RoutineItem(order: 0, exercise: exercise("Bench", in: context))
        let c = RoutineItem(order: 1, exercise: exercise("Dip", in: context))
        let routine = routine("Push", items: [a, b, c], in: context)

        XCTAssertEqual(routine.orderedItems.map(\.displayName), ["Bench", "Dip", "Row"])
        XCTAssertEqual(routine.summary, "Bench · Dip · Row")
    }

    func testUntitledRoutineStillHasALabel() {
        XCTAssertEqual(Routine(name: "   ").displayName, "Untitled routine")
        XCTAssertEqual(Routine(name: "Push Day A").displayName, "Push Day A")
    }

    func testEmptyRoutineSummarises() {
        XCTAssertEqual(Routine(name: "New").summary, "No exercises")
        XCTAssertEqual(Routine(name: "New").plannedSetCount, 0)
        XCTAssertEqual(Routine(name: "New").plannedVolume, 0)
    }

    func testPlannedVolumeSkipsItemsWithNoTargetWeight() throws {
        let context = try makeContext()
        let loaded = RoutineItem(order: 0, exercise: exercise("Bench", in: context),
                                 targetSets: 3, targetReps: 5, targetWeightKg: 100)
        let bodyweight = RoutineItem(order: 1, exercise: exercise("Pull-up", in: context),
                                     targetSets: 3, targetReps: 8, targetWeightKg: nil)
        let routine = routine("Push", items: [loaded, bodyweight], in: context)

        XCTAssertEqual(routine.plannedSetCount, 6)
        // 3 × 5 × 100 only; the pull-ups contribute nothing rather than a guess.
        XCTAssertEqual(routine.plannedVolume, 1500, accuracy: 0.001)
    }

    func testShorthandIncludesWeightOnlyWhenPrescribed() throws {
        let context = try makeContext()
        let weighted = RoutineItem(order: 0, exercise: exercise("Squat", in: context),
                                   targetSets: 5, targetReps: 3, targetWeightKg: 140)
        let open = RoutineItem(order: 1, exercise: exercise("Push-up", in: context),
                               targetSets: 3, targetReps: 15)
        let text: (Double) -> String = { String(format: "%.0f kg", $0) }

        XCTAssertEqual(weighted.shorthand(weightText: text), "5 × 3 @ 140 kg")
        XCTAssertEqual(open.shorthand(weightText: text), "3 × 15")
    }

    // MARK: - Supersets

    func testStandaloneExercisesAreGroupsOfOne() throws {
        let context = try makeContext()
        let items = (0..<3).map {
            RoutineItem(order: $0, exercise: exercise("Lift \($0)", in: context))
        }
        let routine = routine("Push", items: items, in: context)

        XCTAssertEqual(routine.groups.count, 3)
        XCTAssertTrue(routine.groups.allSatisfy { $0.count == 1 })
    }

    func testConsecutiveItemsSharingAGroupFormASuperset() throws {
        let context = try makeContext()
        let items = [
            RoutineItem(order: 0, exercise: exercise("Squat", in: context)),
            RoutineItem(order: 1, exercise: exercise("Bench", in: context), supersetGroup: 1),
            RoutineItem(order: 2, exercise: exercise("Row", in: context), supersetGroup: 1),
            RoutineItem(order: 3, exercise: exercise("Curl", in: context)),
        ]
        let routine = routine("Push", items: items, in: context)

        XCTAssertEqual(routine.groups.map(\.count), [1, 2, 1])
        XCTAssertEqual(routine.groups[1].map(\.displayName), ["Bench", "Row"])
    }

    /// Two separate supersets must not merge just because they're adjacent.
    func testAdjacentSupersetsWithDifferentGroupsStaySeparate() throws {
        let context = try makeContext()
        let items = [
            RoutineItem(order: 0, exercise: exercise("A", in: context), supersetGroup: 1),
            RoutineItem(order: 1, exercise: exercise("B", in: context), supersetGroup: 1),
            RoutineItem(order: 2, exercise: exercise("C", in: context), supersetGroup: 2),
            RoutineItem(order: 3, exercise: exercise("D", in: context), supersetGroup: 2),
        ]
        let routine = routine("Push", items: items, in: context)

        XCTAssertEqual(routine.groups.map(\.count), [2, 2])
        XCTAssertEqual(routine.groups[0].map(\.displayName), ["A", "B"])
        XCTAssertEqual(routine.groups[1].map(\.displayName), ["C", "D"])
    }

    /// A group number reused after something else intervenes is a new group,
    /// not a resumption of the earlier one — you can't superset across a lift
    /// you did in between.
    func testNonAdjacentItemsSharingAGroupDoNotMerge() throws {
        let context = try makeContext()
        let items = [
            RoutineItem(order: 0, exercise: exercise("A", in: context), supersetGroup: 1),
            RoutineItem(order: 1, exercise: exercise("B", in: context)),
            RoutineItem(order: 2, exercise: exercise("C", in: context), supersetGroup: 1),
        ]
        let routine = routine("Push", items: items, in: context)
        XCTAssertEqual(routine.groups.map(\.count), [1, 1, 1])
    }

    // MARK: - Starting a session

    func testPlannedSetsWritesOutEverySetAsPending() throws {
        let context = try makeContext()
        let items = [
            RoutineItem(order: 0, exercise: exercise("Squat", in: context),
                        targetSets: 3, targetReps: 5, targetWeightKg: 100),
            RoutineItem(order: 1, exercise: exercise("Bench", in: context),
                        targetSets: 2, targetReps: 8, targetWeightKg: 60),
        ]
        let sets = routine("Push", items: items, in: context).plannedSets()

        XCTAssertEqual(sets.count, 5)
        XCTAssertTrue(sets.allSatisfy(\.isPending))
        XCTAssertEqual(sets.map(\.order), [0, 1, 2, 3, 4])
        XCTAssertEqual(sets.prefix(3).map { $0.exercise?.name }, ["Squat", "Squat", "Squat"])
        XCTAssertEqual(sets[0].reps, 5)
        XCTAssertEqual(sets[0].weightKg, 100, accuracy: 0.001)
        XCTAssertEqual(sets[3].reps, 8)
    }

    /// A superset is performed A, B, A, B — so that's the order it's written in.
    func testSupersetSetsAreInterleaved() throws {
        let context = try makeContext()
        let items = [
            RoutineItem(order: 0, exercise: exercise("Bench", in: context),
                        targetSets: 3, targetReps: 8, supersetGroup: 1),
            RoutineItem(order: 1, exercise: exercise("Row", in: context),
                        targetSets: 3, targetReps: 8, supersetGroup: 1),
        ]
        let sets = routine("Push", items: items, in: context).plannedSets()

        XCTAssertEqual(sets.map { $0.exercise?.name },
                       ["Bench", "Row", "Bench", "Row", "Bench", "Row"])
        XCTAssertTrue(sets.allSatisfy { $0.supersetGroup == 1 })
    }

    /// Uneven supersets run as far as each exercise goes, then the longer one
    /// finishes on its own — rather than inventing sets for the shorter.
    func testUnevenSupersetStopsEachExerciseAtItsOwnCount() throws {
        let context = try makeContext()
        let items = [
            RoutineItem(order: 0, exercise: exercise("Bench", in: context),
                        targetSets: 3, targetReps: 8, supersetGroup: 1),
            RoutineItem(order: 1, exercise: exercise("Row", in: context),
                        targetSets: 1, targetReps: 8, supersetGroup: 1),
        ]
        let sets = routine("Push", items: items, in: context).plannedSets()

        XCTAssertEqual(sets.map { $0.exercise?.name }, ["Bench", "Row", "Bench", "Bench"])
    }

    /// A lone exercise marked with a group is not a superset, so the sets it
    /// writes must not claim to be one.
    func testSingletonGroupDoesNotMarkSetsAsSuperset() throws {
        let context = try makeContext()
        let items = [RoutineItem(order: 0, exercise: exercise("Squat", in: context),
                                 targetSets: 2, targetReps: 5, supersetGroup: 1)]
        let sets = routine("Push", items: items, in: context).plannedSets()

        XCTAssertEqual(sets.count, 2)
        XCTAssertTrue(sets.allSatisfy { $0.supersetGroup == nil })
    }

    func testItemsWithNoSetsAreSkipped() throws {
        let context = try makeContext()
        let items = [
            RoutineItem(order: 0, exercise: exercise("Squat", in: context), targetSets: 0),
            RoutineItem(order: 1, exercise: exercise("Bench", in: context), targetSets: 2),
        ]
        let sets = routine("Push", items: items, in: context).plannedSets()
        XCTAssertEqual(sets.count, 2)
        XCTAssertEqual(sets.map { $0.exercise?.name }, ["Bench", "Bench"])
    }

    func testRestCarriesFromTheRoutineOntoTheSet() throws {
        let context = try makeContext()
        let items = [RoutineItem(order: 0, exercise: exercise("Squat", in: context),
                                 targetSets: 1, restSeconds: 240)]
        let sets = routine("Push", items: items, in: context).plannedSets()
        XCTAssertEqual(sets.first?.restSeconds, 240)
    }

    // MARK: - Pending sets and the session's accounting

    func testPendingSetsDoNotCountTowardsVolumeUntilDone() throws {
        let context = try makeContext()
        let session = StrengthSession(startedAt: .now)
        context.insert(session)
        let items = [RoutineItem(order: 0, exercise: exercise("Squat", in: context),
                                 targetSets: 2, targetReps: 5, targetWeightKg: 100)]
        for set in routine("Push", items: items, in: context).plannedSets() {
            context.insert(set)
            set.session = session
        }

        XCTAssertEqual(session.workingSets.count, 2)
        XCTAssertEqual(session.completedWorkingSets.count, 0)
        XCTAssertEqual(session.totalVolume, 0, accuracy: 0.001)

        session.pendingSets.first?.complete()
        XCTAssertEqual(session.completedWorkingSets.count, 1)
        XCTAssertEqual(session.totalVolume, 500, accuracy: 0.001)
        XCTAssertEqual(session.pendingSets.count, 1)
    }

    /// Sets logged the ordinary way have always counted, and must keep doing so
    /// without anyone marking them complete.
    func testDirectlyLoggedSetsCountImmediately() throws {
        let context = try makeContext()
        let session = StrengthSession(startedAt: .now)
        context.insert(session)
        let set = SetEntry(order: 0, reps: 5, weightKg: 100,
                           exercise: exercise("Squat", in: context))
        context.insert(set)
        set.session = session

        XCTAssertFalse(set.isPending)
        XCTAssertEqual(session.totalVolume, 500, accuracy: 0.001)
        XCTAssertNil(session.completionFraction, "an unplanned session has no denominator")
    }

    func testCompletionFractionTracksProgressThroughARoutine() throws {
        let context = try makeContext()
        let session = StrengthSession(startedAt: .now)
        session.routineID = UUID()
        context.insert(session)
        let items = [RoutineItem(order: 0, exercise: exercise("Squat", in: context),
                                 targetSets: 4, targetReps: 5, targetWeightKg: 100)]
        for set in routine("Push", items: items, in: context).plannedSets() {
            context.insert(set)
            set.session = session
        }

        XCTAssertEqual(session.completionFraction ?? -1, 0, accuracy: 0.001)
        session.pendingSets.first?.complete()
        XCTAssertEqual(session.completionFraction ?? -1, 0.25, accuracy: 0.001)
        for set in session.pendingSets { set.complete() }
        XCTAssertEqual(session.completionFraction ?? -1, 1, accuracy: 0.001)
        XCTAssertNil(session.nextPendingSet)
    }

    func testNextPendingSetFollowsPerformanceOrder() throws {
        let context = try makeContext()
        let session = StrengthSession(startedAt: .now)
        context.insert(session)
        let items = [
            RoutineItem(order: 0, exercise: exercise("Bench", in: context),
                        targetSets: 2, targetReps: 8, supersetGroup: 1),
            RoutineItem(order: 1, exercise: exercise("Row", in: context),
                        targetSets: 2, targetReps: 8, supersetGroup: 1),
        ]
        for set in routine("Push", items: items, in: context).plannedSets() {
            context.insert(set)
            set.session = session
        }

        XCTAssertEqual(session.nextPendingSet?.exercise?.name, "Bench")
        session.nextPendingSet?.complete()
        XCTAssertEqual(session.nextPendingSet?.exercise?.name, "Row")
    }

    func testCompleteStampsTheTime() {
        let set = SetEntry(order: 0, reps: 5, weightKg: 100)
        set.isPending = true
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        set.complete(at: when)
        XCTAssertFalse(set.isPending)
        XCTAssertEqual(set.completedAt, when)
    }

    // MARK: - Persistence

    func testRoutineSurvivesAFetch() throws {
        let context = try makeContext()
        let items = [RoutineItem(order: 0, exercise: exercise("Squat", in: context),
                                 targetSets: 5, targetReps: 3, targetWeightKg: 140,
                                 restSeconds: 300)]
        _ = routine("Heavy Squat", items: items, in: context)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Routine>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.orderedItems.count, 1)
        XCTAssertEqual(fetched.first?.orderedItems.first?.restSeconds, 300)
    }

    /// Deleting a routine takes its items but must not touch the exercises they
    /// point at, nor any session already logged from it.
    func testDeletingARoutineLeavesExercisesAndHistoryAlone() throws {
        let context = try makeContext()
        let squat = exercise("Squat", in: context)
        let routine = routine("Heavy",
                              items: [RoutineItem(order: 0, exercise: squat, targetSets: 1)],
                              in: context)
        let session = StrengthSession(startedAt: .now)
        session.routineID = routine.id
        session.routineName = routine.name
        context.insert(session)
        let set = SetEntry(order: 0, reps: 5, weightKg: 100, exercise: squat)
        context.insert(set)
        set.session = session
        try context.save()

        context.delete(routine)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Routine>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RoutineItem>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Exercise>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StrengthSession>()).count, 1)
        XCTAssertEqual(session.totalVolume, 500, accuracy: 0.001)
        XCTAssertEqual(session.routineName, "Heavy", "history keeps the name it was run under")
    }

    /// Deleting an exercise must not gut the routines that referenced it.
    func testDeletingAnExerciseNullifiesRatherThanCascades() throws {
        let context = try makeContext()
        let squat = exercise("Squat", in: context)
        let routine = routine("Heavy",
                              items: [RoutineItem(order: 0, exercise: squat, targetSets: 1)],
                              in: context)
        try context.save()

        context.delete(squat)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<RoutineItem>()).count, 1)
        XCTAssertEqual(routine.orderedItems.first?.exercise, nil)
        XCTAssertEqual(routine.orderedItems.first?.displayName, "No exercise")
    }
}

// MARK: - Backup

/// A backup that silently drops routines is worse than no backup: you find out
/// when you restore, after the device is gone.
@MainActor
final class RoutineArchiveTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    func testRoutineSurvivesAnExportAndRestore() throws {
        let source = try makeContext()
        let squat = Exercise(name: "Squat", category: "squat")
        squat.defaultRestSeconds = 240
        let bench = Exercise(name: "Bench", category: "push")
        source.insert(squat)
        source.insert(bench)

        let routine = Routine(name: "Push Day A")
        routine.notes = "Belt from set 3"
        routine.lastUsedAt = Date(timeIntervalSince1970: 1_700_000_000)
        routine.useCount = 7
        source.insert(routine)
        for (index, pair) in [(squat, 140.0), (bench, 90.0)].enumerated() {
            let item = RoutineItem(order: index, exercise: pair.0, targetSets: 5,
                                   targetReps: 3, targetWeightKg: pair.1,
                                   restSeconds: 300, supersetGroup: 1)
            source.insert(item)
            item.routine = routine
        }
        try source.save()

        let data = try DataArchive.exportData(from: source)
        let restored = try makeContext()
        let report = try DataArchive.restore(DataArchive.read(data), into: restored)
        try restored.save()

        XCTAssertEqual(report.routines, 1)
        let fetched = try restored.fetch(FetchDescriptor<Routine>())
        XCTAssertEqual(fetched.count, 1)
        let copy = try XCTUnwrap(fetched.first)
        XCTAssertEqual(copy.name, "Push Day A")
        XCTAssertEqual(copy.notes, "Belt from set 3")
        XCTAssertEqual(copy.useCount, 7)
        XCTAssertEqual(copy.lastUsedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(copy.orderedItems.map(\.displayName), ["Squat", "Bench"])
        XCTAssertEqual(copy.orderedItems.first?.targetWeightKg ?? 0, 140, accuracy: 0.001)
        XCTAssertEqual(copy.orderedItems.first?.restSeconds, 300)
        XCTAssertEqual(copy.groups.map(\.count), [2], "the superset pairing came back")

        // The items must point at the restored exercises, not dangle.
        XCTAssertNotNil(copy.orderedItems.first?.exercise)
        XCTAssertEqual(
            try restored.fetch(FetchDescriptor<Exercise>())
                .first { $0.name == "Squat" }?.defaultRestSeconds,
            240)
    }

    func testPendingSetsRoundTripWithTheirSession() throws {
        let source = try makeContext()
        let squat = Exercise(name: "Squat", category: "squat")
        source.insert(squat)
        let session = StrengthSession(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        session.routineID = UUID()
        session.routineName = "Heavy Day"
        source.insert(session)

        let done = SetEntry(order: 0, reps: 5, weightKg: 100, exercise: squat)
        done.complete(at: Date(timeIntervalSince1970: 1_700_000_100))
        done.restSeconds = 180
        done.supersetGroup = 2
        let todo = SetEntry(order: 1, reps: 5, weightKg: 100, exercise: squat)
        todo.isPending = true
        todo.restSeconds = 180
        for set in [done, todo] {
            source.insert(set)
            set.session = session
        }
        try source.save()

        let data = try DataArchive.exportData(from: source)
        let restored = try makeContext()
        _ = try DataArchive.restore(DataArchive.read(data), into: restored)
        try restored.save()

        let copy = try XCTUnwrap(try restored.fetch(FetchDescriptor<StrengthSession>()).first)
        XCTAssertEqual(copy.routineName, "Heavy Day")
        XCTAssertEqual(copy.workingSets.count, 2)
        XCTAssertEqual(copy.pendingSets.count, 1, "the set still to do is still pending")
        XCTAssertEqual(copy.completedWorkingSets.count, 1)
        XCTAssertEqual(copy.totalVolume, 500, accuracy: 0.001)
        XCTAssertEqual(copy.completedWorkingSets.first?.completedAt,
                       Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(copy.completedWorkingSets.first?.restSeconds, 180)
        XCTAssertEqual(copy.completedWorkingSets.first?.supersetGroup, 2)
    }

    /// An archive written before routines existed has no `isPending` field.
    /// Every set in it was done, and must come back that way.
    ///
    /// Built by exporting a real archive and deleting the field, rather than by
    /// hand-writing JSON — the archive's own shape is what an old file has to
    /// be missing a key *from*.
    func testOlderArchivesWithoutPendingFieldRestoreAsCompleted() throws {
        let source = try makeContext()
        let squat = Exercise(name: "Squat", category: "squat")
        source.insert(squat)
        let session = StrengthSession(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        source.insert(session)
        let set = SetEntry(order: 0, reps: 5, weightKg: 100, exercise: squat)
        set.session = session
        source.insert(set)
        try source.save()

        var json = try XCTUnwrap(String(data: try DataArchive.exportData(from: source),
                                        encoding: .utf8))
        XCTAssertTrue(json.contains("\"isPending\""), "nothing was removed, so nothing is proved")
        json = json.replacingOccurrences(of: "\"isPending\":false,", with: "")
        XCTAssertFalse(json.contains("\"isPending\""))

        let restored = try makeContext()
        _ = try DataArchive.restore(try DataArchive.read(Data(json.utf8)), into: restored)
        try restored.save()

        let copy = try XCTUnwrap(try restored.fetch(FetchDescriptor<StrengthSession>()).first)
        XCTAssertEqual(copy.pendingSets.count, 0)
        XCTAssertEqual(copy.totalVolume, 500, accuracy: 0.001)
        XCTAssertNil(copy.completionFraction)
    }
}

// MARK: - Rest placement inside a superset

/// Where rest lands in a superset, which is the whole difference between a
/// superset and two exercises done one after the other.
@MainActor
final class SupersetRestTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func exercise(_ name: String, in context: ModelContext) -> Exercise {
        let exercise = Exercise(name: name, category: "push")
        context.insert(exercise)
        return exercise
    }

    private func routine(_ items: [RoutineItem], in context: ModelContext) -> Routine {
        let routine = Routine(name: "Push")
        context.insert(routine)
        for item in items {
            context.insert(item)
            item.routine = routine
        }
        return routine
    }

    /// A,B,A,B,A,B rests after each B and never after an A.
    func testRestFallsAtTheEndOfEachRoundNotBetweenHalves() throws {
        let context = try makeContext()
        let items = [
            RoutineItem(order: 0, exercise: exercise("Bench", in: context), targetSets: 3,
                        targetReps: 8, restSeconds: 90, supersetGroup: 1),
            RoutineItem(order: 1, exercise: exercise("Row", in: context), targetSets: 3,
                        targetReps: 8, restSeconds: 120, supersetGroup: 1),
        ]
        let sets = routine(items, in: context).plannedSets()

        XCTAssertEqual(sets.map { $0.exercise?.name },
                       ["Bench", "Row", "Bench", "Row", "Bench", "Row"])
        XCTAssertEqual(sets.map(\.restSeconds), [nil, 120, nil, 120, nil, 120])
    }

    /// A three-way giant set rests only after the third exercise.
    func testGiantSetRestsOnlyAfterTheLastExercise() throws {
        let context = try makeContext()
        let items = (0..<3).map {
            RoutineItem(order: $0, exercise: exercise("Lift \($0)", in: context),
                        targetSets: 2, targetReps: 10, restSeconds: 150, supersetGroup: 1)
        }
        let sets = routine(items, in: context).plannedSets()
        XCTAssertEqual(sets.map(\.restSeconds), [nil, nil, 150, nil, nil, 150])
    }

    /// When the shorter exercise drops out, the one still going becomes the end
    /// of its own round and gets its rest back.
    func testUnevenSupersetRestsAfterWhicheverExerciseEndsTheRound() throws {
        let context = try makeContext()
        let items = [
            RoutineItem(order: 0, exercise: exercise("Bench", in: context), targetSets: 3,
                        targetReps: 8, restSeconds: 90, supersetGroup: 1),
            RoutineItem(order: 1, exercise: exercise("Row", in: context), targetSets: 1,
                        targetReps: 8, restSeconds: 120, supersetGroup: 1),
        ]
        let sets = routine(items, in: context).plannedSets()

        XCTAssertEqual(sets.map { $0.exercise?.name }, ["Bench", "Row", "Bench", "Bench"])
        // Round 1 ends on Row; rounds 2 and 3 are Bench alone.
        XCTAssertEqual(sets.map(\.restSeconds), [nil, 120, 90, 90])
    }

    /// A standalone exercise rests after every set, as it always did.
    func testStandaloneExerciseRestsAfterEverySet() throws {
        let context = try makeContext()
        let items = [RoutineItem(order: 0, exercise: exercise("Squat", in: context),
                                 targetSets: 3, targetReps: 5, restSeconds: 180)]
        let sets = routine(items, in: context).plannedSets()
        XCTAssertEqual(sets.map(\.restSeconds), [180, 180, 180])
    }
}

// MARK: - Demo data

@MainActor
final class DemoExerciseReuseTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// Seeding the library and then the demo data must not leave two exercises
    /// with the same name — one of which has all the history and the other none.
    func testDemoDataReusesLibraryExercisesRatherThanDuplicatingThem() throws {
        let context = try makeContext()
        try ExerciseLibrary.seedStarter(into: context)
        try context.save()

        _ = DemoData.seed(into: context)
        try context.save()

        let names = try context.fetch(FetchDescriptor<Exercise>()).map { $0.name.lowercased() }
        XCTAssertEqual(names.count, Set(names).count,
                       "duplicate exercise names: \(names.sorted())")

        // And the reused rows are the ones carrying the demo's sets.
        let squats = try context.fetch(FetchDescriptor<Exercise>())
            .filter { $0.name == "Back Squat" }
        XCTAssertEqual(squats.count, 1)
        XCTAssertGreaterThan(squats.first?.sets.count ?? 0, 0)
    }

    /// The other order has to work too: demo data first, then the library.
    func testSeedingTheLibraryAfterDemoDataStillLeavesOneOfEach() throws {
        let context = try makeContext()
        _ = DemoData.seed(into: context)
        try context.save()
        try ExerciseLibrary.seedStarter(into: context)
        try context.save()

        let names = try context.fetch(FetchDescriptor<Exercise>()).map { $0.name.lowercased() }
        XCTAssertEqual(names.count, Set(names).count,
                       "duplicate exercise names: \(names.sorted())")
    }
}
