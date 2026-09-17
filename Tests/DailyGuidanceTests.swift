import XCTest
@testable import FitnessTracker

/// What today's training should probably look like.
///
/// This is advice, which makes the failure modes different from the rest of the
/// app: being wrong is bad, but being *confidently* wrong on partial evidence,
/// or nagging about things that aren't actually a problem, is what gets a
/// feature like this ignored. Both are tested for.
final class DailyGuidanceTests: XCTestCase {

    private let today = Calendar.current.startOfDay(for: .now)

    private func readiness(_ score: Int, reliable: Bool = true) -> Readiness.Result {
        Readiness.Result(
            score: score, band: Readiness.band(for: score),
            contributions: [], confidence: reliable ? 0.9 : 0.2, missing: [])
    }

    private func form(fitness: Double, fatigue: Double) -> TrainingLoad.Point {
        TrainingLoad.Point(date: today, load: 0, fitness: fitness, fatigue: fatigue)
    }

    private func plan(_ title: String, load: Double?) -> PlannedWorkoutSnapshot {
        let model = PlannedWorkout(scheduledFor: today, sport: .run, title: title)
        model.targetLoad = load
        return model.snapshot
    }

    /// Fatigue well above fitness — the overreaching read.
    private var overreached: TrainingLoad.Point { form(fitness: 60, fatigue: 85) }
    /// Balanced.
    private var neutral: TrainingLoad.Point { form(fitness: 60, fatigue: 60) }
    /// Rested.
    private var fresh: TrainingLoad.Point { form(fitness: 60, fatigue: 40) }

    // MARK: - Already trained

    /// Nothing else matters once the session is in the bag, and advising a rest
    /// day after a hard morning would read as broken.
    func testAlreadyTrainedShortCircuitsEverything() {
        var input = DailyGuidance.Input()
        input.trainedToday = true
        input.readiness = readiness(20)
        input.form = overreached

        let advice = DailyGuidance.advise(input)
        XCTAssertEqual(advice.recommendation, .done)
        XCTAssertFalse(advice.isPartial)
    }

    // MARK: - Not enough information

    /// Silence beats invention. A brand-new install has nothing to reason from.
    func testNoInputsGivesNoAdvice() {
        let advice = DailyGuidance.advise(DailyGuidance.Input())
        XCTAssertEqual(advice.recommendation, .unknown)
        XCTAssertTrue(advice.isPartial)
    }

    /// A readiness score below its own confidence floor is not evidence, and
    /// must be ignored rather than used.
    func testUnreliableReadinessIsNotTreatedAsEvidence() {
        var input = DailyGuidance.Input()
        input.readiness = readiness(20, reliable: false)

        let advice = DailyGuidance.advise(input)
        XCTAssertEqual(advice.recommendation, .unknown,
                       "an unreliable score must not drive a rest recommendation")
    }

    /// One signal is enough to say something, but the UI has to know it's
    /// working from half the picture.
    func testASingleSignalGivesPartialAdvice() {
        var input = DailyGuidance.Input()
        input.readiness = readiness(85)

        let advice = DailyGuidance.advise(input)
        XCTAssertNotEqual(advice.recommendation, .unknown)
        XCTAssertTrue(advice.isPartial)
    }

    func testBothSignalsGiveCompleteAdvice() {
        var input = DailyGuidance.Input()
        input.readiness = readiness(85)
        input.form = fresh

        XCTAssertFalse(DailyGuidance.advise(input).isPartial)
    }

    // MARK: - Rest

    /// Both signals agreeing you're depleted is the only case that argues for a
    /// day off outright.
    func testBothSignalsDepletedRecommendsRest() {
        var input = DailyGuidance.Input()
        input.readiness = readiness(35)
        input.form = overreached

        let advice = DailyGuidance.advise(input)
        XCTAssertEqual(advice.recommendation, .rest)
        XCTAssertTrue(advice.headline.lowercased().contains("rest"))
    }

    func testRestWordingChangesWhenSomethingIsPlanned() {
        var input = DailyGuidance.Input()
        input.readiness = readiness(35)
        input.form = overreached
        input.outstandingToday = [plan("Intervals", load: 100)]

        let advice = DailyGuidance.advise(input)
        XCTAssertEqual(advice.recommendation, .rest)
        XCTAssertTrue(advice.headline.contains("moving"),
                      "there's a session to move, so say that rather than \"rest day\"")
    }

    // MARK: - Go easier

    func testLowReadinessAloneWithAHardSessionSuggestsEasing() {
        var input = DailyGuidance.Input()
        input.readiness = readiness(40)
        input.form = neutral
        input.typicalSessionLoad = 50
        input.outstandingToday = [plan("8 × 400 m", load: 100)]

        let advice = DailyGuidance.advise(input)
        XCTAssertEqual(advice.recommendation, .easier)
    }

    /// Overreaching with an *easy* session planned is not a problem — the easy
    /// session is the right answer, and telling someone to back off it is noise.
    func testAnEasyPlannedSessionIsLeftAloneEvenWhenTired() {
        var input = DailyGuidance.Input()
        input.readiness = readiness(45)
        input.form = overreached
        input.typicalSessionLoad = 60
        input.outstandingToday = [plan("Recovery jog", load: 25)]

        let advice = DailyGuidance.advise(input)
        XCTAssertEqual(advice.recommendation, .proceed)
        XCTAssertTrue(advice.headline.lowercased().contains("easy"))
    }

    /// The same depleted day with a *hard* session still argues for moving it.
    func testAHardPlannedSessionOnADepletedDayIsStillMoved() {
        var input = DailyGuidance.Input()
        input.readiness = readiness(45)
        input.form = overreached
        input.typicalSessionLoad = 60
        input.outstandingToday = [plan("8 × 400 m", load: 120)]

        XCTAssertEqual(DailyGuidance.advise(input).recommendation, .rest)
    }

    /// Without a baseline the app can't tell a recovery jog from intervals, so
    /// it must not wave the session through on the one day it mattered.
    func testAnUnknownSessionOnADepletedDayIsNotWavedThrough() {
        var input = DailyGuidance.Input()
        input.readiness = readiness(35)
        input.form = overreached
        input.outstandingToday = [plan("Run", load: 30)]   // no baseline given

        XCTAssertEqual(DailyGuidance.advise(input).recommendation, .rest)
    }

    func testTiredWithNothingPlannedSuggestsKeepingItEasy() {
        var input = DailyGuidance.Input()
        input.readiness = readiness(42)
        input.form = neutral

        let advice = DailyGuidance.advise(input)
        XCTAssertEqual(advice.recommendation, .easier)
        XCTAssertTrue(advice.headline.contains("easy"))
    }

    // MARK: - Proceed and opportunity

    func testGoodMarkersWithAPlanJustConfirmIt() {
        var input = DailyGuidance.Input()
        input.readiness = readiness(82)
        input.form = neutral
        input.outstandingToday = [plan("Threshold 3×10", load: 90)]

        let advice = DailyGuidance.advise(input)
        XCTAssertEqual(advice.recommendation, .proceed)
        XCTAssertTrue(advice.headline.contains("Threshold 3×10"),
                      "name the session rather than saying something generic")
    }

    func testTwoPlannedSessionsAreCountedRatherThanNamed() {
        var input = DailyGuidance.Input()
        input.readiness = readiness(82)
        input.form = neutral
        input.outstandingToday = [plan("AM easy", load: 40), plan("PM intervals", load: 90)]

        XCTAssertTrue(DailyGuidance.advise(input).headline.contains("2 sessions"))
    }

    func testFreshWithNothingPlannedIsAnOpportunity() {
        var input = DailyGuidance.Input()
        input.readiness = readiness(88)
        input.form = fresh

        let advice = DailyGuidance.advise(input)
        XCTAssertEqual(advice.recommendation, .opportunity)
    }

    /// Merely-fine markers and an empty day shouldn't be talked up into a
    /// hard session.
    func testAverageMarkersWithNothingPlannedIsNotAnOpportunity() {
        var input = DailyGuidance.Input()
        input.readiness = readiness(65)
        input.form = neutral

        XCTAssertEqual(DailyGuidance.advise(input).recommendation, .proceed)
    }

    // MARK: - What counts as hard

    /// "Hard" has to mean hard *for this athlete*, not against a number picked
    /// out of the air.
    func testDemandingIsRelativeToTheAthletesOwnSessions() {
        let session = plan("Long run", load: 80)
        XCTAssertTrue(DailyGuidance.isDemanding(session, typical: 50))
        XCTAssertFalse(DailyGuidance.isDemanding(session, typical: 100))
    }

    /// Without a baseline there's nothing honest to compare against, and a false
    /// "that's a hard one" in someone's first week is noise they'd learn to
    /// ignore.
    func testNothingIsDemandingWithoutABaseline() {
        XCTAssertFalse(DailyGuidance.isDemanding(plan("Intervals", load: 200), typical: nil))
        XCTAssertFalse(DailyGuidance.isDemanding(plan("Intervals", load: 200), typical: 0))
    }

    func testAPlanWithNoTargetIsNeverDemanding() {
        XCTAssertFalse(DailyGuidance.isDemanding(plan("Run", load: nil), typical: 50))
    }

    // MARK: - The personal yardstick

    /// Median, not mean: one five-hour ride shouldn't redefine what a normal
    /// session looks like.
    func testTypicalLoadUsesTheMedianSoOneEpicDoesNotSkewIt() throws {
        let athlete = TrainingLoad.Athlete()
        func session(_ hours: Double) -> WorkoutSnapshot {
            WorkoutSnapshot(id: UUID(), sport: .run, startedAt: .now,
                            distance: 10_000, duration: hours * 3600)
        }
        // Four normal hours-long runs and one enormous one.
        let workouts = [session(1), session(1), session(1), session(1), session(8)]
        let typical = try XCTUnwrap(DailyGuidance.typicalSessionLoad(
            workouts: workouts, athlete: athlete,
            since: Date(timeIntervalSince1970: 0)))

        let oneHour = try XCTUnwrap(TrainingLoad.score(for: session(1), athlete: athlete)).value
        XCTAssertEqual(typical, oneHour, accuracy: 0.01,
                       "the eight-hour outlier must not move the median")
    }

    func testTypicalLoadNeedsAFewSessionsToMeanAnything() {
        let athlete = TrainingLoad.Athlete()
        let one = [WorkoutSnapshot(id: UUID(), sport: .run, startedAt: .now,
                                   distance: 10_000, duration: 3600)]
        XCTAssertNil(DailyGuidance.typicalSessionLoad(
            workouts: one, athlete: athlete, since: Date(timeIntervalSince1970: 0)))
    }

    func testTypicalLoadIgnoresSessionsOutsideTheWindow() {
        let athlete = TrainingLoad.Athlete()
        let old = (0..<5).map { _ in
            WorkoutSnapshot(id: UUID(), sport: .run,
                            startedAt: Date(timeIntervalSince1970: 0),
                            distance: 10_000, duration: 3600)
        }
        XCTAssertNil(DailyGuidance.typicalSessionLoad(
            workouts: old, athlete: athlete, since: .now))
    }

    // MARK: - Presentation

    func testEveryRecommendationHasALabelAndASymbol() {
        let all: [DailyGuidance.Recommendation] =
            [.done, .proceed, .easier, .rest, .opportunity, .unknown]
        for recommendation in all {
            XCTAssertFalse(recommendation.label.isEmpty)
            XCTAssertFalse(recommendation.symbolName.isEmpty)
        }
    }

    /// The numbers behind the call are always shown, so the advice can be
    /// argued with rather than just obeyed.
    func testReasonsQuoteTheActualNumbers() {
        var input = DailyGuidance.Input()
        input.readiness = readiness(43)
        input.form = overreached

        let advice = DailyGuidance.advise(input)
        XCTAssertTrue(advice.reasons.contains { $0.contains("43") })
        XCTAssertTrue(advice.reasons.contains { $0.contains("Form") })
    }
}
