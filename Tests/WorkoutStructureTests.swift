import XCTest
import SwiftData
import FitDataProtocol
import AntMessageProtocol
@testable import FitnessTracker

/// Structured sessions and the FIT workout files they export to.
///
/// The export is the only place this app *writes* FIT rather than reading it,
/// and a file a watch silently refuses is indistinguishable from one that
/// worked until you're standing on the track. So the round trip is tested by
/// decoding the bytes back with the same library that reads real watch files.
@MainActor
final class WorkoutStructureTests: XCTestCase {

    private let zones = HRZones(maxHR: 190)

    private var intervals: WorkoutStructure {
        .intervals(reps: 8, workMetres: 400, recoveryMetres: 200)
    }

    // MARK: - The model

    func testExpandedStepsUnrollRepeats() {
        let structure = WorkoutStructure.intervals(
            reps: 4, workMetres: 400, recoveryMetres: 200)

        // Warm-up, 4 × (work, float), cool-down.
        XCTAssertEqual(structure.expandedSteps.count, 1 + 4 * 2 + 1)
    }

    func testTotalDistanceAddsUpTheWholeSession() throws {
        let structure = WorkoutStructure.intervals(
            reps: 8, workMetres: 400, recoveryMetres: 200,
            warmupMetres: 2_000, cooldownMetres: 1_500)

        let total = try XCTUnwrap(structure.totalDistance)
        XCTAssertEqual(total, 2_000 + 8 * 600 + 1_500, accuracy: 0.1)
    }

    func testTotalTimeAddsUpWhenEveryStepIsTimed() throws {
        let structure = WorkoutStructure.steady(minutes: 45)
        XCTAssertEqual(try XCTUnwrap(structure.totalDuration), 2_700, accuracy: 0.1)
    }

    /// A session with a 5 km warmup has no duration until it's run, and
    /// inventing one from an assumed pace would make the plan's load estimate
    /// quietly fictional.
    func testMixedUnitsHaveNoSingleTotal() {
        var structure = WorkoutStructure()
        structure.blocks = [
            WorkoutStructure.Block(steps: [
                WorkoutStructure.Step(duration: .distance(5_000)),
                WorkoutStructure.Step(duration: .time(600)),
            ]),
        ]
        XCTAssertNil(structure.totalDuration)
        XCTAssertNil(structure.totalDistance)
    }

    func testAnOpenStepDefeatsBothTotals() {
        var structure = WorkoutStructure.steady(minutes: 30)
        structure.blocks.append(
            WorkoutStructure.Block(steps: [WorkoutStructure.Step(duration: .open)]))
        XCTAssertNil(structure.totalDuration)
    }

    /// The shorthand is the line the athlete reads at a glance, so it has to
    /// come out the way a coach writes it.
    func testShorthandReadsLikeAWrittenSession() {
        let structure = WorkoutStructure.intervals(
            reps: 8, workMetres: 400, recoveryMetres: 200,
            warmupMetres: 2_000, cooldownMetres: 1_500)

        // Targets are carried into the shorthand too — "400 m Z5" says more
        // than "400 m" for the same width.
        let text = structure.shorthand
        XCTAssertTrue(text.contains("8 × (400 m Z5 / 200 m)"), text)
        XCTAssertTrue(text.contains("2 km"), text)
        XCTAssertTrue(text.contains("1.5 km"), text)
    }

    func testSingleStepRepeatsDoNotGetRedundantBrackets() {
        var structure = WorkoutStructure()
        structure.blocks = [WorkoutStructure.Block(
            repeatCount: 5,
            steps: [WorkoutStructure.Step(duration: .time(60))])]
        XCTAssertEqual(structure.shorthand, "5 × 1:00")
    }

    func testEmptyStructureIsEmpty() {
        XCTAssertTrue(WorkoutStructure().isEmpty)
        XCTAssertTrue(WorkoutStructure(blocks: [WorkoutStructure.Block()]).isEmpty)
    }

    // MARK: - Flattening to FIT's linear form

    /// FIT has no nested groups: a repeat is a *step* that points back at an
    /// index. Getting that index wrong produces a file that loops the wrong
    /// part of the session.
    func testRepeatStepPointsBackAtTheStartOfItsBlock() throws {
        let messages = FITWorkoutEncoder.flatten(intervals, zones: zones)

        // warm-up(0), work(1), float(2), repeat(3), cool-down(4).
        XCTAssertEqual(messages.count, 5)
        let repeatStep = messages[3]
        XCTAssertEqual(repeatStep.durationType, .repeatUntilStepsComplete)
        XCTAssertEqual(repeatStep.duration, 1, "loops back to the first work step")
        XCTAssertEqual(repeatStep.target, 8, "eight times through")
    }

    func testABlockThatIsNotRepeatedGetsNoRepeatStep() {
        let messages = FITWorkoutEncoder.flatten(.steady(minutes: 40), zones: zones)
        XCTAssertEqual(messages.count, 1)
        XCTAssertNotEqual(messages[0].durationType, .repeatUntilStepsComplete)
    }

    func testStepIndicesAreSequential() throws {
        let messages = FITWorkoutEncoder.flatten(intervals, zones: zones)
        for (offset, message) in messages.enumerated() {
            XCTAssertEqual(message.messageIndex?.index, UInt16(offset))
        }
    }

    func testEmptyBlocksAreSkippedWithoutBreakingIndices() throws {
        var structure = intervals
        structure.blocks.insert(WorkoutStructure.Block(), at: 1)
        let messages = FITWorkoutEncoder.flatten(structure, zones: zones)

        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages[3].duration, 1, "the repeat still points at the right step")
    }

    // MARK: - Units on the wire

    /// FIT carries step time in milliseconds and distance in centimetres.
    /// Getting either wrong gives a session off by a factor of a hundred, which
    /// a watch will happily accept.
    func testDurationsUseFITsOwnUnits() throws {
        var structure = WorkoutStructure()
        structure.blocks = [WorkoutStructure.Block(steps: [
            WorkoutStructure.Step(duration: .time(300)),
            WorkoutStructure.Step(duration: .distance(400)),
            WorkoutStructure.Step(duration: .open),
        ])]

        let messages = FITWorkoutEncoder.flatten(structure, zones: zones)
        XCTAssertEqual(messages[0].duration, 300_000, "five minutes in milliseconds")
        XCTAssertEqual(messages[1].duration, 40_000, "400 metres in centimetres")
        XCTAssertEqual(messages[2].durationType, .open)
        XCTAssertNil(messages[2].duration)
    }

    func testHeartRateZoneTargetsBecomeAbsoluteRanges() throws {
        var structure = WorkoutStructure()
        structure.blocks = [WorkoutStructure.Block(steps: [
            WorkoutStructure.Step(duration: .time(300), target: .heartRateZone(5)),
        ])]

        let message = FITWorkoutEncoder.flatten(structure, zones: zones)[0]
        let expected = try XCTUnwrap(zones.range(for: 5))
        XCTAssertEqual(message.targetType, .heartRate)
        // FIT's custom-range convention offsets a raw bpm by 100.
        XCTAssertEqual(message.targetLow, UInt32(expected.lowerBound + 100))
        XCTAssertEqual(message.targetHigh, UInt32(expected.upperBound + 100))
    }

    /// Without a max HR there's no honest bpm range to write, so the step goes
    /// out untargeted rather than carrying somebody else's zones.
    func testZoneTargetsAreDroppedWhenThereIsNoMaxHeartRate() throws {
        var structure = WorkoutStructure()
        structure.blocks = [WorkoutStructure.Block(steps: [
            WorkoutStructure.Step(duration: .time(300), target: .heartRateZone(4)),
        ])]

        let message = FITWorkoutEncoder.flatten(structure, zones: nil)[0]
        XCTAssertEqual(message.targetType, .open)
        XCTAssertNil(message.targetLow)
    }

    func testPowerTargetsUseTheirOwnOffset() throws {
        var structure = WorkoutStructure()
        structure.blocks = [WorkoutStructure.Block(steps: [
            WorkoutStructure.Step(duration: .time(600), target: .power(low: 240, high: 260)),
        ])]

        let message = FITWorkoutEncoder.flatten(structure, zones: zones)[0]
        XCTAssertEqual(message.targetType, .power)
        XCTAssertEqual(message.targetLow, 1_240)
        XCTAssertEqual(message.targetHigh, 1_260)
    }

    /// The intensity vocabulary is shared with the lap parser, so a session
    /// planned here and the file the watch writes back describe their steps the
    /// same way.
    func testIntensitiesMatchWhatTheLapParserReads() {
        XCTAssertEqual(FITWorkoutEncoder.fitIntensity(.warmup), .warmup)
        XCTAssertEqual(FITWorkoutEncoder.fitIntensity(.active), .active)
        XCTAssertEqual(FITWorkoutEncoder.fitIntensity(.rest), .rest)
        XCTAssertEqual(FITWorkoutEncoder.fitIntensity(.cooldown), .cooldown)
    }

    // MARK: - The round trip

    /// The test that matters: encode, then decode the bytes back with the same
    /// library that reads real watch files. A file that can't be parsed is one
    /// the watch will refuse, and you find out on the track.
    func testEncodedWorkoutDecodesBackWithItsSteps() throws {
        let data = try FITWorkoutEncoder.encode(
            intervals, name: "8 × 400 m", sport: .run, zones: zones)
        XCTAssertGreaterThan(data.count, 0)

        var workoutName: String?
        var sport: Sport?
        var declaredSteps: UInt16?
        var steps: [WorkoutStepMessage] = []

        var decoder = FitFileDecoder(crcCheckingStrategy: .throws)
        try decoder.decode(data: data, messages: FitFileDecoder.defaultMessages) { message in
            if let workout = message as? WorkoutMessage {
                workoutName = workout.workoutName
                sport = workout.sport
                declaredSteps = workout.numberOfValidSteps
            }
            if let step = message as? WorkoutStepMessage { steps.append(step) }
        }

        // Folded to ASCII on the way out — see the non-ASCII test below.
        XCTAssertEqual(workoutName, "8 x 400 m")
        XCTAssertEqual(sport, .running)
        XCTAssertEqual(declaredSteps, 5)
        XCTAssertEqual(steps.count, 5, "every step survived the round trip")
    }

    /// The declared step count has to match the steps actually written, or a
    /// watch reads past the end of the list.
    func testDeclaredStepCountMatchesWhatIsWritten() throws {
        for structure in [intervals, .steady(minutes: 60),
                          .intervals(reps: 3, workMetres: 1_000, recoveryMetres: 400)] {
            let data = try FITWorkoutEncoder.encode(
                structure, name: "Session", sport: .run, zones: zones)

            var declared: UInt16?
            var counted = 0
            var decoder = FitFileDecoder(crcCheckingStrategy: .throws)
            try decoder.decode(data: data, messages: FitFileDecoder.defaultMessages) { message in
                if let workout = message as? WorkoutMessage { declared = workout.numberOfValidSteps }
                if message is WorkoutStepMessage { counted += 1 }
            }
            XCTAssertEqual(Int(declared ?? 0), counted)
        }
    }

    func testTheFileIsMarkedAsAWorkoutNotAnActivity() throws {
        let data = try FITWorkoutEncoder.encode(
            .steady(minutes: 30), name: "Easy", sport: .run, zones: zones)

        var fileType: FileType?
        var decoder = FitFileDecoder(crcCheckingStrategy: .throws)
        try decoder.decode(data: data, messages: FitFileDecoder.defaultMessages) { message in
            if let id = message as? FileIdMessage { fileType = id.fileType }
        }
        XCTAssertEqual(fileType, FileType.workout,
                       "an activity-typed file would be imported as a workout you did")
    }

    /// A real defect, found by decoding what we write.
    ///
    /// The library sizes a FIT string field by character count while writing
    /// UTF-8 bytes, so one multi-byte character makes the declared length
    /// disagree with the content and the file crashes the decoder outright — a
    /// hard trap, not a thrown error. It matters because the obvious name for
    /// the session is the one that breaks it: "8 × 400 m" is what this app's own
    /// shorthand produces.
    func testANonASCIINameDoesNotProduceAnUnreadableFile() throws {
        let data = try FITWorkoutEncoder.encode(
            intervals, name: "8 × 400 m — Côte", sport: .run, zones: zones)

        var name: String?
        var decoder = FitFileDecoder(crcCheckingStrategy: .throws)
        try decoder.decode(data: data, messages: FitFileDecoder.defaultMessages) { message in
            if let workout = message as? WorkoutMessage { name = workout.workoutName }
        }
        XCTAssertEqual(name, "8 x 400 m - Cote")
    }

    func testASCIIFoldingKeepsWhatMattersAndDropsWhatDoesNot() {
        let fold = { FITWorkoutEncoder.asciiSafe($0, limit: 64, fallback: "Workout") }

        XCTAssertEqual(fold("8 × 400 m"), "8 x 400 m")
        // Accents lose the mark, not the letter.
        XCTAssertEqual(fold("Côte de Vitosha"), "Cote de Vitosha")
        XCTAssertEqual(fold("Tempo · 3×10"), "Tempo - 3x10")
        // A name with nothing ASCII left has to become something, not nothing.
        XCTAssertEqual(fold("日本語"), "Workout")
        XCTAssertEqual(fold("   "), "Workout")
    }

    func testNamesAreTruncatedToWhatFITAllows() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(FITWorkoutEncoder.asciiSafe(long, limit: 64, fallback: "x").count, 64)
    }

    /// Step names go through the same fold, for the same reason.
    func testStepNamesAreAlsoFolded() throws {
        var structure = WorkoutStructure()
        structure.blocks = [WorkoutStructure.Block(steps: [
            WorkoutStructure.Step(name: "Rép ×2", duration: .time(300)),
        ])]

        let data = try FITWorkoutEncoder.encode(
            structure, name: "Session", sport: .run, zones: zones)

        var stepName: String?
        var decoder = FitFileDecoder(crcCheckingStrategy: .throws)
        try decoder.decode(data: data, messages: FitFileDecoder.defaultMessages) { message in
            if let step = message as? WorkoutStepMessage, step.name != nil {
                stepName = step.name
            }
        }
        XCTAssertEqual(stepName, "Rep x2")
    }

    func testEncodingAnEmptyStructureIsRefused() {
        XCTAssertThrowsError(try FITWorkoutEncoder.encode(
            WorkoutStructure(), name: "Nothing", sport: .run, zones: zones)) { error in
            XCTAssertTrue(error.localizedDescription.contains("no steps"))
        }
    }

    func testFilenameIsFilesystemSafe() {
        XCTAssertEqual(FITWorkoutEncoder.filename(for: "8 × 400 m"), "8 × 400 m.fit")
        XCTAssertEqual(FITWorkoutEncoder.filename(for: "Hills 10/12"), "Hills 10-12.fit")
        XCTAssertEqual(FITWorkoutEncoder.filename(for: "   "), "workout.fit")
    }

    // MARK: - Attaching to a plan

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    func testStructureRoundTripsThroughThePlan() throws {
        let context = try makeContext()
        let plan = PlannedWorkout(scheduledFor: .now, sport: .run, title: "Track")
        context.insert(plan)

        XCTAssertFalse(plan.hasStructure)
        plan.structure = intervals
        try context.save()

        XCTAssertTrue(plan.hasStructure)
        let restored = try XCTUnwrap(plan.structure)
        XCTAssertEqual(restored.expandedSteps.count, intervals.expandedSteps.count)
        XCTAssertEqual(restored.shorthand, intervals.shorthand)
    }

    /// Assigning an empty structure clears the blob rather than storing an
    /// empty one, so `hasStructure` stays honest.
    func testAssigningAnEmptyStructureClearsIt() throws {
        let context = try makeContext()
        let plan = PlannedWorkout(scheduledFor: .now, sport: .run)
        context.insert(plan)
        plan.structure = intervals
        XCTAssertTrue(plan.hasStructure)

        plan.structure = WorkoutStructure()
        XCTAssertFalse(plan.hasStructure)
        XCTAssertNil(plan.structure)
    }

    func testStructureSurvivesABackup() throws {
        let context = try makeContext()
        let plan = PlannedWorkout(scheduledFor: .now, sport: .run, title: "Track")
        plan.structure = intervals
        context.insert(plan)
        try context.save()

        let data = try DataArchive.exportData(from: context)
        let restored = try makeContext()
        try DataArchive.restore(try DataArchive.read(data), into: restored)

        let copy = try XCTUnwrap(try restored.fetch(FetchDescriptor<PlannedWorkout>()).first)
        XCTAssertEqual(copy.structure?.shorthand, intervals.shorthand)
    }
}
