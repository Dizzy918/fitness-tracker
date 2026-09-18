import Foundation

/// Sliding-window statistics over a sample stream.
///
/// Extracted because the same two-pointer sweep answers "best average power
/// over 20 minutes" and "best average heart rate over 20 minutes", and a subtle
/// windowing algorithm duplicated in two places is one that drifts.
enum StreamStatistics {

    /// Best average of `channel` over any window of `target` seconds.
    ///
    /// - Parameters:
    ///   - target: window length in seconds.
    ///   - channel: pulls the value out of a sample; samples where it returns
    ///     nil are excluded entirely rather than counted as zero.
    /// - Returns: nil when the stream is shorter than the window.
    static func bestAverage(
        seconds target: TimeInterval,
        of channel: (FITSample) -> Double?,
        in samples: [FITSample]
    ) -> Double? {
        guard target > 0 else { return nil }

        let points: [(t: TimeInterval, value: Double)] = samples
            .compactMap { sample in channel(sample).map { (sample.t, $0) } }
            .sorted { $0.0 < $1.0 }
        guard points.count >= 2,
              let first = points.first, let last = points.last,
              (last.t - first.t) >= target
        else { return nil }

        var best: Double?
        var start = 0
        var sum = 0.0

        for end in points.indices {
            sum += points[end].value
            // Shrink from the left until the window is no longer than target.
            while start < end, points[end].t - points[start].t > target {
                sum -= points[start].value
                start += 1
            }
            let span = points[end].t - points[start].t
            // 0.9 tolerance: a 1 Hz stream can't land exactly on the boundary,
            // and rejecting a 1198-second window from a 1200-second target
            // would throw away the answer.
            guard span >= target * 0.9 else { continue }
            let average = sum / Double(end - start + 1)
            if best == nil || average > best! { best = average }
        }
        return best
    }

    /// Best average power over a window.
    static func bestAveragePower(seconds: TimeInterval, in samples: [FITSample]) -> Double? {
        bestAverage(seconds: seconds, of: { $0.power.map(Double.init) }, in: samples)
    }

    /// Best average heart rate over a window.
    static func bestAverageHeartRate(seconds: TimeInterval, in samples: [FITSample]) -> Double? {
        bestAverage(seconds: seconds, of: { $0.hr.map(Double.init) }, in: samples)
    }

    /// Furthest distance covered in any window of `target` seconds.
    ///
    /// Read off cumulative distance rather than averaging the speed channel:
    /// speed is a smoothed, derived value and averaging it over a window
    /// compounds that smoothing, while the distance delta is what actually
    /// happened.
    static func bestDistance(seconds target: TimeInterval, in samples: [FITSample]) -> Double? {
        guard target > 0 else { return nil }

        let points: [(t: TimeInterval, d: Double)] = samples
            .compactMap { sample in sample.dist.map { (sample.t, $0) } }
            .sorted { $0.0 < $1.0 }
        guard points.count >= 2,
              let first = points.first, let last = points.last,
              (last.t - first.t) >= target
        else { return nil }

        var best: Double?
        var start = 0

        for end in points.indices {
            // Advance the start while the window is still longer than target,
            // keeping the widest window that fits.
            while start + 1 < end, points[end].t - points[start + 1].t >= target {
                start += 1
            }
            let span = points[end].t - points[start].t
            guard span >= target * 0.9 else { continue }
            let covered = points[end].d - points[start].d
            // A negative delta is a distance reset mid-file, not a teleport.
            guard covered > 0 else { continue }
            if best == nil || covered > best! { best = covered }
        }
        return best
    }
}
