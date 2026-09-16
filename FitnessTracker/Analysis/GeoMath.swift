import Foundation
import CoreLocation

/// Distance and elevation math over coordinate paths.
enum GeoMath {

    static let earthRadiusMeters = 6_371_000.0

    /// Great-circle distance between two points.
    ///
    /// Haversine rather than equirectangular: routes can span enough latitude
    /// that the flat approximation drifts, and this is cheap enough to run over
    /// every waypoint pair.
    static func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180

        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(h)))
    }

    /// Total length along an ordered path.
    static func pathDistance(_ points: [CLLocationCoordinate2D]) -> Double {
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { $0 + distance(from: $1.0, to: $1.1) }
    }

    /// Cumulative distance at each point, starting at 0.
    static func cumulativeDistances(_ points: [CLLocationCoordinate2D]) -> [Double] {
        var out: [Double] = []
        var running = 0.0
        for (index, point) in points.enumerated() {
            if index > 0 { running += distance(from: points[index - 1], to: point) }
            out.append(running)
        }
        return out
    }

    /// Sum of positive elevation changes, ignoring drops below `threshold` to
    /// avoid inflating gain from GPS/barometer noise.
    static func elevationGain(_ elevations: [Double], threshold: Double = 1.0) -> Double {
        guard elevations.count >= 2 else { return 0 }
        var gain = 0.0
        var reference = elevations[0]
        for value in elevations.dropFirst() {
            let delta = value - reference
            if delta >= threshold {
                gain += delta
                reference = value
            } else if delta < 0 {
                reference = value
            }
        }
        return gain
    }

    /// Bounding box, padded, for framing a path on a map.
    static func boundingRegion(_ points: [CLLocationCoordinate2D],
                              padding: Double = 1.3) -> (center: CLLocationCoordinate2D,
                                                         span: (lat: Double, lon: Double))? {
        guard let first = points.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for p in points {
            minLat = min(minLat, p.latitude);  maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        return (
            CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                   longitude: (minLon + maxLon) / 2),
            (max((maxLat - minLat) * padding, 0.004),
             max((maxLon - minLon) * padding, 0.004))
        )
    }

    /// Is the path effectively a loop? Used to label routes.
    static func isLoop(_ points: [CLLocationCoordinate2D], tolerance: Double = 150) -> Bool {
        guard let first = points.first, let last = points.last, points.count > 3 else {
            return false
        }
        return distance(from: first, to: last) <= tolerance
    }
}
