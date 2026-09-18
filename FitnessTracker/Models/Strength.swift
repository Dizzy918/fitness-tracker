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

    /// The inverse of `RoutineItem.exercise`. Same reason as `setsStorage`:
    /// CloudKit refuses a relationship with no inverse. Nullify — deleting an
    /// exercise shouldn't silently gut every routine that used it.
    @Relationship(deleteRule: .nullify, inverse: \RoutineItem.exercise)
    var routineItemsStorage: [RoutineItem]?

    var routineItems: [RoutineItem] {
        get { routineItemsStorage ?? [] }
        set { routineItemsStorage = newValue }
    }

    /// How long this lift usually wants between sets. A heavy triple and a set
    /// of curls are not the same wait, and one global default gets one of them
    /// wrong every time.
    var defaultRestSeconds: Int = 120

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

    /// Which routine this was started from, if any.
    ///
    /// An id and a name rather than a relationship, for the same reason
    /// `PlannedWorkout` keeps one: a session is a record of what happened, and
    /// editing or deleting the routine afterwards must not rewrite history.
    /// The name is copied because that's what the routine was *called* at the
    /// time, which is the useful thing to show.
    var routineID: UUID?
    var routineName: String?

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

    /// Working sets actually performed.
    ///
    /// A session started from a routine is written out in full up front, so
    /// "the sets in this session" and "the sets you have done" stop being the
    /// same list the moment a routine is involved.
    var completedWorkingSets: [SetEntry] {
        workingSets.filter { !$0.isPending }
    }

    /// Sets written out by a routine and not yet done, in the order to do them.
    var pendingSets: [SetEntry] {
        sets.filter(\.isPending).sorted { $0.order < $1.order }
    }

    /// The next set to perform, or nil once the session is worked through.
    var nextPendingSet: SetEntry? { pendingSets.first }

    /// Tonnage: Σ weight × reps over working sets that were actually done.
    var totalVolume: Double {
        completedWorkingSets.reduce(0) { $0 + $1.weightKg * Double($1.reps) }
    }

    /// Fraction of the prescribed working sets completed, or nil where nothing
    /// was prescribed — an unplanned session has no denominator and showing it
    /// as 100% done would be meaningless rather than encouraging.
    var completionFraction: Double? {
        let planned = workingSets.count
        guard planned > 0, !pendingSets.isEmpty || routineID != nil else { return nil }
        return Double(completedWorkingSets.count) / Double(planned)
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

    /// Prescribed by a routine but not yet performed.
    ///
    /// Defaults to false so every set logged the ordinary way — and every set
    /// already in the store — counts as done without a migration.
    var isPending: Bool = false
    /// When the set was actually completed, for the rest timer and for
    /// reconstructing the session's shape afterwards.
    var completedAt: Date?
    /// Rest owed after this set, carried from the routine that prescribed it.
    var restSeconds: Int?
    /// Set when this was performed as part of a superset. See
    /// `RoutineItem.supersetGroup`.
    var supersetGroup: Int?

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

    /// Mark the set done, as logged rather than as prescribed.
    func complete(at date: Date = .now) {
        isPending = false
        completedAt = date
    }

    var displayWeight: String {
        weightKg == weightKg.rounded()
            ? String(format: "%.0f kg", weightKg)
            : String(format: "%.1f kg", weightKg)
    }
}
