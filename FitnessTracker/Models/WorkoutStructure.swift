import Foundation

/// The steps of a planned session, in enough detail to send to a watch.
///
/// A plan could say "8 × 400 m" as a *name*, which the athlete then had to
/// remember and execute from memory. Every other direction of data in this app
/// flows through FIT; this is the one that didn't, and structure is exactly what
/// a watch is good at holding for you.
///
/// Stored as a JSON blob on `PlannedWorkout` rather than as its own entity.
/// Steps are always read and written whole, never queried, and a new SwiftData
/// entity would mean a new relationship and a new CloudKit inverse to keep
/// consistent — cost with no benefit.
struct WorkoutStructure: Codable, Sendable, Equatable {
    var blocks: [Block] = []

    var isEmpty: Bool { blocks.allSatisfy(\.steps.isEmpty) }

    /// Steps in execution order, with repeats expanded.
    var expandedSteps: [Step] {
        blocks.flatMap { block in
            Array(repeating: block.steps, count: max(1, block.repeatCount)).flatMap { $0 }
        }
    }

    /// Total time, when every step is time-bound.
    ///
    /// Nil when any step is distance- or open-ended: a session with a 5 km
    /// warmup has no duration until it's run, and guessing one from an assumed
    /// pace would make the plan's load estimate quietly fictional.
    var totalDuration: TimeInterval? {
        var total: TimeInterval = 0
        for step in expandedSteps {
            guard case .time(let seconds) = step.duration else { return nil }
            total += seconds
        }
        return total > 0 ? total : nil
    }

    /// Total distance, when every step is distance-bound.
    var totalDistance: Double? {
        var total = 0.0
        for step in expandedSteps {
            guard case .distance(let metres) = step.duration else { return nil }
            total += metres
        }
        return total > 0 ? total : nil
    }

    /// A one-line description in the shorthand a coach writes:
    /// "2 km w/u · 8 × (400 m / 200 m) · 1.5 km c/d".
    var shorthand: String {
        blocks.compactMap { block -> String? in
            guard !block.steps.isEmpty else { return nil }
            let inner = block.steps.map(\.shorthand).joined(separator: " / ")
            guard block.repeatCount > 1 else { return inner }
            return block.steps.count > 1
                ? "\(block.repeatCount) × (\(inner))"
                : "\(block.repeatCount) × \(inner)"
        }.joined(separator: " · ")
    }

    /// A group of steps, optionally repeated.
    ///
    /// One level of nesting on purpose. Warmup, N × (work, float), cooldown
    /// covers essentially every session anyone actually writes down, and
    /// arbitrary nesting would cost a tree editor for sessions nobody plans.
    struct Block: Codable, Sendable, Equatable, Identifiable {
        var id = UUID()
        var repeatCount: Int = 1
        var steps: [Step] = []

        var isRepeat: Bool { repeatCount > 1 }
    }

    struct Step: Codable, Sendable, Equatable, Identifiable {
        var id = UUID()
        var name: String?
        var intensity: StepIntensity = .active
        var duration: StepDuration = .time(300)
        var target: StepTarget = .none

        /// "400 m", "5:00", "until you stop".
        var shorthand: String {
            var text = duration.shorthand
            if case .heartRateZone(let zone) = target { text += " Z\(zone)" }
            return text
        }
    }

    /// Maps onto the FIT `Intensity` the lap parser already understands, so a
    /// session planned here and the file the watch writes back describe their
    /// steps with the same vocabulary.
    enum StepIntensity: String, Codable, Sendable, CaseIterable, Identifiable {
        case warmup, active, rest, cooldown

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .warmup:   return "Warm-up"
            case .active:   return "Work"
            case .rest:     return "Recovery"
            case .cooldown: return "Cool-down"
            }
        }
    }

    enum StepDuration: Codable, Sendable, Equatable {
        case time(TimeInterval)
        case distance(Double)       // metres
        /// Runs until the athlete presses lap. The watch needs this for a
        /// warmup you finish when you feel ready.
        case open

        var shorthand: String {
            switch self {
            case .time(let seconds):
                let total = Int(seconds.rounded())
                return total >= 60
                    ? String(format: "%d:%02d", total / 60, total % 60)
                    : "\(total)s"
            case .distance(let metres):
                return metres < 1000
                    ? "\(Int(metres.rounded())) m"
                    : String(format: "%.2g km", metres / 1000)
            case .open:
                return "open"
            }
        }
    }

    enum StepTarget: Codable, Sendable, Equatable {
        case none
        /// A heart-rate zone, 1–5, resolved against the athlete's max on export.
        case heartRateZone(Int)
        /// Watts, as an inclusive range.
        case power(low: Int, high: Int)

        var displayName: String {
            switch self {
            case .none:                   return "No target"
            case .heartRateZone(let z):   return "Heart-rate zone \(z)"
            case .power(let lo, let hi):  return "\(lo)–\(hi) W"
            }
        }
    }
}

// MARK: - Common shapes

extension WorkoutStructure {
    /// A ready-made interval session, which is what most structured plans are.
    static func intervals(
        reps: Int,
        workMetres: Double,
        recoveryMetres: Double,
        warmupMetres: Double = 2_000,
        cooldownMetres: Double = 1_500
    ) -> WorkoutStructure {
        var structure = WorkoutStructure()
        structure.blocks = [
            Block(steps: [Step(name: "Warm-up", intensity: .warmup,
                               duration: .distance(warmupMetres))]),
            Block(repeatCount: reps, steps: [
                Step(name: "Rep", intensity: .active, duration: .distance(workMetres),
                     target: .heartRateZone(5)),
                Step(name: "Float", intensity: .rest, duration: .distance(recoveryMetres)),
            ]),
            Block(steps: [Step(name: "Cool-down", intensity: .cooldown,
                               duration: .distance(cooldownMetres))]),
        ]
        return structure
    }

    /// A steady session of one length.
    static func steady(minutes: Int, zone: Int? = nil) -> WorkoutStructure {
        var step = Step(name: "Steady", intensity: .active,
                        duration: .time(TimeInterval(minutes * 60)))
        if let zone { step.target = .heartRateZone(zone) }
        return WorkoutStructure(blocks: [Block(steps: [step])])
    }
}

// MARK: - Attaching to a plan

extension PlannedWorkout {
    /// The structure, decoded on demand. Nil when the plan is just a name.
    var structure: WorkoutStructure? {
        get {
            guard let structureData else { return nil }
            return try? JSONDecoder().decode(WorkoutStructure.self, from: structureData)
        }
        set {
            structureData = newValue.flatMap { $0.isEmpty ? nil : try? JSONEncoder().encode($0) }
        }
    }

    var hasStructure: Bool { structureData != nil }
}
