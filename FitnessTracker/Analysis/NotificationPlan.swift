import Foundation

/// What to remind the athlete about, and when.
///
/// Deliberately a pure function over the plan, the calendar and the
/// preferences. The part of notifications that goes wrong is never the API
/// call — it's scheduling a reminder for a session that's already done, or for
/// 6am tomorrow when it's 8am today, or forty of them at once. Those are
/// decisions, and decisions can be tested; talking to
/// `UNUserNotificationCenter` can't.
enum NotificationPlan {

    struct Settings: Equatable, Sendable {
        var sessionReminders = false
        /// Minutes after midnight, local time.
        var sessionReminderMinute = 7 * 60
        var checkInReminders = false
        var checkInMinute = 20 * 60
        var raceCountdown = false

        /// Nothing enabled means nothing to schedule, and nothing to ask
        /// permission for.
        var isAnyEnabled: Bool {
            sessionReminders || checkInReminders || raceCountdown
        }
    }

    enum Kind: String, Sendable {
        case session, checkIn, race
    }

    struct Request: Equatable, Sendable, Identifiable {
        /// Stable across reschedules, so replacing yesterday's set doesn't
        /// deliver a duplicate.
        let id: String
        let kind: Kind
        let fireAt: Date
        let title: String
        let body: String
    }

    /// iOS keeps at most 64 pending local notifications per app, and silently
    /// drops the rest. Staying well under it leaves room for the ones that
    /// matter rather than filling the budget with distant countdowns.
    static let maximumPending = 48

    /// Days out from a race worth a nudge.
    ///
    /// Sparse on purpose. A daily countdown is noise; these are the points
    /// where an athlete actually changes what they're doing.
    static let raceMilestones = [28, 14, 7, 3, 1, 0]

    /// How far ahead session reminders are scheduled.
    static let sessionHorizonDays = 21

    static func requests(
        plans: [PlannedWorkoutSnapshot],
        races: [RaceSnapshot],
        settings: Settings,
        from now: Date = .now,
        calendar: Calendar = .current
    ) -> [Request] {
        guard settings.isAnyEnabled else { return [] }

        var out: [Request] = []
        if settings.sessionReminders {
            out += sessionRequests(plans: plans, settings: settings,
                                   from: now, calendar: calendar)
        }
        if settings.raceCountdown {
            out += raceRequests(races: races, settings: settings,
                                from: now, calendar: calendar)
        }
        if settings.checkInReminders {
            out += checkInRequests(settings: settings, from: now, calendar: calendar)
        }

        // Soonest first, then truncate: if the budget runs out it should cost
        // the most distant reminder, not tomorrow's.
        return Array(out.sorted { $0.fireAt < $1.fireAt }.prefix(maximumPending))
    }

    // MARK: - Sessions

    private static func sessionRequests(
        plans: [PlannedWorkoutSnapshot],
        settings: Settings,
        from now: Date,
        calendar: Calendar
    ) -> [Request] {
        let horizon = calendar.date(byAdding: .day, value: sessionHorizonDays,
                                    to: now) ?? now

        // One reminder per day, not per session: two notifications for a double
        // day is one too many, and the body can name both.
        var byDay: [Date: [PlannedWorkoutSnapshot]] = [:]
        for plan in plans where plan.isOutstanding {
            let day = calendar.startOfDay(for: plan.scheduledFor)
            guard day <= calendar.startOfDay(for: horizon) else { continue }
            byDay[day, default: []].append(plan)
        }

        return byDay.compactMap { day, sessions in
            guard let fireAt = time(settings.sessionReminderMinute, on: day,
                                    calendar: calendar),
                  fireAt > now
            else { return nil }

            let ordered = sessions.sorted { $0.order < $1.order }
            let names = ordered.map(\.title).joined(separator: " · ")
            return Request(
                id: "session-\(calendar.startOfDay(for: day).timeIntervalSince1970)",
                kind: .session,
                fireAt: fireAt,
                title: ordered.count > 1
                    ? "\(ordered.count) sessions today"
                    : "Today: \(ordered[0].title)",
                body: ordered.count > 1 ? names : bodyDetail(for: ordered[0]))
        }
    }

    private static func bodyDetail(for plan: PlannedWorkoutSnapshot) -> String {
        var parts: [String] = [plan.sport.displayName]
        if let distance = plan.targetDistance, distance > 0 {
            parts.append(String(format: "%.1f km", distance / 1000))
        } else if let duration = plan.targetDuration, duration > 0 {
            parts.append("\(Int((duration / 60).rounded())) min")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Races

    private static func raceRequests(
        races: [RaceSnapshot],
        settings: Settings,
        from now: Date,
        calendar: Calendar
    ) -> [Request] {
        let today = calendar.startOfDay(for: now)

        return races
            .filter { !$0.isComplete }
            .flatMap { race -> [Request] in
                let raceDay = calendar.startOfDay(for: race.date)
                guard raceDay >= today else { return [] }

                return raceMilestones.compactMap { daysOut in
                    guard let day = calendar.date(byAdding: .day, value: -daysOut,
                                                  to: raceDay),
                          day >= today,
                          let fireAt = time(settings.sessionReminderMinute, on: day,
                                            calendar: calendar),
                          fireAt > now
                    else { return nil }

                    return Request(
                        id: "race-\(race.id.uuidString)-\(daysOut)",
                        kind: .race,
                        fireAt: fireAt,
                        title: daysOut == 0
                            ? "\(race.name) — today"
                            : "\(race.name) in \(daysOut) \(daysOut == 1 ? "day" : "days")",
                        body: milestoneBody(daysOut: daysOut, race: race))
                }
            }
    }

    private static func milestoneBody(daysOut: Int, race: RaceSnapshot) -> String {
        switch daysOut {
        case 0:  return "Good luck."
        case 1:  return "Nothing left to gain from training. Eat, sleep, and stay off your feet."
        case 3:  return "Sharpening week. Short and fast beats long and slow from here."
        case 7:  return race.priority == .c
            ? "Train through this one — it's a hard session with a number on your chest."
            : "A week out. Volume down, intensity kept, and trust the work that's already done."
        case 14: return race.priority == .a
            ? "Taper starts now. Cut the volume, keep some intensity."
            : "Two weeks out."
        default: return "Four weeks out — the last block that will actually change your fitness."
        }
    }

    // MARK: - Check-in

    /// A rolling week of evening nudges.
    ///
    /// Not a repeating trigger: the athlete can change the time, and a
    /// repeating notification keeps its original time until it's removed. A
    /// week of dated ones, refreshed on launch, can't drift.
    private static func checkInRequests(
        settings: Settings,
        from now: Date,
        calendar: Calendar
    ) -> [Request] {
        (0...7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset,
                                          to: calendar.startOfDay(for: now)),
                  let fireAt = time(settings.checkInMinute, on: day, calendar: calendar),
                  fireAt > now
            else { return nil }

            return Request(
                id: "checkin-\(calendar.startOfDay(for: day).timeIntervalSince1970)",
                kind: .checkIn,
                fireAt: fireAt,
                title: "How did today feel?",
                body: "Sleep, soreness, mood and motivation — thirty seconds, and tomorrow's readiness is worth reading.")
        }
    }

    // MARK: - Helpers

    private static func time(_ minuteOfDay: Int, on day: Date,
                             calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: minuteOfDay / 60,
                      minute: minuteOfDay % 60,
                      second: 0,
                      of: calendar.startOfDay(for: day))
    }

    /// "07:00", for a settings row.
    static func timeLabel(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }
}
