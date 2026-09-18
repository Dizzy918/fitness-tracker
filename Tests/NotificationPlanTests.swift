import XCTest
@testable import FitnessTracker

/// What gets scheduled, and when.
///
/// The API call is never what goes wrong with notifications. What goes wrong is
/// reminding someone about a session they've already done, or firing at 7am
/// tomorrow when it's 8am today, or queueing forty at once — all decisions, and
/// all tested here rather than against the system.
final class NotificationPlanTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
        return calendar
    }()

    /// 2023-11-14, 08:00 local — deliberately *after* the 07:00 reminder time,
    /// so "today" is the interesting case rather than an easy one.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2023, month: 11, day: 14,
                                           hour: 8, minute: 0))!
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset,
                      to: calendar.startOfDay(for: now))!
    }

    private func plan(_ offset: Int, title: String = "Easy run",
                      load: Double? = 60, distance: Double? = nil,
                      duration: TimeInterval? = nil,
                      completed: Bool = false, skipped: Bool = false,
                      order: Int = 0) -> PlannedWorkoutSnapshot {
        PlannedWorkoutSnapshot(
            id: UUID(), scheduledFor: day(offset), sport: .run, title: title,
            targetDuration: duration, targetDistance: distance,
            estimatedLoad: load,
            completedWorkoutID: completed ? UUID() : nil,
            skippedAt: skipped ? day(offset) : nil, order: order)
    }

    private func race(_ offset: Int, name: String = "Berlin",
                      priority: Race.Priority = .a,
                      complete: Bool = false) -> RaceSnapshot {
        RaceSnapshot(id: UUID(), name: name, date: day(offset), sport: .run,
                     priority: priority, distance: nil, goalDuration: nil,
                     isComplete: complete)
    }

    private var allOn: NotificationPlan.Settings {
        NotificationPlan.Settings(sessionReminders: true, checkInReminders: true,
                                  raceCountdown: true)
    }

    // MARK: - Nothing on, nothing scheduled

    func testEverythingOffSchedulesNothing() {
        let requests = NotificationPlan.requests(
            plans: [plan(1)], races: [race(10)],
            settings: NotificationPlan.Settings(),
            from: now, calendar: calendar)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(NotificationPlan.Settings().isAnyEnabled)
    }

    func testEachToggleOnlyProducesItsOwnKind() {
        var settings = NotificationPlan.Settings()
        settings.sessionReminders = true
        let sessions = NotificationPlan.requests(
            plans: [plan(1)], races: [race(10)], settings: settings,
            from: now, calendar: calendar)
        XCTAssertEqual(Set(sessions.map(\.kind)), [.session])

        settings = NotificationPlan.Settings()
        settings.raceCountdown = true
        let races = NotificationPlan.requests(
            plans: [plan(1)], races: [race(10)], settings: settings,
            from: now, calendar: calendar)
        XCTAssertEqual(Set(races.map(\.kind)), [.race])

        settings = NotificationPlan.Settings()
        settings.checkInReminders = true
        let checkIns = NotificationPlan.requests(
            plans: [plan(1)], races: [race(10)], settings: settings,
            from: now, calendar: calendar)
        XCTAssertEqual(Set(checkIns.map(\.kind)), [.checkIn])
    }

    // MARK: - Sessions

    /// The whole point: no reminder for something already done.
    func testCompletedAndSkippedSessionsGetNoReminder() {
        var settings = NotificationPlan.Settings(); settings.sessionReminders = true
        let requests = NotificationPlan.requests(
            plans: [plan(1, completed: true), plan(2, skipped: true), plan(3)],
            races: [], settings: settings, from: now, calendar: calendar)

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.fireAt, fireTime(onDay: 3, minute: 7 * 60))
    }

    /// It's 08:00 and the reminder time is 07:00, so today's has gone. Firing
    /// it now would be a reminder about something already overdue.
    func testTodaysReminderIsSkippedOnceItsTimeHasPassed() {
        var settings = NotificationPlan.Settings(); settings.sessionReminders = true
        let requests = NotificationPlan.requests(
            plans: [plan(0), plan(1)], races: [], settings: settings,
            from: now, calendar: calendar)

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.fireAt, fireTime(onDay: 1, minute: 7 * 60))
    }

    /// And it is scheduled when the time is still ahead.
    func testTodaysReminderIsKeptWhenItsTimeIsStillAhead() {
        var settings = NotificationPlan.Settings(); settings.sessionReminders = true
        settings.sessionReminderMinute = 18 * 60
        let requests = NotificationPlan.requests(
            plans: [plan(0)], races: [], settings: settings,
            from: now, calendar: calendar)

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.fireAt, fireTime(onDay: 0, minute: 18 * 60))
    }

    func testPastSessionsAreIgnored() {
        var settings = NotificationPlan.Settings(); settings.sessionReminders = true
        let requests = NotificationPlan.requests(
            plans: [plan(-1), plan(-30)], races: [], settings: settings,
            from: now, calendar: calendar)
        XCTAssertTrue(requests.isEmpty)
    }

    func testSessionsBeyondTheHorizonAreNotScheduled() {
        var settings = NotificationPlan.Settings(); settings.sessionReminders = true
        let requests = NotificationPlan.requests(
            plans: [plan(NotificationPlan.sessionHorizonDays + 5)],
            races: [], settings: settings, from: now, calendar: calendar)
        XCTAssertTrue(requests.isEmpty)
    }

    /// A double day is one notification naming both, not two notifications.
    func testTwoSessionsOnADayShareOneReminder() {
        var settings = NotificationPlan.Settings(); settings.sessionReminders = true
        let requests = NotificationPlan.requests(
            plans: [plan(2, title: "Swim", order: 1), plan(2, title: "Tempo", order: 0)],
            races: [], settings: settings, from: now, calendar: calendar)

        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.title, "2 sessions today")
        XCTAssertEqual(request.body, "Tempo · Swim", "named in performance order")
    }

    func testSingleSessionNamesTheSessionAndItsShape() {
        var settings = NotificationPlan.Settings(); settings.sessionReminders = true
        let withDistance = NotificationPlan.requests(
            plans: [plan(1, title: "Long run", distance: 21_000)],
            races: [], settings: settings, from: now, calendar: calendar)
        XCTAssertEqual(withDistance.first?.title, "Today: Long run")
        XCTAssertEqual(withDistance.first?.body, "Run · 21.0 km")

        let withDuration = NotificationPlan.requests(
            plans: [plan(1, title: "Recovery", duration: 45 * 60)],
            races: [], settings: settings, from: now, calendar: calendar)
        XCTAssertEqual(withDuration.first?.body, "Run · 45 min")
    }

    /// Ids have to be stable, or rescheduling delivers the same reminder twice.
    func testSessionIdsAreStableAcrossReschedules() {
        var settings = NotificationPlan.Settings(); settings.sessionReminders = true
        let first = NotificationPlan.requests(plans: [plan(3)], races: [],
                                              settings: settings, from: now,
                                              calendar: calendar)
        let laterSameDay = NotificationPlan.requests(
            plans: [plan(3)], races: [], settings: settings,
            from: now.addingTimeInterval(3600), calendar: calendar)
        XCTAssertEqual(first.map(\.id), laterSameDay.map(\.id))
    }

    // MARK: - Races

    func testRaceMilestonesAreSparseAndInsideTheWindow() {
        var settings = NotificationPlan.Settings(); settings.raceCountdown = true
        let requests = NotificationPlan.requests(
            plans: [], races: [race(30)], settings: settings,
            from: now, calendar: calendar)

        // 30 days out, so the 28-day milestone and everything nearer.
        XCTAssertEqual(requests.count, NotificationPlan.raceMilestones.count)
        XCTAssertEqual(requests.map(\.kind), Array(repeating: .race, count: requests.count))
        XCTAssertEqual(requests.first?.fireAt, fireTime(onDay: 2, minute: 7 * 60),
                       "the 28-day nudge lands two days from now")
    }

    func testMilestonesAlreadyPassedAreDropped() {
        var settings = NotificationPlan.Settings(); settings.raceCountdown = true
        let requests = NotificationPlan.requests(
            plans: [], races: [race(5)], settings: settings,
            from: now, calendar: calendar)
        // 5 days out: only 3, 1 and 0 remain.
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.fireAt > now })
    }

    func testPastAndCompletedRacesAreIgnored() {
        var settings = NotificationPlan.Settings(); settings.raceCountdown = true
        let requests = NotificationPlan.requests(
            plans: [], races: [race(-5), race(10, complete: true)],
            settings: settings, from: now, calendar: calendar)
        XCTAssertTrue(requests.isEmpty)
    }

    func testRaceDayTitleAndBodyReadRight() {
        var settings = NotificationPlan.Settings(); settings.raceCountdown = true
        // Two days out, so the 1-day nudge lands tomorrow morning rather than
        // at 07:00 today, which has already gone.
        let requests = NotificationPlan.requests(
            plans: [], races: [race(2, name: "Berlin")], settings: settings,
            from: now, calendar: calendar)

        XCTAssertEqual(requests.map(\.title),
                       ["Berlin in 1 day", "Berlin — today"])
        XCTAssertEqual(requests.last?.body, "Good luck.")
        XCTAssertEqual(requests.first?.fireAt, fireTime(onDay: 1, minute: 7 * 60))
    }

    /// A race tomorrow, past this morning's reminder time, gets only the
    /// race-day nudge — firing "in 1 day" at 07:00 today is in the past.
    func testMilestoneLandingEarlierTodayIsDropped() {
        var settings = NotificationPlan.Settings(); settings.raceCountdown = true
        let requests = NotificationPlan.requests(
            plans: [], races: [race(1, name: "Berlin")], settings: settings,
            from: now, calendar: calendar)
        XCTAssertEqual(requests.map(\.title), ["Berlin — today"])
    }

    /// A C race is trained through, so its week-out advice must not tell
    /// someone to taper for it.
    func testCRaceAdviceDoesNotSayTaper() {
        var settings = NotificationPlan.Settings(); settings.raceCountdown = true
        // Eight days out, so the seven-day milestone fires tomorrow.
        func weekOut(_ priority: Race.Priority) -> String {
            NotificationPlan.requests(
                plans: [], races: [race(8, priority: priority)], settings: settings,
                from: now, calendar: calendar)
                .first { $0.title.contains("in 7 days") }?.body ?? "missing"
        }

        XCTAssertTrue(weekOut(.c).contains("Train through"), "got \(weekOut(.c))")
        XCTAssertFalse(weekOut(.a).contains("Train through"))
        XCTAssertTrue(weekOut(.a).contains("Volume down"), "got \(weekOut(.a))")
    }

    func testRaceIdsAreUniquePerRaceAndMilestone() {
        var settings = NotificationPlan.Settings(); settings.raceCountdown = true
        let requests = NotificationPlan.requests(
            plans: [], races: [race(20, name: "A"), race(25, name: "B")],
            settings: settings, from: now, calendar: calendar)
        XCTAssertEqual(Set(requests.map(\.id)).count, requests.count)
    }

    // MARK: - Check-in

    /// Dated, not repeating: a repeating trigger keeps its original time when
    /// the athlete changes the setting.
    func testCheckInIsARollingWeekOfDatedReminders() {
        var settings = NotificationPlan.Settings(); settings.checkInReminders = true
        let requests = NotificationPlan.requests(
            plans: [], races: [], settings: settings, from: now, calendar: calendar)

        XCTAssertEqual(requests.count, 8, "today plus a week")
        XCTAssertEqual(requests.first?.fireAt, fireTime(onDay: 0, minute: 20 * 60))
        XCTAssertTrue(requests.allSatisfy { $0.fireAt > now })
        XCTAssertEqual(Set(requests.map(\.id)).count, requests.count)
    }

    func testCheckInRespectsAChangedTime() {
        var settings = NotificationPlan.Settings(); settings.checkInReminders = true
        settings.checkInMinute = 6 * 60   // already past today
        let requests = NotificationPlan.requests(
            plans: [], races: [], settings: settings, from: now, calendar: calendar)

        XCTAssertEqual(requests.count, 7, "today's 06:00 has gone")
        XCTAssertEqual(requests.first?.fireAt, fireTime(onDay: 1, minute: 6 * 60))
    }

    // MARK: - The budget

    /// iOS drops pending notifications past 64, so the cap has to cost the
    /// most distant reminder rather than tomorrow's.
    func testBudgetIsRespectedAndSpentOnTheNearestReminders() {
        let plans = (1...NotificationPlan.sessionHorizonDays).map { plan($0) }
        let races = (1...6).map { race($0 * 10, name: "Race \($0)") }
        let requests = NotificationPlan.requests(
            plans: plans, races: races, settings: allOn,
            from: now, calendar: calendar)

        XCTAssertLessThanOrEqual(requests.count, NotificationPlan.maximumPending)
        XCTAssertEqual(requests, requests.sorted { $0.fireAt < $1.fireAt },
                       "soonest first")
        // The very next reminder survives the cap.
        XCTAssertEqual(requests.first?.fireAt, fireTime(onDay: 0, minute: 20 * 60))
    }

    func testEverythingScheduledIsInTheFuture() {
        let plans = (-10...20).map { plan($0) }
        let requests = NotificationPlan.requests(
            plans: plans, races: [race(-3), race(3)], settings: allOn,
            from: now, calendar: calendar)
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.allSatisfy { $0.fireAt > now })
    }

    func testIdsAreUniqueAcrossKinds() {
        let plans = (1...5).map { plan($0) }
        let requests = NotificationPlan.requests(
            plans: plans, races: [race(7)], settings: allOn,
            from: now, calendar: calendar)
        XCTAssertEqual(Set(requests.map(\.id)).count, requests.count)
    }

    /// Every id this plan produces must be recognised as ours, or stale
    /// reminders are never cleaned up.
    func testEveryScheduledIdIsRecognisedByTheScheduler() {
        let plans = (1...5).map { plan($0) }
        let requests = NotificationPlan.requests(
            plans: plans, races: [race(7)], settings: allOn,
            from: now, calendar: calendar)
        for request in requests {
            XCTAssertTrue(NotificationScheduler.isOurs(request.id),
                          "\(request.id) wouldn't be cleaned up")
        }
        XCTAssertFalse(NotificationScheduler.isOurs("something-else"))
    }

    func testTimeLabelFormatting() {
        XCTAssertEqual(NotificationPlan.timeLabel(7 * 60), "07:00")
        XCTAssertEqual(NotificationPlan.timeLabel(20 * 60 + 30), "20:30")
        XCTAssertEqual(NotificationPlan.timeLabel(0), "00:00")
    }

    // MARK: - Helper

    private func fireTime(onDay offset: Int, minute: Int) -> Date {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0,
                      of: day(offset))!
    }
}
