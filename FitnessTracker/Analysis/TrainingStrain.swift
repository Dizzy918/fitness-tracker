import Foundation

/// Monotony and strain: how *samey* a week was, and what that made it cost.
///
/// Fitness and fatigue answer how much work you did. They can't tell apart two
/// weeks with the same total — 400 load spread evenly over seven days, and 400
/// load as two hard days and five off — and the difference between those two
/// weeks is most of what a coach would say about them.
///
/// Foster's monotony is the week's mean daily load over its standard deviation,
/// counting rest days as zero. A week with real hard days and real rest days
/// has a large spread and a low monotony; a week of identical middling sessions
/// has almost no spread and a high one. Strain multiplies the week's total by
/// its monotony, so a big *and* undifferentiated week scores far worse than
/// either alone.
///
/// **This is a flag, not a diagnosis.** Foster's thresholds come from a small
/// observational study of athletes whose illnesses clustered after spikes in
/// these numbers. It notices the pattern that gets people into trouble — every
/// day the same, no easy days, no days off — and it cannot see sleep, work,
/// or anything else that decides whether that pattern actually hurts you.
enum TrainingStrain {

    /// Foster's window. Monotony over anything other than seven days isn't
    /// Foster's monotony, and the thresholds below wouldn't apply.
    static let windowDays = 7

    /// Above this the week had no meaningful hard/easy separation. Foster's
    /// original cut-off, and the number every later paper quotes.
    static let monotonyFlag = 2.0

    struct Week: Sendable, Equatable, Identifiable {
        /// Start of the seven-day window.
        let start: Date
        /// Sum of daily load across the window, rest days included as zero.
        let total: Double
        /// Mean daily load over its standard deviation.
        let monotony: Double
        /// total × monotony.
        let strain: Double
        /// How many of the seven days had no load at all.
        let restDays: Int

        var id: Date { start }

        var verdict: Verdict {
            if total < 100 { return .tooLittleToJudge }
            return monotony >= monotonyFlag ? .undifferentiated : .varied
        }
    }

    enum Verdict: Sendable, Equatable {
        case tooLittleToJudge
        case varied
        case undifferentiated

        var title: String {
            switch self {
            case .tooLittleToJudge: return String(localized: "Quiet week")
            case .varied:           return String(localized: "Hard days and easy days")
            case .undifferentiated: return String(localized: "Every day the same")
            }
        }

        var detail: String {
            switch self {
            case .tooLittleToJudge:
                return String(localized: "Not enough training in the week for the spread to mean anything.")
            case .varied:
                return String(localized: "The week has a shape: the hard days are clearly harder than the easy ones, which is the pattern adaptation comes from.")
            case .undifferentiated:
                return String(localized: "Every day looks like every other day. The easy days aren't easy enough to recover from, and the hard days aren't hard enough to drive anything — the combination is what Foster found clustering before people got ill.")
            }
        }
    }

    /// Roll a seven-day window across the daily totals.
    ///
    /// - Parameters:
    ///   - dailyTotals: load per day, from `TrainingLoad.dailyTotals`. Days
    ///     missing from the dictionary are rest days and count as zero, which
    ///     is the whole point — dropping them would make a week of two sessions
    ///     look perfectly varied.
    ///   - through: last day to report, inclusive.
    ///   - weeks: how many windows to return, most recent last.
    static func weeks(
        dailyTotals: [Date: Double],
        through end: Date = .now,
        count weeks: Int = 12,
        calendar: Calendar = .current
    ) -> [Week] {
        guard weeks > 0 else { return [] }
        let lastDay = calendar.startOfDay(for: end)

        return (0..<weeks).reversed().compactMap { weeksBack -> Week? in
            guard let windowEnd = calendar.date(byAdding: .day,
                                                value: -weeksBack * windowDays,
                                                to: lastDay),
                  let windowStart = calendar.date(byAdding: .day,
                                                  value: -(windowDays - 1),
                                                  to: windowEnd)
            else { return nil }

            let loads: [Double] = (0..<windowDays).compactMap { offset in
                calendar.date(byAdding: .day, value: offset, to: windowStart)
                    .map { dailyTotals[calendar.startOfDay(for: $0)] ?? 0 }
            }
            guard loads.count == windowDays else { return nil }
            return week(start: windowStart, loads: loads)
        }
    }

    /// The arithmetic for one window, exposed so it can be tested directly.
    static func week(start: Date, loads: [Double]) -> Week {
        let total = loads.reduce(0, +)
        let mean = total / Double(loads.count)

        // Population standard deviation, not the sample one: these seven days
        // are the whole week, not a sample drawn from it.
        let variance = loads.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(loads.count)
        let deviation = variance.squareRoot()

        // A week of seven identical days has no spread at all, and the ratio
        // diverges. Reporting it as infinity would poison every chart, so it
        // is capped at the point where the verdict is already "the same every
        // day" and more precision says nothing.
        let monotony = deviation > 0.01 ? min(mean / deviation, 10) : (total > 0 ? 10 : 0)

        return Week(
            start: start,
            total: total,
            monotony: monotony,
            strain: total * monotony,
            restDays: loads.filter { $0 <= 0 }.count
        )
    }
}
