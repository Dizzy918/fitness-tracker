import Foundation

/// Every third-party source implements this. Deliberately narrow: fetch a
/// window of activities, hand back normalized values. Auth, paging, and
/// provider quirks stay inside the implementation.
protocol ActivityProvider: Sendable {
    var kind: ProviderKind { get }
    /// True when credentials are present. Does not prove they're still valid.
    var isConfigured: Bool { get }
    /// The value this provider writes to `Workout.source`. The sync watermark is
    /// keyed on it, so it must match what `RemoteActivity.source` carries.
    var sourceIdentifier: String { get }
    func fetchActivities(since: Date?) async throws -> [RemoteActivity]

    /// True when this provider can supply per-second data with a second call.
    var supportsStreams: Bool { get }

    /// What's left of the provider's request quota, if it publishes one.
    /// Lets the caller stop before a 429 instead of after it.
    var rateLimitBudget: RateLimitBudget? { get }

    /// Per-second data for one already-imported activity.
    ///
    /// Separate from `fetchActivities` because it costs one request *per
    /// activity*: fetching streams inline would turn a 400-activity first sync
    /// into 400 extra requests and exhaust the day's quota in one go. The sync
    /// engine backfills these a capped batch at a time instead.
    func fetchDetail(externalID: String) async throws -> ActivityDetail
}

extension ActivityProvider {
    var sourceIdentifier: String { kind.sourceIdentifier }
    var supportsStreams: Bool { false }
    var rateLimitBudget: RateLimitBudget? { nil }

    func fetchDetail(externalID: String) async throws -> ActivityDetail {
        throw ProviderError.streamsUnsupported(kind.displayName)
    }
}

/// The per-activity extras a second call can supply.
struct ActivityDetail: Sendable, Equatable {
    /// Per-second stream. Empty when the activity has no recorded detail —
    /// a manual entry, or a treadmill run logged by hand.
    var samples: [FITSample] = []
    /// Full-resolution track, which is a real upgrade on the decimated
    /// `summary_polyline` the activity list carries.
    var coordinates: [[Double]] = []

    var isEmpty: Bool { samples.isEmpty && coordinates.isEmpty }

    static func == (a: ActivityDetail, b: ActivityDetail) -> Bool {
        a.samples.count == b.samples.count && a.coordinates == b.coordinates
    }
}

/// The services we can talk to, and honestly, the ones we can't.
enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case strava
    case intervalsICU
    case garmin
    case suunto
    case polar

    var id: String { rawValue }

    /// Stamped onto every imported `Workout.source`.
    var sourceIdentifier: String {
        switch self {
        case .strava:       return "strava"
        case .intervalsICU: return "intervals"
        case .garmin:       return "garmin"
        case .suunto:       return "suunto"
        case .polar:        return "polar"
        }
    }

    var displayName: String {
        switch self {
        case .strava:       return "Strava"
        case .intervalsICU: return "intervals.icu"
        case .garmin:       return "Garmin Connect"
        case .suunto:       return "Suunto"
        case .polar:        return "Polar Flow"
        }
    }

    /// Whether this app can actually sync from the service today.
    enum Availability {
        /// Implemented and usable with credentials you can self-issue.
        case supported
        /// Not implemented because the API is gated or unavailable; the string
        /// explains what to do instead.
        case unavailable(reason: String)
    }

    var availability: Availability {
        switch self {
        case .strava:
            return .supported
        case .intervalsICU:
            return .supported
        case .garmin:
            return .unavailable(reason: """
                Garmin's Connect API requires approval as a Garmin developer partner — \
                there's no self-service key. Route Garmin data here by letting Garmin \
                auto-sync to Strava and syncing Strava, or export .fit files and import them.
                """)
        case .suunto:
            return .unavailable(reason: """
                Suunto's API needs a subscription key from apizone.suunto.com. Until that's \
                wired up, use the .fit importer — it's full fidelity and already works.
                """)
        case .polar:
            return .unavailable(reason: """
                Polar AccessLink allows self-registration but isn't implemented yet. \
                Polar can also auto-sync to Strava.
                """)
        }
    }

    var isSupported: Bool {
        if case .supported = availability { return true }
        return false
    }
}

enum ProviderError: LocalizedError {
    case notConfigured(String)
    case httpStatus(Int, body: String)
    case decoding(String)
    case authExpired(String)
    case rateLimited
    case streamsUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let p):
            return "\(p) isn't connected yet. Add credentials in Settings."
        case .httpStatus(let code, let body):
            let snippet = body.count > 200 ? String(body.prefix(200)) + "…" : body
            return "Request failed (HTTP \(code)). \(snippet)"
        case .decoding(let detail):
            return "Unexpected response format: \(detail)"
        case .authExpired(let p):
            return "\(p) authorization expired. Reconnect in Settings."
        case .rateLimited:
            return "Rate limited by the provider. Try again later."
        case .streamsUnsupported(let p):
            return "\(p) doesn't provide per-second data."
        }
    }

    /// True for conditions where continuing to hammer the API is pointless.
    var stopsTheBatch: Bool {
        switch self {
        case .rateLimited, .authExpired, .notConfigured: return true
        default: return false
        }
    }
}

/// Shared HTTP helper: throws typed errors instead of returning junk.
enum HTTP {

    struct Response: Sendable {
        let data: Data
        /// Nil for non-HTTP responses, which in practice means a test stub.
        let headers: [AnyHashable: Any]?

        init(data: Data, headers: [AnyHashable: Any]? = nil) {
            self.data = data
            self.headers = headers
        }
    }

    static func data(for request: URLRequest,
                     session: URLSession = .shared) async throws -> Data {
        try await response(for: request, session: session).data
    }

    /// As `data(for:)`, but keeps the headers — rate-limit budgets live there.
    static func response(for request: URLRequest,
                         session: URLSession = .shared) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return Response(data: data)
        }

        switch http.statusCode {
        case 200..<300:
            return Response(data: data, headers: http.allHeaderFields)
        case 401, 403:
            throw ProviderError.authExpired(request.url?.host ?? "Provider")
        case 404:
            // A deleted or private activity. Not fatal to a batch.
            throw ProviderError.httpStatus(404, body: "Not found")
        case 429:
            throw ProviderError.rateLimited
        default:
            throw ProviderError.httpStatus(
                http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }
}

/// What's left of an API quota, read from response headers.
///
/// Strava publishes both a 15-minute and a daily budget. Reading them turns
/// "make requests until one fails with 429" into "stop before it does", which
/// matters because a 429 costs the rest of the batch and the user's patience.
struct RateLimitBudget: Sendable, Equatable {
    var shortTermUsed: Int
    var shortTermLimit: Int
    var dailyUsed: Int
    var dailyLimit: Int

    var shortTermRemaining: Int { max(0, shortTermLimit - shortTermUsed) }
    var dailyRemaining: Int { max(0, dailyLimit - dailyUsed) }

    /// Requests we're willing to spend now, keeping a small reserve so an
    /// unrelated sync a minute later isn't left with nothing.
    func affordableRequests(reserve: Int = 10) -> Int {
        max(0, min(shortTermRemaining, dailyRemaining) - reserve)
    }

    /// Last budget a provider reported, shared across its (value-type)
    /// instances. Locked rather than `nonisolated(unsafe)`: it's written from a
    /// nonisolated async request and read from the main actor.
    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var value: RateLimitBudget?

        var current: RateLimitBudget? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// Strava sends `X-RateLimit-Limit: 200,2000` and a matching
    /// `X-RateLimit-Usage: 45,310` — short-term first, daily second.
    static func strava(from headers: [AnyHashable: Any]?) -> RateLimitBudget? {
        guard let headers else { return nil }

        func pair(_ name: String) -> (Int, Int)? {
            let value = headers.first { ($0.key as? String)?.caseInsensitiveCompare(name) == .orderedSame }?.value
            guard let text = value as? String else { return nil }
            let parts = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count >= 2 else { return nil }
            return (parts[0], parts[1])
        }

        guard let limits = pair("X-RateLimit-Limit"),
              let usage = pair("X-RateLimit-Usage")
        else { return nil }

        return RateLimitBudget(
            shortTermUsed: usage.0, shortTermLimit: limits.0,
            dailyUsed: usage.1, dailyLimit: limits.1
        )
    }
}
