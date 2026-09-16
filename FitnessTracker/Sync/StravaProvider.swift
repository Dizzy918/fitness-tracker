import Foundation

/// Strava sync.
///
/// You register your own API application at strava.com/settings/api (free) and
/// paste the Client ID + Secret into Settings — this app ships no shared
/// credentials. Access tokens live 6 hours; refresh tokens are single-use and
/// rotate on every refresh, so the new one must be persisted immediately or the
/// connection is lost.
struct StravaProvider: ActivityProvider {
    let kind: ProviderKind = .strava
    var session: URLSession = .shared

    static let redirectURI = "fitnesstracker://oauth/strava"
    /// `activity:read_all` also covers activities marked "Only You".
    static let scope = "activity:read_all,profile:read_all"

    var isConfigured: Bool {
        CredentialStore.has(.stravaRefreshToken) && CredentialStore.has(.stravaClientID)
    }

    // MARK: - OAuth

    static func authorizationURL() -> URL? {
        guard let clientID = CredentialStore.get(.stravaClientID), !clientID.isEmpty else {
            return nil
        }
        var c = URLComponents(string: "https://www.strava.com/oauth/authorize")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: scope),
        ]
        return c.url
    }

    /// Pull `code` out of the `fitnesstracker://oauth/strava?...` callback.
    static func authorizationCode(from callback: URL) -> String? {
        URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "code" }?
            .value
    }

    /// Trade the authorization code for tokens and persist them.
    func exchange(code: String) async throws {
        let tokens = try await postToken(params: [
            "code": code,
            "grant_type": "authorization_code",
        ])
        Self.persist(tokens)
    }

    /// Returns a valid access token, refreshing if it expires within 5 minutes.
    func validAccessToken() async throws -> String {
        let expiry = CredentialStore.stravaTokenExpiryDate ?? .distantPast
        if let token = CredentialStore.get(.stravaAccessToken),
           !token.isEmpty,
           expiry.timeIntervalSinceNow > 300 {
            return token
        }
        guard let refresh = CredentialStore.get(.stravaRefreshToken), !refresh.isEmpty else {
            throw ProviderError.notConfigured("Strava")
        }
        let tokens = try await postToken(params: [
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ])
        Self.persist(tokens)
        guard let token = tokens.access_token else {
            throw ProviderError.authExpired("Strava")
        }
        return token
    }

    private struct TokenResponse: Decodable {
        var access_token: String?
        var refresh_token: String?
        var expires_at: Double?
    }

    private func postToken(params: [String: String]) async throws -> TokenResponse {
        guard let clientID = CredentialStore.get(.stravaClientID),
              let secret = CredentialStore.get(.stravaClientSecret)
        else { throw ProviderError.notConfigured("Strava") }

        var body = params
        body["client_id"] = clientID
        body["client_secret"] = secret

        var request = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let data = try await HTTP.data(for: request, session: session)
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
    }

    /// Refresh tokens rotate — always write the new one back.
    private static func persist(_ tokens: TokenResponse) {
        if let access = tokens.access_token {
            CredentialStore.set(access, for: .stravaAccessToken)
        }
        if let refresh = tokens.refresh_token {
            CredentialStore.set(refresh, for: .stravaRefreshToken)
        }
        if let expiresAt = tokens.expires_at {
            CredentialStore.stravaTokenExpiryDate = Date(timeIntervalSince1970: expiresAt)
        }
    }

    static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    static func disconnect() {
        [.stravaAccessToken, .stravaRefreshToken, .stravaTokenExpiry].forEach {
            CredentialStore.remove($0)
        }
    }

    // MARK: - Activities

    func fetchActivities(since: Date?) async throws -> [RemoteActivity] {
        let token = try await validAccessToken()
        var out: [RemoteActivity] = []
        var page = 1
        let perPage = 100

        // Strava pages; stop at the first short page. Cap at 10 pages (1000
        // activities) per sync so a first-run import can't hit the rate limit.
        while page <= 10 {
            var c = URLComponents(string: "https://www.strava.com/api/v3/athlete/activities")!
            var items = [
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "per_page", value: "\(perPage)"),
            ]
            if let since {
                items.append(URLQueryItem(name: "after",
                                          value: "\(Int(since.timeIntervalSince1970))"))
            }
            c.queryItems = items

            var request = URLRequest(url: c.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let data = try await HTTP.data(for: request, session: session)
            let batch = try Self.parse(data)
            out.append(contentsOf: batch)

            if batch.count < perPage { break }
            page += 1
        }
        return out
    }

    // MARK: - Streams

    var supportsStreams: Bool { true }

    /// The channels worth asking for. `time` anchors everything else: every
    /// stream is index-aligned, so without it the samples have no clock.
    static let streamKeys = [
        "time", "distance", "latlng", "altitude",
        "heartrate", "cadence", "watts", "velocity_smooth",
    ]

    /// Per-second data for one activity.
    ///
    /// This is what turns a synced Strava activity into a first-class one: with
    /// streams it gets splits, a zone breakdown, best efforts and a training
    /// load scored from heart rate rather than guessed from an average.
    func fetchDetail(externalID: String) async throws -> ActivityDetail {
        let id = Self.numericID(from: externalID)
        guard !id.isEmpty else { return ActivityDetail() }

        let token = try await validAccessToken()
        var c = URLComponents(
            string: "https://www.strava.com/api/v3/activities/\(id)/streams"
        )!
        c.queryItems = [
            URLQueryItem(name: "keys", value: Self.streamKeys.joined(separator: ",")),
            // Without this the response is an array whose entries you have to
            // match up by `type`; keyed is both smaller to parse and harder to
            // get wrong.
            URLQueryItem(name: "key_by_type", value: "true"),
        ]

        var request = URLRequest(url: c.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let response = try await HTTP.response(for: request, session: session)
        if let budget = RateLimitBudget.strava(from: response.headers) {
            Self.budgetStore.current = budget
        }
        return try Self.parseStreams(response.data)
    }

    /// Most recent rate-limit budget Strava reported, so the sync engine can
    /// stop before a 429 rather than after one.
    static let budgetStore = RateLimitBudget.Store()

    var rateLimitBudget: RateLimitBudget? { Self.budgetStore.current }

    /// `strava:1234` → `1234`.
    static func numericID(from externalID: String) -> String {
        guard let separator = externalID.firstIndex(of: ":") else { return externalID }
        return String(externalID[externalID.index(after: separator)...])
    }

    /// One stream. Strava omits the key entirely when the channel wasn't
    /// recorded, so every one is optional and a missing channel costs that
    /// field rather than the whole activity.
    private struct NumericStream: Decodable { var data: [Double]? }
    private struct LatLngStream: Decodable { var data: [[Double]]? }

    private struct StreamSet: Decodable {
        var time: NumericStream?
        var distance: NumericStream?
        var latlng: LatLngStream?
        var altitude: NumericStream?
        var heartrate: NumericStream?
        var cadence: NumericStream?
        var watts: NumericStream?
        var velocity_smooth: NumericStream?
    }

    static func parseStreams(_ data: Data) throws -> ActivityDetail {
        let set: StreamSet
        do {
            set = try JSONDecoder().decode(StreamSet.self, from: data)
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }

        let times = set.time?.data
        let distances = set.distance?.data
        let latlngs = set.latlng?.data
        let altitudes = set.altitude?.data
        let heartrates = set.heartrate?.data
        let cadences = set.cadence?.data
        let watts = set.watts?.data
        let speeds = set.velocity_smooth?.data

        // Streams are index-aligned but a channel can come back short. Take the
        // longest one as the sample count and read each other defensively, so
        // one ragged array truncates itself instead of the whole activity.
        let count = [times, distances, altitudes, heartrates, cadences, watts, speeds]
            .compactMap { $0?.count }
            .max() ?? latlngs?.count ?? 0
        guard count > 0 else { return ActivityDetail() }

        func value(_ stream: [Double]?, _ index: Int) -> Double? {
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
                // No time channel means an activity recorded without one; a
                // 1 Hz assumption is the only sane reading of an index.
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

        // Full-resolution track, a real upgrade on the decimated summary
        // polyline the activity list carries.
        let coordinates = (latlngs ?? [])
            .filter { $0.count == 2 }
            .filter { (-90...90).contains($0[0]) && (-180...180).contains($0[1]) }

        return ActivityDetail(samples: samples, coordinates: coordinates)
    }

    // MARK: - Activity list

    private struct Activity: Decodable {
        struct Map: Decodable { var summary_polyline: String? }
        var id: Double?
        var name: String?
        var type: String?
        var sport_type: String?
        var start_date: String?
        var distance: Double?
        var moving_time: Double?
        var elapsed_time: Double?
        var average_heartrate: Double?
        var max_heartrate: Double?
        var total_elevation_gain: Double?
        var calories: Double?
        var map: Map?
    }

    static func parse(_ data: Data) throws -> [RemoteActivity] {
        let raw: [Activity]
        do {
            raw = try JSONDecoder().decode([Activity].self, from: data)
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }

        return raw.compactMap { a in
            guard let id = a.id,
                  let startedAt = a.start_date.flatMap({ ISO8601DateFormatter().date(from: $0) })
            else { return nil }

            // `sport_type` is the newer, more specific field (TrailRun, GravelRide).
            let sportRaw = a.sport_type ?? a.type

            return RemoteActivity(
                externalID: "strava:\(Int(id))",
                source: "strava",
                sport: SportMapper.map(sportRaw),
                startedAt: startedAt,
                duration: a.moving_time ?? a.elapsed_time ?? 0,
                distance: a.distance ?? 0,
                avgHeartRate: a.average_heartrate.map { Int($0.rounded()) },
                maxHeartRate: a.max_heartrate.map { Int($0.rounded()) },
                elevationGain: a.total_elevation_gain,
                calories: a.calories,
                name: a.name,
                coordinates: a.map?.summary_polyline.map { Polyline.decode($0) } ?? []
            )
        }
    }
}
