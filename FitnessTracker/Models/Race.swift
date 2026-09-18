import Foundation
import SwiftData

/// A date you're training towards.
///
/// The load model already says what shape you're in today. What it can't say is
/// whether that's the shape you'll be in on the day that matters — and "the day
/// that matters" was information the app simply didn't have. Without it, the
/// fitness and fatigue curves are a report; with it they can be aimed.
///
/// Priorities are the standard A/B/C vocabulary, because what they change is
/// real: you taper for an A race, you train through a C race.
@Model
final class Race {
    var id: UUID = UUID()
    var name: String = ""
    /// Start of the day. A race has a date, not a time, as far as planning goes.
    var date: Date = Date.distantPast
    var sportRaw: String = WorkoutSport.run.rawValue
    var priorityRaw: String = Priority.a.rawValue
    /// Metres, where the event has a set distance.
    var distance: Double?
    var goalDuration: TimeInterval?
    var notes: String?

    /// Filled in afterwards.
    var resultWorkoutID: UUID?
    var resultDuration: TimeInterval?
    var resultNotes: String?

    init(
        id: UUID = UUID(),
        name: String = "",
        date: Date,
        sport: WorkoutSport = .run,
        priority: Priority = .a
    ) {
        self.id = id
        self.name = name
        self.date = Calendar.current.startOfDay(for: date)
        self.sportRaw = sport.rawValue
        self.priorityRaw = priority.rawValue
    }

    var sport: WorkoutSport {
        get { WorkoutSport(rawValue: sportRaw) ?? .other }
        set { sportRaw = newValue.rawValue }
    }

    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .a }
        set { priorityRaw = newValue.rawValue }
    }

    enum Priority: String, CaseIterable, Identifiable, Sendable {
        /// The one you built the season around. Full taper.
        case a
        /// Matters, but you'd train through a bad week to get to it.
        case b
        /// A hard training day with a number on your chest.
        case c

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .a: return "A — goal race"
            case .b: return "B — important"
            case .c: return "C — train through"
            }
        }

        var shortName: String { rawValue.uppercased() }

        /// How long to taper. Not a matter of taste: the point of a taper is to
        /// shed fatigue without shedding fitness, and fatigue has a 7-day time
        /// constant while fitness has a 42-day one. Two weeks sheds nearly all
        /// the fatigue and little of the fitness; a month sheds both.
        var taperDays: Int {
            switch self {
            case .a: return 14
            case .b: return 7
            case .c: return 0
            }
        }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? sport.displayName + " race" : trimmed
    }

    var isComplete: Bool { resultDuration != nil || resultWorkoutID != nil }

    func daysAway(from today: Date = .now, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day],
                                from: calendar.startOfDay(for: today),
                                to: calendar.startOfDay(for: date)).day ?? 0
    }

    func isUpcoming(from today: Date = .now) -> Bool {
        !isComplete && daysAway(from: today) >= 0
    }

    /// The day the taper should begin, or nil where the race doesn't get one.
    func taperStart(calendar: Calendar = .current) -> Date? {
        guard priority.taperDays > 0 else { return nil }
        return calendar.date(byAdding: .day, value: -priority.taperDays, to: date)
    }

    /// Goal pace implied by the distance and goal time, in seconds per
    /// kilometre — the unit every other pace in this app is stored in.
    var goalPace: Double? {
        guard let distance, distance > 0, let goalDuration, goalDuration > 0
        else { return nil }
        return goalDuration / (distance / 1000)
    }

    /// Pace actually achieved, for comparing against the goal.
    var resultPace: Double? {
        guard let distance, distance > 0, let resultDuration, resultDuration > 0
        else { return nil }
        return resultDuration / (distance / 1000)
    }

    /// Seconds faster (negative) or slower (positive) than the goal.
    var resultVersusGoal: TimeInterval? {
        guard let goalDuration, let resultDuration else { return nil }
        return resultDuration - goalDuration
    }
}

/// A plain snapshot, so season maths runs off the main actor and is testable
/// without SwiftData.
struct RaceSnapshot: Sendable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let date: Date
    let sport: WorkoutSport
    let priority: Race.Priority
    let distance: Double?
    let goalDuration: TimeInterval?
    let isComplete: Bool
}

extension Race {
    var snapshot: RaceSnapshot {
        RaceSnapshot(id: id, name: displayName, date: date, sport: sport,
                     priority: priority, distance: distance,
                     goalDuration: goalDuration, isComplete: isComplete)
    }
}
