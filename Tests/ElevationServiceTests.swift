import XCTest
import CoreLocation
@testable import FitnessTracker

/// Route elevation lookup.
///
/// The network call is exercised through a stubbed `URLProtocol` rather than the
/// live service: a test that hits a public API is a test that fails when
/// someone else's server is busy, and it would spend a shared daily quota.
final class ElevationServiceTests: XCTestCase {

    // MARK: - Stub transport

    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
        nonisolated(unsafe) static var requests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            Self.requests.append(request)
            do {
                let (status, data) = try Self.handler?(request) ?? (200, Data())
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status,
                    httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    private func makeService(
        _ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)
    ) -> ElevationService {
        StubProtocol.handler = handler
        StubProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ElevationService(session: URLSession(configuration: configuration))
    }

    private func body(_ elevations: [Double?]) -> Data {
        let results = elevations
            .map { $0.map { "{\"elevation\": \($0)}" } ?? "{\"elevation\": null}" }
            .joined(separator: ",")
        return Data("{\"status\":\"OK\",\"results\":[\(results)]}".utf8)
    }

    private func line(_ count: Int) -> [CLLocationCoordinate2D] {
        (0..<count).map {
            CLLocationCoordinate2D(latitude: 42.70 + Double($0) * 0.001, longitude: 23.32)
        }
    }

    // MARK: - Sampling

    /// A snapped route runs to thousands of points and 30 m terrain data can't
    /// resolve that, so lookups are sampled — but never at the cost of the ends.
    func testSamplingAlwaysKeepsTheFirstAndLastPoint() {
        for count in [2, 5, 199, 200, 201, 5000] {
            let indices = ElevationService.sampleIndices(count: count)
            XCTAssertEqual(indices.first, 0, "count \(count)")
            XCTAssertEqual(indices.last, count - 1, "count \(count)")
            XCTAssertLessThanOrEqual(indices.count, ElevationService.maximumSamples)
            XCTAssertEqual(indices, indices.sorted())
            XCTAssertEqual(Set(indices).count, indices.count, "no repeats at count \(count)")
        }
    }

    func testShortRoutesAreNotSampledAtAll() {
        XCTAssertEqual(ElevationService.sampleIndices(count: 4), [0, 1, 2, 3])
        XCTAssertTrue(ElevationService.sampleIndices(count: 0).isEmpty)
        XCTAssertEqual(ElevationService.sampleIndices(count: 1), [0])
    }

    /// Asserts the property rather than hand-computed indices: the samples span
    /// 0…count-1, so the gaps are `(count-1)/(limit-1)` apart give or take
    /// rounding, and it's the evenness that matters, not the exact integers.
    func testSamplingSpreadsEvenlyAcrossTheRoute() {
        let count = 1000, limit = 11
        let indices = ElevationService.sampleIndices(count: count, limit: limit)
        XCTAssertEqual(indices.count, limit)

        let expectedGap = Double(count - 1) / Double(limit - 1)
        for (a, b) in zip(indices, indices.dropFirst()) {
            XCTAssertEqual(Double(b - a), expectedGap, accuracy: 1.0,
                           "gap \(a)→\(b) should be about \(expectedGap)")
        }
    }

    // MARK: - Interpolation

    func testInterpolationFillsTheGapsLinearly() {
        let filled = ElevationService.interpolate(sampled: [0: 100, 4: 140], count: 5)
        XCTAssertEqual(filled, [100, 110, 120, 130, 140])
    }

    /// Points before the first sample and after the last have nothing to
    /// interpolate between, so they hold the nearest known value rather than
    /// falling to zero — which would invent a cliff at each end.
    func testInterpolationHoldsTheEndsRatherThanDroppingToZero() {
        let filled = ElevationService.interpolate(sampled: [2: 500, 3: 520], count: 6)
        XCTAssertEqual(filled, [500, 500, 500, 520, 520, 520])
    }

    func testInterpolationHandlesDegenerateInput() {
        XCTAssertTrue(ElevationService.interpolate(sampled: [:], count: 5).isEmpty)
        XCTAssertTrue(ElevationService.interpolate(sampled: [0: 100], count: 0).isEmpty)
        XCTAssertEqual(ElevationService.interpolate(sampled: [0: 100], count: 3), [100, 100, 100])
    }

    func testInterpolationProducesOneValuePerPoint() {
        let indices = ElevationService.sampleIndices(count: 850)
        let sampled = Dictionary(uniqueKeysWithValues: indices.map { ($0, Double($0)) })
        XCTAssertEqual(ElevationService.interpolate(sampled: sampled, count: 850).count, 850)
    }

    // MARK: - Fetching

    func testProfileReturnsOneElevationPerPointAndComputesGain() async throws {
        // A steady climb: 100 m over the route.
        let service = makeService { _ in
            (200, self.body((0..<10).map { Double($0) * 10 }))
        }
        let outcome = try await service.profile(for: line(10))

        XCTAssertEqual(outcome.elevations.count, 10)
        XCTAssertEqual(outcome.sampled, 10)
        XCTAssertEqual(outcome.missing, 0)
        XCTAssertEqual(outcome.gain, 90, accuracy: 0.001)
    }

    /// One request per 100 locations, because the public instance caps a request
    /// there and answers a burst with a 429.
    func testLookupsAreBatchedAtAHundredLocations() async throws {
        let service = makeService { request in
            let locations = request.url?.query?
                .components(separatedBy: "locations=").last?
                .components(separatedBy: "%7C").count ?? 0
            return (200, self.body(Array(repeating: 500.0, count: locations)))
        }
        _ = try await service.profile(for: line(250))

        // 250 points sample to 200, which is two batches.
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testSingleBatchMakesOneRequest() async throws {
        let service = makeService { _ in (200, self.body(Array(repeating: 300.0, count: 50))) }
        _ = try await service.profile(for: line(50))
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    /// Nulls come back for coordinates outside the dataset's coverage. They must
    /// be filled from neighbours rather than read as sea level, which would
    /// invent a mountain's worth of gain.
    func testNullElevationsAreInterpolatedNotTreatedAsZero() async throws {
        let service = makeService { _ in (200, self.body([500, nil, nil, 560])) }
        let outcome = try await service.profile(for: line(4))

        XCTAssertEqual(outcome.missing, 2)
        XCTAssertEqual(outcome.elevations.first, 500)
        XCTAssertEqual(outcome.elevations.last, 560)
        XCTAssertTrue(outcome.elevations.allSatisfy { $0 >= 500 && $0 <= 560 },
                      "a missing point must not read as sea level")
        XCTAssertTrue(outcome.summary.contains("2 had no data"))
    }

    func testEntirelyMissingCoverageIsAnError() async {
        let service = makeService { _ in (200, self.body([nil, nil, nil])) }
        do {
            _ = try await service.profile(for: line(3))
            XCTFail("expected noData")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("coverage"))
        }
    }

    func testRateLimitingIsReportedAsSuch() async {
        let service = makeService { _ in (429, Data()) }
        do {
            _ = try await service.profile(for: line(3))
            XCTFail("expected rateLimited")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rate-limited"))
        }
    }

    func testServerErrorsSurfaceTheirStatus() async {
        let service = makeService { _ in (503, Data()) }
        do {
            _ = try await service.profile(for: line(3))
            XCTFail("expected a status error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("503"))
        }
    }

    func testMalformedResponsesFailRatherThanProduceAFlatProfile() async {
        let service = makeService { _ in (200, Data("{\"status\":\"ERROR\"}".utf8)) }
        do {
            _ = try await service.profile(for: line(3))
            XCTFail("expected an error")
        } catch {
            // Either decode failure or noData is acceptable; silently returning
            // a flat profile is not.
            XCTAssertNotNil(error.localizedDescription)
        }
    }

    func testARouteOfOnePointCannotHaveAProfile() async {
        let service = makeService { _ in (200, self.body([500])) }
        do {
            _ = try await service.profile(for: line(1))
            XCTFail("expected tooFewPoints")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("at least two"))
        }
        XCTAssertTrue(StubProtocol.requests.isEmpty, "shouldn't call out at all")
    }

    // MARK: - Request shape

    func testCoordinatesArePipeSeparatedAtSixDecimals() async throws {
        let service = makeService { _ in (200, self.body([500, 510])) }
        _ = try await service.profile(for: [
            CLLocationCoordinate2D(latitude: 42.123456789, longitude: 23.987654321),
            CLLocationCoordinate2D(latitude: 42.2, longitude: 23.9),
        ])

        let url = try XCTUnwrap(StubProtocol.requests.first?.url?.absoluteString)
        XCTAssertTrue(url.contains(ElevationService.dataset))
        let query = try XCTUnwrap(StubProtocol.requests.first?.url?
            .query(percentEncoded: false))
        XCTAssertTrue(query.contains("42.123457,23.987654"),
                      "six decimals is ~10cm, far past what 30m data resolves")
        XCTAssertTrue(query.contains("|"))
    }

    // MARK: - Applying to a route

    /// The stored gain has to be computed the same way an imported GPX's is, or
    /// two routes with identical terrain would report different climbs.
    func testFetchedGainMatchesTheImportedGPXCalculation() async throws {
        let elevations: [Double] = [500, 505, 503, 520, 518, 540]
        let service = makeService { _ in (200, self.body(elevations.map { Optional($0) })) }
        let outcome = try await service.profile(for: line(elevations.count))
        XCTAssertEqual(outcome.gain, GeoMath.elevationGain(elevations), accuracy: 0.001)
    }

    @MainActor
    func testProfileWritesThroughToTheRouteConsistently() async throws {
        let coordinates = line(6)
        let service = makeService { _ in (200, self.body([500, 510, 520, 515, 530, 540])) }
        let outcome = try await service.profile(for: coordinates)

        let route = Route(name: "Vitosha loop", sport: .run)
        route.setGeometry(coordinates: coordinates, elevations: outcome.elevations)

        XCTAssertEqual(route.elevations.count, coordinates.count)
        XCTAssertEqual(route.elevationGain ?? 0, outcome.gain, accuracy: 0.001)
        XCTAssertGreaterThan(route.distance, 0, "distance must be recomputed too")
        XCTAssertEqual(route.points.count, coordinates.count)
    }
}
