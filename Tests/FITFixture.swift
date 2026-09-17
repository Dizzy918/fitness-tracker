import Foundation
import SwiftData
import FitDataProtocol
import AntMessageProtocol
@testable import FitnessTracker

/// Shared test fixtures for FIT data.
///
/// Extracted so more than one suite can build real FIT bytes: a drop-import test
/// that decodes a hand-written stub proves nothing about the decoder it will
/// actually meet.
enum FITFixture {

    /// Build a synthetic Suunto-like activity FIT file in memory.
    static func makeFITData(
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

    /// A plausible run, encoded. Deterministic, so the content hash is stable
    /// and the dedupe path can be exercised.
    static func encodedRun(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> Data {
        try makeFITData(start: start)
    }

    @MainActor
    static func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Workout.self, Shoe.self, StrengthSession.self, SetEntry.self,
            Exercise.self, DailyMetric.self, Route.self, PlannedWorkout.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }
}
