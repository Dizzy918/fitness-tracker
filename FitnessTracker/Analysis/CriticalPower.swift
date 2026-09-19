import Foundation

/// The two-parameter critical power model, fitted to your own best efforts.
///
/// The duration curve already shows *what* you can hold for how long. This puts
/// two numbers on it. Critical power is the asymptote the curve is falling
/// towards — the highest output you could theoretically sustain indefinitely,
/// and a better-grounded threshold than "95% of your twenty-minute power",
/// which is a rule of thumb applied to one data point. W′ is the size of the
/// tank above it: the fixed amount of work you can spend going harder than
/// critical power before you stop, in joules for a rider and in metres of
/// "distance reserve" (D′) for a runner.
///
/// Together they say something a single threshold cannot. Two athletes with the
/// same critical power and very different W′ need different races and different
/// training: one can bridge a gap and recover, the other has to ride at a
/// constant effort and will lose every sprint.
///
/// **It is a fit, not a test.** The model assumes the efforts it is fitted to
/// were genuinely maximal, and a curve built from training rides usually isn't.
/// The fit quality is reported for that reason, and a curve that doesn't fit
/// the hyperbola is refused rather than rounded into one.
enum CriticalPower {

    /// Durations the model is fitted over.
    ///
    /// Below two minutes the hyperbola overestimates — anaerobic capacity and
    /// the oxygen deficit dominate and the two-parameter model has no term for
    /// either. Above twenty minutes it underestimates, because real athletes
    /// drift below critical power on long efforts for reasons (fuel, heat) the
    /// model doesn't contain. This is the window where the assumption holds.
    static let fitRange: ClosedRange<TimeInterval> = 120...1_200

    /// The longest fitted effort must be at least this many times the shortest.
    /// Fitting a line through three points a minute apart gives an intercept
    /// that is mostly noise.
    static let minimumSpanRatio = 3.0

    /// Below this the points aren't on a hyperbola and the two numbers would be
    /// invented. In practice a set of honest maximal efforts fits above 0.97.
    static let minimumFitQuality = 0.95

    struct Model: Sendable, Equatable {
        /// Watts for a rider, metres per second for a runner.
        let critical: Double
        /// Joules above critical power for a rider, metres above critical speed
        /// for a runner.
        let reserve: Double
        let metric: DurationCurve.Metric
        let pointsUsed: Int
        /// Coefficient of determination of the linear fit, 0…1.
        let fitQuality: Double
        /// Shortest and longest effort the fit used.
        let span: ClosedRange<TimeInterval>

        /// What the model says you could hold for a given duration.
        ///
        /// Useful as a sanity check against the curve it came from: where the
        /// prediction and the real best effort diverge is where the model stops
        /// describing you.
        func predicted(at duration: TimeInterval) -> Double? {
            guard duration > 0 else { return nil }
            return critical + reserve / duration
        }

        /// How long the model says you could hold an output above critical.
        /// Nil at or below critical power, where the answer is "indefinitely"
        /// and the model knows it isn't true.
        func timeToExhaustion(at output: Double) -> TimeInterval? {
            guard output > critical else { return nil }
            return reserve / (output - critical)
        }

        /// W′ reads in kilojoules; D′ reads in metres.
        var reserveIsEnergy: Bool { metric == .power }
    }

    /// Fit the model to a duration curve.
    ///
    /// The fit is a straight line rather than a curve: total work done in a
    /// maximal effort is `critical × t + reserve`, so regressing work against
    /// time gives critical power as the slope and W′ as the intercept. That is
    /// the standard linear work–time form, and it is far better behaved than
    /// fitting the hyperbola directly.
    static func fit(_ points: [DurationCurve.Point], metric: DurationCurve.Metric) -> Model? {
        // Convert each point into (time, total work done). For pace the
        // "work" is distance and the slope comes out as critical speed.
        let observations: [(t: Double, work: Double)] = points
            .filter { fitRange.contains($0.duration) }
            .compactMap { point in
                switch metric {
                case .power:
                    guard point.value > 0 else { return nil }
                    return (point.duration, point.value * point.duration)
                case .pace:
                    // value is seconds per kilometre; distance = t / (s/m).
                    guard point.value > 0 else { return nil }
                    let metresPerSecond = 1000 / point.value
                    return (point.duration, metresPerSecond * point.duration)
                }
            }
            .sorted { $0.t < $1.t }

        guard observations.count >= 3,
              let shortest = observations.first?.t,
              let longest = observations.last?.t,
              shortest > 0, longest / shortest >= minimumSpanRatio
        else { return nil }

        guard let line = leastSquares(observations) else { return nil }
        guard line.slope > 0, line.intercept > 0 else { return nil }
        guard line.rSquared >= minimumFitQuality else { return nil }

        return Model(
            critical: line.slope,
            reserve: line.intercept,
            metric: metric,
            pointsUsed: observations.count,
            fitQuality: line.rSquared,
            span: shortest...longest
        )
    }

    // MARK: - Regression

    private struct Line {
        let slope: Double
        let intercept: Double
        let rSquared: Double
    }

    private static func leastSquares(_ points: [(t: Double, work: Double)]) -> Line? {
        let n = Double(points.count)
        guard n >= 2 else { return nil }

        let meanT = points.reduce(0) { $0 + $1.t } / n
        let meanW = points.reduce(0) { $0 + $1.work } / n

        var covariance = 0.0
        var varianceT = 0.0
        for point in points {
            covariance += (point.t - meanT) * (point.work - meanW)
            varianceT += (point.t - meanT) * (point.t - meanT)
        }
        guard varianceT > 0 else { return nil }

        let slope = covariance / varianceT
        let intercept = meanW - slope * meanT

        var residual = 0.0
        var total = 0.0
        for point in points {
            let predicted = slope * point.t + intercept
            residual += (point.work - predicted) * (point.work - predicted)
            total += (point.work - meanW) * (point.work - meanW)
        }
        guard total > 0 else { return nil }

        return Line(slope: slope, intercept: intercept, rSquared: 1 - residual / total)
    }
}
