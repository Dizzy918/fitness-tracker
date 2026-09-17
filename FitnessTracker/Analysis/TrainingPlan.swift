import Foundation

/// Comparing what you planned with what you did.
///
/// The matching is the whole problem. A plan says "Tuesday, intervals"; the
/// watch produces a run on Tuesday. Nothing links them, and asking the athlete
/// to tick things off by hand is a chore they'll abandon by week two — so the
/// pairing is inferred, conservatively, and always visible and overridable.
enum TrainingPlan {

    /// One planned session and whatever fulfilled it.
    struct Entry: Sendable, Identifiable {
        let planned: PlannedWorkoutSnapshot
        let actual: WorkoutSnapshot?
        /// Stress the actual session cost, when it's been scored.
        let actualLoad: Double?

        var id: UUID { planned.id }
        var isCompleted: Bool { actual != nil }

        /// Done against intended, as a fraction. Nil when either side has no
        /// load to compare — a pair of dashes is more honest than 0%.
        var loadRatio: Double? {
            guard let target = planned.estimatedLoad, target > 0,
                  let actualLoad else { return nil }
            return actualLoad / target
        }
    }

    /// A week of plan against a week of training.
    struct Week: Sendable {
        let start: Date
        var entries: [Entry] = []
        /// Sessions done in the week that no plan called for.
        var unplanned: [WorkoutSnapshot] = []
        var unplannedLoad: Double = 0

        var plannedLoad: Double {
            entries.compactMap { $0.planned.estimatedLoad }.reduce(0, +)
        }

        /// Everything actually done in the week, planned or not.
        var completedLoad: Double {
            entries.compactMap(\.actualLoad).reduce(0, +) + unplannedLoad
        }

        var completedCount: Int { entries.filter(\.isCompleted).count }
        var skippedCount: Int { entries.filter(\.planned.isSkipped).count }
        /// Still to do: neither matched to a session nor deliberately skipped.
        ///
        /// Judged on the *match*, not on the plan's own stored flag. Matching is
        /// inferred at read time rather than written back, so a plan you have
        /// already fulfilled still has `completedWorkoutID == nil` — counting
        /// that as outstanding would have the Dashboard nagging all week about
        /// sessions you did on Monday.
        var outstandingCount: Int {
            entries.filter { !$0.isCompleted && !$0.planned.isSkipped }.count
        }

        var isEmpty: Bool { entries.isEmpty && unplanned.isEmpty }

        /// Progress against the week's intent, counting unplanned work — it
        /// still happened and still cost something.
        var completionFraction: Double? {
            let target = plannedLoad
            guard target > 0 else { return nil }
            return completedLoad / target
        }

        var summary: String {
            guard !entries.isEmpty else {
                return unplanned.isEmpty ? "Nothing planned." : "\(unplanned.count) unplanned."
            }
            var parts = ["\(completedCount) of \(entries.count) done"]
            if skippedCount > 0 { parts.append("\(skippedCount) skipped") }
            if !unplanned.isEmpty { parts.append("\(unplanned.count) unplanned") }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// Pair planned sessions with the workouts that fulfilled them.
    ///
    /// Rules, in order:
    /// 1. An explicit link the athlete made always wins.
    /// 2. Otherwise a plan takes the same-day workout of the same sport.
    /// 3. Failing that, the same-day workout of *any* sport — a plan for a run
    ///    that became a ride is still that day's session, and calling it both a
    ///    miss and an extra would double-count the week.
    ///
    /// Never crosses a day boundary. Tuesday's plan is not satisfied by
    /// Thursday's run, and a plan that quietly absorbs any nearby session tells
    /// you nothing about whether you followed it.
    static func match(
        planned: [PlannedWorkoutSnapshot],
        workouts: [WorkoutSnapshot],
        calendar: Calendar = .current
    ) -> (entries: [Entry], unmatched: [WorkoutSnapshot]) {
        var available = workouts
        var claimed = Set<UUID>()
        var entries: [Entry] = []

        let ordered = planned.sorted {
            ($0.scheduledFor, $0.order) < ($1.scheduledFor, $1.order)
        }

        // Explicit links first, so an inferred match can never steal a workout
        // the athlete already assigned.
        var resolved: [UUID: WorkoutSnapshot] = [:]
        for plan in ordered {
            guard let id = plan.completedWorkoutID,
                  let workout = available.first(where: { $0.id == id })
            else { continue }
            resolved[plan.id] = workout
            claimed.insert(workout.id)
        }

        for plan in ordered {
            if let workout = resolved[plan.id] {
                entries.append(Entry(planned: plan, actual: workout, actualLoad: nil))
                continue
            }
            // A skipped plan doesn't reach for a workout; the athlete said so.
            guard !plan.isSkipped else {
                entries.append(Entry(planned: plan, actual: nil, actualLoad: nil))
                continue
            }

            let sameDay = available.filter {
                !claimed.contains($0.id)
                    && calendar.isDate($0.startedAt, inSameDayAs: plan.scheduledFor)
            }
            let match = sameDay.first { $0.sport == plan.sport } ?? sameDay.first
            if let match { claimed.insert(match.id) }
            entries.append(Entry(planned: plan, actual: match, actualLoad: nil))
        }

        available.removeAll { claimed.contains($0.id) }
        return (entries, available)
    }

    /// Build a week, scoring each side on the same load scale.
    static func week(
        containing date: Date,
        planned: [PlannedWorkoutSnapshot],
        workouts: [WorkoutSnapshot],
        athlete: TrainingLoad.Athlete,
        calendar: Calendar = .current
    ) -> Week {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return Week(start: calendar.startOfDay(for: date))
        }
        let inWeek = { (moment: Date) in interval.contains(moment) }

        let plannedThisWeek = planned.filter { inWeek($0.scheduledFor) }
        let workoutsThisWeek = workouts.filter { inWeek($0.startedAt) }

        let (paired, unmatched) = match(planned: plannedThisWeek,
                                        workouts: workoutsThisWeek,
                                        calendar: calendar)

        // Score once here rather than inside `match`, which stays pure geometry.
        let scored = paired.map { entry in
            Entry(planned: entry.planned,
                  actual: entry.actual,
                  actualLoad: entry.actual.flatMap {
                      TrainingLoad.score(for: $0, athlete: athlete)?.value
                  })
        }

        var week = Week(start: interval.start)
        week.entries = scored
        week.unplanned = unmatched
        week.unplannedLoad = unmatched.compactMap {
            TrainingLoad.score(for: $0, athlete: athlete)?.value
        }.reduce(0, +)
        return week
    }

    /// How a week's intended load compares with recent fitness.
    ///
    /// Planning a week far above what you've been doing is the classic way to
    /// get hurt, and it's exactly the mistake a plan makes easy to commit —
    /// which is why the app should say so while it's still a plan.
    enum RampVerdict: String, Sendable {
        case light, sustainable, ambitious, reckless

        var label: String {
            switch self {
            case .light:       return "Easy week"
            case .sustainable: return "Sustainable"
            case .ambitious:   return "Ambitious"
            case .reckless:    return "Too much, too soon"
            }
        }

        var guidance: String {
            switch self {
            case .light:
                return "Well below your recent average. Fine for a taper or a recovery week."
            case .sustainable:
                return "In line with what you've been doing."
            case .ambitious:
                return "A real step up. Workable if you're fresh and it isn't the third one in a row."
            case .reckless:
                return "Far above your recent load. This is the shape of week that ends in an injury."
            }
        }
    }

    /// Compare a week's planned load with the recent weekly average.
    ///
    /// Returns nil until there's enough history to compare against — declaring
    /// a first week "reckless" because it's above a baseline of zero would be
    /// both useless and quickly ignored.
    static func ramp(plannedLoad: Double, recentWeeklyLoad: Double) -> RampVerdict? {
        guard recentWeeklyLoad > 20, plannedLoad > 0 else { return nil }
        switch plannedLoad / recentWeeklyLoad {
        case ..<0.7:     return .light
        case 0.7..<1.15: return .sustainable
        case 1.15..<1.4: return .ambitious
        default:         return .reckless
        }
    }

    /// Average weekly load over the trailing weeks, for the ramp comparison.
    ///
    /// Weeks with no training at all are excluded: an injury lay-off shouldn't
    /// make a return to normal training read as reckless.
    static func recentWeeklyLoad(
        workouts: [WorkoutSnapshot],
        athlete: TrainingLoad.Athlete,
        before date: Date = .now,
        weeks: Int = 4,
        calendar: Calendar = .current
    ) -> Double {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: date) else { return 0 }

        var totals: [Double] = []
        for offset in 1...weeks {
            guard let start = calendar.date(byAdding: .weekOfYear, value: -offset,
                                            to: thisWeek.start),
                  let interval = calendar.dateInterval(of: .weekOfYear, for: start)
            else { continue }
            let total = workouts
                .filter { interval.contains($0.startedAt) }
                .compactMap { TrainingLoad.score(for: $0, athlete: athlete)?.value }
                .reduce(0, +)
            if total > 0 { totals.append(total) }
        }
        guard !totals.isEmpty else { return 0 }
        return totals.reduce(0, +) / Double(totals.count)
    }
}
