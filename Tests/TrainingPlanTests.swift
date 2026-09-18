import XCTest
import SwiftData
@testable import FitnessTracker

/// Planned vs actual.
///
/// The matching is the whole problem: a plan says "Tuesday, intervals" and the
/// watch produces a run on Tuesday, with nothing linking them. Getting it wrong
/// in either direction is bad — a plan that absorbs any nearby session tells you
/// nothing about whether you followed it, and one that matches too strictly
/// reports a week you actually completed as a week of misses.
@MainActor
final class TrainingPlanTests: XCTestCase {

    private let calendar = Calendar.current
    private var monday: Date {
        calendar.dateInterval(of: .weekOfYear,
                              for: Date(timeIntervalSince1970: 1_700_000_000))!.start
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: monday)!
    }

    private func plan(_ offset: Int, _ sport: WorkoutSport = .run,
                      title: String = "Session",
                      duration: TimeInterval? = 3600,
                      load: Double? = nil,
                      completed: UUID? = nil,
                      skipped: Bool = false,
                      order: Int = 0) -> PlannedWorkoutSnapshot {
        let model = PlannedWorkout(scheduledFor: day(offset), sport: sport,
                                   title: title, order: order)
        model.targetDuration = duration
        model.targetLoad = load
        model.completedWorkoutID = completed
        model.skippedAt = skipped ? .now : nil
        return model.snapshot
    }

    private func workout(_ offset: Int, _ sport: WorkoutSport = .run,
                         hour: Int = 9, distance: Double = 10_000,
                         duration: TimeInterval = 3600,
                         id: UUID = UUID()) -> WorkoutSnapshot {
        WorkoutSnapshot(
            id: id, sport: sport,
            startedAt: calendar.date(byAdding: .hour, value: hour, to: day(offset))!,
            distance: distance, duration: duration, avgHeartRate: 150)
    }

    // MARK: - Matching

    func testSameDaySameSportIsMatched() {
        let run = workout(1, .run)
        let (entries, unmatched) = TrainingPlan.match(
            planned: [plan(1, .run)], workouts: [run])

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].actual?.id, run.id)
        XCTAssertTrue(unmatched.isEmpty)
    }

    /// Tuesday's plan is not satisfied by Thursday's run. A plan that reaches
    /// across days stops measuring whether you followed it.
    func testMatchingNeverCrossesADayBoundary() {
        let (entries, unmatched) = TrainingPlan.match(
            planned: [plan(1, .run)], workouts: [workout(3, .run)])

        XCTAssertNil(entries[0].actual)
        XCTAssertEqual(unmatched.count, 1)
    }

    /// A planned run that became a ride is still that day's session. Calling it
    /// both a miss and an extra would double-count the week.
    func testASameDayWorkoutOfAnotherSportStillCounts() {
        let ride = workout(2, .bike)
        let (entries, unmatched) = TrainingPlan.match(
            planned: [plan(2, .run)], workouts: [ride])

        XCTAssertEqual(entries[0].actual?.id, ride.id)
        XCTAssertTrue(unmatched.isEmpty)
    }

    /// With both available, the matching sport wins over the merely-same-day one.
    func testSportMatchIsPreferredOverAnySameDaySession() {
        let ride = workout(2, .bike)
        let run = workout(2, .run, hour: 18)
        let (entries, _) = TrainingPlan.match(
            planned: [plan(2, .run)], workouts: [ride, run])

        XCTAssertEqual(entries[0].actual?.id, run.id)
    }

    /// One workout can't satisfy two plans, or a double day reads as complete
    /// when only half of it happened.
    func testOneWorkoutSatisfiesOnlyOnePlan() {
        let run = workout(2, .run)
        let (entries, _) = TrainingPlan.match(
            planned: [plan(2, .run, title: "AM", order: 0),
                      plan(2, .run, title: "PM", order: 1)],
            workouts: [run])

        XCTAssertEqual(entries.filter { $0.actual != nil }.count, 1)
        XCTAssertEqual(entries.filter { $0.actual == nil }.count, 1)
    }

    func testTwoWorkoutsSatisfyTwoPlansOnTheSameDay() {
        let (entries, unmatched) = TrainingPlan.match(
            planned: [plan(2, .run, order: 0), plan(2, .run, order: 1)],
            workouts: [workout(2, .run, hour: 7), workout(2, .run, hour: 18)])

        XCTAssertEqual(entries.filter { $0.actual != nil }.count, 2)
        XCTAssertTrue(unmatched.isEmpty)
    }

    /// An explicit link the athlete made must never be stolen by an inferred
    /// match, whatever order things are considered in.
    func testAnExplicitLinkWinsOverInference() {
        let morning = workout(2, .run, hour: 7)
        let evening = workout(2, .run, hour: 18)
        let pinned = plan(2, .run, title: "PM", completed: evening.id, order: 1)
        let loose = plan(2, .run, title: "AM", order: 0)

        let (entries, _) = TrainingPlan.match(planned: [loose, pinned],
                                              workouts: [morning, evening])
        let byTitle = Dictionary(uniqueKeysWithValues: entries.map { ($0.planned.title, $0) })
        XCTAssertEqual(byTitle["PM"]?.actual?.id, evening.id)
        XCTAssertEqual(byTitle["AM"]?.actual?.id, morning.id)
    }

    /// A skipped plan doesn't reach for a workout — the athlete already said it
    /// didn't happen, so the day's session is an extra, not a fulfilment.
    func testASkippedPlanDoesNotClaimThatDaysWorkout() {
        let run = workout(2, .run)
        let (entries, unmatched) = TrainingPlan.match(
            planned: [plan(2, .run, skipped: true)], workouts: [run])

        XCTAssertNil(entries[0].actual)
        XCTAssertEqual(unmatched.map(\.id), [run.id])
    }

    func testWorkoutsWithNoPlanComeBackAsUnmatched() {
        let (entries, unmatched) = TrainingPlan.match(
            planned: [], workouts: [workout(1), workout(3)])
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(unmatched.count, 2)
    }

    func testEmptyInputsAreHandled() {
        let (entries, unmatched) = TrainingPlan.match(planned: [], workouts: [])
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(unmatched.isEmpty)
    }

    // MARK: - Week assembly

    func testWeekScoresBothSidesOnTheSameScale() {
        let week = TrainingPlan.week(
            containing: day(2),
            planned: [plan(1, .run, load: 60), plan(3, .bike, load: 90)],
            workouts: [workout(1, .run), workout(5, .swim, distance: 2000, duration: 2400)],
            athlete: .init(maxHR: 190, restingHR: 50))

        XCTAssertEqual(week.entries.count, 2)
        XCTAssertEqual(week.plannedLoad, 150, accuracy: 0.001)
        XCTAssertEqual(week.completedCount, 1)
        XCTAssertEqual(week.outstandingCount, 1)
        XCTAssertEqual(week.unplanned.count, 1, "the swim wasn't planned")
        XCTAssertGreaterThan(week.unplannedLoad, 0)
        // Unplanned work still happened and still cost something.
        XCTAssertGreaterThan(week.completedLoad, 0)
    }

    /// A week only counts its own days — last Sunday's session is not this
    /// week's progress.
    func testWeekIgnoresSessionsOutsideIt() {
        let week = TrainingPlan.week(
            containing: day(2),
            planned: [plan(1), plan(-3, .run, title: "last week")],
            workouts: [workout(-3), workout(9)],
            athlete: .init())

        XCTAssertEqual(week.entries.count, 1)
        XCTAssertTrue(week.unplanned.isEmpty)
    }

    func testEmptyWeekReportsItselfAsEmpty() {
        let week = TrainingPlan.week(containing: day(2), planned: [],
                                     workouts: [], athlete: .init())
        XCTAssertTrue(week.isEmpty)
        XCTAssertNil(week.completionFraction)
        XCTAssertEqual(week.summary, "Nothing planned.")
    }

    func testCompletionFractionNeedsAPlannedLoadToDivideBy() {
        // Plans with no target: nothing to measure progress against.
        let week = TrainingPlan.week(
            containing: day(2),
            planned: [plan(1, .run, duration: nil)],
            workouts: [workout(1, .run)], athlete: .init())
        XCTAssertNil(week.completionFraction)
    }

    func testSummaryCountsDoneSkippedAndUnplanned() {
        let week = TrainingPlan.week(
            containing: day(2),
            planned: [plan(1), plan(2, skipped: true), plan(4)],
            workouts: [workout(1), workout(6, .swim)],
            athlete: .init())
        XCTAssertTrue(week.summary.contains("1 of 3 done"))
        XCTAssertTrue(week.summary.contains("1 skipped"))
        XCTAssertTrue(week.summary.contains("1 unplanned"))
    }

    // MARK: - Estimated load

    /// A week planned in minutes has to land on the same scale as one planned in
    /// TSS, or the header's total is meaningless.
    func testLoadIsEstimatedFromDurationWhenNotGivenOutright() {
        let model = PlannedWorkout(scheduledFor: monday, sport: .run)
        model.targetDuration = 3600
        let intensity = TrainingLoad.defaultIntensity(for: .run)
        XCTAssertEqual(model.estimatedLoad ?? 0, intensity * intensity * 100, accuracy: 0.001)

        // An explicit target always wins.
        model.targetLoad = 95
        XCTAssertEqual(model.estimatedLoad, 95)
    }

    func testAPlanWithNoTargetHasNoLoad() {
        let model = PlannedWorkout(scheduledFor: monday, sport: .run)
        XCTAssertNil(model.estimatedLoad)
    }

    /// The estimate uses the same per-sport assumption the load model makes for
    /// an unmeasured session, so planned and completed agree.
    func testEstimateMatchesWhatAnUnmeasuredSessionWouldScore() throws {
        let model = PlannedWorkout(scheduledFor: monday, sport: .bike)
        model.targetDuration = 5400

        let asDone = WorkoutSnapshot(id: UUID(), sport: .bike, startedAt: monday,
                                     distance: 40_000, duration: 5400)
        let scored = try XCTUnwrap(TrainingLoad.score(for: asDone, athlete: .init()))
        XCTAssertEqual(model.estimatedLoad ?? 0, scored.value, accuracy: 0.001)
    }

    func testDisplayTitleFallsBackToTheSport() {
        let model = PlannedWorkout(scheduledFor: monday, sport: .swim)
        XCTAssertEqual(model.displayTitle, "Swim")
        model.title = "   "
        XCTAssertEqual(model.displayTitle, "Swim", "whitespace isn't a title")
        model.title = "4 × 400 IM"
        XCTAssertEqual(model.displayTitle, "4 × 400 IM")
    }

    func testStateFlagsAreMutuallyConsistent() {
        let model = PlannedWorkout(scheduledFor: monday)
        XCTAssertTrue(model.isOutstanding)

        model.skippedAt = .now
        XCTAssertTrue(model.isSkipped)
        XCTAssertFalse(model.isOutstanding)

        model.skippedAt = nil
        model.completedWorkoutID = UUID()
        XCTAssertTrue(model.isCompleted)
        XCTAssertFalse(model.isOutstanding)
    }

    // MARK: - Ramp warning

    func testRampComparesPlannedLoadWithRecentAverage() {
        XCTAssertEqual(TrainingPlan.ramp(plannedLoad: 300, recentWeeklyLoad: 300), .sustainable)
        XCTAssertEqual(TrainingPlan.ramp(plannedLoad: 150, recentWeeklyLoad: 300), .light)
        XCTAssertEqual(TrainingPlan.ramp(plannedLoad: 380, recentWeeklyLoad: 300), .ambitious)
        XCTAssertEqual(TrainingPlan.ramp(plannedLoad: 600, recentWeeklyLoad: 300), .reckless)
    }

    /// Declaring a first week "reckless" because it's above a baseline of zero
    /// would be useless and quickly ignored.
    func testNoRampVerdictWithoutEnoughHistory() {
        XCTAssertNil(TrainingPlan.ramp(plannedLoad: 400, recentWeeklyLoad: 0))
        XCTAssertNil(TrainingPlan.ramp(plannedLoad: 400, recentWeeklyLoad: 10))
        XCTAssertNil(TrainingPlan.ramp(plannedLoad: 0, recentWeeklyLoad: 300))
    }

    func testEveryRampVerdictExplainsItself() {
        for verdict in [TrainingPlan.RampVerdict.light, .sustainable, .ambitious, .reckless] {
            XCTAssertFalse(verdict.label.isEmpty)
            XCTAssertFalse(verdict.guidance.isEmpty)
        }
    }

    /// A lay-off shouldn't make a return to normal training read as reckless, so
    /// weeks with no training at all are excluded from the average.
    func testRecentAverageIgnoresWeeksWithNoTraining() {
        let athlete = TrainingLoad.Athlete()
        // Trained two weeks ago; nothing since.
        let workouts = [workout(-14, .run, duration: 3600),
                        workout(-13, .run, duration: 3600)]

        let average = TrainingPlan.recentWeeklyLoad(
            workouts: workouts, athlete: athlete, before: monday, weeks: 4)
        XCTAssertGreaterThan(average, 0, "an empty week must not drag the average to zero")
    }

    func testRecentAverageIsZeroWithNoHistoryAtAll() {
        XCTAssertEqual(TrainingPlan.recentWeeklyLoad(
            workouts: [], athlete: .init(), before: monday), 0)
    }

    // MARK: - Persistence and backup

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    func testScheduledDatesNormalizeToStartOfDay() throws {
        let context = try makeContext()
        let afternoon = calendar.date(byAdding: .hour, value: 15, to: monday)!
        let plan = PlannedWorkout(scheduledFor: afternoon, sport: .run)
        context.insert(plan)
        try context.save()

        XCTAssertEqual(plan.scheduledFor, calendar.startOfDay(for: afternoon))
    }

    /// Losing next week's training because you restored a backup is exactly the
    /// failure the archive exists to prevent.
    func testPlansSurviveABackupRoundTrip() throws {
        let context = try makeContext()
        let plan = PlannedWorkout(scheduledFor: monday, sport: .bike, title: "Threshold 3×10")
        plan.targetDuration = 4500
        plan.targetLoad = 85
        plan.notes = "Keep it on the flat"
        context.insert(plan)
        try context.save()

        let data = try DataArchive.exportData(from: context)
        let restored = try makeContext()
        let report = try DataArchive.restore(try DataArchive.read(data), into: restored)

        XCTAssertEqual(report.plannedWorkouts, 1)
        let copy = try XCTUnwrap(try restored.fetch(FetchDescriptor<PlannedWorkout>()).first)
        XCTAssertEqual(copy.title, "Threshold 3×10")
        XCTAssertEqual(copy.targetLoad, 85)
        XCTAssertEqual(copy.sport, .bike)
        XCTAssertEqual(copy.notes, "Keep it on the flat")
    }

    func testRestoringPlansTwiceDoesNotDuplicateThem() throws {
        let context = try makeContext()
        context.insert(PlannedWorkout(scheduledFor: monday, sport: .run, title: "Long"))
        try context.save()

        let data = try DataArchive.exportData(from: context)
        let target = try makeContext()
        try DataArchive.restore(try DataArchive.read(data), into: target)
        try target.save()
        let second = try DataArchive.restore(try DataArchive.read(data), into: target)

        XCTAssertEqual(second.plannedWorkouts, 0)
        XCTAssertEqual(try target.fetch(FetchDescriptor<PlannedWorkout>()).count, 1)
    }
}
