import XCTest
import SwiftData
@testable import FitnessTracker

/// Races, and running the load model forward over a plan.
final class SeasonPlanTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)
    private let today = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14

    private func day(_ offset: Int) -> Date {
        calendar.startOfDay(for: today.addingTimeInterval(Double(offset) * 86_400))
    }

    /// A settled history at a given fitness and fatigue, so a projection has
    /// somewhere realistic to start from.
    private func history(fitness: Double, fatigue: Double) -> [TrainingLoad.Point] {
        [TrainingLoad.Point(date: day(0), load: 0,
                            fitness: fitness, fatigue: fatigue)]
    }

    private func plan(_ dayOffset: Int, load: Double) -> PlannedWorkoutSnapshot {
        PlannedWorkoutSnapshot(
            id: UUID(), scheduledFor: day(dayOffset), sport: .run, title: "Session",
            targetDuration: nil, targetDistance: nil, estimatedLoad: load,
            completedWorkoutID: nil, skippedAt: nil, order: 0)
    }

    // MARK: - The verdict thresholds

    func testVerdictFollowsTheConventionalTSBWindow() {
        XCTAssertEqual(SeasonPlan.verdict(form: -25), .carryingFatigue)
        XCTAssertEqual(SeasonPlan.verdict(form: -11), .carryingFatigue)
        XCTAssertEqual(SeasonPlan.verdict(form: -10), .slightlyFatigued)
        XCTAssertEqual(SeasonPlan.verdict(form: 0), .slightlyFatigued)
        XCTAssertEqual(SeasonPlan.verdict(form: 5), .sharp)
        XCTAssertEqual(SeasonPlan.verdict(form: 15), .sharp)
        XCTAssertEqual(SeasonPlan.verdict(form: 25), .sharp)
        XCTAssertEqual(SeasonPlan.verdict(form: 26), .overTapered)
        XCTAssertTrue(SeasonPlan.verdict(form: 15).isGood)
        XCTAssertFalse(SeasonPlan.verdict(form: 40).isGood)
    }

    // MARK: - Projection mechanics

    func testProjectionStartsTheDayAfterHistoryEnds() {
        let projection = SeasonPlan.project(
            history: history(fitness: 60, fatigue: 60), plans: [],
            through: day(5), calendar: calendar)

        XCTAssertEqual(projection.points.count, 5)
        XCTAssertEqual(projection.points.first?.date, day(1),
                       "today is the last actual point, not the first projected one")
        XCTAssertEqual(projection.points.last?.date, day(5))
        XCTAssertEqual(projection.from?.date, day(0))
    }

    /// With nothing planned, both curves decay — and fatigue decays much faster
    /// than fitness. That asymmetry is the entire mechanism of a taper.
    func testRestDecaysFatigueFasterThanFitness() throws {
        let projection = SeasonPlan.project(
            history: history(fitness: 60, fatigue: 60), plans: [],
            through: day(14), calendar: calendar)
        let arrival = try XCTUnwrap(projection.arrival)

        XCTAssertLessThan(arrival.fatigue, 10, "7-day constant over 14 days")
        XCTAssertGreaterThan(arrival.fitness, 40, "42-day constant holds most of it")
        XCTAssertGreaterThan(arrival.form, 25)
        // Two weeks of *complete* rest is not a taper. The balance alone would
        // read it as merely over-tapered; a 29% drop in fitness is detraining,
        // and that's the more useful thing to say. See TaperVerdictFitnessTests.
        XCTAssertEqual(projection.verdict(), .detrained)
        XCTAssertEqual(SeasonPlan.verdict(form: arrival.form), .overTapered,
                       "reading the balance on its own still says over-tapered")
    }

    /// The point of the whole feature: the same athlete, two plans, two answers.
    func testTheSamePlanShapeChangesRaceDayForm() {
        // Hard right up to the day.
        let relentless = (1...14).map { plan($0, load: 90) }
        // Two weeks of reducing volume.
        let tapered = (1...7).map { plan($0, load: 70) } + (8...14).map { plan($0, load: 25) }

        let hard = SeasonPlan.project(history: history(fitness: 70, fatigue: 70),
                                      plans: relentless, through: day(14),
                                      calendar: calendar)
        let easy = SeasonPlan.project(history: history(fitness: 70, fatigue: 70),
                                      plans: tapered, through: day(14),
                                      calendar: calendar)

        XCTAssertLessThan(hard.arrival?.form ?? 0, easy.arrival?.form ?? 0,
                          "tapering has to arrive fresher than not tapering")
        XCTAssertEqual(hard.verdict(), .carryingFatigue)
        XCTAssertTrue([.sharp, .slightlyFatigued].contains(easy.verdict()),
                      "got \(String(describing: easy.verdict()))")
    }

    /// Two sessions on one day are one day's load, summed — same as the
    /// retrospective totals do it.
    func testTwoSessionsOnADaySum() {
        let doubled = SeasonPlan.project(
            history: history(fitness: 50, fatigue: 50),
            plans: [plan(1, load: 40), plan(1, load: 40)],
            through: day(1), calendar: calendar)
        let single = SeasonPlan.project(
            history: history(fitness: 50, fatigue: 50),
            plans: [plan(1, load: 80)],
            through: day(1), calendar: calendar)

        XCTAssertEqual(doubled.arrival?.load ?? 0, 80, accuracy: 0.001)
        XCTAssertEqual(doubled.arrival?.fatigue ?? 0, single.arrival?.fatigue ?? -1,
                       accuracy: 0.001)
    }

    /// A completed plan is already in the history as a real workout. Counting
    /// it again would double its load.
    func testCompletedAndSkippedPlansAreExcluded() {
        let completed = PlannedWorkoutSnapshot(
            id: UUID(), scheduledFor: day(1), sport: .run, title: "Done",
            targetDuration: nil, targetDistance: nil, estimatedLoad: 100,
            completedWorkoutID: UUID(), skippedAt: nil, order: 0)
        let skipped = PlannedWorkoutSnapshot(
            id: UUID(), scheduledFor: day(2), sport: .run, title: "Skipped",
            targetDuration: nil, targetDistance: nil, estimatedLoad: 100,
            completedWorkoutID: nil, skippedAt: day(2), order: 0)

        let projection = SeasonPlan.project(
            history: history(fitness: 50, fatigue: 50),
            plans: [completed, skipped], through: day(3), calendar: calendar)

        XCTAssertEqual(projection.plannedDays, 0)
        XCTAssertTrue(projection.points.allSatisfy { $0.load == 0 })
    }

    func testPlansOutsideTheWindowAreIgnored() {
        let projection = SeasonPlan.project(
            history: history(fitness: 50, fatigue: 50),
            plans: [plan(-3, load: 100), plan(20, load: 100)],
            through: day(5), calendar: calendar)
        XCTAssertEqual(projection.plannedDays, 0)
        XCTAssertEqual(projection.unplannedDays, 5)
    }

    func testPlannedAndUnplannedDaysAreCounted() {
        let projection = SeasonPlan.project(
            history: history(fitness: 50, fatigue: 50),
            plans: [plan(1, load: 50), plan(3, load: 50), plan(5, load: 50)],
            through: day(6), calendar: calendar)
        XCTAssertEqual(projection.plannedDays, 3)
        XCTAssertEqual(projection.unplannedDays, 3)
    }

    /// An empty calendar makes the projection a statement about the calendar,
    /// not about the athlete. It has to say so.
    func testAnEmptyCalendarIsFlaggedAsAssumption() {
        let empty = SeasonPlan.project(history: history(fitness: 60, fatigue: 60),
                                       plans: [], through: day(20), calendar: calendar)
        XCTAssertTrue(empty.isMostlyAssumed)

        let full = SeasonPlan.project(
            history: history(fitness: 60, fatigue: 60),
            plans: (1...20).map { plan($0, load: 60) },
            through: day(20), calendar: calendar)
        XCTAssertFalse(full.isMostlyAssumed)
    }

    func testNoHistoryYieldsNoProjectionRatherThanZeroes() {
        let projection = SeasonPlan.project(history: [], plans: [plan(1, load: 50)],
                                            through: day(5), calendar: calendar)
        XCTAssertTrue(projection.points.isEmpty)
        XCTAssertNil(projection.arrival)
        XCTAssertNil(projection.verdict())
        XCTAssertTrue(projection.isMostlyAssumed)
    }

    func testRaceInThePastYieldsNoProjection() {
        let projection = SeasonPlan.project(history: history(fitness: 60, fatigue: 60),
                                            plans: [], through: day(-5),
                                            calendar: calendar)
        XCTAssertTrue(projection.points.isEmpty)
        XCTAssertNotNil(projection.from, "the starting state is still known")
    }

    /// A race today is not projectable — today's state is already measured.
    func testRaceTodayYieldsNoProjection() {
        let projection = SeasonPlan.project(history: history(fitness: 60, fatigue: 60),
                                            plans: [], through: day(0),
                                            calendar: calendar)
        XCTAssertTrue(projection.points.isEmpty)
    }

    // MARK: - Choosing what to show

    private func race(_ dayOffset: Int, _ priority: Race.Priority,
                      complete: Bool = false, name: String = "Race") -> RaceSnapshot {
        RaceSnapshot(id: UUID(), name: name, date: day(dayOffset), sport: .run,
                     priority: priority, distance: nil, goalDuration: nil,
                     isComplete: complete)
    }

    /// An A race further out still beats a C race next week: the A race is the
    /// one the season is built around.
    func testFocusPrefersTheNextARaceOverASoonerCRace() {
        let focus = SeasonPlan.focus(
            among: [race(7, .c, name: "Parkrun"), race(60, .a, name: "Marathon")],
            from: today, calendar: calendar)
        XCTAssertEqual(focus?.name, "Marathon")
    }

    func testFocusFallsBackToAnyRaceWhenThereIsNoA() {
        let focus = SeasonPlan.focus(among: [race(30, .c), race(10, .b, name: "Half")],
                                     from: today, calendar: calendar)
        XCTAssertEqual(focus?.name, "Half")
    }

    func testFocusIgnoresPastAndCompletedRaces() {
        XCTAssertNil(SeasonPlan.focus(among: [race(-10, .a), race(5, .a, complete: true)],
                                      from: today, calendar: calendar))
    }

    func testARaceTodayIsStillUpcoming() {
        let focus = SeasonPlan.focus(among: [race(0, .a, name: "Today")],
                                     from: today, calendar: calendar)
        XCTAssertEqual(focus?.name, "Today")
    }

    func testSplitOrdersUpcomingSoonestAndPastMostRecent() {
        let races = [race(30, .a, name: "Far"), race(-5, .b, name: "Recent"),
                     race(5, .c, name: "Soon"), race(-40, .a, name: "Old")]
        let split = SeasonPlan.split(races, from: today, calendar: calendar)

        XCTAssertEqual(split.upcoming.map(\.name), ["Soon", "Far"])
        XCTAssertEqual(split.past.map(\.name), ["Recent", "Old"])
    }

    /// A race that's been and gone is in the past whether or not a result was
    /// ever entered — otherwise it sits in "upcoming" forever.
    func testPastRaceWithNoResultIsStillPast() {
        let split = SeasonPlan.split([race(-3, .a, name: "Unrecorded")],
                                     from: today, calendar: calendar)
        XCTAssertTrue(split.upcoming.isEmpty)
        XCTAssertEqual(split.past.map(\.name), ["Unrecorded"])
    }

    // MARK: - Weekly shape

    func testWeeksCoverTheWholeBlockIncludingEmptyOnes() {
        let weeks = SeasonPlan.weeks(
            plans: [plan(2, load: 60)], until: day(20), taperStart: nil,
            from: today, calendar: calendar)

        XCTAssertGreaterThanOrEqual(weeks.count, 3)
        XCTAssertEqual(weeks.map(\.load).reduce(0, +), 60, accuracy: 0.001)
        XCTAssertTrue(weeks.contains { $0.load == 0 }, "a gap in the plan must show")
        // Weeks are contiguous and ascending.
        for (earlier, later) in zip(weeks, weeks.dropFirst()) {
            XCTAssertEqual(calendar.dateComponents([.day], from: earlier.start,
                                                   to: later.start).day, 7)
        }
    }

    func testTaperWeeksAreMarked() {
        let weeks = SeasonPlan.weeks(
            plans: [], until: day(21), taperStart: day(7),
            from: today, calendar: calendar)
        XCTAssertTrue(weeks.contains { !$0.isTaper })
        XCTAssertTrue(weeks.contains { $0.isTaper })
        // Once the taper starts it doesn't stop.
        let flags = weeks.map(\.isTaper)
        XCTAssertEqual(flags, flags.sorted { !$0 && $1 })
    }

    func testWeeksAreEmptyForAPastRace() {
        XCTAssertTrue(SeasonPlan.weeks(plans: [], until: day(-1), taperStart: nil,
                                       from: today, calendar: calendar).isEmpty)
    }

    func testSessionsAreCountedPerWeek() {
        let weeks = SeasonPlan.weeks(
            plans: [plan(1, load: 30), plan(2, load: 30), plan(3, load: 30)],
            until: day(10), taperStart: nil, from: today, calendar: calendar)
        XCTAssertEqual(weeks.map(\.sessions).reduce(0, +), 3)
    }
}

/// The `Race` model itself.
@MainActor
final class RaceTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)
    private let today = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func day(_ offset: Int) -> Date {
        today.addingTimeInterval(Double(offset) * 86_400)
    }

    func testDateIsNormalisedToTheStartOfTheDay() {
        let race = Race(date: today.addingTimeInterval(43_200))
        XCTAssertEqual(race.date, Calendar.current.startOfDay(for: today.addingTimeInterval(43_200)))
    }

    func testDaysAwayCountsForwardsAndBackwards() {
        XCTAssertEqual(Race(date: day(30)).daysAway(from: today, calendar: calendar), 30)
        XCTAssertEqual(Race(date: day(0)).daysAway(from: today, calendar: calendar), 0)
        XCTAssertEqual(Race(date: day(-7)).daysAway(from: today, calendar: calendar), -7)
    }

    /// Taper length is dictated by the time constants, not by taste: fatigue
    /// clears in about a week, fitness takes six.
    func testTaperLengthFollowsPriority() {
        XCTAssertEqual(Race.Priority.a.taperDays, 14)
        XCTAssertEqual(Race.Priority.b.taperDays, 7)
        XCTAssertEqual(Race.Priority.c.taperDays, 0)

        let a = Race(date: day(30), priority: .a)
        XCTAssertEqual(calendar.dateComponents([.day], from: try! XCTUnwrap(a.taperStart(calendar: calendar)),
                                               to: a.date).day, 14)
        XCTAssertNil(Race(date: day(30), priority: .c).taperStart(calendar: calendar),
                     "you train through a C race")
    }

    func testUpcomingExcludesPastAndCompleted() {
        XCTAssertTrue(Race(date: day(1)).isUpcoming(from: today))
        XCTAssertTrue(Race(date: day(0)).isUpcoming(from: today))
        XCTAssertFalse(Race(date: day(-1)).isUpcoming(from: today))

        let done = Race(date: day(5))
        done.resultDuration = 3600
        XCTAssertTrue(done.isComplete)
        XCTAssertFalse(done.isUpcoming(from: today))
    }

    func testNamelessRaceStillHasALabel() {
        XCTAssertEqual(Race(name: "  ", date: today, sport: .bike).displayName, "Bike race")
        XCTAssertEqual(Race(name: "Berlin", date: today).displayName, "Berlin")
    }

    func testGoalPaceNeedsBothDistanceAndTime() {
        let race = Race(date: today)
        XCTAssertNil(race.goalPace)
        race.distance = 42_195
        XCTAssertNil(race.goalPace)
        race.goalDuration = 3 * 3600
        // Seconds per kilometre: a 3-hour marathon is 4:16/km.
        XCTAssertEqual(race.goalPace ?? 0, 10_800 / 42.195, accuracy: 0.001)
        XCTAssertEqual((race.goalPace ?? 0) / 60, 4.266, accuracy: 0.01)
    }

    func testResultVersusGoalIsSignedTowardsSlower() {
        let race = Race(date: today)
        race.goalDuration = 3 * 3600
        race.resultDuration = 3 * 3600 - 120
        XCTAssertEqual(race.resultVersusGoal ?? 0, -120, accuracy: 0.001,
                       "faster than goal is negative")
        race.resultDuration = 3 * 3600 + 300
        XCTAssertEqual(race.resultVersusGoal ?? 0, 300, accuracy: 0.001)
    }

    func testRaceSurvivesAFetch() throws {
        let context = try makeContext()
        let race = Race(name: "Berlin Marathon", date: day(90), sport: .run, priority: .a)
        race.distance = 42_195
        race.goalDuration = 3 * 3600
        race.notes = "Flat, fast, crowded"
        context.insert(race)
        try context.save()

        let fetched = try XCTUnwrap(try context.fetch(FetchDescriptor<Race>()).first)
        XCTAssertEqual(fetched.name, "Berlin Marathon")
        XCTAssertEqual(fetched.priority, .a)
        XCTAssertEqual(fetched.sport, .run)
        XCTAssertEqual(fetched.distance ?? 0, 42_195, accuracy: 0.001)
        XCTAssertEqual(fetched.snapshot.name, "Berlin Marathon")
    }
}

// MARK: - Backup

@MainActor
final class RaceArchiveTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    func testRaceSurvivesAnExportAndRestore() throws {
        let source = try makeContext()
        let race = Race(name: "Berlin", date: Date(timeIntervalSince1970: 1_700_000_000),
                        sport: .run, priority: .a)
        race.distance = 42_195
        race.goalDuration = 3 * 3600
        race.notes = "Flat"
        race.resultDuration = 3 * 3600 + 180
        race.resultNotes = "Went out too hard"
        source.insert(race)
        try source.save()

        let restored = try makeContext()
        let report = try DataArchive.restore(
            try DataArchive.read(try DataArchive.exportData(from: source)), into: restored)
        try restored.save()

        XCTAssertEqual(report.races, 1)
        let copy = try XCTUnwrap(try restored.fetch(FetchDescriptor<Race>()).first)
        XCTAssertEqual(copy.name, "Berlin")
        XCTAssertEqual(copy.priority, .a)
        XCTAssertEqual(copy.sport, .run)
        XCTAssertEqual(copy.distance ?? 0, 42_195, accuracy: 0.001)
        XCTAssertEqual(copy.goalDuration ?? 0, 10_800, accuracy: 0.001)
        XCTAssertEqual(copy.resultVersusGoal ?? 0, 180, accuracy: 0.001)
        XCTAssertEqual(copy.resultNotes, "Went out too hard")
        XCTAssertTrue(copy.isComplete)
    }

    func testRestoringTwiceDoesNotDuplicateRaces() throws {
        let source = try makeContext()
        source.insert(Race(name: "Berlin", date: .now))
        try source.save()
        let data = try DataArchive.exportData(from: source)

        let restored = try makeContext()
        _ = try DataArchive.restore(try DataArchive.read(data), into: restored)
        try restored.save()
        let second = try DataArchive.restore(try DataArchive.read(data), into: restored)
        try restored.save()

        XCTAssertEqual(second.races, 0)
        XCTAssertEqual(try restored.fetch(FetchDescriptor<Race>()).count, 1)
    }
}

// MARK: - The verdict has to look at fitness, not only at form

/// Form is fitness minus fatigue, so reading it alone can't tell "sharp" from
/// "detrained" — an athlete who has done nothing for three months has no
/// fatigue to subtract and a lovely positive balance. The Simulator showed
/// exactly that: "Sharp, form +8" with a fitness of 8, down from 70.
final class TaperVerdictFitnessTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)
    private let today = Date(timeIntervalSince1970: 1_700_000_000)

    private func day(_ offset: Int) -> Date {
        calendar.startOfDay(for: today.addingTimeInterval(Double(offset) * 86_400))
    }

    func testDetrainedIsNotSharpEvenWithIdealForm() {
        // Same +8 balance, two very different athletes.
        XCTAssertEqual(
            SeasonPlan.verdict(form: 8, fitness: 65, startingFitness: 70), .sharp)
        XCTAssertEqual(
            SeasonPlan.verdict(form: 8, fitness: 8, startingFitness: 70), .detrained)
        XCTAssertFalse(SeasonPlan.verdict(form: 8, fitness: 8, startingFitness: 70).isGood)
    }

    /// A normal taper costs a little fitness and must still read as a taper.
    func testAModestFitnessLossIsStillATaper() {
        XCTAssertEqual(
            SeasonPlan.verdict(form: 15, fitness: 64, startingFitness: 70), .sharp,
            "9% off is what a two-week taper costs")
        XCTAssertEqual(
            SeasonPlan.verdict(form: 15, fitness: 59.5, startingFitness: 70), .sharp,
            "exactly at the floor is still a taper")
        XCTAssertEqual(
            SeasonPlan.verdict(form: 15, fitness: 55, startingFitness: 70), .detrained)
    }

    /// Detraining outranks the balance whichever side of the window it lands on.
    func testDetrainingOutranksEveryFormBand() {
        for form in [-30.0, -5, 10, 40] {
            XCTAssertEqual(
                SeasonPlan.verdict(form: form, fitness: 5, startingFitness: 70),
                .detrained, "form \(form) with no fitness left")
        }
    }

    /// With no baseline the verdict has to fall back to the balance rather than
    /// calling everyone detrained.
    func testNoBaselineFallsBackToReadingTheBalance() {
        XCTAssertEqual(SeasonPlan.verdict(form: 15, fitness: 0, startingFitness: 0), .sharp)
        XCTAssertEqual(SeasonPlan.verdict(form: -20), .carryingFatigue)
    }

    /// End to end: three months of an empty calendar is detraining, not a taper.
    func testEmptyCalendarToADistantRaceReadsAsDetraining() {
        let history = [TrainingLoad.Point(date: day(0), load: 0,
                                          fitness: 70, fatigue: 62)]
        let projection = SeasonPlan.project(history: history, plans: [],
                                            through: day(91), calendar: calendar)

        XCTAssertEqual(projection.verdict(), .detrained)
        XCTAssertLessThan(projection.fitnessRetained ?? 1, 0.3)
    }

    /// And a real block of training to the same race does not.
    func testATrainingBlockToTheSameRaceReadsAsATaper() {
        let history = [TrainingLoad.Point(date: day(0), load: 0,
                                          fitness: 70, fatigue: 70)]
        // Steady work, then two easier weeks.
        let plans = (1...77).map { plannedDay($0, load: 72) }
            + (78...91).map { plannedDay($0, load: 30) }
        let projection = SeasonPlan.project(history: history, plans: plans,
                                            through: day(91), calendar: calendar)

        XCTAssertNotEqual(projection.verdict(), .detrained,
                          "retained \(projection.fitnessRetained ?? -1)")
        XCTAssertGreaterThan(projection.fitnessRetained ?? 0, 0.85)
        XCTAssertGreaterThan(projection.arrival?.form ?? -99, 0)
    }

    func testFitnessRetainedNeedsABaseline() {
        let projection = SeasonPlan.project(history: [], plans: [],
                                            through: day(10), calendar: calendar)
        XCTAssertNil(projection.fitnessRetained)
    }

    private func plannedDay(_ offset: Int, load: Double) -> PlannedWorkoutSnapshot {
        PlannedWorkoutSnapshot(
            id: UUID(), scheduledFor: day(offset), sport: .run, title: "Session",
            targetDuration: nil, targetDistance: nil, estimatedLoad: load,
            completedWorkoutID: nil, skippedAt: nil, order: 0)
    }
}
