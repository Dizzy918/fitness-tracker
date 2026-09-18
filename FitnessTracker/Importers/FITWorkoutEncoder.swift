import Foundation
import FitDataProtocol
import AntMessageProtocol

/// Writes a planned session as a `.fit` workout file.
///
/// This is the only direction data didn't flow in a FIT-first app. The watch
/// records and this app reads; a plan written here stayed here, as a name the
/// athlete had to hold in their head and execute from memory. Suunto, Garmin and
/// Coros all import FIT workout files, which is the same route the route
/// planner's GPX already takes.
enum FITWorkoutEncoder {

    enum EncodeError: LocalizedError {
        case empty
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "There are no steps to send. Add at least one before exporting."
            case .encodingFailed(let detail):
                return "Couldn't write the workout file: \(detail)"
            }
        }
    }

    /// Encode a structure into FIT bytes.
    ///
    /// - Parameters:
    ///   - zones: resolves a heart-rate zone target into the bpm range the
    ///     watch needs. FIT carries absolute values, not zone numbers, so
    ///     without this a "zone 5" step would have to be exported untargeted.
    static func encode(
        _ structure: WorkoutStructure,
        name: String,
        sport: WorkoutSport,
        zones: HRZones?
    ) throws -> Data {
        guard !structure.isEmpty else { throw EncodeError.empty }

        let fileId = FileIdMessage(
            fileCreationDate: FitTime(date: .now),
            manufacturer: .development,
            fileType: FileType.workout
        )

        let steps = flatten(structure, zones: zones)
        let workout = WorkoutMessage(
            workoutName: asciiSafe(name, limit: 64, fallback: "Workout"),
            numberOfValidSteps: UInt16(steps.count),
            sport: fitSport(sport)
        )

        var messages: [FitMessage] = [workout]
        messages.append(contentsOf: steps)

        var encoder = FitFileEncoder(dataValidityStrategy: .none)
        switch encoder.encode(fildIdMessage: fileId, messages: messages) {
        case .success(let data):
            return data
        case .failure(let error):
            throw EncodeError.encodingFailed(String(describing: error))
        }
    }

    /// Flatten blocks into the linear step list FIT uses.
    ///
    /// FIT has no nested groups. A repeat is a *step* whose duration value is
    /// the index to jump back to and whose target value is the number of
    /// repetitions — so a group of two steps repeated eight times becomes the
    /// two steps followed by one repeat step pointing at the first of them.
    static func flatten(_ structure: WorkoutStructure, zones: HRZones?) -> [WorkoutStepMessage] {
        var messages: [WorkoutStepMessage] = []

        for block in structure.blocks where !block.steps.isEmpty {
            let blockStart = messages.count

            for step in block.steps {
                messages.append(message(for: step, index: messages.count, zones: zones))
            }

            guard block.repeatCount > 1 else { continue }
            messages.append(repeatMessage(
                index: messages.count,
                backTo: blockStart,
                times: block.repeatCount))
        }
        return messages
    }

    private static func message(
        for step: WorkoutStructure.Step,
        index: Int,
        zones: HRZones?
    ) -> WorkoutStepMessage {
        var durationType: WorkoutStepDurationType
        var durationValue: UInt32?

        switch step.duration {
        case .time(let seconds):
            durationType = .time
            // FIT carries step time in milliseconds.
            durationValue = UInt32(max(0, seconds * 1000))
        case .distance(let metres):
            durationType = .distance
            // And distance in centimetres.
            durationValue = UInt32(max(0, metres * 100))
        case .open:
            durationType = .open
            durationValue = nil
        }

        var targetType: WorkoutStepTargetType = .open
        var targetLow: UInt32?
        var targetHigh: UInt32?

        switch step.target {
        case .none:
            break
        case .heartRateZone(let zone):
            // FIT wants absolute bpm, offset by 100 when given as a raw rate —
            // the custom-range convention. Without a max HR to resolve against
            // there's no honest value to write, so the step goes out untargeted
            // rather than carrying someone else's zones.
            if let range = zones?.range(for: zone) {
                targetType = .heartRate
                targetLow = UInt32(range.lowerBound + 100)
                targetHigh = UInt32(range.upperBound + 100)
            }
        case .power(let low, let high):
            targetType = .power
            // Same convention for power.
            targetLow = UInt32(low + 1000)
            targetHigh = UInt32(high + 1000)
        }

        return WorkoutStepMessage(
            messageIndex: MessageIndex(value: UInt16(index)),
            name: step.name.map { asciiSafe($0, limit: 48, fallback: "Step") },
            duration: durationValue,
            durationType: durationType,
            target: targetType == .open ? nil : 0,
            targetLow: targetLow,
            targetHigh: targetHigh,
            targetType: targetType,
            intensity: fitIntensity(step.intensity)
        )
    }

    private static func repeatMessage(index: Int, backTo: Int, times: Int) -> WorkoutStepMessage {
        WorkoutStepMessage(
            messageIndex: MessageIndex(value: UInt16(index)),
            // The step index to loop back to.
            duration: UInt32(backTo),
            durationType: .repeatUntilStepsComplete,
            // How many times through, counting the first pass.
            target: UInt32(times),
            targetType: .open
        )
    }

    static func fitSport(_ sport: WorkoutSport) -> Sport {
        switch sport {
        case .run, .trailRun: return .running
        case .bike:           return .cycling
        case .swim:           return .swimming
        case .hike:           return .hiking
        case .walk:           return .walking
        case .other:          return .generic
        }
    }

    static func fitIntensity(_ intensity: WorkoutStructure.StepIntensity) -> Intensity {
        switch intensity {
        case .warmup:   return .warmup
        case .active:   return .active
        case .rest:     return .rest
        case .cooldown: return .cooldown
        }
    }

    /// Fold a name down to ASCII before it goes into a FIT string field.
    ///
    /// **This works around a real defect, not a style preference.** The encoder
    /// sizes a string field by character count while writing UTF-8 bytes, so a
    /// single multi-byte character makes the declared length disagree with the
    /// content — and the resulting file crashes this library's own decoder. A
    /// watch is unlikely to be more forgiving.
    ///
    /// It matters because the obvious name for a session is exactly the one
    /// that breaks: "8 × 400 m" is what this app's own shorthand produces.
    /// Folding to "8 x 400 m" loses nothing anyone will miss.
    static func asciiSafe(_ text: String, limit: Int, fallback: String) -> String {
        let substituted = text
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "·", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        // Strip accents rather than dropping the letters they sit on, so
        // "Côte" becomes "Cote" instead of "Cte".
        let folded = substituted.folding(options: [.diacriticInsensitive,
                                                   .widthInsensitive],
                                         locale: Locale(identifier: "en_US_POSIX"))
        let ascii = String(folded.unicodeScalars.filter { $0.isASCII })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ascii.isEmpty ? fallback : String(ascii.prefix(limit))
    }

    /// Filesystem-safe name for the exported file.
    static func filename(for name: String) -> String {
        let safe = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (safe.isEmpty ? "workout" : safe) + ".fit"
    }
}
