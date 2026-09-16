import XCTest
import FitDataProtocol
import AntMessageProtocol
@testable import FitnessTracker

final class FITImporterTests: XCTestCase {

    /// Build a synthetic Suunto-like activity FIT file in memory.
    private func makeFITData(
        sport: Sport = .running,
        subSport: SubSport? = nil,
        start: Date,
        duration: TimeInterval = 1800,
        distance: Double = 5000,
        avgHR: UInt8 = 150,
        maxHR: UInt8 = 172,
        ascent: Double = 42,
        kcal: Double = 380,
        recordCount: Int = 5
    ) throws -> Data {
        let fileId = FileIdMessage(
            deviceSerialNumber: 1234,
            fileCreationDate: FitTime(date: start),
            manufacturer: .suunto,
            fileType: FileType.activity
        )

        let session = SessionMessage(
            startTime: FitTime(date: start),
            sport: sport,
            subSport: subSport,
            totalElapsedTime: Measurement(value: duration, unit: UnitDuration.seconds),
            totalDistance: Measurement(value: distance, unit: UnitLength.meters),
            totalCalories: Measurement(value: kcal, unit: UnitEnergy.kilocalories),
            averageHeartRate: avgHR,
            maximumHeartRate: maxHR,
            totalAscent: Measurement(value: ascent, unit: UnitLength.meters)
        )

        var messages: [FitMessage] = [session]

        // Records climbing steadily north-east, gaining altitude.
        for i in 0..<recordCount {
            let t = start.addingTimeInterval(Double(i) * 10)
            let rec = RecordMessage(
                timeStamp: FitTime(date: t),
                position: Position(
                    latitude: Measurement(value: 42.6977 + Double(i) * 0.001, unit: UnitAngle.degrees),
                    longitude: Measurement(value: 23.3219 + Double(i) * 0.001, unit: UnitAngle.degrees)
                ),
                altitude: Measurement(value: 500 + Double(i) * 5, unit: UnitLength.meters),
                speed: Measurement(value: 2.8, unit: UnitSpeed.metersPerSecond),
                heartRate: UInt8(140 + i),
                cadence: UInt8(80)
            )
            messages.append(rec)
        }

        let lap = LapMessage(
            startTime: FitTime(date: start),
            totalElapsedTime: Measurement(value: 900, unit: UnitDuration.seconds),
            totalDistance: Measurement(value: 2500, unit: UnitLength.meters),
            averageHeartRate: 148
        )
        messages.append(lap)

        let encoder = FitFileEncoder(dataValidityStrategy: .none)
        switch encoder.encode(fildIdMessage: fileId, messages: messages) {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    func testDecodeSummaryFields() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try makeFITData(start: start)

        let decoded = try FITImporter().decode(data: data)

        XCTAssertEqual(decoded.sport, .run)
        XCTAssertEqual(decoded.duration, 1800, accuracy: 1)
        XCTAssertEqual(decoded.distance, 5000, accuracy: 1)
        XCTAssertEqual(decoded.avgHR, 150)
        XCTAssertEqual(decoded.maxHR, 172)
        XCTAssertEqual(decoded.elevationGain ?? 0, 42, accuracy: 1)
        XCTAssertEqual(decoded.calories ?? 0, 380, accuracy: 1)
        // FIT timestamps have 1s resolution.
        XCTAssertEqual(decoded.startedAt.timeIntervalSince1970,
                       start.timeIntervalSince1970, accuracy: 1)
    }

    func testDecodeTrackAndSamples() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try makeFITData(start: start, recordCount: 5)

        let decoded = try FITImporter().decode(data: data)

        XCTAssertEqual(decoded.coordinates.count, 5)
        XCTAssertEqual(decoded.samples.count, 5)

        // Semicircle round-trip should preserve degrees to ~1e-5.
        let first = try XCTUnwrap(decoded.coordinates.first)
        XCTAssertEqual(first[0], 42.6977, accuracy: 0.0001)
        XCTAssertEqual(first[1], 23.3219, accuracy: 0.0001)

        // Samples must be rebased to offsets from start, in order.
        XCTAssertEqual(decoded.samples[0].t, 0, accuracy: 1)
        XCTAssertEqual(decoded.samples[4].t, 40, accuracy: 1)
        XCTAssertEqual(decoded.samples[0].hr, 140)
        XCTAssertEqual(decoded.samples[4].hr, 144)
        XCTAssertEqual(decoded.samples[0].cadence, 80)
        XCTAssertEqual(try XCTUnwrap(decoded.samples[0].speed), 2.8, accuracy: 0.05)
    }

    func testLapsDecoded() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try makeFITData(start: start)

        let decoded = try FITImporter().decode(data: data)

        XCTAssertEqual(decoded.laps.count, 1)
        let lap = try XCTUnwrap(decoded.laps.first)
        XCTAssertEqual(lap.distance, 2500, accuracy: 1)
        XCTAssertEqual(lap.duration, 900, accuracy: 1)
        XCTAssertEqual(lap.avgHR, 148)
        // 900s / 2.5km = 360 s/km
        XCTAssertEqual(try XCTUnwrap(lap.paceSecPerKm), 360, accuracy: 1)
    }

    func testTrailSubSportMapsToTrailRun() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try makeFITData(sport: .running, subSport: .trail, start: start)

        let decoded = try FITImporter().decode(data: data)

        XCTAssertEqual(decoded.sport, .trailRun)
    }

    func testSportMapping() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(Sport, WorkoutSport)] = [
            (.cycling, .bike),
            (.swimming, .swim),
            (.hiking, .hike),
            (.walking, .walk),
            (.rowing, .other),
        ]
        for (fitSport, expected) in cases {
            let data = try makeFITData(sport: fitSport, start: start)
            let decoded = try FITImporter().decode(data: data)
            XCTAssertEqual(decoded.sport, expected, "sport \(fitSport) should map to \(expected)")
        }
    }

    func testExternalIDIsStableAndContentAddressed() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try makeFITData(start: start, distance: 5000)
        let b = try makeFITData(start: start, distance: 5000)
        let c = try makeFITData(start: start, distance: 9999)

        let idA = try FITImporter().decode(data: a).externalID
        let idB = try FITImporter().decode(data: b).externalID
        let idC = try FITImporter().decode(data: c).externalID

        XCTAssertEqual(idA, idB, "identical bytes must produce identical IDs")
        XCTAssertNotEqual(idA, idC, "different content must produce different IDs")
        XCTAssertTrue(idA.hasPrefix("fit:"), "IDs are namespaced by source")
        XCTAssertEqual(idA.count, 4 + 64, "fit: prefix plus SHA-256 hex")
    }

    func testGarbageDataThrows() {
        let junk = Data(repeating: 0xAB, count: 128)
        XCTAssertThrowsError(try FITImporter().decode(data: junk))
    }

    func testPaceDerivation() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // 30:00 over 5 km => 360 s/km => 6:00/km
        let data = try makeFITData(start: start, duration: 1800, distance: 5000)
        let decoded = try FITImporter().decode(data: data)
        XCTAssertEqual(decoded.distanceKm, 5.0, accuracy: 0.01)
        let pace = decoded.duration / decoded.distanceKm
        XCTAssertEqual(pace, 360, accuracy: 1)
    }
}
