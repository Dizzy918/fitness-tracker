import Foundation

/// Runs the fitness/fatigue model forwards over the planned weeks.
///
/// The load curves were retrospective: they told you what shape you're in
/// today, which is only half of what an athlete with a race date wants to
/// know. The recurrence doesn't care which direction it runs in — given the
/// load you *intend* to do, it projects the same fitness and fatigue forward,
/// and answers the question that actually matters: given this plan, what shape
/// will I be in on the day?
///
/// It is a projection, not a prediction. It assumes the plan gets done and that
/// unplanned days are rest, and it says so rather than presenting a number as
/// if it were measured.
enum SeasonPlan {

    /// Race-day form, and what it means.
    ///
    /// Thresholds follow the conventional reading of TSB — roughly +5 to +25 is
    /// the window people race well in — but TSB alone is not enough to judge a
    /// taper, and reading it alone is a trap this originally fell into.
    ///
    /// Form is a *difference*, fitness minus fatigue. An athlete who has done
    /// nothing for three months has no fatigue at all, so their form is
    /// beautifully positive and they have no engine. "Sharp" and "detrained"
    /// are indistinguishable from the balance and obvious from the fitness, so
    /// the fitness has to be part of the answer.
    enum TaperVerdict: String, Sendable {
        case carryingFatigue
        case slightlyFatigued
        case sharp
        case overTapered
        case detrained

        var label: String {
            switch self {
            case .carryingFatigue:  return String(localized: "Carrying fatigue")
            case .slightlyFatigued: return String(localized: "Slightly heavy")
            case .sharp:            return String(localized: "Sharp")
            case .overTapered:      return String(localized: "Over-tapered")
            case .detrained:        return String(localized: "Losing fitness")
            }
        }

        var detail: String {
            switch self {
            case .carryingFatigue:
                return String(localized: "On this plan you arrive tired. Cutting volume over the last two weeks — while keeping some intensity — sheds fatigue much faster than it sheds fitness.")
            case .slightlyFatigued:
                return String(localized: "Close, but you arrive with a little fatigue still in the legs. An easier final week would sharpen it.")
            case .sharp:
                return String(localized: "This is the window people race well from: the fatigue has cleared and the fitness is still there.")
            case .overTapered:
                return String(localized: "Fresh, but this much rest costs fitness as well as fatigue. Keeping a couple of short, sharp sessions in the last week holds more of it.")
            case .detrained:
                return String(localized: "This plan arrives rested but a long way down on fitness. Form looks healthy because there's no fatigue left to subtract — that isn't the same as being sharp. There's room for a lot more work between now and then.")
            }
        }

        var isGood: Bool { self == .sharp }
    }

    /// How much of today's fitness a plan may shed before the verdict stops
    /// calling it a taper and starts calling it detraining.
    ///
    /// A two-week taper normally costs 5–10% of CTL. Losing more than 15% over
    /// the whole run-in isn't sharpening.
    static let fitnessRetentionFloor = 0.85

    /// - Parameters:
    ///   - fitness: projected fitness on the day.
    ///   - startingFitness: fitness today, to judge what the plan costs. Pass
    ///     zero (or nothing) when there's no baseline to compare against, and
    ///     the verdict falls back to reading the balance alone.
    static func verdict(form: Double, fitness: Double = 0,
                        startingFitness: Double = 0) -> TaperVerdict {
        if startingFitness > 0, fitness < startingFitness * fitnessRetentionFloor {
            return .detrained
        }
        switch form {
        case ..<(-10): return .carryingFatigue
        case ..<5:     return .slightlyFatigued
        case ...25:    return .sharp
        default:       return .overTapered
        }
    }

    /// The result of running the model forward.
    struct Projection: Sendable, Equatable {
        /// Projected days only — today is the last actual point, not the first
        /// projected one, so a chart can join the two without a duplicate.
        let points: [TrainingLoad.Point]
        /// The last actual point the projection continues from.
        let from: TrainingLoad.Point?
        /// How many of the projected days have a planned session.
        let plannedDays: Int
        /// How many are assumed to be rest because nothing is planned.
        let unplannedDays: Int

        var arrival: TrainingLoad.Point? { points.last }

        /// True when the projection is mostly assumption rather than plan.
        ///
        /// Worth saying out loud: with an empty calendar the projection is
        /// nothing but decay, and "you'll be over-tapered" is then a statement
        /// about the empty calendar, not about the athlete.
        var isMostlyAssumed: Bool {
            let total = plannedDays + unplannedDays
            guard total > 0 else { return true }
            return Double(plannedDays) / Double(total) < 0.25
        }

        func verdict() -> TaperVerdict? {
            guard let arrival else { return nil }
            return SeasonPlan.verdict(form: arrival.form,
                                      fitness: arrival.fitness,
                                      startingFitness: from?.fitness ?? 0)
        }

        /// Fitness kept, as a fraction of today's. Nil with no baseline.
        var fitnessRetained: Double? {
            guard let from, from.fitness > 0, let arrival else { return nil }
            return arrival.fitness / from.fitness
        }
    }

    /// Continue the fitness/fatigue recurrence from `history` over `plans`.
    ///
    /// - Parameters:
    ///   - history: the actual series, oldest first. Its last point is the
    ///     starting state.
    ///   - plans: planned sessions. Outstanding ones only — a plan already
    ///     completed is in `history` as a real workout, and counting it in both
    ///     places would double its load.
    ///   - through: the last day to project, typically race day.
    static func project(
        history: [TrainingLoad.Point],
        plans: [PlannedWorkoutSnapshot],
        through end: Date,
        calendar: Calendar = .current
    ) -> Projection {
        guard let last = history.last else {
            return Projection(points: [], from: nil, plannedDays: 0, unplannedDays: 0)
        }
        let endDay = calendar.startOfDay(for: end)
        guard let firstProjected = calendar.date(byAdding: .day, value: 1, to: last.date),
              firstProjected <= endDay
        else {
            return Projection(points: [], from: last, plannedDays: 0, unplannedDays: 0)
        }

        // Planned load per day. Two sessions on one day sum, as they do in the
        // retrospective totals.
        var plannedLoad: [Date: Double] = [:]
        for plan in plans where plan.isOutstanding {
            guard let load = plan.estimatedLoad, load > 0 else { continue }
            plannedLoad[calendar.startOfDay(for: plan.scheduledFor), default: 0] += load
        }

        let fitnessDecay = exp(-1 / TrainingLoad.fitnessTimeConstant)
        let fatigueDecay = exp(-1 / TrainingLoad.fatigueTimeConstant)

        var points: [TrainingLoad.Point] = []
        var fitness = last.fitness
        var fatigue = last.fatigue
        var planned = 0
        var unplanned = 0
        var day = firstProjected

        while day <= endDay {
            let load = plannedLoad[day] ?? 0
            if load > 0 { planned += 1 } else { unplanned += 1 }
            fitness = fitness * fitnessDecay + load * (1 - fitnessDecay)
            fatigue = fatigue * fatigueDecay + load * (1 - fatigueDecay)
            points.append(TrainingLoad.Point(date: day, load: load,
                                             fitness: fitness, fatigue: fatigue))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        return Projection(points: points, from: last,
                          plannedDays: planned, unplannedDays: unplanned)
    }

    // MARK: - Picking the race to talk about

    /// The race the dashboard should lead with.
    ///
    /// The nearest upcoming A race, or the nearest upcoming race of any
    /// priority if there's no A. A C race isn't worth a countdown on its own,
    /// but showing nothing when it's the only thing on the calendar is worse.
    static func focus(among races: [RaceSnapshot], from today: Date = .now,
                      calendar: Calendar = .current) -> RaceSnapshot? {
        let upcoming = races
            .filter { !$0.isComplete }
            .filter { calendar.startOfDay(for: $0.date) >= calendar.startOfDay(for: today) }
            .sorted { $0.date < $1.date }
        return upcoming.first { $0.priority == .a } ?? upcoming.first
    }

    /// Races grouped into what's ahead and what's behind, each in the order
    /// you'd want to read them: soonest first, most recent first.
    static func split(_ races: [RaceSnapshot], from today: Date = .now,
                      calendar: Calendar = .current)
    -> (upcoming: [RaceSnapshot], past: [RaceSnapshot]) {
        let todayStart = calendar.startOfDay(for: today)
        var upcoming: [RaceSnapshot] = []
        var past: [RaceSnapshot] = []
        for race in races {
            // A race that's been and gone belongs in the past whether or not a
            // result was ever filled in.
            if race.isComplete || calendar.startOfDay(for: race.date) < todayStart {
                past.append(race)
            } else {
                upcoming.append(race)
            }
        }
        return (upcoming.sorted { $0.date < $1.date },
                past.sorted { $0.date > $1.date })
    }

    // MARK: - Weekly shape

    /// Planned load per week between now and the race, for a bar chart of the
    /// block.
    ///
    /// Weeks start on the calendar's own first weekday, so an athlete whose
    /// week starts on Sunday doesn't see their long run land in the wrong bar.
    struct Week: Sendable, Identifiable, Equatable {
        let start: Date
        let load: Double
        let sessions: Int
        /// Whether this week falls inside the taper.
        let isTaper: Bool

        var id: Date { start }
    }

    static func weeks(
        plans: [PlannedWorkoutSnapshot],
        until raceDate: Date,
        taperStart: Date?,
        from today: Date = .now,
        calendar: Calendar = .current
    ) -> [Week] {
        let todayStart = calendar.startOfDay(for: today)
        let raceDay = calendar.startOfDay(for: raceDate)
        guard todayStart <= raceDay else { return [] }

        var totals: [Date: (load: Double, sessions: Int)] = [:]
        for plan in plans where plan.isOutstanding {
            let day = calendar.startOfDay(for: plan.scheduledFor)
            guard day >= todayStart, day <= raceDay,
                  let week = calendar.dateInterval(of: .weekOfYear, for: day)?.start
            else { continue }
            let load = plan.estimatedLoad ?? 0
            let existing = totals[week] ?? (0, 0)
            totals[week] = (existing.load + load, existing.sessions + 1)
        }

        // Emit every week in the range, including empty ones — a gap in the
        // plan is the thing you most want to see.
        guard var week = calendar.dateInterval(of: .weekOfYear, for: todayStart)?.start
        else { return [] }

        var out: [Week] = []
        while week <= raceDay {
            let entry = totals[week] ?? (0, 0)
            let isTaper = taperStart.map { week >= calendar.startOfDay(for: $0) } ?? false
            out.append(Week(start: week, load: entry.load,
                            sessions: entry.sessions, isTaper: isTaper))
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: week)
            else { break }
            week = next
        }
        return out
    }
}
