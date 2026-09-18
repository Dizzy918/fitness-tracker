import Foundation

/// The mean-maximal curve: your best effort at every duration.
///
/// The app already finds best efforts at five fixed race distances, which
/// answers "how fast is my 10 km" and nothing else. The curve answers the
/// question a training block is actually judged on — *which part* of your range
/// moved. A sprinter's curve and a marathoner's can cross at 20 minutes and look
/// identical at that one point while being completely different athletes.
///
/// This is the standard view in TrainingPeaks, intervals.icu and Golden Cheetah,
/// and the reason it's worth having is comparison: this season's curve laid over
/// last season's shows where the work went.
enum DurationCurve {

    /// Durations the curve is sampled at, spaced roughly logarithmically
    /// because that's how the underlying physiology separates — the interesting
    /// distinctions are 5s vs 30s and 20min vs 60min, not 41 vs 42 minutes.
    static let durations: [TimeInterval] = [
        5, 15, 30, 60, 120, 300, 600, 1_200, 1_800, 3_600, 5_400, 10_800,
    ]

    static func label(for duration: TimeInterval) -> String {
        switch duration {
        case ..<60:   return "\(Int(duration))s"
        case ..<3600: return "\(Int(duration / 60))m"
        default:
            let hours = duration / 3600
            return hours == hours.rounded()
                ? "\(Int(hours))h"
                : String(format: "%.1fh", hours)
        }
    }

    struct Point: Sendable, Identifiable, Equatable {
        let duration: TimeInterval
        /// Watts for power, seconds-per-kilometre for pace.
        let value: Double
        /// Which session produced it, so a suspicious point can be inspected.
        let workoutID: UUID
        let date: Date

        var id: TimeInterval { duration }
        var label: String { DurationCurve.label(for: duration) }
    }

    /// What the curve is measuring. They're read the opposite way round —
    /// higher power is better, lower pace is better — which the chart has to
    /// know about.
    enum Metric: String, CaseIterable, Identifiable, Sendable {
        case power, pace

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .power: return "Power"
            case .pace:  return "Pace"
            }
        }

        /// True when a bigger number is a better effort.
        var higherIsBetter: Bool { self == .power }

        var sports: [WorkoutSport] {
            switch self {
            case .power: return [.bike]
            case .pace:  return [.run, .trailRun]
            }
        }
    }

    /// Best power at each duration across a set of workouts.
    ///
    /// Expensive — decodes every stream and sweeps it once per duration — so
    /// call it off the main actor.
    static func power(from workouts: [WorkoutSnapshot]) -> [Point] {
        curve(from: workouts, metric: .power) { samples, duration in
            StreamStatistics.bestAveragePower(seconds: duration, in: samples)
        }
    }

    /// Best pace at each duration, in seconds per kilometre.
    ///
    /// Derived from distance covered rather than the speed channel, and
    /// inverted: the *furthest* you went in 20 minutes is the *fastest* pace you
    /// held for 20 minutes.
    static func pace(from workouts: [WorkoutSnapshot]) -> [Point] {
        curve(from: workouts, metric: .pace) { samples, duration in
            guard let metres = StreamStatistics.bestDistance(seconds: duration, in: samples),
                  metres > 0
            else { return nil }
            return duration / (metres / 1000)
        }
    }

    private static func curve(
        from workouts: [WorkoutSnapshot],
        metric: Metric,
        best: ([FITSample], TimeInterval) -> Double?
    ) -> [Point] {
        var bestByDuration: [TimeInterval: Point] = [:]

        for workout in workouts where metric.sports.contains(workout.sport) {
            let samples = workout.samples
            guard samples.count >= 2 else { continue }

            for duration in durations {
                // A workout shorter than the window can't contribute to it, and
                // checking here skips a sweep that would return nil anyway.
                guard workout.duration >= duration * 0.9 else { continue }
                guard let value = best(samples, duration) else { continue }

                let improves = bestByDuration[duration].map {
                    metric.higherIsBetter ? value > $0.value : value < $0.value
                } ?? true
                if improves {
                    bestByDuration[duration] = Point(
                        duration: duration, value: value,
                        workoutID: workout.id, date: workout.startedAt)
                }
            }
        }
        return durations.compactMap { bestByDuration[$0] }
    }

    /// Two curves over different windows, for comparison.
    struct Comparison: Sendable {
        let current: [Point]
        let previous: [Point]
        let metric: Metric

        var isEmpty: Bool { current.isEmpty && previous.isEmpty }

        /// Change at one duration, as a percentage, positive meaning better.
        ///
        /// Signed by *improvement*, not by raw arithmetic — a pace that dropped
        /// from 4:00 to 3:50 is a gain, and reporting it as −4% would read as a
        /// loss at a glance.
        func change(at duration: TimeInterval) -> Double? {
            guard let now = current.first(where: { $0.duration == duration }),
                  let then = previous.first(where: { $0.duration == duration }),
                  then.value > 0
            else { return nil }
            let raw = (now.value - then.value) / then.value
            return metric.higherIsBetter ? raw : -raw
        }

        /// Where the biggest improvement is, which is the question the whole
        /// comparison exists to answer.
        var largestGain: (duration: TimeInterval, change: Double)? {
            let changes = current.compactMap { point in
                change(at: point.duration).map { (point.duration, $0) }
            }
            return changes.max { $0.1 < $1.1 }.flatMap { $0.1 > 0.01 ? $0 : nil }
        }
    }

    /// Build the current window against the one immediately before it.
    static func compare(
        workouts: [WorkoutSnapshot],
        metric: Metric,
        days: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Comparison {
        let start = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        let previousStart = calendar.date(byAdding: .day, value: -days * 2, to: now) ?? now

        let build: ([WorkoutSnapshot]) -> [Point] = metric == .power ? power : pace
        return Comparison(
            current: build(workouts.filter { $0.startedAt >= start }),
            previous: build(workouts.filter {
                $0.startedAt >= previousStart && $0.startedAt < start
            }),
            metric: metric)
    }
}
