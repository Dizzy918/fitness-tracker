import Foundation
import CoreGraphics

/// Fits a GPS track into a rectangle.
///
/// Its own type because getting this wrong is invisible until you look: a
/// naive scale to the bounding box squashes a north–south run into a
/// horizontal smear, and latitude and longitude aren't the same distance apart
/// anyway — a degree of longitude at 43°N is about 73% of a degree of latitude.
/// A route that doesn't look like the route is worse than no route.
enum RouteGeometry {

    /// Project `coordinates` (as `[[lat, lon], …]`) into `rect`, preserving
    /// shape and centring what's left over.
    ///
    /// Returns an empty array for fewer than two points: a single fix isn't a
    /// route, and drawing it as a dot in the middle of a card implies one.
    static func path(for coordinates: [[Double]], in rect: CGRect,
                     inset: CGFloat = 0) -> [CGPoint] {
        let points = coordinates.compactMap { pair -> (lat: Double, lon: Double)? in
            guard pair.count >= 2, pair[0].isFinite, pair[1].isFinite else { return nil }
            return (pair[0], pair[1])
        }
        guard points.count >= 2 else { return [] }

        let lats = points.map(\.lat)
        let lons = points.map(\.lon)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max()
        else { return [] }

        let drawable = rect.insetBy(dx: inset, dy: inset)
        guard drawable.width > 0, drawable.height > 0 else { return [] }

        // A degree of longitude shrinks with latitude. Without this correction
        // an east–west route is drawn wider than it was run.
        let midLat = (minLat + maxLat) / 2
        let lonScale = max(0.01, cos(midLat * .pi / 180))

        let rawSpanX = (maxLon - minLon) * lonScale
        let rawSpanY = maxLat - minLat

        // A track that never moved has no shape to preserve. Falling through
        // to the general case works out arithmetically but pins it to an edge,
        // because the epsilon spans happen to fill one axis exactly.
        guard rawSpanX > 1e-12 || rawSpanY > 1e-12 else {
            return Array(repeating: CGPoint(x: drawable.midX, y: drawable.midY),
                         count: points.count)
        }

        // An epsilon only where a span is genuinely zero, to keep the division
        // finite; that axis then centres on its own, since its drawn extent
        // is zero.
        let spanX = max(rawSpanX, 1e-9)
        let spanY = max(rawSpanY, 1e-9)

        // One scale for both axes, so the shape survives.
        let scale = min(drawable.width / spanX, drawable.height / spanY)
        let drawnWidth = spanX * scale
        let drawnHeight = spanY * scale
        let offsetX = drawable.minX + (drawable.width - drawnWidth) / 2
        let offsetY = drawable.minY + (drawable.height - drawnHeight) / 2

        return points.map { point in
            let x = offsetX + (point.lon - minLon) * lonScale * scale
            // Flipped: latitude increases northwards, y increases downwards.
            let y = offsetY + (maxLat - point.lat) * scale
            return CGPoint(x: x, y: y)
        }
    }

    /// Whether a track is worth drawing at all.
    ///
    /// Two fixes in the same place is a stationary recording, not a route, and
    /// rendering it as a dot in the middle of a card claims more than it knows.
    static func isDrawable(_ coordinates: [[Double]]) -> Bool {
        let points = coordinates.compactMap { pair -> (Double, Double)? in
            guard pair.count >= 2, pair[0].isFinite, pair[1].isFinite else { return nil }
            return (pair[0], pair[1])
        }
        guard points.count >= 2 else { return false }
        let lats = points.map(\.0)
        let lons = points.map(\.1)
        return (lats.max()! - lats.min()!) > 1e-6 || (lons.max()! - lons.min()!) > 1e-6
    }
}
