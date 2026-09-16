import Foundation

/// One split (default: one kilometer) derived from a workout's sample stream.
struct Split: Identifiable, Sendable {
    let index: Int          // 0-based
    let distance: Double    // meters covered in this split (< splitMeters if partial)
    let duration: TimeInterval
    let avgHR: Int?
    let elevationGain: Double?
    let isPartial: Bool

    var id: Int { index }

    /// Human label: "1", "2", … or "0.4" for the trailing partial split.
    var label: String {
        isPartial ? String(format: "%.2f", distance / 1000) : "\(index + 1)"
    }

    var paceSecPerKm: Double? {
        guard distance > 0, duration > 0 else { return nil }
        return duration / (distance / 1000)
    }
}

enum SplitCalculator {

    /// Compute splits from a sample stream.
    ///
    /// Requires cumulative `dist` on samples (FIT records provide it). Boundary
    /// crossings are linearly interpolated between the two bracketing samples,
    /// so a 1 Hz stream still yields accurate per-km times.
    static func splits(from samples: [FITSample], splitMeters: Double = 1000) -> [Split] {
        guard splitMeters > 0 else { return [] }

        // Only samples carrying cumulative distance are usable, and distance
        // must be non-decreasing for interpolation to be meaningful.
        let usable = samples
            .filter { $0.dist != nil }
            .sorted { $0.t < $1.t }
        guard usable.count >= 2 else { return [] }

        var result: [Split] = []
        var boundary = splitMeters
        var splitStartTime = usable[0].t
        var splitStartDist = usable[0].dist ?? 0
        var splitStartAlt = usable[0].alt
        var hrAccumulator: [Int] = []
        var gain: Double = 0
        var lastAlt = usable[0].alt

        for i in 1..<usable.count {
            let prev = usable[i - 1]
            let cur = usable[i]
            guard let prevDist = prev.dist, let curDist = cur.dist else { continue }

            if let hr = cur.hr { hrAccumulator.append(hr) }
            if let alt = cur.alt {
                if let last = lastAlt, alt > last { gain += (alt - last) }
                lastAlt = alt
            }

            // A single sample gap can span more than one boundary (GPS dropout).
            while curDist >= boundary, curDist > prevDist {
                let fraction = (boundary - prevDist) / (curDist - prevDist)
                let tAtBoundary = prev.t + fraction * (cur.t - prev.t)

                result.append(Split(
                    index: result.count,
                    distance: boundary - splitStartDist,
                    duration: tAtBoundary - splitStartTime,
                    avgHR: hrAccumulator.isEmpty
                        ? nil
                        : Int((Double(hrAccumulator.reduce(0, +)) / Double(hrAccumulator.count)).rounded()),
                    elevationGain: gain > 0 ? gain : nil,
                    isPartial: false
                ))

                splitStartTime = tAtBoundary
                splitStartDist = boundary
                splitStartAlt = cur.alt
                hrAccumulator.removeAll(keepingCapacity: true)
                gain = 0
                boundary += splitMeters
            }
        }

        // Trailing remainder, if it's meaningful (>10 m avoids noise splits).
        if let last = usable.last, let lastDist = last.dist {
            let remaining = lastDist - splitStartDist
            if remaining > 10 {
                result.append(Split(
                    index: result.count,
                    distance: remaining,
                    duration: last.t - splitStartTime,
                    avgHR: hrAccumulator.isEmpty
                        ? nil
                        : Int((Double(hrAccumulator.reduce(0, +)) / Double(hrAccumulator.count)).rounded()),
                    elevationGain: gain > 0 ? gain : nil,
                    isPartial: true
                ))
            }
        }

        _ = splitStartAlt   // reserved for per-split net elevation
        return result
    }

    /// Fastest full split, for highlighting in the UI.
    static func fastest(_ splits: [Split]) -> Split? {
        splits.filter { !$0.isPartial }.min {
            ($0.paceSecPerKm ?? .infinity) < ($1.paceSecPerKm ?? .infinity)
        }
    }
}
