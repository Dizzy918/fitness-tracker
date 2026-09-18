import Foundation

/// Training-readiness scoring.
///
/// This is a transparent heuristic over *your own* trends — not a validated
/// medical or physiological measure. Every component reports its own subscore so
/// the number can always be explained, and the score degrades gracefully when
/// inputs are missing rather than quietly inventing a value.
enum Readiness {

    enum Component: String, CaseIterable, Sendable {
        case hrv, sleep, restingHR, load, subjective

        /// Relative importance. Renormalized over whichever inputs exist.
        var weight: Double {
            switch self {
            case .hrv:        return 0.35
            case .sleep:      return 0.25
            case .restingHR:  return 0.15
            case .load:       return 0.15
            case .subjective: return 0.10
            }
        }

        var displayName: String {
            switch self {
            case .hrv:        return String(localized: "HRV")
            case .sleep:      return String(localized: "Sleep")
            case .restingHR:  return String(localized: "Resting HR")
            case .load:       return String(localized: "Training load")
            case .subjective: return String(localized: "How you feel")
            }
        }
    }

    struct Contribution: Sendable, Identifiable {
        let component: Component
        /// 0–1, where ~0.75 means "at your normal baseline".
        let subscore: Double
        let detail: String
        var id: String { component.rawValue }
    }

    enum Band: String, Sendable {
        case rest, easy, moderate, primed

        var label: String {
            switch self {
            case .rest:     return String(localized: "Rest")
            case .easy:     return String(localized: "Take it easy")
            case .moderate: return String(localized: "Normal training")
            case .primed:   return String(localized: "Primed")
            }
        }

        var guidance: String {
            switch self {
            case .rest:     return "Your markers are well below baseline. Rest or move very easy."
            case .easy:     return "Somewhat below baseline. Keep it aerobic and short."
            case .moderate: return "Around baseline. Train as planned."
            case .primed:   return "Above baseline. A hard session should go well."
            }
        }
    }

    struct Result: Sendable {
        let score: Int                    // 0–100
        let band: Band
        let contributions: [Contribution]
        /// Fraction of total weight that had data. Below 0.3 we refuse to score.
        let confidence: Double
        let missing: [Component]

        var isReliable: Bool { confidence >= 0.3 }
    }

    /// Minimum prior days needed before a baseline is meaningful.
    static let minimumBaselineSamples = 3
    /// Baseline window for HRV / resting HR.
    static let baselineDays = 7
    static let sleepTargetHours = 8.0

    /// Score one day.
    ///
    /// - Parameters:
    ///   - day: the day being scored (its own values are the "today" reading).
    ///   - history: prior days, used only for baselines. Days on or after `day`
    ///     are ignored so a score can never see the future.
    ///   - loadRatio: acute:chronic training-load ratio, if known.
    static func score(
        day: MetricSnapshot,
        history: [MetricSnapshot],
        loadRatio: Double? = nil
    ) -> Result {
        let priors = history
            .filter { $0.date < day.date }
            .sorted { $0.date > $1.date }
            .prefix(baselineDays)

        var contributions: [Contribution] = []

        // HRV: higher than baseline is better.
        if let today = day.hrvSDNN,
           let stats = Stats(values: priors.compactMap(\.hrvSDNN)) {
            let z = stats.zScore(today)
            contributions.append(Contribution(
                component: .hrv,
                subscore: clamp(0.75 + z * 0.2),
                detail: String(format: "%.0f ms vs %.0f baseline", today, stats.mean)
            ))
        }

        // Sleep: duration against target, blended with subjective quality.
        if let hours = day.sleepHours {
            let duration = clamp(hours / sleepTargetHours)
            var subscore = duration
            var detail = String(format: "%.1f h", hours)
            if let quality = day.sleepQuality {
                let q = normalizeScale(quality)
                subscore = duration * 0.7 + q * 0.3
                detail += ", quality \(quality)/5"
            }
            contributions.append(Contribution(
                component: .sleep, subscore: clamp(subscore), detail: detail
            ))
        } else if let quality = day.sleepQuality {
            contributions.append(Contribution(
                component: .sleep,
                subscore: normalizeScale(quality),
                detail: "quality \(quality)/5 (no duration)"
            ))
        }

        // Resting HR: lower than baseline is better, so the z-score is inverted.
        if let today = day.restingHR,
           let stats = Stats(values: priors.compactMap(\.restingHR)) {
            let z = stats.zScore(today)
            contributions.append(Contribution(
                component: .restingHR,
                subscore: clamp(0.75 - z * 0.2),
                detail: String(format: "%.0f bpm vs %.0f baseline", today, stats.mean)
            ))
        }

        // Training load: a recent spike lowers readiness; being fresh doesn't
        // raise it above "good", since freshness isn't fitness.
        if let ratio = loadRatio, ratio > 0 {
            contributions.append(Contribution(
                component: .load,
                subscore: loadSubscore(ratio),
                detail: String(format: "acute:chronic %.2f", ratio)
            ))
        }

        // Subjective: soreness is inverted (5 = very sore).
        var subjectiveParts: [Double] = []
        if let soreness = day.soreness { subjectiveParts.append(normalizeScale(6 - soreness)) }
        if let mood = day.mood { subjectiveParts.append(normalizeScale(mood)) }
        if let motivation = day.motivation { subjectiveParts.append(normalizeScale(motivation)) }
        if !subjectiveParts.isEmpty {
            contributions.append(Contribution(
                component: .subjective,
                subscore: subjectiveParts.reduce(0, +) / Double(subjectiveParts.count),
                detail: "\(subjectiveParts.count) of 3 answered"
            ))
        }

        let availableWeight = contributions.reduce(0) { $0 + $1.component.weight }
        guard availableWeight > 0 else {
            return Result(score: 0, band: .moderate, contributions: [],
                          confidence: 0, missing: Component.allCases)
        }

        // Renormalize so a missing input doesn't silently drag the score down.
        let weighted = contributions.reduce(0.0) {
            $0 + $1.subscore * $1.component.weight
        } / availableWeight
        let score = Int((weighted * 100).rounded())

        let present = Set(contributions.map(\.component))
        return Result(
            score: score,
            band: band(for: score),
            contributions: contributions.sorted {
                $0.component.weight > $1.component.weight
            },
            confidence: availableWeight,
            missing: Component.allCases.filter { !present.contains($0) }
        )
    }

    static func band(for score: Int) -> Band {
        switch score {
        case ..<40:   return .rest
        case 40..<60: return .easy
        case 60..<80: return .moderate
        default:      return .primed
        }
    }

    /// Flat through the sustainable band, falling off as the ramp gets steep.
    static func loadSubscore(_ ratio: Double) -> Double {
        switch ratio {
        case ..<0.8:      return 0.90   // fresh, but freshness isn't fitness
        case 0.8..<1.2:   return 1.00
        case 1.2..<1.35:  return 0.80
        case 1.35..<1.5:  return 0.60
        case 1.5..<1.8:   return 0.40
        default:          return 0.20
        }
    }

    private static func normalizeScale(_ value: Int) -> Double {
        // 1–5 maps onto 0.2–1.0 so the worst answer isn't a hard zero.
        clamp(Double(value) / 5.0)
    }

    private static func clamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double {
        min(hi, max(lo, v))
    }

    /// Mean and standard deviation of a baseline window.
    struct Stats {
        let mean: Double
        let sd: Double
        let count: Int

        init?(values: [Double]) {
            guard values.count >= Readiness.minimumBaselineSamples else { return nil }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
            self.mean = mean
            self.sd = sqrt(variance)
            self.count = values.count
        }

        /// Guarded so a perfectly flat baseline can't divide by zero.
        func zScore(_ value: Double) -> Double {
            let denominator = max(sd, max(mean * 0.02, 0.5))
            return (value - mean) / denominator
        }
    }
}
