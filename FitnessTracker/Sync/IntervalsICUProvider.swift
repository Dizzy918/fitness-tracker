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
