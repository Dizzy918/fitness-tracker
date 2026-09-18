import Foundation
import SwiftData

@Model
final class Exercise {
    var id: UUID = UUID()
    var name: String = ""
    var category: String = "accessory"   // squat|hinge|push|pull|carry|core|accessory
    var primaryMuscles: [String] = []
    var notes: String?

    /// The inverse of `SetEntry.exercise`.
    ///
    /// CloudKit refuses to load a store containing a relationship with no
    /// inverse, so this isn't optional decoration — without it the container
    /// falls back to local forever. Nullify, not cascade: deleting an exercise
    /// must never take logged sets with it.
    @Relationship(deleteRule: .nullify, inverse: \SetEntry.exercise)
    var setsStorage: [SetEntry]?

    /// Non-optional view; the stored side has to be optional for CloudKit.
    var sets: [SetEntry] {
        get { setsStorage ?? [] }
        set { setsStorage = newValue }
    }

    init(id: UUID = UUID(), name: String, category: String, primaryMuscles: [String] = []) {
        self.id = id
        self.name = name
        self.category = category
        self.primaryMuscles = primaryMuscles
    }
}

@Model
final class StrengthSession {
    var id: UUID = UUID()
    var startedAt: Date = Date.distantPast
    var endedAt: Date?
    var notes: String?

    @Relationship(deleteRule: .cascade, inverse: \SetEntry.session)
    var setsStorage: [SetEntry]?

    /// Non-optional view; the stored side has to be optional for CloudKit.
    var sets: [SetEntry] {
        get { setsStorage ?? [] }
        set { setsStorage = newValue }
    }

    init(id: UUID = UUID(), startedAt: Date = .now) {
        self.id = id
        self.startedAt = startedAt
    }

    /// Working sets only — warmups shouldn't inflate volume.
    var workingSets: [SetEntry] {
        sets.filter { !$0.isWarmup }.sorted { $0.order < $1.order }
    }

    /// Tonnage: Σ weight × reps over working sets.
    var totalVolume: Double {
        workingSets.reduce(0) { $0 + $1.weightKg * Double($1.reps) }
    }

    /// Distinct exercise names in the order first performed.
    var exerciseNames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for set in sets.sorted(by: { $0.order < $1.order }) {
            guard let name = set.exercise?.name, !seen.contains(name) else { continue }
            seen.insert(name)
            out.append(name)
        }
        return out
    }

    var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}

@Model
final class SetEntry {
    var id: UUID = UUID()
    var order: Int = 0
    var reps: Int = 0
    var weightKg: Double = 0
    var rpe: Double?          // 6.0 – 10.0
    var isWarmup: Bool = false

    var exercise: Exercise?
    var session: StrengthSession?

    init(
        id: UUID = UUID(),
        order: Int,
        reps: Int,
        weightKg: Double,
        rpe: Double? = nil,
        isWarmup: Bool = false,
        exercise: Exercise? = nil
    ) {
        self.id = id
        self.order = order
        self.reps = reps
        self.weightKg = weightKg
        self.rpe = rpe
        self.isWarmup = isWarmup
        self.exercise = exercise
    }

    /// Epley estimate. Only meaningful for rep counts roughly ≤ 12.
    var estimated1RM: Double {
        guard reps > 0 else { return 0 }
        return weightKg * (1 + Double(reps) / 30.0)
    }

    var volume: Double { weightKg * Double(reps) }

    var displayWeight: String {
        weightKg == weightKg.rounded()
            ? String(format: "%.0f kg", weightKg)
            : String(format: "%.1f kg", weightKg)
    }
}
