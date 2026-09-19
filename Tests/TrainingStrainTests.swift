import XCTest
@testable import FitnessTracker

/// Monotony and strain.
///
/// The measurement lives or dies on whether rest days are counted. A week of
/// two hard sessions has a *low* monotony precisely because five of its days
/// were zero; drop those and it looks like the most undifferentiated week of
/// the year. Several of these tests exist only to pin that down.
final class TrainingStrainTests: XCTestCase {

    private let monday = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

    // MARK: - The arithmetic

    func testSevenIdenticalDaysAreMaximallyMonotonous() {
        let week = TrainingStrain.week(start: monday, loads: Array(repeating: 60, count: 7))

        XCTAssertEqual(week.total, 420)
        XCTAssertEqual(week.monotony, 10)         // capped rather than infinite
        XCTAssertEqual(week.restDays, 0)
        XCTAssertEqual(week.verdict, .undifferentiated)
    }

    func testTwoHardDaysAndFiveRestDaysAreNotMonotonous() {
        let week = TrainingStrain.week(start: monday, loads: [210, 0, 0, 210, 0, 0, 0])

        XCTAssertEqual(week.total, 420)           // same total as the week above
        XCTAssertLessThan(week.monotony, TrainingStrain.monotonyFlag)
        XCTAssertEqual(week.restDays, 5)
        XCTAssertEqual(week.verdict, .varied)
    }

    func testTheSameTotalCanScoreVeryDifferentStrain() {
        let flat = TrainingStrain.week(start: monday, loads: Array(repeating: 60, count: 7))
        let shaped = TrainingStrain.week(start: monday, loads: [210, 0, 0, 210, 0, 0, 0])

        XCTAssertEqual(flat.total, shaped.total)
        XCTAssertGreaterThan(flat.strain, shaped.strain * 5)
    }

    func testAnEmptyWeekScoresZeroRatherThanDividingByZero() {
        let week = TrainingStrain.week(start: monday, loads: Array(repeating: 0, count: 7))

        XCTAssertEqual(week.total, 0)
        XCTAssertEqual(week.monotony, 0)
        XCTAssertEqual(week.strain, 0)
        XCTAssertEqual(week.restDays, 7)
        XCTAssertEqual(week.verdict, .tooLittleToJudge)
    }

    func testAVeryLightWeekIsNotJudged() {
        // Below the floor the spread is arithmetically fine and practically
        // meaningless: three easy jogs is not a monotony problem.
        let week = TrainingStrain.week(start: monday, loads: [20, 20, 20, 0, 0, 0, 0])

        XCTAssertEqual(week.verdict, .tooLittleToJudge)
    }

    func testStrainIsTotalTimesMonotony() {
        let week = TrainingStrain.week(start: monday, loads: [100, 50, 80, 0, 120, 30, 60])

        XCTAssertEqual(week.strain, week.total * week.monotony, accuracy: 0.0001)
    }

    func testMonotonyUsesThePopulationDeviation() {
        // mean 60; population variance of [120,0,120,0,120,0,60] is 21600/7 =
        // 3085.7, deviation 55.55, so monotony ≈ 1.080. The sample deviation
        // would be 59.9 and give 1.001 — a visibly different answer, which is
        // why the choice is pinned here.
        let week = TrainingStrain.week(start: monday, loads: [120, 0, 120, 0, 120, 0, 60])

        XCTAssertEqual(week.monotony, 1.080, accuracy: 0.01)
    }

    // MARK: - Rolling the window

    func testRestDaysMissingFromTheDictionaryStillCount() {
        // Only two days appear in the totals at all. If the absent five were
        // dropped instead of read as zero, the week would look like two
        // identical days and score as undifferentiated.
        let calendar = Calendar.current
        let end = monday
        let totals: [Date: Double] = [
            calendar.date(byAdding: .day, value: -6, to: end)!: 210,
            calendar.date(byAdding: .day, value: -3, to: end)!: 210,
        ]

        let weeks = TrainingStrain.weeks(dailyTotals: totals, through: end, count: 1)
        let week = try! XCTUnwrap(weeks.first)

        XCTAssertEqual(week.total, 420)
        XCTAssertEqual(week.restDays, 5)
        XCTAssertEqual(week.verdict, .varied)
    }

    func testTheRequestedNumberOfWeeksComesBackOldestFirst() {
        let weeks = TrainingStrain.weeks(dailyTotals: [:], through: monday, count: 6)

        XCTAssertEqual(weeks.count, 6)
        XCTAssertEqual(weeks, weeks.sorted { $0.start < $1.start })
    }

    func testTheLastWindowEndsOnTheRequestedDay() {
        let calendar = Calendar.current
        let totals = [monday: 300.0]

        let weeks = TrainingStrain.weeks(dailyTotals: totals, through: monday, count: 2)
        let latest = try! XCTUnwrap(weeks.last)

        XCTAssertEqual(latest.total, 300)
        XCTAssertEqual(calendar.dateComponents([.day], from: latest.start, to: monday).day, 6)
    }

    func testWindowsDoNotOverlap() {
        let calendar = Calendar.current
        let weeks = TrainingStrain.weeks(dailyTotals: [:], through: monday, count: 4)

        for (earlier, later) in zip(weeks, weeks.dropFirst()) {
            let gap = calendar.dateComponents([.day], from: earlier.start, to: later.start).day
            XCTAssertEqual(gap, TrainingStrain.windowDays)
        }
    }

    func testAskingForNoWeeksReturnsNothing() {
        XCTAssertTrue(TrainingStrain.weeks(dailyTotals: [:], through: monday, count: 0).isEmpty)
    }
}
