import Foundation

/// Aerobic decoupling: how much your output-per-heartbeat fell away over a
/// steady session.
///
/// Every other number in this app tells you what a session *cost*. This one
/// tells you something the cost can't: whether you could hold it. Two athletes
/// can finish the same two-hour ride at the same average power and the same
/// average heart rate, and one of them was working visibly harder by the end.
/// Splitting the session in half and comparing power-per-beat between the
/// halves is what separates them.
///
/// The convention is Friel's Pw:Hr (rides) and Pa:Hr (runs): below 5% is the
/// mark of an aerobically durable athlete at that intensity, and a number that
/// keeps climbing at a pace you used to hold is the earliest honest sign that
/// the aerobic base has gone backwards.
///
/// It is only meaningful on a *steady* effort. An interval session decouples by
/// construction — the second half contains different work — so this refuses to
/// score one rather than printing a number that means nothing. Heat, dehydration
/// and a session that was simply too hard all push it up, and none of those is
/// a fitness problem, so the verdict says what it is rather than grading you.
enum Decoupling {

    /// Which channel stood in for "output".
    ///
    /// Power is the honest one: it measures what you produced. Speed is a proxy
    /// that the ground interferes with, which is why hills disqualify a run
    /// below.
    enum Basis: Sendable, Equatable {
        case power
        case speed
    }

    struct Result: Sendable, Equatable {
        /// Positive means you decoupled — the second half cost more beats per
        /// unit of output. Negative means the opposite, which usually means the
        /// warm-up wasn't fully trimmed rather than that you got fitter mid-ride.
        let percent: Double
        /// Output per beat, first half and second half. Units are arbitrary and
        /// only the ratio between them matters, so they aren't shown.
        let firstHalf: Double
        let secondHalf: Double
        let basis: Basis
        /// How much of the session was scored, after the warm-up trim.
        let analysedSeconds: TimeInterval

        var verdict: Verdict {
            switch percent {
            case ..<(-2):  return .warmupIncluded
            case ..<5:     return .coupled
            case ..<10:    return .drifting
            default:       return .decoupled
            }
        }
    }

    enum Verdict: Sendable, Equatable {
        /// Efficiency *rose* — almost always an incomplete warm-up trim.
        case warmupIncluded
        case coupled
        case drifting
        case decoupled

        var title: String {
            switch self {
            case .warmupIncluded: return String(localized: "Still warming up")
            case .coupled:        return String(localized: "Held together")
            case .drifting:       return String(localized: "Drifting")
            case .decoupled:      return String(localized: "Came apart")
            }
        }

        var detail: String {
            switch self {
            case .warmupIncluded:
                return String(localized: "Output per beat rose over the session, which normally means you were still warming up when the scored part began rather than that you got fitter mid-session.")
            case .coupled:
                return String(localized: "Under 5% is the usual mark of aerobic durability at this intensity: the second half cost about what the first half did.")
            case .drifting:
                return String(localized: "Some drift. Normal on a long or warm day, and normal at an intensity you can't hold all day — worth watching if it shows up at an easy pace.")
            case .decoupled:
                return String(localized: "The second half cost noticeably more per beat. Heat, dehydration and going out too hard all do this; so does a session that is simply longer than your base supports.")
            }
        }
    }

    // MARK: - Tuning

    /// Dropped from the front before scoring. Heart rate lags effort by minutes
    /// at the start of a session, and leaving that in makes every ride look like
    /// it got *more* efficient.
    static let warmupTrim: TimeInterval = 600

    /// Below this there isn't enough session left for two halves to mean
    /// anything. Friel's original applies to aerobic-threshold work of an hour
    /// or more; 25 minutes is the point where a tempo run starts to be worth
    /// scoring, and the verdict is weaker the closer you are to it.
    static let minimumAnalysedSeconds: TimeInterval = 1_500

    /// Variability index ceiling. 1.0 is perfectly steady; an interval session
    /// runs well above this, and scoring one would compare a rep block against
    /// a recovery block and call the difference "decoupling".
    static let steadinessCeiling = 1.12

    /// Runs on rolling terrain are disqualified: speed-per-beat falls on a climb
    /// for reasons that have nothing to do with aerobic durability, so a hilly
    /// second half fakes the whole measurement. Metres of gain per kilometre.
    static let maximumGradientForSpeed = 12.0

    // MARK: - Analysis

    /// Score a session, or explain nothing by returning nil.
    ///
    /// - Parameters:
    ///   - samples: the recorded stream. Needs heart rate throughout, plus
    ///     either power (preferred) or speed.
    ///   - sport: decides which channel is allowed to stand in for output.
    static func analyse(samples: [FITSample], sport: WorkoutSport) -> Result? {
        let ordered = samples.sorted { $0.t < $1.t }
        guard let start = ordered.first?.t, let end = ordered.last?.t else { return nil }
        guard end - start >= warmupTrim + minimumAnalysedSeconds else { return nil }

        let scored = ordered.filter { $0.t >= start + warmupTrim }
        guard let basis = basis(for: sport, in: scored) else { return nil }

        let output: (FITSample) -> Double? = { sample in
            switch basis {
            case .power: return sample.power.map(Double.init)
            case .speed: return sample.speed
            }
        }

        // Both channels have to be present in the same sample: a ratio built
        // from power at t=100 and heart rate at t=400 isn't a ratio.
        let paired = scored.compactMap { sample -> (t: TimeInterval, out: Double, hr: Double)? in
            guard let out = output(sample), out > 0,
                  let hr = sample.hr, hr > 0 else { return nil }
            return (sample.t, out, Double(hr))
        }
        guard let first = paired.first, let last = paired.last,
              last.t - first.t >= minimumAnalysedSeconds
        else { return nil }

        // Enough of the window has to survive the pairing, or we're scoring a
        // handful of scattered seconds and calling it a half.
        let covered = Double(paired.count) / Double(max(scored.count, 1))
        guard covered >= 0.8 else { return nil }

        guard variabilityIndex(of: paired.map(\.out), at: paired.map(\.t)) <= steadinessCeiling
        else { return nil }

        if basis == .speed, isTooHilly(scored) { return nil }

        let midpoint = first.t + (last.t - first.t) / 2
        let firstHalf = paired.filter { $0.t < midpoint }
        let secondHalf = paired.filter { $0.t >= midpoint }
        guard firstHalf.count >= 2, secondHalf.count >= 2 else { return nil }

        guard let efficiencyOne = efficiency(firstHalf), efficiencyOne > 0,
              let efficiencyTwo = efficiency(secondHalf)
        else { return nil }

        return Result(
            percent: (efficiencyOne - efficiencyTwo) / efficiencyOne * 100,
            firstHalf: efficiencyOne,
            secondHalf: efficiencyTwo,
            basis: basis,
            analysedSeconds: last.t - first.t
        )
    }

    // MARK: - Pieces

    /// Power where it exists, speed for runs, nothing for anything else.
    ///
    /// Swimming is left out on purpose: a pool stream's speed is a sawtooth of
    /// walls and turns, and open water has no reliable speed at all.
    private static func basis(for sport: WorkoutSport, in samples: [FITSample]) -> Basis? {
        let hasPower = samples.contains { ($0.power ?? 0) > 0 }
        if hasPower { return .power }
        switch sport {
        case .run, .trailRun, .bike:
            return samples.contains { ($0.speed ?? 0) > 0 } ? .speed : nil
        default:
            return nil
        }
    }

    /// Mean of output divided by mean of heart rate.
    ///
    /// Taking the mean of the per-sample ratios instead would let one stray
    /// low-heart-rate sample dominate the half.
    private static func efficiency(_ points: [(t: TimeInterval, out: Double, hr: Double)]) -> Double? {
        guard !points.isEmpty else { return nil }
        let meanOut = points.reduce(0) { $0 + $1.out } / Double(points.count)
        let meanHR = points.reduce(0) { $0 + $1.hr } / Double(points.count)
        guard meanHR > 0 else { return nil }
        return meanOut / meanHR
    }

    /// Coggan's variability index, generalised to any output channel: the
    /// fourth-root-mean of a 30-second rolling average, over the plain mean.
    ///
    /// The fourth power is what makes it notice surges — a session that
    /// alternates 400 W and 100 W has the same mean as a steady 250 W and a far
    /// higher index.
    static func variabilityIndex(of values: [Double], at times: [TimeInterval]) -> Double {
        guard values.count == times.count, values.count >= 2 else { return .infinity }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return .infinity }

        var rolling: [Double] = []
        var start = 0
        var sum = 0.0
        for end in values.indices {
            sum += values[end]
            while start < end, times[end] - times[start] > 30 {
                sum -= values[start]
                start += 1
            }
            rolling.append(sum / Double(end - start + 1))
        }

        let fourth = rolling.reduce(0) { $0 + pow($1, 4) } / Double(rolling.count)
        return pow(fourth, 0.25) / mean
    }

    /// Metres of climbing per kilometre, over the scored window.
    private static func isTooHilly(_ samples: [FITSample]) -> Bool {
        var gain = 0.0
        var previous: Double?
        for sample in samples {
            guard let alt = sample.alt else { continue }
            if let previous, alt > previous { gain += alt - previous }
            previous = alt
        }
        guard let firstDistance = samples.compactMap(\.dist).first,
              let lastDistance = samples.compactMap(\.dist).last
        else { return false }  // No distance channel: can't judge, so don't block.
        let kilometres = (lastDistance - firstDistance) / 1000
        guard kilometres > 0.5 else { return false }
        return gain / kilometres > maximumGradientForSpeed
    }
}
