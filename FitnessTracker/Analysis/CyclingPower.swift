import Foundation

/// Power-based cycling analysis.
///
/// Normalized Power, Intensity Factor and TSS are the standard trio: NP weights
/// hard surges more heavily than a plain average, IF expresses NP relative to
/// threshold, and TSS turns that into a single training-cost number.
enum CyclingPower {

    struct Summary: Sendable, Equatable {
        let averagePower: Double        // watts
        let normalizedPower: Double     // watts
        let intensityFactor: Double?    // NP / FTP
        let trainingStressScore: Double?
        let maxPower: Double
        let durationSeconds: TimeInterval
        /// NP / average — how "spiky" the ride was. 1.0 is perfectly steady.
        let variabilityIndex: Double

        /// Power-to-weight, when the athlete's weight is known.
        func wattsPerKg(_ bodyWeightKg: Double?) -> Double? {
            guard let bodyWeightKg, bodyWeightKg > 0 else { return nil }
            return averagePower / bodyWeightKg
        }

    }

    /// Rolling window for NP, per Coggan's definition.
    static let rollingWindowSeconds: TimeInterval = 30

    /// Compute a power summary. Returns nil when the stream has no power data.
    ///
    /// - Parameters:
    ///   - samples: workout stream; samples without power are ignored.
    ///   - ftp: functional threshold power, if the user has set one.
    static func summary(samples: [FITSample], ftp: Int?) -> Summary? {
        let ordered = samples
            .filter { $0.power != nil }
            .sorted { $0.t < $1.t }
        guard ordered.count >= 2 else { return nil }

        let powers = ordered.map { Double($0.power ?? 0) }
        let average = powers.reduce(0, +) / Double(powers.count)
        let maxPower = powers.max() ?? 0
        let duration = (ordered.last?.t ?? 0) - (ordered.first?.t ?? 0)

        let np = normalizedPower(samples: ordered)
        let intensityFactor = ftp.flatMap { $0 > 0 ? np / Double($0) : nil }
        let tss = intensityFactor.map { intensity in
            // TSS = (seconds × NP × IF) / (FTP × 3600) × 100
            duration * np * intensity / (Double(ftp ?? 1) * 3600) * 100
        }

        return Summary(
            averagePower: average,
            normalizedPower: np,
            intensityFactor: intensityFactor,
            trainingStressScore: tss,
            maxPower: maxPower,
            durationSeconds: duration,
            variabilityIndex: average > 0 ? np / average : 1
        )
    }

    /// Normalized Power: 30-second rolling average, then the fourth root of the
    /// mean of those values raised to the fourth power.
    static func normalizedPower(samples: [FITSample]) -> Double {
        let ordered = samples.filter { $0.power != nil }.sorted { $0.t < $1.t }
        guard !ordered.isEmpty else { return 0 }

        var rollingValues: [Double] = []
        var windowStart = 0

        for (index, sample) in ordered.enumerated() {
            // Advance the window start until it's within 30 s of this sample.
            while windowStart < index,
                  sample.t - ordered[windowStart].t > rollingWindowSeconds {
                windowStart += 1
            }
            let window = ordered[windowStart...index]
            let mean = window.reduce(0.0) { $0 + Double($1.power ?? 0) } / Double(window.count)
            rollingValues.append(mean)
        }

        let fourthPowerMean = rollingValues.reduce(0.0) { $0 + pow($1, 4) }
            / Double(rollingValues.count)
        return pow(fourthPowerMean, 0.25)
    }

    /// Best average power over a duration — the shape of a power-duration curve.
    static func bestAverage(seconds target: TimeInterval, samples: [FITSample]) -> Double? {
        let ordered = samples.filter { $0.power != nil }.sorted { $0.t < $1.t }
        guard ordered.count >= 2, target > 0 else { return nil }
        guard (ordered.last!.t - ordered.first!.t) >= target else { return nil }

        var best: Double?
        var start = 0
        var sum = 0.0

        for end in ordered.indices {
            sum += Double(ordered[end].power ?? 0)
            // Shrink from the left until the window is no longer than target.
            while start < end, ordered[end].t - ordered[start].t > target {
                sum -= Double(ordered[start].power ?? 0)
                start += 1
            }
            let span = ordered[end].t - ordered[start].t
            guard span >= target * 0.9 else { continue }
            let count = Double(end - start + 1)
            let average = sum / count
            if best == nil || average > best! { best = average }
        }
        return best
    }
}
