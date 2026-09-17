import Foundation

/// intervals.icu sync.
///
/// Auth is HTTP basic with the literal username `API_KEY` and your personal key
/// (Settings → bottom of the page). Athlete IDs are the Strava numeric ID with
/// an `i` prefix; `0` means "the authenticated athlete".
struct IntervalsICUProvider: ActivityProvider {
    let kind: ProviderKind = .intervalsICU
    var session: URLSession = .shared

    var isConfigured: Bool { CredentialStore.has(.intervalsAPIKey) }

    func fetchActivities(since: Date?) async throws -> [RemoteActivity] {
        guard let apiKey = CredentialStore.get(.intervalsAPIKey), !apiKey.isEmpty else {
            throw ProviderError.notConfigured("intervals.icu")
        }
        let athlete = Self.normalizeAthleteID(CredentialStore.get(.intervalsAthleteID))

        let oldest = since ?? Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .now
        var components = URLComponents(
            string: "https://intervals.icu/api/v1/athlete/\(athlete)/activities"
        )!
        components.queryItems = [
            URLQueryItem(name: "oldest", value: Self.dateFormatter.string(from: oldest)),
            URLQueryItem(name: "newest", value: Self.dateFormatter.string(from: .now)),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(Self.basicAuthHeader(apiKey: apiKey), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await HTTP.data(for: request, session: session)
        return try Self.parse(data)
    }

    // MARK: - Streams

    var supportsStreams: Bool { true }

    static let streamTypes = [
        "time", "distance", "latlng", "altitude",
        "heartrate", "cadence", "watts", "velocity_smooth",
    ]

    /// Per-second data for one activity.
    ///
    /// Same shape as Strava's, one request per activity, so it goes through the
    /// same capped backfill rather than being fetched inline. intervals.icu
    /// publishes no rate-limit headers, so the engine's own per-sync cap is the
    /// only budget — which is why that cap is a constant rather than something
    /// derived per provider.
    func fetchDetail(externalID: String) async throws -> ActivityDetail {
        guard let apiKey = CredentialStore.get(.intervalsAPIKey), !apiKey.isEmpty else {
            throw ProviderError.notConfigured("intervals.icu")
        }
        let id = Self.activityID(from: externalID)
        guard !id.isEmpty else { return ActivityDetail() }

        var components = URLComponents(
            string: "https://intervals.icu/api/v1/activity/\(id)/streams"
        )!
        components.queryItems = [
            URLQueryItem(name: "types", value: Self.streamTypes.joined(separator: ",")),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(Self.basicAuthHeader(apiKey: apiKey), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await HTTP.data(for: request, session: session)
        return try Self.parseStreams(data)
    }

    /// `intervals:i12345` → `i12345`.
    static func activityID(from externalID: String) -> String {
        guard let separator = externalID.firstIndex(of: ":") else { return externalID }
        return String(externalID[externalID.index(after: separator)...])
    }

    /// intervals.icu returns an *array* of `{type, data}` rather than Strava's
    /// keyed object, so the channels are matched by `type` instead of by key.
    /// A stream element, which may be a number, `null` where a sensor dropped
    /// out, or — for `latlng` — a two-element array.
    ///
    /// All three shapes arrive under the same `data` key, so a strict decode
    /// fails the *entire* response on whichever channel doesn't match. Reading
    /// each element permissively keeps one odd channel from costing the rest.
    private struct LenientValue: Decodable {
        let number: Double?
        let pair: [Double]?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            number = try? container.decode(Double.self)
            pair = try? container.decode([Double].self)
        }
    }

    private struct Stream: Decodable {
        var type: String?
        var data: [LenientValue]?
    }

    static func parseStreams(_ data: Data) throws -> ActivityDetail {
        let streams: [Stream]
        do {
            streams = try JSONDecoder().decode([Stream].self, from: data)
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }

        func channel(_ type: String) -> [Double?]? {
            streams.first { $0.type == type }?.data?.map(\.number)
        }
        let times = channel("time")
        let distances = channel("distance")
        let altitudes = channel("altitude")
        let heartrates = channel("heartrate")
        let cadences = channel("cadence")
        let watts = channel("watts")
        let speeds = channel("velocity_smooth")
        let latlngs = streams.first { $0.type == "latlng" }?.data?.map(\.pair)

        let count = [times, distances, altitudes, heartrates, cadences, watts, speeds]
            .compactMap { $0?.count }
            .max() ?? latlngs?.count ?? 0
        guard count > 0 else { return ActivityDetail() }

        // intervals.icu writes nulls into a channel where the sensor dropped
        // out, so a value can be absent mid-stream rather than only past the end.
        func value(_ stream: [Double?]?, _ index: Int) -> Double? {
            guard let stream, index < stream.count else { return nil }
            return stream[index]
        }

        var samples: [FITSample] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let pair = latlngs.flatMap { index < $0.count ? $0[index] : nil }
            let lat = pair.flatMap { $0.count == 2 ? $0[0] : nil }
            let lon = pair.flatMap { $0.count == 2 ? $0[1] : nil }

            samples.append(FITSample(
                t: value(times, index) ?? Double(index),
                lat: lat, lon: lon,
                hr: value(heartrates, index).map { Int($0) },
                alt: value(altitudes, index),
                speed: value(speeds, index),
                cadence: value(cadences, index).map { Int($0) },
                dist: value(distances, index),
                power: value(watts, index).map { Int($0) }
            ))
        }

        let coordinates = (latlngs ?? [])
            .compactMap { $0 }
            .filter { $0.count == 2 }
            .filter { (-90...90).contains($0[0]) && (-180...180).contains($0[1]) }

        return ActivityDetail(samples: samples, coordinates: coordinates)
    }

    // MARK: - Parsing

    /// Every field is optional: intervals.icu returns a wide, evolving object and
    /// a missing key must never fail the whole sync.
    private struct Activity: Decodable {
        var id: String?
        var name: String?
        var type: String?
        var start_date_local: String?
        var distance: Double?
        var moving_time: Double?
        var elapsed_time: Double?
        var average_heartrate: Double?
        var max_heartrate: Double?
        var total_elevation_gain: Double?
        var calories: Double?
    }

    static func parse(_ data: Data) throws -> [RemoteActivity] {
        let decoder = JSONDecoder()
        let raw: [Activity]
        do {
            raw = try decoder.decode([Activity].self, from: data)
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }

        return raw.compactMap { a in
            guard let id = a.id,
                  let startedAt = a.start_date_local.flatMap(parseDate)
            else { return nil }

            return RemoteActivity(
                externalID: "intervals:\(id)",
                source: "intervals",
                sport: SportMapper.map(a.type),
                startedAt: startedAt,
                duration: a.moving_time ?? a.elapsed_time ?? 0,
                distance: a.distance ?? 0,
                avgHeartRate: a.average_heartrate.map { Int($0.rounded()) },
                maxHeartRate: a.max_heartrate.map { Int($0.rounded()) },
                elevationGain: a.total_elevation_gain,
                calories: a.calories,
                name: a.name,
                coordinates: []   // intervals.icu streams need a separate call
            )
        }
    }

    /// intervals.icu local timestamps come without a zone offset.
    static func parseDate(_ string: String) -> Date? {
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.dateFormat = format
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = format.hasSuffix("Z") ? TimeZone(identifier: "UTC") : .current
            if let date = f.date(from: string) { return date }
        }
        return ISO8601DateFormatter().date(from: string)
    }

    /// Accepts `i123456`, `123456`, or `0`; normalizes to what the API expects.
    static func normalizeAthleteID(_ raw: String?) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return "0" }                      // 0 = authenticated athlete
        if trimmed == "0" { return "0" }
        return trimmed.hasPrefix("i") ? trimmed : "i\(trimmed)"
    }

    static func basicAuthHeader(apiKey: String) -> String {
        let token = Data("API_KEY:\(apiKey)".utf8).base64EncodedString()
        return "Basic \(token)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
