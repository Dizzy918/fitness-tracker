import Foundation
import SwiftData
import CoreLocation

/// A planned route: an ordered list of coordinates you can send to a watch.
@Model
final class Route {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date.distantPast
    var sportRaw: String = WorkoutSport.run.rawValue
    var notes: String?
    /// Cached so the list doesn't recompute geometry for every row.
    var distance: Double = 0          // meters
    var elevationGain: Double?        // meters, when elevations are known
    var isLoop: Bool = false
    /// [[lat, lon]] — same encoding `Workout.polylineData` uses.
    @Attribute(.externalStorage) var pointsData: Data?
    /// Parallel elevations array when a source provided them.
    @Attribute(.externalStorage) var elevationsData: Data?

    init(id: UUID = UUID(), name: String, sport: WorkoutSport = .run) {
        self.id = id
        self.name = name
        self.createdAt = .now
        self.sportRaw = sport.rawValue
    }

    var sport: WorkoutSport {
        get { WorkoutSport(rawValue: sportRaw) ?? .run }
        set { sportRaw = newValue.rawValue }
    }

    var points: [[Double]] {
        guard let pointsData else { return [] }
        return (try? JSONDecoder().decode([[Double]].self, from: pointsData)) ?? []
    }

    var elevations: [Double] {
        guard let elevationsData else { return [] }
        return (try? JSONDecoder().decode([Double].self, from: elevationsData)) ?? []
    }

    var coordinates: [CLLocationCoordinate2D] {
        points.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
        }
    }

    var distanceKm: Double { distance / 1000 }

    /// Write the geometry and refresh the cached summary in one place, so the
    /// stored distance can't drift from the stored points.
    func setGeometry(coordinates: [CLLocationCoordinate2D], elevations: [Double] = []) {
        pointsData = try? JSONEncoder().encode(
            coordinates.map { [$0.latitude, $0.longitude] }
        )
        elevationsData = elevations.isEmpty ? nil : (try? JSONEncoder().encode(elevations))
        distance = GeoMath.pathDistance(coordinates)
        elevationGain = elevations.isEmpty ? nil : GeoMath.elevationGain(elevations)
        isLoop = GeoMath.isLoop(coordinates)
    }

    var gpx: String {
        let elevations = self.elevations
        let points = coordinates.enumerated().map { index, coordinate in
            GPX.Point(coordinate,
                      elevation: index < elevations.count ? elevations[index] : nil)
        }
        return GPX.export(points: points, name: name, timestamp: createdAt)
    }

    /// Filesystem-safe filename for sharing.
    var gpxFilename: String {
        let safe = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (safe.isEmpty ? "route" : safe) + ".gpx"
    }
}
