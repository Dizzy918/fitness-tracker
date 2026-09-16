import Foundation

/// A workout fetched from a third-party service, normalized across providers.
///
/// Providers translate their own JSON into this; nothing downstream knows or
/// cares which service the data came from.
struct RemoteActivity: Sendable, Equatable {
    /// Provider-scoped identity, e.g. `strava:14237788123`. Namespaced so two
    /// services can't collide on the same numeric ID.
    let externalID: String
    let source: String            // "strava" | "intervals" | ...
    let sport: WorkoutSport
    let startedAt: Date
    let duration: TimeInterval    // seconds (moving time preferred)
    let distance: Double          // meters
    let avgHeartRate: Int?
    let maxHeartRate: Int?
    let elevationGain: Double?
    let calories: Double?
    let name: String?
    /// Route as [[lat, lon]] if the provider gave us one.
    let coordinates: [[Double]]

    var hasRoute: Bool { !coordinates.isEmpty }
}

/// Maps a provider's sport string onto our enum. Providers use overlapping but
/// inconsistent vocabularies (Strava `TrailRun`, intervals.icu `Ride`), so this
/// is deliberately forgiving and falls back to `.other` rather than guessing.
enum SportMapper {
    static func map(_ raw: String?) -> WorkoutSport {
        guard let raw else { return .other }
        switch raw.lowercased().replacingOccurrences(of: " ", with: "") {
        case "run", "running", "virtualrun", "treadmillrun":
            return .run
        case "trailrun", "trailrunning":
            return .trailRun
        case "ride", "bike", "biking", "cycling", "virtualride",
             "gravelride", "mountainbikeride", "ebikeride":
            return .bike
        case "swim", "swimming", "openwaterswim":
            return .swim
        case "hike", "hiking":
            return .hike
        case "walk", "walking":
            return .walk
        default:
            return .other
        }
    }
}
