import Foundation
import SwiftData

/// A session you intend to do.
///
/// Everything else in this app is retrospective: it tells you what you did and
/// what it cost. That makes the fitness and fatigue curves a report rather than
/// a tool — you can see you're overreaching, but the app has no idea what you
/// were planning to do about it. A plan is what closes that loop.
///
/// Deliberately light. This is not a periodization engine: it's the week written
/// on a whiteboard, with enough structure that "planned" and "actual" can be
/// compared honestly.
@Model
final class PlannedWorkout {
    var id: UUID = UUID()
    /// Normalized to the start of the day. A plan is for a day, not a time —
    /// nobody sticks to "06:30 tempo" and pretending otherwise makes every
    /// comparison a miss.
    var scheduledFor: Date = Date.distantPast
    var sportRaw: String = WorkoutSport.run.rawValue
    /// What the session is, in the words you'd write on a whiteboard.
    var title: String = ""
    var notes: String?

    var targetDuration: TimeInterval?   // seconds
    var targetDistance: Double?         // meters
    /// Intended training stress, on the same TSS scale as everything else.
    var targetLoad: Double?

    /// The workout that fulfilled this, once one has.
    ///
    /// An id rather than a relationship: a plan and the session that satisfied
    /// it have independent lifetimes — deleting a workout shouldn't delete the
    /// plan that called for it, and a dangling id is a cheaper, more honest
    /// failure than a relationship that has to be kept consistent across a sync.
    var completedWorkoutID: UUID?
    /// Set when the athlete marked it skipped rather than leaving it to lapse,
    /// so a deliberate rest day reads differently from one that got away.
    var skippedAt: Date?

    /// Position within the day, for weeks with a double session.
    var order: Int = 0

    init(
        id: UUID = UUID(),
        scheduledFor: Date,
        sport: WorkoutSport = .run,
        title: String = "",
        order: Int = 0
    ) {
        self.id = id
        self.scheduledFor = Calendar.current.startOfDay(for: scheduledFor)
        self.sportRaw = sport.rawValue
        self.title = title
        self.order = order
    }

    var sport: WorkoutSport {
        get { WorkoutSport(rawValue: sportRaw) ?? .other }
        set { sportRaw = newValue.rawValue }
    }

    var isCompleted: Bool { completedWorkoutID != nil }
    var isSkipped: Bool { skippedAt != nil }
    var isOutstanding: Bool { !isCompleted && !isSkipped }

    /// A label even when the athlete didn't type one, so the row is never blank.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? sport.displayName : trimmed
    }

    /// Estimated stress, for weeks planned in duration rather than TSS.
    ///
    /// Falls back to the same per-sport default the load model uses for an
    /// unmeasured session, so a planned week and a completed one are compared on
    /// one scale rather than two.
    var estimatedLoad: Double? {
        if let targetLoad, targetLoad > 0 { return targetLoad }
        guard let targetDuration, targetDuration > 0 else { return nil }
        let intensity = TrainingLoad.defaultIntensity(for: sport)
        return targetDuration / 3600 * intensity * intensity * 100
    }
}

/// A plain snapshot, so planning maths can run off the main actor and be tested
/// without SwiftData.
struct PlannedWorkoutSnapshot: Sendable, Identifiable, Equatable {
    let id: UUID
    let scheduledFor: Date
    let sport: WorkoutSport
    let title: String
    let targetDuration: TimeInterval?
    let targetDistance: Double?
    let estimatedLoad: Double?
    let completedWorkoutID: UUID?
    let skippedAt: Date?
    let order: Int

    var isCompleted: Bool { completedWorkoutID != nil }
    var isSkipped: Bool { skippedAt != nil }
    var isOutstanding: Bool { !isCompleted && !isSkipped }
}

extension PlannedWorkout {
    var snapshot: PlannedWorkoutSnapshot {
        PlannedWorkoutSnapshot(
            id: id, scheduledFor: scheduledFor, sport: sport, title: displayTitle,
            targetDuration: targetDuration, targetDistance: targetDistance,
            estimatedLoad: estimatedLoad, completedWorkoutID: completedWorkoutID,
            skippedAt: skippedAt, order: order
        )
    }
}
