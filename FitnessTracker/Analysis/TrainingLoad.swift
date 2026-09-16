import Foundation

/// Unified, multi-sport training load.
///
/// The old model summed raw distance across every sport, which made an 80 km
/// ride worth four times a 20 km run and a hard 2 km swim worth almost nothing.
/// This replaces it with a single stress number per session on the TSS scale —
/// **100 = one hour at threshold** — computed by the best method the available
/// data supports, then accumulated into the standard fitness/fatigue curves.
///
/// Every score reports which `Method` produced it, so the UI can say how much
/// to trust it rather than presenting an estimate as a measurement.
enum TrainingLoad {

    // MARK: - Inputs

    /// The athlete constants scoring depends on. All optional: each missing
    /// value drops scoring to the next-best method rather than failing.
    struct Athlete: Sendable, Equatable {
        var ftp: Int?                          // watts
        var maxHR: Int?                        // bpm
        var restingHR: Int?                    // bpm
        var thresholdPaceSecPerKm: Double?     // sec/km

        init(ftp: Int? = nil,
             maxHR: Int? = nil,
             restingHR: Int? = nil,
             thresholdPaceSecPerKm: Double? = nil) {
            self.ftp = ftp.flatMap { $0 > 0 ? $0 : nil }
            self.maxHR = maxHR.flatMap { $0 >= 100 ? $0 : nil }
            self.restingHR = restingHR.flatMap { $0 > 0 ? $0 : nil }
            self.thresholdPaceSecPerKm = thresholdPaceSecPerKm.flatMap { $0 > 0 ? $0 : nil }
        }

        /// Heart-rate reserve. Falls back to a 60 bpm resting rate, which is
        /// wrong by less than the error from not modelling HR at all.
        var heartRateReserve: Double? {
            guard let maxHR else { return nil }
            let rest = Double(restingHR ?? 60)
            let reserve = Double(maxHR) - rest
            return reserve > 20 ? reserve : nil
        }
    }

    /// How a score was derived, worst-to-best as a confidence ordering.
    enum Method: String, Sendable, CaseIterable, Comparable {
        /// Duration × a per-sport default intensity. A guess, and labelled one.
        case duration
        /// Average pace against threshold pace. Running only.
        case pace
        /// Average heart rate against threshold heart rate.
        case averageHeartRate
        /// Per-sample heart rate integrated over the session — captures intervals.
        case heartRateStream
        /// Normalized power against FTP. The reference method.
        case power

        var displayName: String {
            switch self {
            case .duration:         return "Estimated from duration"
            case .pace:             return "From pace vs threshold"
            case .averageHeartRate: return "From average heart rate"
            case .heartRateStream:  return "From heart-rate stream"
            case .power:            return "From power"
            }
        }

        /// True when the number rests on measured intensity rather than a guess.
        var isMeasured: Bool { self != .duration }

        private var rank: Int {
            switch self {
            case .duration:         return 0
            case .pace:             return 1
            case .averageHeartRate: return 2
            case .heartRateStream:  return 3
            case .power:            return 4
            }
        }

        static func < (a: Method, b: Method) -> Bool { a.rank < b.rank }
    }

    struct Score: Sendable, Equatable {
        /// Training stress. 100 ≈ one hour at threshold.
        let value: Double
        let method: Method
        /// Intensity factor — effort relative to threshold. 1.0 is threshold.
        let intensityFactor: Double?
    }

    // MARK: - Constants

    /// Lactate threshold sits near 85% of heart-rate reserve for most trained
    /// athletes. Used to convert a heart-rate reserve fraction into an IF.
    static let thresholdHRReserveFraction = 0.85

    /// Longest gap between samples still treated as continuous. A bigger jump is
    /// a recording dropout, not 20 minutes of effort.
    static let maxSampleGapSeconds: TimeInterval = 60

    /// Per-sport intensity used only when nothing measured the effort. These are
    /// deliberately conservative — an unmeasured session should never dominate.
    static func defaultIntensity(for sport: WorkoutSport) -> Double {
        switch sport {
        case .run, .trailRun: return 0.75
        case .bike:           return 0.70
        case .swim:           return 0.75
        case .hike:           return 0.55
        case .walk:           return 0.40
        case .other:          return 0.65
        }
    }

    // MARK: - Scoring one session

    /// Training stress for one workout, by the best method its data supports.
    ///
    /// Order of preference: power → heart-rate stream → average heart rate →
    /// pace → duration. Each step down is a real loss of accuracy, which is why
    /// the method comes back with the number.
    static func score(for workout: WorkoutSnapshot, athlete: Athlete) -> Score? {
        guard workout.duration > 0 else { return nil }
        let hours = workout.duration / 3600

        // 1. Power. Only cycling records it, and it's the reference standard.
        if let ftp = athlete.ftp {
            let samples = workout.samples
            if let power = CyclingPower.summary(samples: samples, ftp: ftp),
               let tss = power.trainingStressScore,
               let intensity = power.intensityFactor,
               tss > 0 {
                return Score(value: tss, method: .power, intensityFactor: intensity)
            }
        }

        // 2. Heart-rate stream, integrated sample by sample. An interval session
        //    and a steady run at the same average HR are not the same stress, and
        //    squaring the intensity before integrating is what separates them.
        if let reserve = athlete.heartRateReserve, let maxHR = athlete.maxHR {
            let rest = Double(athlete.restingHR ?? 60)
            let samples = workout.samples.filter { $0.hr != nil }.sorted { $0.t < $1.t }

            if samples.count >= 2 {
                var weightedSeconds = 0.0
                var totalSeconds = 0.0
                for index in samples.indices.dropLast() {
                    guard let hr = samples[index].hr else { continue }
                    let dt = samples[index + 1].t - samples[index].t
                    guard dt > 0, dt <= maxSampleGapSeconds else { continue }
                    let intensity = intensityFactor(forHeartRate: Double(hr),
                                                    rest: rest, reserve: reserve)
                    weightedSeconds += intensity * intensity * dt
                    totalSeconds += dt
                }
                if totalSeconds > 0 {
                    let tss = weightedSeconds / 3600 * 100
                    // Report the IF the session averaged out at, for the UI.
                    let effectiveIF = (weightedSeconds / totalSeconds).squareRoot()
                    return Score(value: tss, method: .heartRateStream,
                                 intensityFactor: effectiveIF)
                }
            }

            // 3. Average heart rate — every synced activity has this even when
            //    the provider didn't give us streams.
            if let avg = workout.avgHeartRate, Double(avg) > rest, avg <= maxHR + 20 {
                let intensity = intensityFactor(forHeartRate: Double(avg),
                                                rest: rest, reserve: reserve)
                return Score(value: hours * intensity * intensity * 100,
                             method: .averageHeartRate, intensityFactor: intensity)
            }
        }

        // 4. Pace against threshold. Running only — cycling pace says nothing
        //    about effort (wind, draft, gradient) and swimming needs its own
        //    threshold, which we don't ask for.
        if [.run, .trailRun].contains(workout.sport),
           let thresholdPace = athlete.thresholdPaceSecPerKm,
           workout.distance > 0 {
            let pace = workout.duration / (workout.distance / 1000)
            if pace > 0 {
                // Faster pace is a smaller number, so threshold/actual.
                let intensity = min(thresholdPace / pace, 1.5)
                return Score(value: hours * intensity * intensity * 100,
                             method: .pace, intensityFactor: intensity)
            }
        }

        // 5. Nothing measured the effort. Assume a per-sport default so the
        //    session still counts for something, and say it's an estimate.
        let intensity = defaultIntensity(for: workout.sport)
        return Score(value: hours * intensity * intensity * 100,
                     method: .duration, intensityFactor: nil)
    }

    /// Strength sessions carry real fatigue but no heart rate. RPE is the only
    /// intensity signal a lifter reliably records, so use it: RPE 10 is maximal
    /// (IF 1.0), RPE 6 is genuinely easy (IF ~0.6). Sets are the duration proxy
    /// when the session wasn't timed, at roughly three minutes each including
    /// rest — the number that makes an hour-long session come out near an hour.
    static func score(for session: StrengthSessionSnapshot) -> Score? {
        let working = session.sets.filter { !$0.isWarmup }
        guard !working.isEmpty else { return nil }

        let rpes = working.compactMap(\.rpe)
        let averageRPE = rpes.isEmpty ? 7.5 : rpes.reduce(0, +) / Double(rpes.count)
        let intensity = min(max(averageRPE / 10.0, 0.4), 1.0)

        let hours = session.duration.map { $0 / 3600 }
            ?? (Double(working.count) * 180 / 3600)

        return Score(value: hours * intensity * intensity * 100,
                     method: rpes.isEmpty ? .duration : .averageHeartRate,
                     intensityFactor: intensity)
    }

    /// Karvonen reserve fraction, expressed relative to threshold so 1.0 means
    /// "at threshold" exactly like a power-based IF does.
    static func intensityFactor(forHeartRate hr: Double,
                                rest: Double,
                                reserve: Double) -> Double {
        let fraction = (hr - rest) / reserve
        // Clamped: a stray 250 bpm spike shouldn't produce a 3× intensity.
        return min(max(fraction / thresholdHRReserveFraction, 0), 1.5)
    }

    // MARK: - Daily totals

    /// One day's total stress, keyed by start-of-day.
    static func dailyTotals(
        workouts: [WorkoutSnapshot],
        strength: [StrengthSessionSnapshot] = [],
        athlete: Athlete,
        calendar: Calendar = .current
    ) -> [Date: Double] {
        var totals: [Date: Double] = [:]
        for workout in workouts {
            guard let score = score(for: workout, athlete: athlete) else { continue }
            totals[calendar.startOfDay(for: workout.startedAt), default: 0] += score.value
        }
        for session in strength {
            guard let score = score(for: session) else { continue }
            totals[calendar.startOfDay(for: session.startedAt), default: 0] += score.value
        }
        return totals
    }

    // MARK: - Fitness / fatigue curves

    /// Banister-style impulse-response state for one day.
    struct Point: Sendable, Identifiable, Equatable {
        let date: Date
        /// Training stress on this day.
        let load: Double
        /// Chronic training load — "fitness". 42-day exponential average.
        let fitness: Double
        /// Acute training load — "fatigue". 7-day exponential average.
        let fatigue: Double

        /// Training stress balance — "form". Positive means fresh.
        var form: Double { fitness - fatigue }

        /// Acute:chronic ratio, the injury-risk framing of the same two numbers.
        var acuteChronicRatio: Double? {
            fitness > 0 ? fatigue / fitness : nil
        }

        var id: Date { date }
    }

    static let fitnessTimeConstant = 42.0
    static let fatigueTimeConstant = 7.0

    /// Daily fitness/fatigue series from the first day of training to `through`.
    ///
    /// Days with no training are still emitted — decay between sessions is the
    /// whole point of the model, and a chart with gaps would read as flat.
    static func series(
        dailyTotals: [Date: Double],
        through end: Date = .now,
        calendar: Calendar = .current
    ) -> [Point] {
        guard let first = dailyTotals.keys.min() else { return [] }
        let lastDay = calendar.startOfDay(for: end)
        guard first <= lastDay else { return [] }

        let fitnessDecay = exp(-1 / fitnessTimeConstant)
        let fatigueDecay = exp(-1 / fatigueTimeConstant)

        var points: [Point] = []
        var fitness = 0.0
        var fatigue = 0.0
        var day = first

        while day <= lastDay {
            let load = dailyTotals[day] ?? 0
            fitness = fitness * fitnessDecay + load * (1 - fitnessDecay)
            fatigue = fatigue * fatigueDecay + load * (1 - fatigueDecay)
            points.append(Point(date: day, load: load, fitness: fitness, fatigue: fatigue))

            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return points
    }

    /// How the last week compares to the one before it, in fitness terms. A ramp
    /// above ~7 CTL/week is the classic "too much, too soon" threshold.
    static func weeklyRamp(_ series: [Point]) -> Double? {
        guard let latest = series.last, series.count > 7 else { return nil }
        let weekAgo = series[series.count - 8]
        return latest.fitness - weekAgo.fitness
    }

    /// Plain-language read on current form, so the dashboard doesn't just show
    /// three numbers and leave the athlete to interpret them.
    enum FormVerdict: String, Sendable {
        case fresh, neutral, productive, overreaching

        var label: String {
            switch self {
            case .fresh:        return "Fresh"
            case .neutral:      return "Neutral"
            case .productive:   return "Productive"
            case .overreaching: return "Overreaching"
            }
        }

        var guidance: String {
            switch self {
            case .fresh:
                return "Rested and ready. Good window for a race or a hard block."
            case .neutral:
                return "Balanced. Training is keeping pace with recovery."
            case .productive:
                return "Carrying fatigue while building. This is where fitness comes from — don't stay here forever."
            case .overreaching:
                return "Fatigue well ahead of fitness. Back off before it costs you."
            }
        }
    }

    /// Thresholds follow the usual TSB reading, scaled by fitness so they mean
    /// the same thing to a 30-CTL beginner and a 90-CTL racer.
    static func verdict(for point: Point) -> FormVerdict {
        guard point.fitness > 5 else { return .neutral }
        let relative = point.form / point.fitness
        switch relative {
        case 0.10...:       return .fresh
        case -0.10..<0.10:  return .neutral
        case -0.30..<(-0.10): return .productive
        default:            return .overreaching
        }
    }
}
