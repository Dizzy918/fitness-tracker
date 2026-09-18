import Foundation
import SwiftData

/// Assembles the athlete constants that training-load scoring needs.
///
/// These live in three different places — user settings, HealthKit's resting
/// heart rate, and the app's own best efforts — and every screen that scores
/// load needs the same combination. Building it in one place keeps the Dashboard
/// and Recovery tabs from disagreeing about how hard a week was.
enum AthleteProfile {

    /// Defaults key names, shared so a typo can't silently read zero.
    enum Key {
        static let maxHeartRate = "maxHeartRate"
        static let restingHeartRate = "restingHeartRate"
        /// Lactate-threshold heart rate, estimated or entered.
        static let thresholdHeartRate = "thresholdHeartRate"
        static let ftpWatts = "ftpWatts"
        static let bodyWeightKg = "bodyWeightKg"
    }

    /// Build from stored settings, falling back to what the data implies.
    ///
    /// - Parameters:
    ///   - workouts: used for the max-HR fallback and to derive threshold pace.
    ///   - restingHR: most recent measured resting HR, if any.
    static func make(
        workouts: [WorkoutSnapshot],
        restingHR: Double? = nil,
        defaults: UserDefaults = .standard
    ) -> TrainingLoad.Athlete {
        let storedMax = defaults.integer(forKey: Key.maxHeartRate)
        let maxHR: Int? = storedMax >= 100
            ? storedMax
            : workouts.compactMap(\.maxHeartRate).max().flatMap { $0 >= 100 ? $0 : nil }

        let storedResting = defaults.integer(forKey: Key.restingHeartRate)
        let resting: Int? = storedResting > 0
            ? storedResting
            : restingHR.map { Int($0.rounded()) }

        let ftp = defaults.integer(forKey: Key.ftpWatts)

        return TrainingLoad.Athlete(
            ftp: ftp,
            maxHR: maxHR,
            restingHR: resting,
            thresholdPaceSecPerKm: thresholdPace(from: workouts)
        )
    }

    /// Threshold pace from the athlete's own best efforts, so pace-based scoring
    /// is calibrated to them rather than to a generic table.
    ///
    /// Scanning every stream would be far too expensive to run on each render,
    /// so this uses recorded averages: the fastest average pace over a run of at
    /// least 5 km is a serviceable threshold proxy, and pace scoring is only
    /// ever the fourth-choice method anyway.
    static func thresholdPace(from workouts: [WorkoutSnapshot]) -> Double? {
        let candidates = workouts
            .filter { $0.isFootSport && $0.distance >= 5_000 && $0.duration > 0 }
            .map { $0.duration / ($0.distance / 1000) }
        guard let fastest = candidates.min() else { return nil }
        // A 5–10 km race pace runs a little quicker than true threshold.
        return fastest * 1.03
    }
}

/// A computed view of the athlete's current training state.
///
/// Built off the main actor (it decodes sample streams) and handed to the UI as
/// one immutable value, so a view never recomputes the same curve three times
/// while laying itself out.
struct TrainingState: Sendable {
    var series: [TrainingLoad.Point] = []
    var today: TrainingLoad.Point?
    var weeklyRamp: Double?
    /// How the most recent sessions were scored, worst first — drives the
    /// "these numbers are estimates" caveat.
    var weakestRecentMethod: TrainingLoad.Method?
    /// Sessions in the last 7 days that had no measured intensity at all.
    var estimatedSessionCount = 0

    var fitness: Double { today?.fitness ?? 0 }
    var fatigue: Double { today?.fatigue ?? 0 }
    var form: Double { today?.form ?? 0 }
    var acuteChronicRatio: Double? { today?.acuteChronicRatio }

    var verdict: TrainingLoad.FormVerdict {
        today.map(TrainingLoad.verdict) ?? .neutral
    }

    /// True once there's enough history for the 42-day fitness average to mean
    /// something. Below this the curves are still warming up.
    var isEstablished: Bool { series.count >= 21 }

    static func build(
        workouts: [WorkoutSnapshot],
        strength: [StrengthSessionSnapshot],
        athlete: TrainingLoad.Athlete,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> TrainingState {
        let totals = TrainingLoad.dailyTotals(
            workouts: workouts, strength: strength, athlete: athlete, calendar: calendar
        )
        let series = TrainingLoad.series(dailyTotals: totals, through: now, calendar: calendar)

        var state = TrainingState()
        state.series = series
        state.today = series.last
        state.weeklyRamp = TrainingLoad.weeklyRamp(series)

        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let recent = workouts.filter { $0.startedAt >= weekAgo }
        let methods = recent.compactMap { TrainingLoad.score(for: $0, athlete: athlete)?.method }
        state.weakestRecentMethod = methods.min()
        state.estimatedSessionCount = methods.filter { !$0.isMeasured }.count
        return state
    }
}
