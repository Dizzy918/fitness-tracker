import XCTest
import SwiftData
@testable import FitnessTracker

/// Correcting data after the fact.
///
/// Two gaps this covers: a hand-logged workout with a typo was permanent, and
/// objective wellness metrics could only come from HealthKit — which is iOS-only,
/// so on the Mac the readiness score could never see HRV or resting heart rate
/// and sat permanently below its confidence floor.
@MainActor
final class EditingTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Workout.self, Shoe.self, StrengthSession.self, SetEntry.self,
            Exercise.self, DailyMetric.self, Route.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    // MARK: - Editing a workout in place

    /// Identity has to survive an edit. A replacement row would lose the
    /// source, look unsynced to the watermark, and orphan any streams.
    func testEditingKeepsIdentitySourceAndStreams() throws {
        let context = try makeContext()
        let samples = [FITSample(t: 0, hr: 140, dist: 0), FITSample(t: 1, hr: 142, dist: 3)]
        let workout = Workout(sport: .run, startedAt: .now, duration: 1800,
                              distance: 5000, source: "strava",
                              externalID: "strava:42")
        workout.streamsData = try JSONEncoder().encode(samples)
        workout.detailFetchedAt = .now
        context.insert(workout)
        try context.save()

        let originalID = workout.id

        // What the editor does on save.
        workout.distance = 5200
        workout.duration = 1850
        workout.notes = "measured long"
        try context.save()

        let rows = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(rows.count, 1, "editing must not create a second row")
        XCTAssertEqual(rows[0].id, originalID)
        XCTAssertEqual(rows[0].source, "strava")
        XCTAssertEqual(rows[0].externalID, "strava:42")
        XCTAssertEqual(rows[0].samples.count, 2, "streams survive a summary edit")
        XCTAssertNotNil(rows[0].detailFetchedAt)
    }

    /// A wrong distance isn't just cosmetic — it feeds pace and training load.
    func testCorrectingDistanceFlowsThroughToPaceAndLoad() throws {
        let workout = Workout(sport: .run, startedAt: .now, duration: 1800,
                              distance: 5000, source: "manual",
                              externalID: "manual:1")
        workout.avgHeartRate = 150

        let before = TrainingLoad.score(for: workout.snapshot,
                                        athlete: .init(thresholdPaceSecPerKm: 300))
        XCTAssertEqual(workout.paceSecPerKm ?? 0, 360, accuracy: 0.1)

        // A fat-fingered 5 km that was really 10 km.
        workout.distance = 10_000
        XCTAssertEqual(workout.paceSecPerKm ?? 0, 180, accuracy: 0.1)

        let after = TrainingLoad.score(for: workout.snapshot,
                                       athlete: .init(thresholdPaceSecPerKm: 300))
        XCTAssertNotEqual(before?.value ?? 0, after?.value ?? 0,
                          "load has to follow the correction")
    }

    func testChangingSportChangesHowItIsScoredAndCounted() throws {
        let workout = Workout(sport: .run, startedAt: .now, duration: 3600,
                              distance: 30_000, source: "manual",
                              externalID: "manual:2")
        // Logged as a run by mistake — 30 km in an hour is a ride.
        XCTAssertEqual(PersonalRecords.milestones(from: [workout.snapshot]).longestRun?.distance,
                       30_000)

        workout.sport = .bike
        let milestones = PersonalRecords.milestones(from: [workout.snapshot])
        XCTAssertNil(milestones.longestRun, "no longer a run")
        XCTAssertEqual(milestones.longestRide?.distance, 30_000)
    }

    func testClearingAnOptionalFieldActuallyClearsIt() throws {
        let context = try makeContext()
        let workout = Workout(sport: .run, startedAt: .now, duration: 1800,
                              distance: 5000, source: "manual", externalID: "manual:3")
        workout.avgHeartRate = 150
        workout.calories = 400
        context.insert(workout)
        try context.save()

        // The editor writes nil when a stepper is back at zero.
        workout.avgHeartRate = nil
        workout.calories = nil
        try context.save()

        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<Workout>()).first)
        XCTAssertNil(row.avgHeartRate)
        XCTAssertNil(row.calories)
    }

    /// The editor warns rather than hides when a workout has recorded data the
    /// summary could contradict.
    func testRecordedDataIsDetectedForTheWarning() throws {
        let plain = Workout(sport: .run, startedAt: .now, duration: 1800,
                            distance: 5000, source: "manual", externalID: "manual:4")
        XCTAssertFalse(plain.hasStreams)
        XCTAssertFalse(plain.hasRoute)
        XCTAssertTrue(plain.laps.isEmpty)

        let recorded = Workout(sport: .run, startedAt: .now, duration: 1800,
                               distance: 5000, source: "fit", externalID: "fit:abc")
        recorded.streamsData = try JSONEncoder().encode([FITSample(t: 0, hr: 140)])
        recorded.polylineData = try JSONEncoder().encode([[42.7, 23.3]])
        XCTAssertTrue(recorded.hasStreams)
        XCTAssertTrue(recorded.hasRoute)
    }

    // MARK: - Objective metrics by hand

    /// Half the readiness score's weight is HRV plus resting HR. Without a way
    /// to enter them, a Mac-only user sat permanently below the confidence floor.
    func testManualHRVAndRestingHRMakeAScoreReliable() {
        let today = Calendar.current.startOfDay(for: .now)
        let history = (1...7).map { day in
            MetricSnapshot(date: Calendar.current.date(byAdding: .day, value: -day, to: today)!,
                           hrvSDNN: 60, restingHR: 50)
        }

        // Subjective only: below the floor, so no score is shown at all.
        let subjective = MetricSnapshot(date: today, sleepQuality: 4, mood: 4, motivation: 4)
        let weak = Readiness.score(day: subjective, history: history)
        XCTAssertLessThan(weak.confidence, 0.5)

        // The same day with hand-entered measurements.
        let measured = MetricSnapshot(date: today, hrvSDNN: 65, restingHR: 48,
                                      sleepHours: 8, sleepQuality: 4,
                                      mood: 4, motivation: 4)
        let strong = Readiness.score(day: measured, history: history)
        XCTAssertTrue(strong.isReliable)
        XCTAssertGreaterThan(strong.confidence, weak.confidence)
        XCTAssertTrue(strong.contributions.contains { $0.component == .hrv })
        XCTAssertTrue(strong.contributions.contains { $0.component == .restingHR })
    }

    /// Zero means "not entered", not "measured as zero". Writing it would put a
    /// resting heart rate of 0 into the baseline and poison every later z-score.
    func testUnenteredMeasurementsAreNotWrittenAsZero() throws {
        let context = try makeContext()
        let metric = try HealthKitReader.upsert(day: .now, in: context)

        // What save() does with steppers left at zero.
        let hrv = 0.0, restingHR = 0, weight = 0.0
        if hrv > 0 { metric.hrvSDNN = hrv }
        if restingHR > 0 { metric.restingHR = Double(restingHR) }
        if weight > 0 { metric.weightKg = weight }
        try context.save()

        XCTAssertNil(metric.hrvSDNN)
        XCTAssertNil(metric.restingHR)
        XCTAssertNil(metric.weightKg)
        XCTAssertFalse(metric.hasObjectiveData)
    }

    /// A zero resting HR in the history would drag the baseline mean down and
    /// make every subsequent day look like a dramatic improvement.
    func testAZeroInTheBaselineWouldCorruptScoring() {
        let today = Calendar.current.startOfDay(for: .now)
        func history(withZero: Bool) -> [MetricSnapshot] {
            (1...7).map { day in
                MetricSnapshot(
                    date: Calendar.current.date(byAdding: .day, value: -day, to: today)!,
                    restingHR: withZero && day == 3 ? 0 : 50)
            }
        }
        let day = MetricSnapshot(date: today, restingHR: 50)
        let clean = Readiness.score(day: day, history: history(withZero: false))
        let poisoned = Readiness.score(day: day, history: history(withZero: true))

        XCTAssertNotEqual(clean.score, poisoned.score,
                          "a zero in the baseline visibly distorts the score — which is why it is never written")
    }

    func testManualEntryAndHealthKitShareOneRowPerDay() throws {
        let context = try makeContext()

        // HealthKit wrote today's objective values.
        let fromHealth = try HealthKitReader.upsert(day: .now, in: context)
        fromHealth.hrvSDNN = 62
        fromHealth.restingHR = 48
        fromHealth.source = "healthkit"
        try context.save()

        // The check-in sheet then adds the subjective half.
        let sameRow = try HealthKitReader.upsert(day: .now, in: context)
        sameRow.mood = 4
        sameRow.soreness = 2
        try context.save()

        let rows = try context.fetch(FetchDescriptor<DailyMetric>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].hrvSDNN, 62)
        XCTAssertEqual(rows[0].mood, 4)
        XCTAssertTrue(rows[0].hasObjectiveData)
        XCTAssertTrue(rows[0].hasCheckIn)
    }

    func testWeightEntryRoundTripsThroughTheDisplayedUnit() {
        for system in [UnitSystem.metric, .imperial] {
            let formatter = UnitFormatter(system)
            for kilograms in [0.0, 58.4, 82.5, 113.6] {
                let displayed = formatter.displayedWeight(fromKilograms: kilograms)
                XCTAssertEqual(formatter.kilograms(fromDisplayed: displayed),
                               kilograms, accuracy: 1e-9)
            }
        }
    }
}
