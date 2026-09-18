import XCTest
import CoreGraphics
@testable import FitnessTracker

/// Fitting a GPS track into a rectangle.
///
/// The failure mode here is silent: a route that's been squashed still looks
/// like a route, just not like *your* route.
final class RouteGeometryTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 200, height: 100)

    // MARK: - Degenerate input

    func testFewerThanTwoPointsDrawsNothing() {
        XCTAssertTrue(RouteGeometry.path(for: [], in: rect).isEmpty)
        XCTAssertTrue(RouteGeometry.path(for: [[43.2, 27.9]], in: rect).isEmpty)
        XCTAssertFalse(RouteGeometry.isDrawable([[43.2, 27.9]]))
        XCTAssertTrue(RouteGeometry.isDrawable([[43.2, 27.9], [43.3, 27.9]]))
        // Two fixes in the same place is a stationary recording, not a route.
        XCTAssertFalse(RouteGeometry.isDrawable([[43.2, 27.9], [43.2, 27.9]]))
    }

    func testMalformedAndNonFinitePointsAreDropped() {
        let coordinates: [[Double]] = [
            [43.2, 27.9], [43.3],                // too short
            [Double.nan, 27.9], [43.4, .infinity],
            [43.5, 28.0],
        ]
        let path = RouteGeometry.path(for: coordinates, in: rect)
        XCTAssertEqual(path.count, 2, "only the two good fixes survive")
        XCTAssertTrue(path.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func testAllPointsIdenticalDoesNotDivideByZero() {
        let path = RouteGeometry.path(for: Array(repeating: [43.2, 27.9], count: 5),
                                      in: rect)
        XCTAssertEqual(path.count, 5)
        XCTAssertTrue(path.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        // Everything lands on one spot, centred rather than pinned to an edge.
        XCTAssertEqual(path[0].x, rect.midX, accuracy: 0.001)
        XCTAssertEqual(path[0].y, rect.midY, accuracy: 0.001)
    }

    func testZeroSizedRectDrawsNothing() {
        XCTAssertTrue(RouteGeometry.path(for: [[43.2, 27.9], [43.3, 28.0]],
                                         in: .zero).isEmpty)
        XCTAssertTrue(RouteGeometry.path(for: [[43.2, 27.9], [43.3, 28.0]],
                                         in: rect, inset: 200).isEmpty)
    }

    // MARK: - Fitting

    func testEverythingLandsInsideTheRect() {
        let coordinates = (0..<50).map { i -> [Double] in
            [43.2 + Double(i) * 0.001, 27.9 + sin(Double(i) / 5) * 0.01]
        }
        let path = RouteGeometry.path(for: coordinates, in: rect, inset: 8)
        XCTAssertEqual(path.count, 50)
        for point in path {
            XCTAssertTrue((8...192).contains(point.x), "x \(point.x) escaped")
            XCTAssertTrue((8...92).contains(point.y), "y \(point.y) escaped")
        }
    }

    /// The point of a single scale factor: a square route has to come out
    /// square, not stretched to fill a wide card.
    func testAspectRatioIsPreserved() {
        // A square in real distance terms at this latitude.
        let latitude = 43.2
        let lonScale = cos(latitude * .pi / 180)
        let square: [[Double]] = [
            [latitude, 27.9],
            [latitude + 0.01, 27.9],
            [latitude + 0.01, 27.9 + 0.01 / lonScale],
            [latitude, 27.9 + 0.01 / lonScale],
            [latitude, 27.9],
        ]
        let path = RouteGeometry.path(for: square, in: rect)

        let width = path.map(\.x).max()! - path.map(\.x).min()!
        let height = path.map(\.y).max()! - path.map(\.y).min()!
        XCTAssertEqual(width, height, accuracy: 0.5,
                       "a square route came out \(width)×\(height)")
    }

    /// A degree of longitude is shorter than a degree of latitude everywhere
    /// but the equator. Ignoring that draws east–west routes too wide.
    func testLongitudeIsScaledByLatitude() {
        // Equal degree spans, at a latitude where they are not equal distances.
        let coordinates: [[Double]] = [[60.0, 20.0], [60.01, 20.01]]
        let path = RouteGeometry.path(for: coordinates, in: CGRect(x: 0, y: 0,
                                                                   width: 400, height: 400))
        let dx = abs(path[1].x - path[0].x)
        let dy = abs(path[1].y - path[0].y)
        // At 60°N, cos ≈ 0.5, so the east–west leg is about half as long.
        XCTAssertEqual(dx / dy, 0.5, accuracy: 0.02)
    }

    /// Near the poles cos(lat) collapses; the floor stops the scale exploding.
    func testExtremeLatitudeStaysFinite() {
        let path = RouteGeometry.path(for: [[89.999, 0], [89.999, 180]], in: rect)
        XCTAssertTrue(path.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        for point in path {
            XCTAssertTrue((0...200).contains(point.x))
        }
    }

    // MARK: - Orientation

    /// Latitude increases northwards and screen y increases downwards, so the
    /// northernmost point must be at the *top*. Getting this wrong draws every
    /// route upside down, which looks plausible until you know the road.
    func testNorthIsUp() {
        let south: [Double] = [43.20, 27.9]
        let north: [Double] = [43.30, 27.9]
        let path = RouteGeometry.path(for: [south, north], in: rect)
        XCTAssertLessThan(path[1].y, path[0].y, "north drawn below south")
    }

    func testEastIsRight() {
        let west: [Double] = [43.2, 27.90]
        let east: [Double] = [43.2, 28.00]
        let path = RouteGeometry.path(for: [west, east], in: rect)
        XCTAssertGreaterThan(path[1].x, path[0].x, "east drawn left of west")
    }

    func testPointOrderIsPreserved() {
        let coordinates: [[Double]] = [[43.20, 27.90], [43.25, 27.95], [43.30, 28.00]]
        let path = RouteGeometry.path(for: coordinates, in: rect)
        XCTAssertEqual(path.count, 3)
        // Monotonic in both axes, as the input is.
        XCTAssertLessThan(path[0].x, path[1].x)
        XCTAssertLessThan(path[1].x, path[2].x)
        XCTAssertGreaterThan(path[0].y, path[1].y)
    }

    // MARK: - Centring

    /// A route that doesn't fill the rect is centred in the leftover space
    /// rather than pinned to a corner.
    func testLeftoverSpaceIsSplitEvenly() {
        // Tall and narrow: it will fit the height and leave width over.
        let coordinates: [[Double]] = [[43.20, 27.90], [43.40, 27.90001]]
        let path = RouteGeometry.path(for: coordinates, in: rect)
        let midX = (path.map(\.x).min()! + path.map(\.x).max()!) / 2
        XCTAssertEqual(midX, rect.midX, accuracy: 0.5)
    }

    func testInsetIsRespectedOnEveryEdge() {
        let coordinates = (0..<20).map { i -> [Double] in
            [43.2 + Double(i % 5) * 0.01, 27.9 + Double(i / 5) * 0.01]
        }
        let path = RouteGeometry.path(for: coordinates, in: rect, inset: 20)
        XCTAssertGreaterThanOrEqual(path.map(\.x).min()!, 20 - 0.001)
        XCTAssertLessThanOrEqual(path.map(\.x).max()!, 180 + 0.001)
        XCTAssertGreaterThanOrEqual(path.map(\.y).min()!, 20 - 0.001)
        XCTAssertLessThanOrEqual(path.map(\.y).max()!, 80 + 0.001)
    }
}

/// Speed formatting, which the share card uses for rides.
final class SpeedFormattingTests: XCTestCase {

    func testMetricSpeedFromMetresPerSecond() {
        let units = UnitFormatter(.metric)
        // 10 m/s is 36 km/h.
        XCTAssertEqual(units.speed(10), "36.0 km/h")
        XCTAssertEqual(units.speed(8.333), "30.0 km/h")
        XCTAssertEqual(units.speedUnit, "km/h")
    }

    func testImperialSpeedFromMetresPerSecond() {
        let units = UnitFormatter(.imperial)
        // 10 m/s is 22.4 mph.
        XCTAssertEqual(units.speed(10), "22.4 mph")
        XCTAssertEqual(units.speedUnit, "mph")
    }

    func testNonsenseSpeedsDegrade() {
        let units = UnitFormatter(.metric)
        XCTAssertEqual(units.speed(nil), "–")
        XCTAssertEqual(units.speed(0), "–")
        XCTAssertEqual(units.speed(-5), "–")
        XCTAssertEqual(units.speed(.nan), "–")
        XCTAssertEqual(units.speed(.infinity), "–")
    }

    /// Speed and pace have to describe the same movement.
    func testSpeedAndPaceAgree() {
        let units = UnitFormatter(.metric)
        // 5 m/s = 18 km/h = 200 s/km = 3:20/km.
        XCTAssertEqual(units.speed(5), "18.0 km/h")
        XCTAssertEqual(units.pace(200), "3:20/km")
    }
}

/// How each sport states its rate.
final class SportRateFormattingTests: XCTestCase {

    private let metric = UnitFormatter(.metric)

    func testRidesReadAsSpeed() {
        // 120 s/km is 30 km/h.
        XCTAssertEqual(metric.rate(120, sport: .bike), "30.0 km/h")
        XCTAssertEqual(metric.rateLabel(for: .bike), "Speed")
    }

    func testRunsReadAsPace() {
        XCTAssertEqual(metric.rate(300, sport: .run), "5:00/km")
        XCTAssertEqual(metric.rate(300, sport: .trailRun), "5:00/km")
        XCTAssertEqual(metric.rateLabel(for: .run), "Pace")
    }

    func testSwimsReadAsPerHundred() {
        // 1000 s/km is 100 s per 100 m.
        XCTAssertEqual(metric.rate(1000, sport: .swim), "1:40/100 m")
        XCTAssertEqual(metric.rateLabel(for: .swim), "Pace")
    }

    func testWalksAndHikesReadAsPace() {
        XCTAssertEqual(metric.rate(600, sport: .walk), "10:00/km")
        XCTAssertEqual(metric.rate(600, sport: .hike), "10:00/km")
    }

    func testNonsenseDegradesForEverySport() {
        for sport in WorkoutSport.allCases {
            XCTAssertEqual(metric.rate(nil, sport: sport), "–")
            XCTAssertEqual(metric.rate(0, sport: sport), "–")
            XCTAssertEqual(metric.rate(.nan, sport: sport), "–")
        }
    }

    func testImperialRidesReadAsMph() {
        let imperial = UnitFormatter(.imperial)
        // 120 s/km = 30 km/h = 18.6 mph.
        XCTAssertEqual(imperial.rate(120, sport: .bike), "18.6 mph")
    }
}
