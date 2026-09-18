import Foundation
import SwiftData

/// A saved session you intend to repeat.
///
/// Logging worked, but every gym session started from nothing: pick the
/// exercise, pick the reps, pick the weight, remember what you did last Monday.
/// A programme is by definition the same handful of sessions on rotation, so
/// re-entering one from memory each time is the app failing to hold the thing
/// it's best placed to hold.
///
/// Deliberately a *template*, not a prescription. Starting a session from a
/// routine writes out the sets it calls for and then gets out of the way — you
/// edit the actuals as you lift, and what's recorded is what you did.
@Model
final class Routine {
    var id: UUID = UUID()
    var name: String = ""
    var notes: String?
    var createdAt: Date = Date.distantPast
    /// When a session was last started from this, so the list can put the
    /// routine you're actually running at the top.
    var lastUsedAt: Date?
    var useCount: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \RoutineItem.routine)
    var itemsStorage: [RoutineItem]?

    /// Non-optional view; the stored side has to be optional for CloudKit.
    var items: [RoutineItem] {
        get { itemsStorage ?? [] }
        set { itemsStorage = newValue }
    }

    init(id: UUID = UUID(), name: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }

    var orderedItems: [RoutineItem] {
        items.sorted { $0.order < $1.order }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled routine" : trimmed
    }

    /// The exercises in order, for a one-line subtitle.
    var summary: String {
        let names = orderedItems.compactMap { $0.exercise?.name }
        return names.isEmpty ? "No exercises" : names.joined(separator: " · ")
    }

    /// How many sets the routine calls for, warmups excluded — routines
    /// prescribe working sets.
    var plannedSetCount: Int {
        orderedItems.reduce(0) { $0 + max(0, $1.targetSets) }
    }

    /// Rough tonnage, for comparing one routine against another. Only counts
    /// items with a target weight; an unloaded item contributes nothing rather
    /// than a guess.
    var plannedVolume: Double {
        orderedItems.reduce(0) { total, item in
            guard let weight = item.targetWeightKg else { return total }
            return total + weight * Double(item.targetReps) * Double(max(0, item.targetSets))
        }
    }

    /// Groups of items performed back to back, in order.
    ///
    /// A standalone exercise is a group of one, so a view can render the whole
    /// routine by walking this without special-casing.
    var groups: [[RoutineItem]] {
        var out: [[RoutineItem]] = []
        var current: [RoutineItem] = []
        var currentGroup: Int?

        for item in orderedItems {
            if let group = item.supersetGroup, group == currentGroup {
                current.append(item)
            } else {
                if !current.isEmpty { out.append(current) }
                current = [item]
                currentGroup = item.supersetGroup
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// One exercise's worth of a routine.
@Model
final class RoutineItem {
    var id: UUID = UUID()
    var order: Int = 0
    var targetSets: Int = 3
    var targetReps: Int = 8
    /// Nil where the weight is the point of the session rather than a given —
    /// bodyweight work, or a lift you take to the day's feel.
    var targetWeightKg: Double?
    /// Seconds to rest after each set of this exercise.
    var restSeconds: Int = 120
    var notes: String?

    /// Consecutive items sharing a value are a superset: you alternate between
    /// them and rest once at the end of the round, rather than resting after
    /// each. Nil means the exercise stands on its own.
    ///
    /// An `Int` rather than a `Bool` pairing so three-way giant sets work, and
    /// so two separate supersets in one session don't merge.
    var supersetGroup: Int?

    var exercise: Exercise?
    var routine: Routine?

    init(
        id: UUID = UUID(),
        order: Int,
        exercise: Exercise?,
        targetSets: Int = 3,
        targetReps: Int = 8,
        targetWeightKg: Double? = nil,
        restSeconds: Int = 120,
        supersetGroup: Int? = nil
    ) {
        self.id = id
        self.order = order
        self.exercise = exercise
        self.targetSets = targetSets
        self.targetReps = targetReps
        self.targetWeightKg = targetWeightKg
        self.restSeconds = restSeconds
        self.supersetGroup = supersetGroup
    }

    var displayName: String { exercise?.name ?? "No exercise" }

    /// "3 × 8 @ 80 kg", or "3 × 8" where no weight is prescribed.
    func shorthand(weightText: (Double) -> String) -> String {
        let base = "\(max(0, targetSets)) × \(targetReps)"
        guard let targetWeightKg else { return base }
        return base + " @ " + weightText(targetWeightKg)
    }
}

// MARK: - Starting a session

extension Routine {

    /// Write the routine out as pending sets on a new session.
    ///
    /// The sets exist up front rather than being added as you go, because the
    /// point of a routine is to see what's left. They're marked pending, so
    /// they count towards the session's plan but not towards volume until
    /// they're actually done.
    ///
    /// Returns the sets in performance order. Supersets are interleaved —
    /// a paired A/B goes A1, B1, A2, B2 — because that's the order you lift
    /// them in, and a session that lists them any other way is lying about
    /// what happened.
    func plannedSets() -> [SetEntry] {
        var out: [SetEntry] = []

        for group in groups {
            let rounds = group.map(\.targetSets).max() ?? 0
            guard rounds > 0 else { continue }

            for round in 0..<rounds {
                let thisRound = group.filter { round < $0.targetSets }
                for (position, item) in thisRound.enumerated() {
                    let entry = SetEntry(
                        order: out.count,
                        reps: item.targetReps,
                        weightKg: item.targetWeightKg ?? 0,
                        exercise: item.exercise
                    )
                    entry.isPending = true
                    // Rest belongs to the *round*, not to each set in it: you
                    // go straight from one half of a superset into the other
                    // and rest once at the end. Deciding that here rather than
                    // when a set is ticked off is what makes it right — only
                    // this loop knows where a round ends. Looking at the next
                    // set can't tell you: after the last exercise of round one
                    // the next set is the first exercise of round two, which
                    // is indistinguishable from staying inside a round.
                    let endsTheRound = position == thisRound.count - 1
                    entry.restSeconds = endsTheRound ? item.restSeconds : nil
                    entry.supersetGroup = group.count > 1 ? item.supersetGroup : nil
                    out.append(entry)
                }
            }
        }
        return out
    }
}
