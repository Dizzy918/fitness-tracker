import Foundation

/// What the same effort would have been worth on the flat.
///
/// Pace is the number runners judge themselves by and the one the ground
/// interferes with most: 5:30/km up a hill and 5:30/km down it are not the same
/// run, and a hilly week looks like a bad week in any log that only records
/// clock pace. Grade-adjusted pace converts each metre of the route into the
/// flat distance that would have cost the same energy, then reads the pace off
/// the total.
///
/// **This is a model, not a measurement.** It uses Minetti's 2002 treadmill
/// measurements of the metabolic cost of running on a gradient — the same
/// source most implementations use — and inherits their limits: the subjects
/// were running, not hiking, and the fit was never validated at the extremes
/// where people stop running and start walking. The gradient is clamped for
/// that reason, and the adjustment is shown beside the real pace rather than
/// replacing it.
enum GradeAdjustedPace {

    /// Minetti's polynomial for the cost of running, in J/kg/m, as a function
    /// of gradient (rise over run, so 0.1 is 10%).
    ///
    /// Minetti, Moia, Roi, Susta & Ferretti (2002), *Energy cost of walking and
    /// running at extreme uphill and downhill slopes*, J Appl Physiol 93:1039.
    static func costOfRunning(gradient: Double) -> Double {
        let i = min(max(gradient, clamp.lowerBound), clamp.upperBound)
        return 155.4 * pow(i, 5)
            - 30.4 * pow(i, 4)
            - 43.3 * pow(i, 3)
            + 46.3 * pow(i, 2)
            + 19.5 * i
            + 3.6
    }

    /// Cost on the flat, from the same polynomial: the constant term.
    static let flatCost = 3.6

    /// Gradients outside this are clipped rather than extrapolated.
    ///
    /// Minetti's own range is ±45%, but past roughly 30% nobody is running: the
    /// curve keeps charging you for a run you are not doing, and a scramble up
    /// a 60% bank would otherwise convert into an implausible flat pace.
    static let clamp = -0.30...0.30

    /// Gradient is computed over chunks of at least this many metres.
    ///
    /// Barometric and GPS altitude both wander by a metre or two between
    /// samples. Over one second of running that is a 10% gradient out of pure
    /// noise, and the cost curve is steep enough there to turn the noise into
    /// minutes.
    static let smoothingMetres = 30.0

    /// How much the adjustment has to move the pace before it is worth showing.
    /// On a flat route the answer is the pace you already know.
    static let reportingThreshold = 0.02

    struct Result: Sendable, Equatable {
        /// Seconds per kilometre, as if the route had been flat.
        let adjustedPaceSecPerKm: Double
        /// Seconds per kilometre actually run, over the same samples.
        let actualPaceSecPerKm: Double
        /// Metres of climbing per kilometre over the analysed portion — the
        /// reason the two differ.
        let gradientPerKm: Double

        /// Negative when the hills cost you time, which is the usual case: the
        /// flat-equivalent pace is faster than the clock pace.
        var differenceSeconds: Double { adjustedPaceSecPerKm - actualPaceSecPerKm }

        /// False on a route flat enough that the model has nothing to say.
        var isWorthShowing: Bool {
            guard actualPaceSecPerKm > 0 else { return false }
            return abs(differenceSeconds) / actualPaceSecPerKm >= reportingThreshold
        }
    }

    /// Convert a recorded run into its flat equivalent.
    ///
    /// - Parameters:
    ///   - samples: needs cumulative distance and altitude. Samples missing
    ///     either are skipped, and a stream missing one entirely returns nil.
    ///   - sport: running only. Walking and hiking have a different cost curve,
    ///     and applying the running one to a hike overstates the climb badly.
    static func analyse(samples: [FITSample], sport: WorkoutSport) -> Result? {
        guard sport == .run || sport == .trailRun else { return nil }

        let usable = samples
            .filter { $0.dist != nil && $0.alt != nil }
            .sorted { $0.t < $1.t }
        guard usable.count >= 2 else { return nil }

        var adjustedMetres = 0.0
        var flatMetres = 0.0
        var climb = 0.0
        var elapsed = 0.0

        var anchor = usable[0]
        for sample in usable.dropFirst() {
            let run = (sample.dist ?? 0) - (anchor.dist ?? 0)
            // Accumulate until the chunk is long enough for its gradient to
            // mean something. The last partial chunk is dropped rather than
            // measured badly.
            guard run >= smoothingMetres else { continue }

            let rise = (sample.alt ?? 0) - (anchor.alt ?? 0)
            let ratio = costOfRunning(gradient: rise / run) / flatCost

            adjustedMetres += run * ratio
            flatMetres += run
            if rise > 0 { climb += rise }
            elapsed += sample.t - anchor.t
            anchor = sample
        }

        guard flatMetres > 100, elapsed > 0 else { return nil }

        let adjustedSpeed = adjustedMetres / elapsed        // m/s, flat-equivalent
        let actualSpeed = flatMetres / elapsed
        guard adjustedSpeed > 0, actualSpeed > 0 else { return nil }

        return Result(
            adjustedPaceSecPerKm: 1000 / adjustedSpeed,
            actualPaceSecPerKm: 1000 / actualSpeed,
            gradientPerKm: climb / (flatMetres / 1000)
        )
    }
}
