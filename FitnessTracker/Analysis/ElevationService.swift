import Foundation
import CoreLocation
import OSLog

/// Looks up ground elevation for a planned route.
///
/// Apple publishes no elevation API, so a route you draw in the app has no climb
/// figure and no profile — only imported GPX carrying `<ele>` ever did. That's a
/// real gap when the whole point of planning a route is knowing what it costs.
///
/// **This sends coordinates to a third party.** The app otherwise talks only to
/// services you configured with your own credentials, so this is never automatic:
/// it runs when you ask for it, and the UI says where the request goes. The
/// public OpenTopoData instance needs no key and no account, which is the only
/// reason it fits an app that ships no shared credentials.
struct ElevationService: Sendable {

    private static let log = Logger(subsystem: "com.slavov.fitnesstracker", category: "elevation")

    var session: URLSession = .shared

    /// The public instance's limits: 100 locations per request, one request per
    /// second, 1000 requests a day. Everything below is shaped by these.
    static let locationsPerRequest = 100
    static let minimumRequestInterval: Duration = .milliseconds(1100)

    /// Most points to look up for one route.
    ///
    /// A snapped route can run to thousands of points, and 30 m terrain data
    /// can't resolve more detail than this anyway. Sampling to 200 costs two
    /// requests and still draws an honest profile; the rest is interpolated.
    static let maximumSamples = 200

    /// SRTM 30 m, which covers everywhere between 60°N and 56°S. Above that it
    /// returns nulls rather than failing, which `apply` treats as "unknown".
    static let dataset = "srtm30m"

    enum ServiceError: LocalizedError {
        case tooFewPoints
        case noData
        case rateLimited
        case status(Int)

        var errorDescription: String? {
            switch self {
            case .tooFewPoints:
                return "This route needs at least two points before it can have a profile."
            case .noData:
                return "The elevation service had no data for this route. That usually means it's outside the dataset's coverage (roughly 60°N to 56°S)."
            case .rateLimited:
                return "The elevation service is rate-limited right now. Try again in a minute."
            case .status(let code):
                return "The elevation service returned an error (HTTP \(code))."
            }
        }
    }

    // MARK: - Sampling

    /// Evenly spaced indices into `count` points, at most `limit` of them.
    ///
    /// Always includes the first and last: a profile that doesn't start where
    /// the route starts reads as wrong even when the middle is right.
    static func sampleIndices(count: Int, limit: Int = maximumSamples) -> [Int] {
        guard count > 0 else { return [] }
        guard count > limit else { return Array(0..<count) }

        var indices = (0..<limit).map { step in
            Int((Double(step) / Double(limit - 1) * Double(count - 1)).rounded())
        }
        indices[indices.count - 1] = count - 1
        // Rounding can repeat an index on short routes.
        return Array(Set(indices)).sorted()
    }

    /// Spread sampled elevations back across every point by linear
    /// interpolation, so the stored array lines up 1:1 with the geometry.
    static func interpolate(sampled: [Int: Double], count: Int) -> [Double] {
        guard count > 0, !sampled.isEmpty else { return [] }
        let known = sampled.keys.sorted()

        var out: [Double] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            if let exact = sampled[index] { out.append(exact); continue }

            let before = known.last { $0 < index }
            let after = known.first { $0 > index }
            switch (before, after) {
            case let (.some(a), .some(b)):
                let span = Double(b - a)
                let fraction = span > 0 ? Double(index - a) / span : 0
                out.append(sampled[a]! + (sampled[b]! - sampled[a]!) * fraction)
            case let (.some(a), .none):
                out.append(sampled[a]!)      // past the last sample
            case let (.none, .some(b)):
                out.append(sampled[b]!)      // before the first
            case (.none, .none):
                out.append(0)
            }
        }
        return out
    }

    // MARK: - Fetching

    private struct Response: Decodable {
        struct Result: Decodable {
            /// Null where the dataset has no coverage.
            var elevation: Double?
        }
        var status: String?
        var error: String?
        var results: [Result]?
    }

    /// Elevations for the given coordinates, in metres, in order.
    ///
    /// Batched at 100 per request with a pause between batches, because the
    /// public instance allows one request a second and answers a burst with a
    /// 429 rather than a queue.
    func elevations(for coordinates: [CLLocationCoordinate2D]) async throws -> [Double?] {
        guard !coordinates.isEmpty else { return [] }

        var out: [Double?] = []
        out.reserveCapacity(coordinates.count)

        let batches = stride(from: 0, to: coordinates.count, by: Self.locationsPerRequest)
            .map { Array(coordinates[$0..<min($0 + Self.locationsPerRequest, coordinates.count)]) }

        for (index, batch) in batches.enumerated() {
            if index > 0 { try await Task.sleep(for: Self.minimumRequestInterval) }
            out.append(contentsOf: try await fetchBatch(batch))
        }
        return out
    }

    private func fetchBatch(_ batch: [CLLocationCoordinate2D]) async throws -> [Double?] {
        // Coordinates go in the path query as `lat,lon|lat,lon`. Six decimals is
        // ~10 cm, far past what 30 m terrain data can distinguish, and keeps the
        // URL inside any sane length limit.
        let locations = batch
            .map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }
            .joined(separator: "|")

        var components = URLComponents(string: "https://api.opentopodata.org/v1/\(Self.dataset)")!
        components.queryItems = [URLQueryItem(name: "locations", value: locations)]
        guard let url = components.url else { throw ServiceError.noData }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Self.log.notice("elevation lookup failed: HTTP \(http.statusCode, privacy: .public)")
            throw http.statusCode == 429 ? ServiceError.rateLimited
                                         : ServiceError.status(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let results = decoded.results else { throw ServiceError.noData }
        return results.map(\.elevation)
    }

    // MARK: - Applying to a route

    struct Outcome: Sendable, Equatable {
        /// One entry per route point.
        var elevations: [Double]
        var gain: Double
        /// Points the dataset had no value for, filled by interpolation.
        var missing: Int
        /// How many were actually looked up, the rest being interpolated.
        var sampled: Int

        var summary: String {
            var text = "Looked up \(sampled) point\(sampled == 1 ? "" : "s")."
            if missing > 0 {
                text += " \(missing) had no data and were filled from their neighbours."
            }
            return text
        }
    }

    /// Fetch elevations for a route's geometry and fold them into a result.
    ///
    /// Pure of SwiftData so it can run off the main actor; the caller writes the
    /// outcome onto the model.
    func profile(for coordinates: [CLLocationCoordinate2D]) async throws -> Outcome {
        guard coordinates.count >= 2 else { throw ServiceError.tooFewPoints }

        let indices = Self.sampleIndices(count: coordinates.count)
        let sampledCoordinates = indices.map { coordinates[$0] }
        let fetched = try await elevations(for: sampledCoordinates)

        var known: [Int: Double] = [:]
        var missing = 0
        for (offset, index) in indices.enumerated() {
            if offset < fetched.count, let value = fetched[offset] {
                known[index] = value
            } else {
                missing += 1
            }
        }
        guard !known.isEmpty else { throw ServiceError.noData }

        let elevations = Self.interpolate(sampled: known, count: coordinates.count)
        return Outcome(
            elevations: elevations,
            // Same threshold the imported-GPX path uses, so a fetched profile
            // and an imported one report gain the same way.
            gain: GeoMath.elevationGain(elevations),
            missing: missing,
            sampled: known.count
        )
    }
}
