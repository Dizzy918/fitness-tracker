import Foundation

/// Five-zone heart-rate model as a percentage of max HR.
///
/// Percent-of-max is the simplest defensible split and needs only one input the
/// user actually knows. Lactate-threshold zones would be better but need a test
/// result most people don't have.
struct HRZones: Sendable {
    let maxHR: Int

    /// Lower bound of each zone as a fraction of max HR.
    static let bounds: [Double] = [0.50, 0.60, 0.70, 0.80, 0.90]

    static let names = ["Recovery", "Easy", "Aerobic", "Threshold", "VO₂max"]

    init(maxHR: Int) {
        self.maxHR = max(maxHR, 100)
    }

    /// Zone 1–5, or nil below zone 1.
    func zone(for bpm: Int) -> Int? {
        let fraction = Double(bpm) / Double(maxHR)
        guard fraction >= Self.bounds[0] else { return nil }
        // Walk down so the highest matching bound wins.
        for (index, bound) in Self.bounds.enumerated().reversed() {
            if fraction >= bound { return index + 1 }
        }
        return nil
    }

    func range(for zone: Int) -> ClosedRange<Int>? {
        guard (1...5).contains(zone) else { return nil }
        let lower = Int((Self.bounds[zone - 1] * Double(maxHR)).rounded())
        let upper = zone == 5
            ? maxHR
            : Int((Self.bounds[zone] * Double(maxHR)).rounded()) - 1
        return lower...max(lower, upper)
    }

    /// Seconds spent in each zone (1–5). Samples without HR are skipped, and the
    /// interval is measured to the next sample so gaps don't inflate totals.
    func timeInZones(_ samples: [FITSample]) -> [Int: TimeInterval] {
        let ordered = samples.sorted { $0.t < $1.t }
        var totals: [Int: TimeInterval] = [:]

        // Each sample covers the interval until the next one. The final sample
        // covers nothing measurable — extrapolating it would let the zone totals
        // exceed the workout's elapsed time, which is never correct.
        for index in ordered.indices.dropLast() {
            let sample = ordered[index]
            guard let hr = sample.hr, let zone = zone(for: hr) else { continue }
            let dt = ordered[index + 1].t - sample.t
            // A long gap is a recording dropout, not 20 minutes at that HR.
            guard dt > 0, dt <= 60 else { continue }
            totals[zone, default: 0] += dt
        }
        return totals
    }

    /// Highest HR seen across a workout history — a usable default when the user
    /// hasn't entered their own max.
    static func observedMax(in workouts: [Workout]) -> Int? {
        workouts.compactMap { $0.maxHeartRate }.max()
    }
}
