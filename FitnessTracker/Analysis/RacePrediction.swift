import Foundation

/// Race-time prediction and training paces derived from a known effort.
enum RacePrediction {

    /// Riegel's exponent. 1.06 is the classic value; it over-predicts for
    /// marathons off short-distance form, which is why long predictions carry a
    /// caveat in the UI.
    static let riegelExponent = 1.06

    struct Prediction: Identifiable, Sendable {
        let distance: Double        // meters
        let label: String
        let time: TimeInterval
        /// How far this extrapolates from the source effort. Above ~3× the
        /// prediction is optimistic.
        let extrapolationFactor: Double

        var id: String { label }
        var paceSecPerKm: Double { time / (distance / 1000) }
        var isSpeculative: Bool { extrapolationFactor > 3 || extrapolationFactor < 0.33 }
    }

    /// Predict a time at `target` from a known `time` over `distance`.
    ///
    /// T2 = T1 × (D2 / D1) ^ 1.06
    static func predict(time: TimeInterval, distance: Double, target: Double) -> TimeInterval? {
        guard time > 0, distance > 0, target > 0 else { return nil }
        return time * pow(target / distance, riegelExponent)
    }

    /// Predictions at standard distances from the best available effort.
    ///
    /// Uses the *longest* known best effort as the source: extrapolating up from
    /// a 1 km time wildly over-predicts marathon pace.
    static func predictions(from records: [PersonalRecord]) -> [Prediction] {
        guard let source = records.max(by: { $0.distance < $1.distance }) else { return [] }

        return PersonalRecords.distances.compactMap { target in
            guard abs(target.meters - source.distance) > 1 else { return nil }
            guard let time = predict(time: source.time,
                                     distance: source.distance,
                                     target: target.meters) else { return nil }
            return Prediction(
                distance: target.meters,
                label: target.label,
                time: time,
                extrapolationFactor: target.meters / source.distance
            )
        }
    }

    /// Training-pace bands derived from a threshold pace.
    struct TrainingPaces: Sendable {
        let easy: ClosedRange<Double>       // sec/km
        let steady: ClosedRange<Double>
        let tempo: ClosedRange<Double>
        let threshold: ClosedRange<Double>
        let interval: ClosedRange<Double>

        /// Multipliers on threshold pace. Slower paces are larger numbers.
        static func from(thresholdPaceSecPerKm t: Double) -> TrainingPaces {
            TrainingPaces(
                easy:      (t * 1.28)...(t * 1.45),
                steady:    (t * 1.15)...(t * 1.28),
                tempo:     (t * 1.06)...(t * 1.15),
                threshold: (t * 0.98)...(t * 1.06),
                interval:  (t * 0.88)...(t * 0.98)
            )
        }

        var bands: [(name: String, range: ClosedRange<Double>, purpose: String)] {
            [
                ("Easy", easy, "Most of your volume"),
                ("Steady", steady, "Aerobic development"),
                ("Tempo", tempo, "Comfortably hard"),
                ("Threshold", threshold, "~1 hour race effort"),
                ("Interval", interval, "VO₂max work"),
            ]
        }
    }

    /// Threshold pace estimated from a best effort, then bands from that.
    ///
    /// A 10 km time is close to threshold for most runners; other distances are
    /// converted to a 10 km equivalent first.
    static func trainingPaces(from records: [PersonalRecord]) -> TrainingPaces? {
        guard let source = records.max(by: { $0.distance < $1.distance }) else { return nil }
        guard let tenKTime = predict(time: source.time,
                                     distance: source.distance,
                                     target: 10_000) else { return nil }
        return TrainingPaces.from(thresholdPaceSecPerKm: tenKTime / 10)
    }
}
