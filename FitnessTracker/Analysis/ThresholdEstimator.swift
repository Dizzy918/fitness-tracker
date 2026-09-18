import Foundation

/// Derives the athlete's thresholds from their own recorded efforts.
///
/// FTP, max heart rate and lactate-threshold heart rate were all numbers the
/// user had to already know and type in. That's a real burden: the whole
/// training-load model rests on them, so an athlete who doesn't know their FTP
/// got duration-estimated load for every ride, and one who never set a max HR
/// got zones derived from a guess.
///
/// Every estimate here is a **convention applied to your own best efforts**, not
/// a lab measurement, and each carries the effort it came from so it can be
/// judged rather than trusted blindly.
enum ThresholdEstimator {

    /// FTP is conventionally 95% of the best 20-minute power.
    ///
    /// The number comes from Coggan's protocol — a 20-minute all-out test, take
    /// 95%. Applying it to a best effort pulled from ordinary training is a
    /// weaker claim than running the test: if your hardest 20 minutes this
    /// season was a hilly group ride rather than a maximal effort, this
    /// under-reads.
    static let ftpFractionOfTwentyMinutePower = 0.95

    /// The window both estimates are read over.
    static let testWindow: TimeInterval = 20 * 60

    /// A derived threshold and where it came from.
    struct Estimate: Sendable, Equatable {
        /// The threshold value, in its natural unit.
        let value: Int
        /// What the window actually averaged, before any convention was applied.
        let observed: Int
        let date: Date
        /// How long the effort the estimate was read from was.
        let windowSeconds: TimeInterval

        var windowMinutes: Int { Int(windowSeconds / 60) }
    }

    struct Result: Sendable, Equatable {
        var ftp: Estimate?
        var lactateThresholdHR: Estimate?
        var maxHeartRate: Estimate?

        var isEmpty: Bool {
            ftp == nil && lactateThresholdHR == nil && maxHeartRate == nil
        }
    }

    /// Estimate everything derivable from a set of workouts.
    ///
    /// Expensive — decodes every sample stream — so call it off the main actor.
    ///
    /// - Parameter since: only efforts after this count. Thresholds decay; a
    ///   personal best from three years ago is a memento, not a current FTP,
    ///   and training against it produces sessions you can't complete.
    static func estimate(from workouts: [WorkoutSnapshot], since: Date) -> Result {
        var result = Result()

        var bestPower: (value: Double, date: Date)?
        var bestHR: (value: Double, date: Date)?
        var peakHR: (value: Int, date: Date)?

        for workout in workouts where workout.startedAt >= since {
            let samples = workout.samples

            // Power: cycling only. A running power meter reports a different
            // quantity on a different scale, and folding the two together would
            // produce an FTP that means nothing for either.
            if workout.sport == .bike,
               let power = StreamStatistics.bestAveragePower(seconds: testWindow, in: samples),
               power > 0, power > (bestPower?.value ?? 0) {
                bestPower = (power, workout.startedAt)
            }

            if let hr = StreamStatistics.bestAverageHeartRate(seconds: testWindow, in: samples),
               hr > 0, hr > (bestHR?.value ?? 0) {
                bestHR = (hr, workout.startedAt)
            }

            // Max HR takes the recorded session maximum, which is what the
            // watch reports and is less noisy than a single stream spike.
            if let max = workout.maxHeartRate, max >= 100, max > (peakHR?.value ?? 0) {
                peakHR = (max, workout.startedAt)
            }
        }

        if let bestPower {
            result.ftp = Estimate(
                value: Int((bestPower.value * ftpFractionOfTwentyMinutePower).rounded()),
                observed: Int(bestPower.value.rounded()),
                date: bestPower.date, windowSeconds: testWindow)
        }
        if let bestHR {
            // Unlike power, no fraction is applied. The best 20 minutes of heart
            // rate an athlete can hold sits at or just above lactate threshold,
            // so the observed value *is* the estimate.
            result.lactateThresholdHR = Estimate(
                value: Int(bestHR.value.rounded()),
                observed: Int(bestHR.value.rounded()),
                date: bestHR.date, windowSeconds: testWindow)
        }
        if let peakHR {
            result.maxHeartRate = Estimate(
                value: peakHR.value, observed: peakHR.value,
                date: peakHR.date, windowSeconds: 0)
        }
        return result
    }

    /// How far back to look. A year covers a full season without letting a
    /// threshold from two seasons ago set today's training.
    static func defaultWindowStart(from now: Date = .now) -> Date {
        Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
    }

    /// Plain-language note about what an estimate rests on, for the UI to show
    /// next to the number.
    static func caveat(for kind: Kind) -> String {
        switch kind {
        case .ftp:
            return "95% of your best 20 minutes of power. That's the standard test protocol applied to ordinary training, so if your hardest 20 minutes wasn't an all-out effort this reads low."
        case .lactateThresholdHR:
            return "The best 20 minutes of heart rate you've held. That sits at or just above lactate threshold for most people — close enough to set zones from, not a lab result."
        case .maxHeartRate:
            return "The highest your watch has recorded. A true maximum only shows up in an all-out effort, so this reads low until you've done one."
        }
    }

    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case ftp, lactateThresholdHR, maxHeartRate
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .ftp:                return String(localized: "FTP")
            case .lactateThresholdHR: return String(localized: "Threshold HR")
            case .maxHeartRate:       return String(localized: "Max heart rate")
            }
        }

        var unit: String {
            switch self {
            case .ftp:  return "W"
            default:    return "bpm"
            }
        }
    }

    /// Pull one kind out of a result, so the UI can iterate.
    static func estimate(_ kind: Kind, in result: Result) -> Estimate? {
        switch kind {
        case .ftp:                return result.ftp
        case .lactateThresholdHR: return result.lactateThresholdHR
        case .maxHeartRate:       return result.maxHeartRate
        }
    }
}
