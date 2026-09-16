import Foundation

/// Fastest continuous effort over a target distance within one workout.
enum BestEffort {

    /// Minimum time to cover `distance` anywhere inside the sample stream.
    ///
    /// A two-pointer sweep over cumulative distance, interpolating the window
    /// start so the answer isn't quantized to sample boundaries. Returns nil if
    /// the workout never covers the distance.
    static func fastestTime(forDistance distance: Double, in samples: [FITSample]) -> TimeInterval? {
        guard distance > 0 else { return nil }

        // Usable samples: cumulative distance, non-decreasing, ordered by time.
        let points: [(t: TimeInterval, d: Double)] = samples
            .compactMap { s in s.dist.map { (s.t, $0) } }
            .sorted { $0.0 < $1.0 }
        guard points.count >= 2, let total = points.last?.d, total >= distance else {
            return nil
        }

        var best: TimeInterval?
        var start = 0

        for end in 1..<points.count {
            // Advance the start pointer while the window still spans `distance`.
            while start + 1 < end,
                  points[end].d - points[start + 1].d >= distance {
                start += 1
            }
            let span = points[end].d - points[start].d
            guard span >= distance else { continue }

            // Interpolate the exact point where the window is `distance` long.
            let targetStartDistance = points[end].d - distance
            let a = points[start], b = points[start + 1]
            let startTime: TimeInterval
            if b.d > a.d {
                let fraction = (targetStartDistance - a.d) / (b.d - a.d)
                startTime = a.t + fraction.clampedUnit * (b.t - a.t)
            } else {
                startTime = a.t
            }

            let elapsed = points[end].t - startTime
            if elapsed > 0, best == nil || elapsed < best! {
                best = elapsed
            }
        }
        return best
    }
}

private extension Double {
    /// Interpolation factors can drift slightly outside 0…1 on noisy data.
    var clampedUnit: Double { min(1, max(0, self)) }
}

/// An immutable, `Sendable` copy of the fields record computation needs.
///
/// SwiftData models are bound to their context and must never cross an actor
/// boundary — doing so crashes with "this model instance was destroyed". The raw
/// stream blob is carried undecoded so the expensive JSON work still happens on
/// the background task rather than the main actor.
struct WorkoutSnapshot: Sendable, Identifiable {
    let id: UUID
    let sport: WorkoutSport
    let startedAt: Date
    let distance: Double
    let duration: TimeInterval
    let elevationGain: Double?
    let avgHeartRate: Int?
    let maxHeartRate: Int?
    let streamsData: Data?

    init(
        id: UUID,
        sport: WorkoutSport,
        startedAt: Date,
        distance: Double,
        duration: TimeInterval,
        elevationGain: Double? = nil,
        avgHeartRate: Int? = nil,
        maxHeartRate: Int? = nil,
        streamsData: Data? = nil
    ) {
        self.id = id
        self.sport = sport
        self.startedAt = startedAt
        self.distance = distance
        self.duration = duration
        self.elevationGain = elevationGain
        self.avgHeartRate = avgHeartRate
        self.maxHeartRate = maxHeartRate
        self.streamsData = streamsData
    }

    var samples: [FITSample] {
        guard let streamsData else { return [] }
        return (try? JSONDecoder().decode([FITSample].self, from: streamsData)) ?? []
    }

    /// Foot-based sports, where distance means the same thing across sessions.
    var isFootSport: Bool { [.run, .trailRun].contains(sport) }
}

extension Workout {
    /// Cheap to build: copies scalars and retains the blob without decoding it.
    var snapshot: WorkoutSnapshot {
        WorkoutSnapshot(
            id: id, sport: sport, startedAt: startedAt,
            distance: distance, duration: duration,
            elevationGain: elevationGain,
            avgHeartRate: avgHeartRate, maxHeartRate: maxHeartRate,
            streamsData: streamsData
        )
    }
}

/// A personal best over a standard distance.
struct PersonalRecord: Identifiable, Sendable {
    let distance: Double        // meters
    let label: String
    let time: TimeInterval
    let date: Date
    let workoutID: UUID

    var id: String { label }
    var paceSecPerKm: Double { time / (distance / 1000) }
}

enum PersonalRecords {

    /// Standard race distances worth tracking.
    static let distances: [(meters: Double, label: String)] = [
        (1_000, "1 km"),
        (5_000, "5 km"),
        (10_000, "10 km"),
        (21_097.5, "Half marathon"),
        (42_195, "Marathon"),
    ]

    /// Best effort per distance across every foot-based workout with streams.
    ///
    /// Expensive — decodes each workout's sample blob — so call it off the main
    /// thread and cache the result.
    static func compute(from workouts: [WorkoutSnapshot]) -> [PersonalRecord] {
        var best: [String: PersonalRecord] = [:]

        for workout in workouts {
            // Comparing a bike split to a run split isn't meaningful.
            guard [.run, .trailRun].contains(workout.sport) else { continue }
            let samples = workout.samples
            guard samples.count >= 2 else { continue }

            for (meters, label) in distances where workout.distance >= meters {
                guard let time = BestEffort.fastestTime(forDistance: meters, in: samples)
                else { continue }
                if let existing = best[label], existing.time <= time { continue }
                best[label] = PersonalRecord(
                    distance: meters, label: label, time: time,
                    date: workout.startedAt, workoutID: workout.id
                )
            }
        }

        return distances.compactMap { best[$0.label] }
    }

    /// Headline totals that don't need stream data.
    ///
    /// Distance milestones are **per sport**: an 80 km ride and a 20 km run are
    /// not comparable, and reporting the ride as a "longest run" — which the
    /// all-sports version did — is simply wrong. Lifetime totals stay across
    /// everything, because "how far have I moved" is a fair question.
    struct Milestones: Sendable {
        var longestRun: (distance: Double, date: Date)?
        var longestRide: (distance: Double, date: Date)?
        var longestSwim: (distance: Double, date: Date)?
        /// Biggest running week — the number a runner actually tracks.
        var biggestWeek: (distance: Double, weekStart: Date)?
        var mostElevation: (gain: Double, date: Date)?
        var totalDistance: Double = 0
        var totalWorkouts: Int = 0
    }

    static func milestones(from workouts: [WorkoutSnapshot]) -> Milestones {
        var out = Milestones()
        out.totalWorkouts = workouts.count
        out.totalDistance = workouts.reduce(0) { $0 + $1.distance }

        func longest(_ matching: (WorkoutSnapshot) -> Bool) -> (Double, Date)? {
            guard let best = workouts.filter(matching).max(by: { $0.distance < $1.distance }),
                  best.distance > 0
            else { return nil }
            return (best.distance, best.startedAt)
        }

        out.longestRun = longest { $0.isFootSport }
        out.longestRide = longest { $0.sport == .bike }
        out.longestSwim = longest { $0.sport == .swim }

        if let climb = workouts
            .compactMap({ w in (w.elevationGain ?? 0) > 0 ? w : nil })
            .max(by: { ($0.elevationGain ?? 0) < ($1.elevationGain ?? 0) }) {
            out.mostElevation = (climb.elevationGain ?? 0, climb.startedAt)
        }

        let calendar = Calendar.current
        let byWeek = Dictionary(grouping: workouts.filter(\.isFootSport)) { w in
            calendar.dateInterval(of: .weekOfYear, for: w.startedAt)?.start ?? w.startedAt
        }
        if let heaviest = byWeek
            .map({ (week: $0.key, total: $0.value.reduce(0) { $0 + $1.distance }) })
            .max(by: { $0.total < $1.total }), heaviest.total > 0 {
            out.biggestWeek = (heaviest.total, heaviest.week)
        }
        return out
    }
}
