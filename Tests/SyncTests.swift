import XCTest
import SwiftData
@testable import FitnessTracker

final class PolylineTests: XCTestCase {

    /// Google's canonical example from the encoded-polyline spec.
    func testDecodesCanonicalExample() {
        let decoded = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0][0], 38.5, accuracy: 0.00001)
        XCTAssertEqual(decoded[0][1], -120.2, accuracy: 0.00001)
        XCTAssertEqual(decoded[1][0], 40.7, accuracy: 0.00001)
        XCTAssertEqual(decoded[1][1], -120.95, accuracy: 0.00001)
        XCTAssertEqual(decoded[2][0], 43.252, accuracy: 0.00001)
        XCTAssertEqual(decoded[2][1], -126.453, accuracy: 0.00001)
    }

    func testEmptyAndGarbageInput() {
        XCTAssertTrue(Polyline.decode("").isEmpty)
        // Truncated input must stop cleanly, not crash or loop.
        XCTAssertTrue(Polyline.decode("_p~iF").isEmpty)
    }
}

final class SportMapperTests: XCTestCase {

    func testMapsProviderVocabularies() {
        XCTAssertEqual(SportMapper.map("Run"), .run)
        XCTAssertEqual(SportMapper.map("VirtualRun"), .run)
        XCTAssertEqual(SportMapper.map("TrailRun"), .trailRun)
        XCTAssertEqual(SportMapper.map("Ride"), .bike)
        XCTAssertEqual(SportMapper.map("GravelRide"), .bike)
        XCTAssertEqual(SportMapper.map("EBikeRide"), .bike)
        XCTAssertEqual(SportMapper.map("Swim"), .swim)
        XCTAssertEqual(SportMapper.map("Hike"), .hike)
        XCTAssertEqual(SportMapper.map("Walk"), .walk)
    }

    func testUnknownAndNilFallBackToOther() {
        XCTAssertEqual(SportMapper.map("Kitesurf"), .other)
        XCTAssertEqual(SportMapper.map(nil), .other)
        XCTAssertEqual(SportMapper.map(""), .other)
    }
}

final class StravaParsingTests: XCTestCase {

    private let json = """
    [
      {
        "id": 14237788123,
        "name": "Morning Run",
        "type": "Run",
        "sport_type": "TrailRun",
        "start_date": "2026-08-19T05:32:11Z",
        "distance": 10234.5,
        "moving_time": 2951,
        "elapsed_time": 3100,
        "average_heartrate": 148.4,
        "max_heartrate": 171.0,
        "total_elevation_gain": 312.0,
        "map": {"summary_polyline": "_p~iF~ps|U_ulLnnqC_mqNvxq`@"}
      },
      {
        "id": 14237788124,
        "name": "No date activity",
        "type": "Ride",
        "distance": 40000
      }
    ]
    """

    func testParsesActivityAndPrefersSportType() throws {
        let activities = try StravaProvider.parse(Data(json.utf8))

        // The undated second entry is dropped rather than defaulted.
        XCTAssertEqual(activities.count, 1)
        let a = try XCTUnwrap(activities.first)

        XCTAssertEqual(a.externalID, "strava:14237788123")
        XCTAssertEqual(a.source, "strava")
        XCTAssertEqual(a.sport, .trailRun, "sport_type should win over type")
        XCTAssertEqual(a.distance, 10234.5, accuracy: 0.1)
        XCTAssertEqual(a.duration, 2951, "moving_time preferred over elapsed_time")
        XCTAssertEqual(a.avgHeartRate, 148)
        XCTAssertEqual(a.maxHeartRate, 171)
        XCTAssertEqual(a.elevationGain, 312)
        XCTAssertEqual(a.name, "Morning Run")
        XCTAssertTrue(a.hasRoute)
        XCTAssertEqual(a.coordinates.count, 3, "summary_polyline should decode to a track")
    }

    func testMissingFieldsDoNotThrow() throws {
        let minimal = """
        [{"id": 1, "type": "Run", "start_date": "2026-01-01T00:00:00Z"}]
        """
        let activities = try StravaProvider.parse(Data(minimal.utf8))
        let a = try XCTUnwrap(activities.first)
        XCTAssertEqual(a.distance, 0)
        XCTAssertEqual(a.duration, 0)
        XCTAssertNil(a.avgHeartRate)
        XCTAssertFalse(a.hasRoute)
    }

    func testMalformedJSONThrowsDecodingError() {
        XCTAssertThrowsError(try StravaProvider.parse(Data("{not json".utf8)))
    }

    func testAuthorizationURLRequiresClientID() {
        CredentialStore.remove(.stravaClientID)
        XCTAssertNil(StravaProvider.authorizationURL())

        CredentialStore.set("12345", for: .stravaClientID)
        defer { CredentialStore.remove(.stravaClientID) }

        let url = StravaProvider.authorizationURL()
        let query = URLComponents(url: XCTUnwrap2(url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        XCTAssertEqual(value("client_id"), "12345")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("redirect_uri"), StravaProvider.redirectURI)
        XCTAssertEqual(value("scope"), "activity:read_all,profile:read_all")
    }

    func testExtractsCodeFromCallback() {
        let url = URL(string: "fitnesstracker://oauth/strava?state=&code=abc123&scope=activity:read_all")!
        XCTAssertEqual(StravaProvider.authorizationCode(from: url), "abc123")

        let denied = URL(string: "fitnesstracker://oauth/strava?error=access_denied")!
        XCTAssertNil(StravaProvider.authorizationCode(from: denied))
    }

    /// Small helper so the test above stays readable.
    private func XCTUnwrap2(_ url: URL?) -> URL {
        guard let url else { XCTFail("expected URL"); return URL(string: "about:blank")! }
        return url
    }
}

final class IntervalsICUParsingTests: XCTestCase {

    func testParsesActivities() throws {
        let json = """
        [
          {
            "id": "i4455",
            "name": "Tempo",
            "type": "Run",
            "start_date_local": "2026-08-18T18:05:00",
            "distance": 12000.0,
            "moving_time": 3300,
            "average_heartrate": 156.0,
            "max_heartrate": 178.0,
            "total_elevation_gain": 88.0,
            "calories": 820.0
          }
        ]
        """
        let activities = try IntervalsICUProvider.parse(Data(json.utf8))
        let a = try XCTUnwrap(activities.first)

        XCTAssertEqual(a.externalID, "intervals:i4455")
        XCTAssertEqual(a.source, "intervals")
        XCTAssertEqual(a.sport, .run)
        XCTAssertEqual(a.distance, 12000)
        XCTAssertEqual(a.duration, 3300)
        XCTAssertEqual(a.avgHeartRate, 156)
        XCTAssertEqual(a.calories, 820)
    }

    func testSkipsEntriesMissingIDOrDate() throws {
        let json = """
        [
          {"name": "no id", "start_date_local": "2026-08-18T18:05:00"},
          {"id": "i1", "name": "no date"}
        ]
        """
        XCTAssertTrue(try IntervalsICUProvider.parse(Data(json.utf8)).isEmpty)
    }

    func testAthleteIDNormalization() {
        XCTAssertEqual(IntervalsICUProvider.normalizeAthleteID("i123456"), "i123456")
        XCTAssertEqual(IntervalsICUProvider.normalizeAthleteID("123456"), "i123456")
        XCTAssertEqual(IntervalsICUProvider.normalizeAthleteID("  123456 "), "i123456")
        XCTAssertEqual(IntervalsICUProvider.normalizeAthleteID("0"), "0")
        XCTAssertEqual(IntervalsICUProvider.normalizeAthleteID(nil), "0")
        XCTAssertEqual(IntervalsICUProvider.normalizeAthleteID(""), "0")
    }

    func testBasicAuthUsesLiteralAPIKEYUsername() {
        let header = IntervalsICUProvider.basicAuthHeader(apiKey: "secret123")
        XCTAssertTrue(header.hasPrefix("Basic "))

        let encoded = String(header.dropFirst("Basic ".count))
        let decoded = String(data: Data(base64Encoded: encoded)!, encoding: .utf8)
        XCTAssertEqual(decoded, "API_KEY:secret123")
    }

    func testDateParsingVariants() {
        XCTAssertNotNil(IntervalsICUProvider.parseDate("2026-08-18T18:05:00"))
        XCTAssertNotNil(IntervalsICUProvider.parseDate("2026-08-18"))
        XCTAssertNil(IntervalsICUProvider.parseDate("not a date"))
    }
}

@MainActor
final class SyncEngineTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func activity(id: String, source: String = "strava",
                          date: Date = Date(timeIntervalSince1970: 1_700_000_000),
                          coords: [[Double]] = []) -> RemoteActivity {
        RemoteActivity(
            externalID: "\(source):\(id)", source: source, sport: .run,
            startedAt: date, duration: 1800, distance: 5000,
            avgHeartRate: 150, maxHeartRate: 170, elevationGain: 40,
            calories: 350, name: "Test run", coordinates: coords
        )
    }

    func testPersistsNewActivities() throws {
        let context = try makeContext()
        let report = SyncEngine(context: context).persist([
            activity(id: "1"), activity(id: "2"),
        ])
        try context.save()

        XCTAssertEqual(report.added, 2)
        XCTAssertEqual(report.duplicates, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 2)
    }

    func testResyncIsIdempotent() throws {
        let context = try makeContext()
        let engine = SyncEngine(context: context)
        let batch = [activity(id: "1"), activity(id: "2")]

        _ = engine.persist(batch)
        try context.save()
        let second = engine.persist(batch)
        try context.save()

        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.duplicates, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 2,
                       "re-syncing must not duplicate rows")
    }

    func testSameNumericIDFromDifferentProvidersStaysDistinct() throws {
        let context = try makeContext()
        let report = SyncEngine(context: context).persist([
            activity(id: "555", source: "strava"),
            activity(id: "555", source: "intervals"),
        ])
        try context.save()

        XCTAssertEqual(report.added, 2, "namespacing keeps providers from colliding")
    }

    func testRouteIsStored() throws {
        let context = try makeContext()
        let coords = [[42.7, 23.3], [42.71, 23.31]]
        _ = SyncEngine(context: context).persist([activity(id: "9", coords: coords)])
        try context.save()

        let workout = try XCTUnwrap(try context.fetch(FetchDescriptor<Workout>()).first)
        XCTAssertTrue(workout.hasRoute)
        XCTAssertEqual(workout.coordinates.count, 2)
        XCTAssertEqual(workout.coordinates[0][0], 42.7, accuracy: 0.0001)
    }

    func testDefaultSinceUsesNewestWorkoutFromTheSameProvider() throws {
        let context = try makeContext()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        _ = SyncEngine(context: context).persist([
            activity(id: "1", date: newest.addingTimeInterval(-86400 * 30)),
            activity(id: "2", date: newest),
        ])
        try context.save()

        let since = SyncEngine(context: context).defaultSince(forSource: "strava")
        // One day of overlap before the newest known activity.
        XCTAssertEqual(since.timeIntervalSince1970,
                       newest.addingTimeInterval(-86400).timeIntervalSince1970,
                       accuracy: 1)
    }

    /// The watermark must not be shared across sources. It used to key off
    /// "anything not manual", so a `.fit` import — or the demo seeder the README
    /// tells you to run first — capped Strava's very first sync at one day.
    func testAnotherSourcesWorkoutDoesNotNarrowTheWindow() throws {
        let context = try makeContext()
        let today = Workout(sport: .run, startedAt: .now, duration: 1800,
                            distance: 5000, source: "fit", externalID: "fit:abc")
        context.insert(today)
        let demo = Workout(sport: .run, startedAt: .now, duration: 1800,
                           distance: 5000, source: "demo", externalID: "demo-0-0")
        context.insert(demo)
        try context.save()

        let since = SyncEngine(context: context).defaultSince(forSource: "strava")
        XCTAssertLessThan(since, Calendar.current.date(byAdding: .day, value: -300, to: .now)!,
                          "a first Strava sync must still reach back a year")
    }

    func testDefaultSinceFallsBackAYearWhenEmpty() throws {
        let context = try makeContext()
        let since = SyncEngine(context: context).defaultSince(forSource: "strava")
        XCTAssertLessThan(since, Date.now)
        XCTAssertGreaterThan(since, Calendar.current.date(byAdding: .day, value: -400, to: .now)!)
    }

    func testProviderSourceIdentifiersMatchWhatTheyStamp() throws {
        XCTAssertEqual(StravaProvider().sourceIdentifier, "strava")
        XCTAssertEqual(IntervalsICUProvider().sourceIdentifier, "intervals")

        // The watermark query only works if the identifier equals the `source`
        // the provider actually writes onto each row.
        let stravaRows = try StravaProvider.parse(Data(#"""
        [{"id": 1, "start_date": "2026-01-01T08:00:00Z", "distance": 5000}]
        """#.utf8))
        XCTAssertEqual(stravaRows.first?.source, StravaProvider().sourceIdentifier)
    }

    func testUnsupportedProvidersExplainThemselves() {
        for kind in ProviderKind.allCases where !kind.isSupported {
            guard case .unavailable(let reason) = kind.availability else {
                return XCTFail("\(kind) should be unavailable")
            }
            XCTAssertFalse(reason.isEmpty, "\(kind) must say what to do instead")
        }
        XCTAssertTrue(ProviderKind.strava.isSupported)
        XCTAssertTrue(ProviderKind.intervalsICU.isSupported)
    }
}
