import Foundation

/// Sport classification. Deliberately dependency-free (no SwiftData) so the
/// FIT decode layer can use it without pulling in persistence.
enum WorkoutSport: String, Codable, CaseIterable, Sendable {
    case run, trailRun, bike, swim, hike, walk, other

    var displayName: String {
        switch self {
        case .run:      return "Run"
        case .trailRun: return "Trail Run"
        case .bike:     return "Bike"
        case .swim:     return "Swim"
        case .hike:     return "Hike"
        case .walk:     return "Walk"
        case .other:    return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .run, .trailRun: return "figure.run"
        case .bike:           return "bicycle"
        case .swim:           return "figure.pool.swim"
        case .hike:           return "figure.hiking"
        case .walk:           return "figure.walk"
        case .other:          return "figure.mixed.cardio"
        }
    }

    /// Distance-based sports get pace/mileage treatment in the UI.
    var isDistanceBased: Bool { self != .other }
}
