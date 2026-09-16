import Foundation

/// Google encoded-polyline codec.
///
/// Strava returns routes as `summary_polyline` in this format, so decoding it
/// gives us a map track without a second API call per activity.
enum Polyline {

    /// Decode to `[[lat, lon]]` — the same shape `Workout.polylineData` stores.
    static func decode(_ encoded: String) -> [[Double]] {
        var coordinates: [[Double]] = []
        var index = encoded.startIndex
        var lat = 0, lon = 0

        while index < encoded.endIndex {
            guard let dLat = nextValue(encoded, &index) else { break }
            guard let dLon = nextValue(encoded, &index) else { break }
            lat += dLat
            lon += dLon
            coordinates.append([Double(lat) / 1e5, Double(lon) / 1e5])
        }
        return coordinates
    }

    /// Read one varint-style chunked value, advancing `index`.
    private static func nextValue(_ s: String, _ index: inout String.Index) -> Int? {
        var result = 0
        var shift = 0
        var byte = 0

        repeat {
            guard index < s.endIndex else { return nil }
            guard let ascii = s[index].asciiValue else { return nil }
            byte = Int(ascii) - 63
            guard byte >= 0 else { return nil }
            result |= (byte & 0x1F) << shift
            shift += 5
            index = s.index(after: index)
        } while byte >= 0x20

        // Low bit set means the value was negative before zig-zag encoding.
        return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
    }
}
