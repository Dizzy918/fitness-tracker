import XCTest
import SwiftData
import CoreLocation
@testable import FitnessTracker

final class GeoMathTests: XCTestCase {

    private let sofia = CLLocationCoordinate2D(latitude: 42.6977, longitude: 23.3219)

    func testKnownDistance() {
        // Sofia → Plovdiv is about 133 km great-circle.
        let plovdiv = CLLocationCoordinate2D(latitude: 42.1354, longitude: 24.7453)
        let d = GeoMath.distance(from: sofia, to: plovdiv)
        XCTAssertEqual(d, 133_000, accuracy: 3_000)
    }

    func testOneDegreeOfLatitude() {
        // A degree of latitude is ~111.2 km anywhere on Earth.
        let north = CLLocationCoordinate2D(latitude: 43.6977, longitude: 23.3219)
        XCTAssertEqual(GeoMath.distance(from: sofia, to: north), 111_200, accuracy: 500)
    }

    func testZeroDistanceForSamePoint() {
        XCTAssertEqual(GeoMath.distance(from: sofia, to: sofia), 0, accuracy: 0.001)
    }

    func testPathDistanceSumsSegments() {
        let a = CLLocationCoordinate2D(latitude: 42.0, longitude: 23.0)
        let b = CLLocationCoordinate2D(latitude: 42.01, longitude: 23.0)
        let c = CLLocationCoordinate2D(latitude: 42.02, longitude: 23.0)

        let leg = GeoMath.distance(from: a, to: b)
        XCTAssertEqual(GeoMath.pathDistance([a, b, c]), leg * 2, accuracy: 5)
        XCTAssertEqual(GeoMath.pathDistance([a]), 0)
        XCTAssertEqual(GeoMath.pathDistance([]), 0)
    }

    func testCumulativeDistancesStartAtZero() {
        let points = (0..<5).map {
            CLLocationCoordinate2D(latitude: 42.0 + Double($0) * 0.01, longitude: 23.0)
        }
        let cumulative = GeoMath.cumulativeDistances(points)
        XCTAssertEqual(cumulative.count, 5)
        XCTAssertEqual(cumulative[0], 0)
        XCTAssertEqual(cumulative.last!, GeoMath.pathDistance(points), accuracy: 1)
        // Must be monotonically increasing.
        XCTAssertEqual(cumulative, cumulative.sorted())
    }

    func testElevationGainIgnoresNoise() {
        // A clean 100 m climb.
        XCTAssertEqual(GeoMath.elevationGain([100, 150, 200]), 100, accuracy: 0.1)
        // Jitter under the threshold must not accumulate into fake gain.
        let noisy = (0..<100).map { i in 100.0 + (i % 2 == 0 ? 0.3 : -0.3) }
        XCTAssertEqual(GeoMath.elevationGain(noisy), 0, accuracy: 0.5)
        // Descent-only contributes nothing.
        XCTAssertEqual(GeoMath.elevationGain([300, 200, 100]), 0, accuracy: 0.1)
        XCTAssertEqual(GeoMath.elevationGain([100]), 0)
    }

    func testRollingTerrainGain() {
        // Up 50, down 50, up 50 → 100 total gain.
        XCTAssertEqual(GeoMath.elevationGain([100, 150, 100, 150]), 100, accuracy: 0.5)
    }

    func testLoopDetection() {
        let start = CLLocationCoordinate2D(latitude: 42.0, longitude: 23.0)
        let loop = [
            start,
            CLLocationCoordinate2D(latitude: 42.01, longitude: 23.0),
            CLLocationCoordinate2D(latitude: 42.01, longitude: 23.01),
            CLLocationCoordinate2D(latitude: 42.0001, longitude: 23.0001),
        ]
        XCTAssertTrue(GeoMath.isLoop(loop))

        let outAndBack = [
            start,
            CLLocationCoordinate2D(latitude: 42.05, longitude: 23.0),
            CLLocationCoordinate2D(latitude: 42.10, longitude: 23.0),
            CLLocationCoordinate2D(latitude: 42.15, longitude: 23.0),
        ]
        XCTAssertFalse(GeoMath.isLoop(outAndBack))
        XCTAssertFalse(GeoMath.isLoop([start, start]), "too few points to be a loop")
    }

    func testBoundingRegionCoversAllPoints() throws {
        let points = [
            CLLocationCoordinate2D(latitude: 42.0, longitude: 23.0),
            CLLocationCoordinate2D(latitude: 42.1, longitude: 23.2),
        ]
        let region = try XCTUnwrap(GeoMath.boundingRegion(points))
        XCTAssertEqual(region.center.latitude, 42.05, accuracy: 0.001)
        XCTAssertEqual(region.center.longitude, 23.1, accuracy: 0.001)
        XCTAssertGreaterThan(region.span.lat, 0.1)
        XCTAssertNil(GeoMath.boundingRegion([]))
    }
}

final class GPXTests: XCTestCase {

    private let points = [
        GPX.Point(CLLocationCoordinate2D(latitude: 42.6977, longitude: 23.3219), elevation: 550),
        GPX.Point(CLLocationCoordinate2D(latitude: 42.7050, longitude: 23.3300), elevation: 585.5),
        GPX.Point(CLLocationCoordinate2D(latitude: 42.7100, longitude: 23.3400)),
    ]

    func testExportProducesValidStructure() {
        let gpx = GPX.export(points: points, name: "Vitosha Loop")

        XCTAssertTrue(gpx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(gpx.contains("<gpx version=\"1.1\""))
        XCTAssertTrue(gpx.contains("http://www.topografix.com/GPX/1/1"))
        XCTAssertTrue(gpx.contains("<name>Vitosha Loop</name>"))
        XCTAssertTrue(gpx.contains("<trkseg>"))
        XCTAssertTrue(gpx.contains("<ele>550.0</ele>"))
        XCTAssertTrue(gpx.hasSuffix("</gpx>\n"))
        XCTAssertEqual(gpx.components(separatedBy: "trkpt lat=").count - 1, 3)
    }

    func testExportEscapesXMLInNames() {
        let gpx = GPX.export(points: points, name: "Tom & Jerry's <route>")
        XCTAssertTrue(gpx.contains("Tom &amp; Jerry&apos;s &lt;route&gt;"))
        XCTAssertFalse(gpx.contains("<route>"), "raw angle brackets would break the XML")
    }

    func testExportIsParseableXML() throws {
        let gpx = GPX.export(points: points, name: "Round trip")
        let parser = XMLParser(data: Data(gpx.utf8))
        XCTAssertTrue(parser.parse(), "exported GPX must be well-formed XML")
    }

    func testRoundTripPreservesCoordinates() throws {
        let gpx = GPX.export(points: points, name: "Round trip")
        let parsed = try GPX.parse(data: Data(gpx.utf8))

        XCTAssertEqual(parsed.name, "Round trip")
        XCTAssertEqual(parsed.points.count, 3)
        XCTAssertEqual(parsed.points[0].coordinate.latitude, 42.6977, accuracy: 0.0000001)
        XCTAssertEqual(parsed.points[0].coordinate.longitude, 23.3219, accuracy: 0.0000001)
        XCTAssertEqual(parsed.points[0].elevation ?? 0, 550, accuracy: 0.1)
        XCTAssertEqual(parsed.points[1].elevation ?? 0, 585.5, accuracy: 0.1)
        XCTAssertNil(parsed.points[2].elevation)
    }

    func testParsesRoutePointsAsWellAsTracks() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1">
          <rte>
            <name>Planned</name>
            <rtept lat="42.1" lon="23.1"><ele>500</ele></rtept>
            <rtept lat="42.2" lon="23.2"/>
          </rte>
        </gpx>
        """
        let parsed = try GPX.parse(data: Data(gpx.utf8))
        XCTAssertEqual(parsed.name, "Planned")
        XCTAssertEqual(parsed.points.count, 2)
        XCTAssertEqual(parsed.points[0].elevation ?? 0, 500, accuracy: 0.1)
    }

    func testRejectsImpossibleCoordinates() throws {
        let gpx = """
        <gpx version="1.1"><trk><trkseg>
          <trkpt lat="200.0" lon="23.1"/>
          <trkpt lat="42.1" lon="500.0"/>
          <trkpt lat="42.2" lon="23.2"/>
        </trkseg></trk></gpx>
        """
        let parsed = try GPX.parse(data: Data(gpx.utf8))
        XCTAssertEqual(parsed.points.count, 1, "out-of-range coordinates are dropped")
        XCTAssertEqual(parsed.points[0].coordinate.latitude, 42.2, accuracy: 0.001)
    }

    func testMalformedAndEmptyInputThrow() {
        XCTAssertThrowsError(try GPX.parse(data: Data("not xml at all <<<".utf8)))
        XCTAssertThrowsError(try GPX.parse(data: Data("<gpx></gpx>".utf8))) { error in
            guard case GPX.ImportError.noPoints = error else {
                return XCTFail("expected noPoints, got \(error)")
            }
        }
    }
}

@MainActor
final class RouteModelTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Workout.self, Shoe.self, StrengthSession.self, SetEntry.self,
                Exercise.self, DailyMetric.self, Route.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private var square: [CLLocationCoordinate2D] {
        [
            CLLocationCoordinate2D(latitude: 42.00, longitude: 23.00),
            CLLocationCoordinate2D(latitude: 42.01, longitude: 23.00),
            CLLocationCoordinate2D(latitude: 42.01, longitude: 23.01),
            CLLocationCoordinate2D(latitude: 42.00, longitude: 23.00),
        ]
    }

    func testSetGeometryCachesSummary() throws {
        let context = try makeContext()
        let route = Route(name: "Test loop", sport: .run)
        context.insert(route)
        route.setGeometry(coordinates: square, elevations: [500, 540, 520, 500])
        try context.save()

        XCTAssertEqual(route.points.count, 4)
        XCTAssertEqual(route.distance, GeoMath.pathDistance(square), accuracy: 1)
        XCTAssertEqual(route.elevationGain ?? 0, 40, accuracy: 1, "only the 40 m climb counts")
        XCTAssertTrue(route.isLoop)
        XCTAssertEqual(route.coordinates.count, 4)
    }

    func testGeometryWithoutElevationsLeavesGainNil() throws {
        let context = try makeContext()
        let route = Route(name: "Flat", sport: .bike)
        context.insert(route)
        route.setGeometry(coordinates: square)
        XCTAssertNil(route.elevationGain)
        XCTAssertTrue(route.elevations.isEmpty)
    }

    func testGPXExportRoundTripsThroughTheModel() throws {
        let context = try makeContext()
        let route = Route(name: "Export me", sport: .trailRun)
        context.insert(route)
        route.setGeometry(coordinates: square, elevations: [500, 540, 520, 500])

        let parsed = try GPX.parse(data: Data(route.gpx.utf8))
        XCTAssertEqual(parsed.points.count, 4)
        XCTAssertEqual(parsed.name, "Export me")
        XCTAssertEqual(parsed.points[1].elevation ?? 0, 540, accuracy: 0.1)
    }

    func testFilenameIsFilesystemSafe() {
        let route = Route(name: "Vitosha / Aleko: loop")
        XCTAssertEqual(route.gpxFilename, "Vitosha - Aleko- loop.gpx")

        let unnamed = Route(name: "   ")
        XCTAssertEqual(unnamed.gpxFilename, "route.gpx")
    }

    func testSportRawRoundTrip() {
        let route = Route(name: "R", sport: .bike)
        XCTAssertEqual(route.sport, .bike)
        route.sport = .hike
        XCTAssertEqual(route.sportRaw, "hike")
    }
}

final class CyclingPowerTests: XCTestCase {

    /// Steady power stream at 1 Hz.
    private func steady(watts: Int, seconds: Int) -> [FITSample] {
        (0..<seconds).map {
            FITSample(t: Double($0), lat: nil, lon: nil, hr: nil, alt: nil,
                      speed: nil, cadence: nil, dist: nil, power: watts)
        }
    }

    func testSteadyPowerGivesNPEqualToAverage() throws {
        let summary = try XCTUnwrap(CyclingPower.summary(samples: steady(watts: 200, seconds: 600),
                                                        ftp: 250))
        XCTAssertEqual(summary.averagePower, 200, accuracy: 0.5)
        // For perfectly steady power, NP converges on the average.
        XCTAssertEqual(summary.normalizedPower, 200, accuracy: 3)
        XCTAssertEqual(summary.variabilityIndex, 1.0, accuracy: 0.02)
    }

    func testNPExceedsAverageForVariablePower() throws {
        // Alternating 100/300 W averages 200 but is far harder than steady 200.
        var samples: [FITSample] = []
        for i in 0..<600 {
            samples.append(FITSample(t: Double(i), lat: nil, lon: nil, hr: nil, alt: nil,
                                     speed: nil, cadence: nil, dist: nil,
                                     power: (i / 60) % 2 == 0 ? 100 : 300))
        }
        let summary = try XCTUnwrap(CyclingPower.summary(samples: samples, ftp: 250))
        XCTAssertEqual(summary.averagePower, 200, accuracy: 2)
        XCTAssertGreaterThan(summary.normalizedPower, summary.averagePower)
        XCTAssertGreaterThan(summary.variabilityIndex, 1.05)
    }

    func testIntensityFactorAndTSS() throws {
        // One hour exactly at FTP should be IF 1.0 and TSS ~100 by definition.
        let summary = try XCTUnwrap(CyclingPower.summary(samples: steady(watts: 250, seconds: 3601),
                                                        ftp: 250))
        XCTAssertEqual(try XCTUnwrap(summary.intensityFactor), 1.0, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(summary.trainingStressScore), 100, accuracy: 3)
    }

    func testHalfHourAtHalfIntensityIsLowTSS() throws {
        let summary = try XCTUnwrap(CyclingPower.summary(samples: steady(watts: 125, seconds: 1800),
                                                        ftp: 250))
        // IF 0.5 for 0.5 h → TSS = 0.5 × 0.5² × 100 = 12.5
        XCTAssertEqual(try XCTUnwrap(summary.trainingStressScore), 12.5, accuracy: 1.5)
    }

    func testNoFTPMeansNoIntensityOrTSS() throws {
        let summary = try XCTUnwrap(CyclingPower.summary(samples: steady(watts: 200, seconds: 600),
                                                        ftp: nil))
        XCTAssertNil(summary.intensityFactor)
        XCTAssertNil(summary.trainingStressScore)
        XCTAssertEqual(summary.averagePower, 200, accuracy: 0.5)
    }

    func testNilWithoutPowerData() {
        let noPower = (0..<100).map {
            FITSample(t: Double($0), lat: nil, lon: nil, hr: 140, alt: nil,
                      speed: nil, cadence: nil, dist: nil, power: nil)
        }
        XCTAssertNil(CyclingPower.summary(samples: noPower, ftp: 250))
        XCTAssertNil(CyclingPower.summary(samples: [], ftp: 250))
    }

    func testZeroFTPDoesNotDivideByZero() throws {
        let summary = try XCTUnwrap(CyclingPower.summary(samples: steady(watts: 200, seconds: 300),
                                                        ftp: 0))
        XCTAssertNil(summary.intensityFactor)
        XCTAssertNil(summary.trainingStressScore)
    }

    func testBestAverageFindsTheHardestBlock() throws {
        // 10 min at 150 W, then 5 min at 300 W.
        var samples = steady(watts: 150, seconds: 600)
        for i in 0..<300 {
            samples.append(FITSample(t: Double(600 + i), lat: nil, lon: nil, hr: nil, alt: nil,
                                     speed: nil, cadence: nil, dist: nil, power: 300))
        }
        let best5min = try XCTUnwrap(CyclingPower.bestAverage(seconds: 300, samples: samples))
        XCTAssertEqual(best5min, 300, accuracy: 6)

        XCTAssertNil(CyclingPower.bestAverage(seconds: 7200, samples: samples),
                     "can't report a window longer than the ride")
    }
}

final class SwimMetricsTests: XCTestCase {

    func testPacePer100() throws {
        // 2000 m in 40:00 → 2:00/100 m.
        let summary = try XCTUnwrap(SwimMetrics.summary(distance: 2000, duration: 2400, samples: []))
        XCTAssertEqual(summary.pacePer100, 120, accuracy: 0.5)
        XCTAssertEqual(summary.pacePer100Formatted, "2:00")
    }

    func testStrokeRateFromCadence() throws {
        let samples = (0..<20).map {
            FITSample(t: Double($0) * 15, lat: nil, lon: nil, hr: 130, alt: nil,
                      speed: nil, cadence: 32, dist: nil, power: nil)
        }
        let summary = try XCTUnwrap(SwimMetrics.summary(distance: 1500, duration: 1800,
                                                        samples: samples))
        XCTAssertEqual(try XCTUnwrap(summary.strokeRate), 32, accuracy: 0.1)
    }

    func testLengthsAndSwolfWithPoolLength() throws {
        let samples = (0..<20).map {
            FITSample(t: Double($0) * 15, lat: nil, lon: nil, hr: 130, alt: nil,
                      speed: nil, cadence: 30, dist: nil, power: nil)
        }
        // 1000 m in a 25 m pool = 40 lengths.
        let summary = try XCTUnwrap(SwimMetrics.summary(distance: 1000, duration: 1200,
                                                        samples: samples, poolLength: 25))
        XCTAssertEqual(summary.lengths, 40)
        // 30 s per length + 15 strokes = SWOLF 45.
        XCTAssertEqual(try XCTUnwrap(summary.swolf), 45, accuracy: 1)
    }

    func testNoPoolLengthMeansNoLengthsOrSwolf() throws {
        let summary = try XCTUnwrap(SwimMetrics.summary(distance: 1000, duration: 1200, samples: []))
        XCTAssertNil(summary.lengths)
        XCTAssertNil(summary.swolf)
    }

    func testRejectsDegenerateInput() {
        XCTAssertNil(SwimMetrics.summary(distance: 0, duration: 1200, samples: []))
        XCTAssertNil(SwimMetrics.summary(distance: 1000, duration: 0, samples: []))
    }
}

final class RacePredictionTests: XCTestCase {

    private func record(distance: Double, label: String, time: TimeInterval) -> PersonalRecord {
        PersonalRecord(distance: distance, label: label, time: time,
                       date: .now, workoutID: UUID())
    }

    func testRiegelPredictsSlowerOverLongerDistance() throws {
        // 20:00 5 km → roughly 41:36 for 10 km.
        let tenK = try XCTUnwrap(RacePrediction.predict(time: 1200, distance: 5000, target: 10_000))
        XCTAssertEqual(tenK, 2496, accuracy: 30)
        XCTAssertGreaterThan(tenK, 2400, "doubling distance must cost more than doubling time")
    }

    func testPredictsFasterOverShorterDistance() throws {
        let fiveK = try XCTUnwrap(RacePrediction.predict(time: 2496, distance: 10_000, target: 5000))
        XCTAssertEqual(fiveK, 1200, accuracy: 30)
    }

    func testRejectsInvalidInput() {
        XCTAssertNil(RacePrediction.predict(time: 0, distance: 5000, target: 10_000))
        XCTAssertNil(RacePrediction.predict(time: 1200, distance: 0, target: 10_000))
        XCTAssertNil(RacePrediction.predict(time: 1200, distance: 5000, target: 0))
    }

    func testPredictionsUseTheLongestKnownEffort() throws {
        let records = [
            record(distance: 1000, label: "1 km", time: 200),
            record(distance: 10_000, label: "10 km", time: 2400),
        ]
        let predictions = RacePrediction.predictions(from: records)

        // The 10 km must not appear as a prediction of itself.
        XCTAssertFalse(predictions.contains { $0.label == "10 km" })

        let marathon = try XCTUnwrap(predictions.first { $0.label == "Marathon" })
        // From a 40:00 10 km, a marathon lands near 3:05–3:15, not 2:48.
        XCTAssertGreaterThan(marathon.time, 3 * 3600)
        XCTAssertLessThan(marathon.time, 3.5 * 3600)
    }

    func testLongExtrapolationsAreFlaggedSpeculative() throws {
        let predictions = RacePrediction.predictions(from: [
            record(distance: 1000, label: "1 km", time: 200)
        ])
        let marathon = try XCTUnwrap(predictions.first { $0.label == "Marathon" })
        XCTAssertTrue(marathon.isSpeculative, "42× extrapolation should be flagged")

        let fiveK = try XCTUnwrap(predictions.first { $0.label == "5 km" })
        XCTAssertTrue(fiveK.isSpeculative, "5× is still a stretch")
    }

    func testEmptyRecordsProduceNothing() {
        XCTAssertTrue(RacePrediction.predictions(from: []).isEmpty)
        XCTAssertNil(RacePrediction.trainingPaces(from: []))
    }

    func testTrainingPaceBandsAreOrdered() throws {
        let paces = try XCTUnwrap(RacePrediction.trainingPaces(from: [
            record(distance: 10_000, label: "10 km", time: 2400)   // 4:00/km
        ]))
        // Easy is slower (larger sec/km) than interval.
        XCTAssertGreaterThan(paces.easy.lowerBound, paces.interval.upperBound)
        XCTAssertGreaterThan(paces.easy.lowerBound, paces.threshold.upperBound)
        // Bands are contiguous by design: no gaps between adjacent zones, so
        // adjoining bounds touch rather than overlap.
        XCTAssertLessThanOrEqual(paces.interval.upperBound, paces.threshold.lowerBound)

        // Threshold should sit near the source 10 km pace of 240 s/km.
        XCTAssertTrue(paces.threshold.contains(240), "threshold band should include 10k pace")
        XCTAssertEqual(paces.bands.count, 5)
    }
}

@MainActor
final class StrengthAnalysisTests: XCTestCase {

    private func session(daysAgo: Int, sets: [StrengthSetSnapshot]) -> StrengthSessionSnapshot {
        StrengthSessionSnapshot(
            id: UUID(),
            startedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!,
            sets: sets
        )
    }

    private func set(_ category: String, weight: Double, reps: Int,
                     warmup: Bool = false, id: UUID = UUID()) -> StrengthSetSnapshot {
        StrengthSetSnapshot(reps: reps, weightKg: weight, isWarmup: warmup,
                            exerciseID: id, category: category)
    }

    func testVolumeByCategoryExcludesWarmups() throws {
        let sessions = [session(daysAgo: 1, sets: [
            set("squat", weight: 100, reps: 5),
            set("squat", weight: 100, reps: 5),
            set("squat", weight: 50, reps: 5, warmup: true),
            set("push", weight: 60, reps: 8),
        ])]

        let volumes = StrengthAnalysis.volumeByCategory(sessions: sessions)
        let squat = try XCTUnwrap(volumes.first { $0.category == "squat" })
        XCTAssertEqual(squat.volume, 1000, accuracy: 0.1, "warmup set must not count")
        XCTAssertEqual(squat.sets, 2)

        let push = try XCTUnwrap(volumes.first { $0.category == "push" })
        XCTAssertEqual(push.volume, 480, accuracy: 0.1)
    }

    func testCategoriesKeepCanonicalOrder() {
        let sessions = [session(daysAgo: 1, sets: [
            set("accessory", weight: 20, reps: 12),
            set("push", weight: 60, reps: 5),
            set("squat", weight: 100, reps: 5),
        ])]
        let order = StrengthAnalysis.volumeByCategory(sessions: sessions).map(\.category)
        XCTAssertEqual(order, ["squat", "push", "accessory"])
    }

    func testUnknownCategoriesAppearAfterKnownOnes() {
        let sessions = [session(daysAgo: 1, sets: [
            set("grip", weight: 40, reps: 10),
            set("squat", weight: 100, reps: 5),
        ])]
        let order = StrengthAnalysis.volumeByCategory(sessions: sessions).map(\.category)
        XCTAssertEqual(order, ["squat", "grip"])
    }

    func testSinceFilter() {
        let sessions = [
            session(daysAgo: 40, sets: [set("squat", weight: 100, reps: 5)]),
            session(daysAgo: 2, sets: [set("squat", weight: 120, reps: 5)]),
        ]
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
        let recent = StrengthAnalysis.volumeByCategory(sessions: sessions, since: cutoff)
        XCTAssertEqual(recent.first?.volume ?? 0, 600, accuracy: 0.1)
    }

    func testWeeklyVolumeIsChronological() {
        let sessions = [
            session(daysAgo: 20, sets: [set("squat", weight: 100, reps: 5)]),
            session(daysAgo: 3, sets: [set("squat", weight: 100, reps: 5)]),
        ]
        let weekly = StrengthAnalysis.weeklyVolume(sessions: sessions)
        XCTAssertEqual(weekly.count, 2)
        XCTAssertLessThan(weekly[0].weekStart, weekly[1].weekStart)
    }

    func testE1RMHistoryAndPRDetection() {
        let squatID = UUID()
        let sessions = [
            session(daysAgo: 21, sets: [set("squat", weight: 100, reps: 5, id: squatID)]),
            session(daysAgo: 14, sets: [set("squat", weight: 95, reps: 5, id: squatID)]),
            session(daysAgo: 7, sets: [set("squat", weight: 110, reps: 5, id: squatID)]),
        ]

        let history = StrengthAnalysis.e1RMHistory(sessions: sessions, exerciseID: squatID)
        XCTAssertEqual(history.count, 3)
        XCTAssertLessThan(history[0].date, history[2].date)

        // Only the first and the 110 kg session are records; 95 kg is not.
        let prs = StrengthAnalysis.personalRecordDates(sessions: sessions, exerciseID: squatID)
        XCTAssertEqual(prs.count, 2)
        XCTAssertEqual(prs.last?.e1rm ?? 0, 110 * (1 + 5.0 / 30.0), accuracy: 0.01)
    }

    func testUnknownExerciseHasNoHistory() {
        let sessions = [session(daysAgo: 1, sets: [set("squat", weight: 100, reps: 5)])]
        XCTAssertTrue(StrengthAnalysis.e1RMHistory(sessions: sessions,
                                                   exerciseID: UUID()).isEmpty)
    }

    func testEmptyInput() {
        XCTAssertTrue(StrengthAnalysis.volumeByCategory(sessions: []).isEmpty)
        XCTAssertTrue(StrengthAnalysis.weeklyVolume(sessions: []).isEmpty)
    }
}
