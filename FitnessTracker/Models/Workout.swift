import Foundation
import SwiftData

@Model
final class Workout {
    var id: UUID = UUID()
    var sportRaw: String = WorkoutSport.other.rawValue
    var startedAt: Date = Date.distantPast
    var duration: TimeInterval = 0     // seconds
    var distance: Double = 0           // meters
    var avgHeartRate: Int?
    var maxHeartRate: Int?
    var elevationGain: Double?         // meters
    var calories: Double?              // kcal
    var avgPower: Int?                 // watts (cycling)
    var poolLength: Double?            // meters (pool swims)
    var notes: String?
    var source: String = "manual"      // "fit" | "healthkit" | "manual"
    var externalID: String?            // content hash, for import dedupe

    /// When per-activity detail was last fetched from the provider.
    ///
    /// Set even when the provider returned nothing, because plenty of
    /// activities genuinely have no streams — a manual entry, a treadmill run
    /// logged by hand. Without this marker the backfill would ask about those
    /// same activities on every single sync and burn the daily quota on
    /// answers it already has.
    var detailFetchedAt: Date?

    // Large payloads kept as blobs and decoded on demand.
    //
    // `.externalStorage` is what actually keeps list queries cheap: it writes
    // anything sizeable to a side file and leaves only a reference in the row,
    // so fetching 500 workouts for the dashboard no longer pulls 500 sample
    // streams (hundreds of MB at 1 Hz) through memory with them.
    @Attribute(.externalStorage) var polylineData: Data?   // [[lat, lon], ...]
    @Attribute(.externalStorage) var streamsData: Data?    // [FITSample]
    @Attribute(.externalStorage) var lapsData: Data?       // [FITLap]

    @Relationship(deleteRule: .nullify, inverse: \Shoe.workouts)
    var shoe: Shoe?

    init(
        id: UUID = UUID(),
        sport: WorkoutSport,
        startedAt: Date,
        duration: TimeInterval,
        distance: Double,
        source: String,
        externalID: String? = nil
    ) {
        self.id = id
        self.sportRaw = sport.rawValue
        self.startedAt = startedAt
        self.duration = duration
        self.distance = distance
        self.source = source
        self.externalID = externalID
    }

    /// SwiftData stores the raw string so the enum can gain cases without a migration.
    var sport: WorkoutSport {
        get { WorkoutSport(rawValue: sportRaw) ?? .other }
        set { sportRaw = newValue.rawValue }
    }

    var distanceKm: Double { distance / 1000 }

    var paceSecPerKm: Double? {
        guard distance > 0, duration > 0 else { return nil }
        return duration / distanceKm
    }

    // MARK: - Decoded payloads

    var coordinates: [[Double]] {
        guard let polylineData else { return [] }
        return (try? JSONDecoder().decode([[Double]].self, from: polylineData)) ?? []
    }

    var samples: [FITSample] {
        guard let streamsData else { return [] }
        return (try? JSONDecoder().decode([FITSample].self, from: streamsData)) ?? []
    }

    var laps: [FITLap] {
        guard let lapsData else { return [] }
        return (try? JSONDecoder().decode([FITLap].self, from: lapsData)) ?? []
    }

    var hasRoute: Bool { polylineData != nil }

    /// True when this workout carries per-second data, so the UI can promise
    /// splits, zones and best efforts rather than quietly omitting them.
    var hasStreams: Bool { streamsData != nil }

    /// A synced workout we haven't asked the provider about yet.
    var needsDetailFetch: Bool { detailFetchedAt == nil && streamsData == nil }
}
