import Foundation

/// Swim-specific analysis. Swimmers think in per-100 m pace and stroke economy,
/// not per-kilometer pace.
enum SwimMetrics {

    struct Summary: Sendable, Equatable {
        let distance: Double            // meters
        let duration: TimeInterval
        /// Seconds per 100 m — the unit every swim set is written in.
        let pacePer100: Double
        /// Strokes per minute, when the stream carries cadence.
        let strokeRate: Double?
        /// Pool lengths, when the pool length is known.
        let lengths: Int?
        /// SWOLF: length time + strokes for that length. Lower is more efficient.
        let swolf: Double?

        var pacePer100Formatted: String {
            let total = Int(pacePer100.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        }
    }

    /// Build a swim summary.
    ///
    /// - Parameters:
    ///   - poolLength: meters per length, when known — enables lengths and SWOLF.
    static func summary(
        distance: Double,
        duration: TimeInterval,
        samples: [FITSample],
        poolLength: Double? = nil
    ) -> Summary? {
        guard distance > 0, duration > 0 else { return nil }

        let pacePer100 = duration / (distance / 100)

        // For swims, FIT reports stroke rate in the cadence field.
        let cadences = samples.compactMap(\.cadence).filter { $0 > 0 }
        let strokeRate = cadences.isEmpty
            ? nil
            : Double(cadences.reduce(0, +)) / Double(cadences.count)

        var lengths: Int?
        var swolf: Double?
        if let poolLength, poolLength > 0 {
            let count = Int((distance / poolLength).rounded())
            lengths = count
            if count > 0, let strokeRate {
                let secondsPerLength = duration / Double(count)
                // Strokes taken during one length, from the average rate.
                let strokesPerLength = strokeRate * (secondsPerLength / 60)
                swolf = secondsPerLength + strokesPerLength
            }
        }

        return Summary(
            distance: distance, duration: duration,
            pacePer100: pacePer100, strokeRate: strokeRate,
            lengths: lengths, swolf: swolf
        )
    }
}
