import Foundation
import CoreLocation

/// GPX 1.1 reading and writing.
///
/// Export exists so a planned route can be loaded onto a watch — Suunto, Garmin
/// and Coros all import GPX. Import exists so routes built elsewhere
/// (plotaroute, Strava, a friend's file) can come in.
enum GPX {

    struct Point: Equatable, Sendable {
        let coordinate: CLLocationCoordinate2D
        let elevation: Double?

        init(_ coordinate: CLLocationCoordinate2D, elevation: Double? = nil) {
            self.coordinate = coordinate
            self.elevation = elevation
        }

        static func == (a: Point, b: Point) -> Bool {
            abs(a.coordinate.latitude - b.coordinate.latitude) < 1e-9
                && abs(a.coordinate.longitude - b.coordinate.longitude) < 1e-9
                && a.elevation == b.elevation
        }
    }

    // MARK: - Export

    /// Serialize as a single `<trk>`.
    ///
    /// Tracks rather than `<rte>`: watch and platform importers accept tracks
    /// near-universally, while route support is patchier.
    static func export(points: [Point], name: String, timestamp: Date? = nil) -> String {
        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(#"<gpx version="1.1" creator="FitnessTracker" xmlns="http://www.topografix.com/GPX/1/1">"#)
        lines.append("  <metadata>")
        lines.append("    <name>\(escape(name))</name>")
        if let timestamp {
            lines.append("    <time>\(iso8601.string(from: timestamp))</time>")
        }
        lines.append("  </metadata>")
        lines.append("  <trk>")
        lines.append("    <name>\(escape(name))</name>")
        lines.append("    <trkseg>")
        for point in points {
            // 7 decimals is ~1 cm — well past GPS precision, and keeps files small.
            let lat = String(format: "%.7f", point.coordinate.latitude)
            let lon = String(format: "%.7f", point.coordinate.longitude)
            if let elevation = point.elevation {
                lines.append("      <trkpt lat=\"\(lat)\" lon=\"\(lon)\">")
                lines.append("        <ele>\(String(format: "%.1f", elevation))</ele>")
                lines.append("      </trkpt>")
            } else {
                lines.append("      <trkpt lat=\"\(lat)\" lon=\"\(lon)\"/>")
            }
        }
        lines.append("    </trkseg>")
        lines.append("  </trk>")
        lines.append("</gpx>")
        return lines.joined(separator: "\n") + "\n"
    }

    static func export(coordinates: [[Double]], name: String) -> String {
        export(
            points: coordinates.compactMap { pair in
                guard pair.count >= 2 else { return nil }
                return Point(CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1]))
            },
            name: name
        )
    }

    // MARK: - Import

    enum ImportError: LocalizedError {
        case unreadable
        case noPoints

        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file isn't readable GPX."
            case .noPoints:   return "No track or route points found in that GPX file."
            }
        }
    }

    struct ParsedFile {
        var name: String?
        var points: [Point]
    }

    /// Parse track or route points. Accepts either `<trkpt>` or `<rtept>`, since
    /// files in the wild use both.
    static func parse(data: Data) throws -> ParsedFile {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { throw ImportError.unreadable }
        guard !delegate.points.isEmpty else { throw ImportError.noPoints }
        return ParsedFile(name: delegate.firstName, points: delegate.points)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var points: [Point] = []
        var firstName: String?

        private var pendingCoordinate: CLLocationCoordinate2D?
        private var pendingElevation: Double?
        private var currentElement: String?
        private var textBuffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            currentElement = elementName
            textBuffer = ""

            guard elementName == "trkpt" || elementName == "rtept" else { return }
            guard let latString = attributeDict["lat"], let lonString = attributeDict["lon"],
                  let lat = Double(latString), let lon = Double(lonString),
                  // Reject impossible coordinates rather than plotting them.
                  (-90...90).contains(lat), (-180...180).contains(lon)
            else { return }
            pendingCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            pendingElevation = nil
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBuffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "ele":
                pendingElevation = Double(text)
            case "name":
                if firstName == nil, !text.isEmpty { firstName = text }
            case "trkpt", "rtept":
                if let coordinate = pendingCoordinate {
                    points.append(Point(coordinate, elevation: pendingElevation))
                }
                pendingCoordinate = nil
                pendingElevation = nil
            default:
                break
            }
            textBuffer = ""
        }
    }

    // MARK: - Helpers

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
