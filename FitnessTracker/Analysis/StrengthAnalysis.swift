import Foundation

/// Strength-training analysis over logged sessions.
enum StrengthAnalysis {

    /// Movement patterns, in the order a program usually prioritizes them.
    static let categories = ["squat", "hinge", "push", "pull", "carry", "core", "accessory"]

    struct CategoryVolume: Identifiable, Sendable {
        let category: String
        let volume: Double      // kg lifted (weight × reps)
        let sets: Int
        var id: String { category }
    }

    /// Working-set volume per movement pattern within a window.
    ///
    /// Warmups are excluded — counting them would reward long ramp-ups.
    static func volumeByCategory(
        sessions: [StrengthSessionSnapshot],
        since: Date? = nil
    ) -> [CategoryVolume] {
        var volumes: [String: (volume: Double, sets: Int)] = [:]

        for session in sessions {
            if let since, session.startedAt < since { continue }
            for set in session.sets where !set.isWarmup {
                let key = set.category ?? "accessory"
                var entry = volumes[key] ?? (0, 0)
                entry.volume += set.weightKg * Double(set.reps)
                entry.sets += 1
                volumes[key] = entry
            }
        }

        // Keep the canonical order, then any custom categories alphabetically.
        let known = categories.compactMap { key -> CategoryVolume? in
            guard let entry = volumes[key] else { return nil }
            return CategoryVolume(category: key, volume: entry.volume, sets: entry.sets)
        }
        let extra = volumes.keys
            .filter { !categories.contains($0) }
            .sorted()
            .compactMap { key -> CategoryVolume? in
                guard let entry = volumes[key] else { return nil }
                return CategoryVolume(category: key, volume: entry.volume, sets: entry.sets)
            }
        return known + extra
    }

    /// Weekly tonnage, oldest first, for a volume trend chart.
    static func weeklyVolume(sessions: [StrengthSessionSnapshot]) -> [(weekStart: Date, volume: Double)] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sessions) { session in
            calendar.dateInterval(of: .weekOfYear, for: session.startedAt)?.start
                ?? session.startedAt
        }
        return grouped
            .map { (weekStart: $0.key,
                    volume: $0.value.reduce(0.0) { total, session in
                        total + session.sets.filter { !$0.isWarmup }
                            .reduce(0.0) { $0 + $1.weightKg * Double($1.reps) }
                    }) }
            .sorted { $0.weekStart < $1.weekStart }
    }

    /// Progression of best working-set e1RM per session for one exercise.
    static func e1RMHistory(
        sessions: [StrengthSessionSnapshot],
        exerciseID: UUID
    ) -> [(date: Date, e1rm: Double)] {
        sessions.compactMap { session in
            let best = session.sets
                .filter { !$0.isWarmup && $0.exerciseID == exerciseID }
                .map { $0.weightKg * (1 + Double($0.reps) / 30.0) }
                .max()
            guard let best else { return nil }
            return (session.startedAt, best)
        }
        .sorted { $0.date < $1.date }
    }

    /// Sessions where an exercise hit a new best e1RM — the PR moments.
    static func personalRecordDates(
        sessions: [StrengthSessionSnapshot],
        exerciseID: UUID
    ) -> [(date: Date, e1rm: Double)] {
        var records: [(Date, Double)] = []
        var best = 0.0
        for point in e1RMHistory(sessions: sessions, exerciseID: exerciseID) {
            if point.e1rm > best {
                best = point.e1rm
                records.append((point.date, point.e1rm))
            }
        }
        return records
    }
}

/// Sendable copies so strength analysis can run off the main actor.
struct StrengthSetSnapshot: Sendable {
    let reps: Int
    let weightKg: Double
    let isWarmup: Bool
    let exerciseID: UUID?
    let category: String?
    /// Rate of perceived exertion, 6–10. The only intensity signal a lifter
    /// reliably records, so training load leans on it.
    let rpe: Double?

    init(reps: Int, weightKg: Double, isWarmup: Bool,
         exerciseID: UUID?, category: String?, rpe: Double? = nil) {
        self.reps = reps
        self.weightKg = weightKg
        self.isWarmup = isWarmup
        self.exerciseID = exerciseID
        self.category = category
        self.rpe = rpe
    }
}

struct StrengthSessionSnapshot: Sendable {
    let id: UUID
    let startedAt: Date
    let sets: [StrengthSetSnapshot]
    /// Wall-clock length, when the session was closed out.
    let duration: TimeInterval?

    init(id: UUID, startedAt: Date, sets: [StrengthSetSnapshot], duration: TimeInterval? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.sets = sets
        self.duration = duration
    }
}

extension StrengthSession {
    var snapshot: StrengthSessionSnapshot {
        StrengthSessionSnapshot(
            id: id,
            startedAt: startedAt,
            sets: sets.map { set in
                StrengthSetSnapshot(
                    reps: set.reps, weightKg: set.weightKg, isWarmup: set.isWarmup,
                    exerciseID: set.exercise?.id, category: set.exercise?.category,
                    rpe: set.rpe
                )
            },
            duration: duration
        )
    }
}
