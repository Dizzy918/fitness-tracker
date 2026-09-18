import Foundation

/// What today's training should probably look like.
///
/// Every input for this already existed and none of them talked to each other:
/// readiness knew your markers were down, the fitness curve knew you were
/// carrying fatigue, and the plan knew today was intervals — but the athlete had
/// to hold all three in their head and do the reasoning. This does that
/// reasoning out loud.
///
/// **It is a suggestion, and it defers to how you actually feel.** The score
/// behind it is a heuristic over your own trends, not a measurement, and the
/// wording is chosen so it never reads as an instruction.
enum DailyGuidance {

    enum Recommendation: String, Sendable {
        /// Already trained today.
        case done
        /// Nothing here argues against the plan.
        case proceed
        /// Do it, but smaller — or swap it for the easy day later in the week.
        case easier
        /// The markers and the fatigue agree. Today is a rest day.
        case rest
        /// Fresh, and nothing scheduled. A good day to use.
        case opportunity
        /// Not enough information to say anything useful.
        case unknown

        var label: String {
            switch self {
            case .done:        return "Done for today"
            case .proceed:     return "Good to go"
            case .easier:      return "Go easier"
            case .rest:        return "Rest"
            case .opportunity: return "Free hit"
            case .unknown:     return "Not enough to go on"
            }
        }

        var symbolName: String {
            switch self {
            case .done:        return "checkmark.circle.fill"
            case .proceed:     return "checkmark.circle"
            case .easier:      return "arrow.down.circle"
            case .rest:        return "moon.zzz"
            case .opportunity: return "bolt.circle"
            case .unknown:     return "questionmark.circle"
            }
        }
    }

    struct Advice: Sendable {
        let recommendation: Recommendation
        /// One sentence saying what to do.
        let headline: String
        /// The reasons, in the athlete's own numbers. Empty when there are none
        /// worth stating.
        let reasons: [String]
        /// True when a missing input meant the call was made on partial
        /// evidence, so the UI can hedge honestly.
        let isPartial: Bool
    }

    /// Everything the call depends on, gathered by the caller.
    struct Input: Sendable {
        var readiness: Readiness.Result?
        var form: TrainingLoad.Point?
        /// Today's planned sessions that haven't been done or skipped.
        var outstandingToday: [PlannedWorkoutSnapshot] = []
        /// True when something was already logged today.
        var trainedToday = false
        /// Typical stress of a session for this athlete, for deciding whether
        /// what's planned counts as hard *for them* rather than against a
        /// number picked out of the air.
        var typicalSessionLoad: Double?
    }

    /// A planned session counts as demanding when it's well above this
    /// athlete's own normal session. 1.3× is deliberately generous — the point
    /// is to catch "intervals on a day you're wrecked", not to second-guess
    /// every slightly longer run.
    static let hardSessionMultiplier = 1.3

    /// Below this readiness the markers are saying something worth acting on.
    static let lowReadiness = 50
    /// Above this, and with form not deeply negative, there's no case for
    /// holding back.
    static let strongReadiness = 75

    static func advise(_ input: Input) -> Advice {
        if input.trainedToday {
            return Advice(recommendation: .done,
                          headline: "You've already logged a session today.",
                          reasons: [], isPartial: false)
        }

        let readiness = input.readiness.flatMap { $0.isReliable ? $0 : nil }
        let formVerdict = input.form.map(TrainingLoad.verdict)
        let hasAnything = readiness != nil || formVerdict != nil

        guard hasAnything else {
            return Advice(
                recommendation: .unknown,
                headline: "Not enough recorded yet to suggest anything.",
                reasons: ["A daily check-in, or a few weeks of training, gives this something to work from."],
                isPartial: true)
        }

        var reasons: [String] = []
        if let readiness {
            reasons.append("Readiness \(readiness.score) — \(readiness.band.label.lowercased()).")
        }
        if let point = input.form, let formVerdict {
            reasons.append("Form \(Fmt.signed(point.form)) — \(formVerdict.label.lowercased()).")
        }

        let planned = input.outstandingToday
        let demanding = planned.contains { isDemanding($0, typical: input.typicalSessionLoad) }
        // Only *known* easy: without a personal baseline we can't tell a
        // recovery jog from a threshold session, and guessing "easy" there
        // would wave through the one day it mattered.
        let knownEasy = !planned.isEmpty && input.typicalSessionLoad != nil && !demanding
        let isPartial = readiness == nil || formVerdict == nil

        // Both signals agreeing that you're depleted is the one case worth
        // actually arguing for a day off.
        let markersLow = (readiness?.score ?? 100) < lowReadiness
        let overreaching = formVerdict == .overreaching

        if markersLow && overreaching {
            // An easy session is not worth arguing against, even here. Active
            // recovery is a legitimate answer to fatigue, and telling someone to
            // skip a recovery jog is the kind of over-caution that gets the
            // whole card ignored.
            if knownEasy {
                return Advice(
                    recommendation: .proceed,
                    headline: "What's planned is easy, which is about right for how today looks.",
                    reasons: reasons, isPartial: isPartial)
            }
            return Advice(
                recommendation: .rest,
                headline: planned.isEmpty
                    ? "Everything points to a rest day."
                    : "Everything points to moving today's session.",
                reasons: reasons, isPartial: isPartial)
        }

        if markersLow || overreaching {
            if demanding {
                return Advice(
                    recommendation: .easier,
                    headline: "What's planned is a hard one — consider shortening it or swapping it with an easy day.",
                    reasons: reasons, isPartial: isPartial)
            }
            if knownEasy {
                return Advice(
                    recommendation: .proceed,
                    headline: "What's planned is already easy, so it should be fine.",
                    reasons: reasons, isPartial: isPartial)
            }
            return Advice(
                recommendation: .easier,
                headline: planned.isEmpty
                    ? "If you train today, keep it easy and short."
                    : "Worth keeping today shorter or easier than planned.",
                reasons: reasons, isPartial: isPartial)
        }

        let strong = (readiness?.score ?? 0) >= strongReadiness
        if planned.isEmpty {
            return Advice(
                recommendation: strong ? .opportunity : .proceed,
                headline: strong
                    ? "Nothing scheduled and you're in good shape — a good day to use for something hard."
                    : "Nothing scheduled. Train if you want to; nothing here argues against it.",
                reasons: reasons, isPartial: isPartial)
        }

        return Advice(
            recommendation: .proceed,
            headline: planned.count == 1
                ? "\(planned[0].title) as planned."
                : "\(planned.count) sessions planned — nothing here argues against them.",
            reasons: reasons, isPartial: isPartial)
    }

    /// Whether a planned session is demanding *for this athlete*.
    ///
    /// Without a personal baseline there's nothing honest to compare against, so
    /// this says no rather than guessing — a false "that's a hard one" on
    /// someone's first week would be noise they'd learn to ignore.
    static func isDemanding(_ plan: PlannedWorkoutSnapshot, typical: Double?) -> Bool {
        guard let typical, typical > 0, let load = plan.estimatedLoad else { return false }
        return load >= typical * hardSessionMultiplier
    }

    /// Median session load over recent training, as the personal yardstick.
    ///
    /// Median rather than mean: one five-hour ride shouldn't redefine what a
    /// normal session looks like.
    static func typicalSessionLoad(
        workouts: [WorkoutSnapshot],
        athlete: TrainingLoad.Athlete,
        since: Date
    ) -> Double? {
        let loads = workouts
            .filter { $0.startedAt >= since }
            .compactMap { TrainingLoad.score(for: $0, athlete: athlete)?.value }
            .filter { $0 > 0 }
            .sorted()
        guard loads.count >= 3 else { return nil }
        return loads.count.isMultiple(of: 2)
            ? (loads[loads.count / 2 - 1] + loads[loads.count / 2]) / 2
            : loads[loads.count / 2]
    }
}
