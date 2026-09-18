import Foundation
import SwiftData

/// The starter exercise catalogue, and the vocabulary for movement patterns.
///
/// Without this the Strength tab was unusable for anyone who hadn't seeded demo
/// data: `Exercise` rows existed in the schema and the set picker read them, but
/// nothing in the app could create one. An empty picker meant no set could be
/// logged at all.
///
/// The catalogue is deliberately small. A thousand-entry database is somebody
/// else's product; what a lifter needs on day one is the handful of lifts a
/// program is actually built from, with room to add their own.
enum ExerciseLibrary {

    /// Movement patterns, in the order a program usually prioritizes them.
    ///
    /// Shared with `StrengthAnalysis.categories` — volume is attributed by
    /// pattern, so a category the analysis doesn't know about silently becomes
    /// "accessory" in every chart.
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case squat, hinge, push, pull, carry, core, accessory

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .squat:     return String(localized: "Squat")
            case .hinge:     return String(localized: "Hinge")
            case .push:      return String(localized: "Push")
            case .pull:      return String(localized: "Pull")
            case .carry:     return String(localized: "Carry")
            case .core:      return String(localized: "Core")
            case .accessory: return String(localized: "Accessory")
            }
        }

        var detail: String {
            switch self {
            case .squat:     return String(localized: "Knee-dominant, upright torso")
            case .hinge:     return String(localized: "Hip-dominant, loaded posterior chain")
            case .push:      return String(localized: "Pressing, horizontal or vertical")
            case .pull:      return String(localized: "Rowing and pulling, horizontal or vertical")
            case .carry:     return String(localized: "Loaded carries and holds")
            case .core:      return String(localized: "Trunk bracing and anti-rotation")
            case .accessory: return String(localized: "Everything else — arms, calves, rehab")
            }
        }

        var symbolName: String {
            switch self {
            case .squat:     return "figure.strengthtraining.functional"
            case .hinge:     return "figure.strengthtraining.traditional"
            case .push:      return "arrow.up.circle"
            case .pull:      return "arrow.down.circle"
            case .carry:     return "figure.walk"
            case .core:      return "circle.hexagongrid"
            case .accessory: return "ellipsis.circle"
            }
        }
    }

    struct Seed: Sendable {
        let name: String
        let category: Category
        let muscles: [String]
        /// One cue that actually prevents the usual failure, not a paragraph of
        /// technique theory nobody reads mid-session.
        let formNote: String
    }

    /// The lifts a general strength program is built from.
    static let starter: [Seed] = [
        Seed(name: "Back Squat", category: .squat,
             muscles: ["quads", "glutes"],
             formNote: "Brace before you unrack, not after. Knees track over the toes; depth comes from the hips, not from letting the chest drop."),
        Seed(name: "Front Squat", category: .squat,
             muscles: ["quads", "upper back"],
             formNote: "Elbows high the whole way. The moment they drop the bar rolls forward and the rep is gone."),
        Seed(name: "Bulgarian Split Squat", category: .squat,
             muscles: ["quads", "glutes"],
             formNote: "Front shin roughly vertical. If the back foot is taking load, the bench is too close."),
        Seed(name: "Deadlift", category: .hinge,
             muscles: ["hamstrings", "glutes", "back"],
             formNote: "Take the slack out of the bar before you pull. Hips and shoulders rise together — if the hips shoot first, it's a good-morning."),
        Seed(name: "Romanian Deadlift", category: .hinge,
             muscles: ["hamstrings", "glutes"],
             formNote: "Push the hips back, don't bend down. Stop where the hamstrings stop, not where the floor is."),
        Seed(name: "Hip Thrust", category: .hinge,
             muscles: ["glutes"],
             formNote: "Ribs down and chin tucked at the top. Extension comes from the glutes, not from arching the lower back."),
        Seed(name: "Bench Press", category: .push,
             muscles: ["chest", "triceps", "shoulders"],
             formNote: "Shoulder blades pinned back and down. Feet drive into the floor; the bar path is a shallow arc, not a straight line."),
        Seed(name: "Overhead Press", category: .push,
             muscles: ["shoulders", "triceps"],
             formNote: "Squeeze the glutes so the lower back doesn't do the extending. Head moves back, then through, as the bar passes."),
        Seed(name: "Dip", category: .push,
             muscles: ["chest", "triceps"],
             formNote: "Lean forward for chest, stay upright for triceps. Stop at the depth your shoulders tolerate, not the depth someone else uses."),
        Seed(name: "Pull-up", category: .pull,
             muscles: ["lats", "biceps"],
             formNote: "Start from a dead hang with the shoulders engaged. Pull the elbows to the ribs rather than the chin to the bar."),
        Seed(name: "Barbell Row", category: .pull,
             muscles: ["lats", "upper back", "biceps"],
             formNote: "Torso angle stays fixed for the whole set. If it rises as you pull, the weight is picking the movement."),
        Seed(name: "Lat Pulldown", category: .pull,
             muscles: ["lats", "biceps"],
             formNote: "Chest up, bar to the collarbone. Leaning back turns it into a row — fine, but know which one you're doing."),
        Seed(name: "Farmer's Carry", category: .carry,
             muscles: ["grip", "traps", "core"],
             formNote: "Tall and quiet. Shoulders packed, no leaning away from the load."),
        Seed(name: "Suitcase Carry", category: .carry,
             muscles: ["obliques", "grip"],
             formNote: "Load on one side only — the work is staying vertical, so match the distance on both sides."),
        Seed(name: "Plank", category: .core,
             muscles: ["abs", "shoulders"],
             formNote: "Ribs down, glutes on. A long sagging hold trains nothing; stop when the position goes."),
        Seed(name: "Pallof Press", category: .core,
             muscles: ["obliques", "abs"],
             formNote: "The point is not rotating. Move slowly and let the cable try to turn you."),
        Seed(name: "Calf Raise", category: .accessory,
             muscles: ["calves"],
             formNote: "Full range through the bottom. Runners in particular want the lengthened position, not just the top squeeze."),
    ]

    /// Insert the starter catalogue, skipping anything already there.
    ///
    /// Matched by name, case-insensitively, so seeding after a restore — or
    /// after the demo data added its own "Back Squat" — doesn't create a second
    /// copy that would split an exercise's progress history in two.
    @MainActor
    @discardableResult
    static func seedStarter(into context: ModelContext) throws -> Int {
        let existing = Set(try context.fetch(FetchDescriptor<Exercise>())
            .map { $0.name.lowercased() })

        var inserted = 0
        for seed in starter where !existing.contains(seed.name.lowercased()) {
            let exercise = Exercise(name: seed.name,
                                    category: seed.category.rawValue,
                                    primaryMuscles: seed.muscles)
            exercise.notes = seed.formNote
            context.insert(exercise)
            inserted += 1
        }
        return inserted
    }

    /// True when nothing has been defined yet, so the UI can offer the starter
    /// set rather than an empty list with no way forward.
    @MainActor
    static func isEmpty(in context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<Exercise>()
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor)) ?? []).isEmpty
    }

    /// Whether an exercise can be deleted, and why not when it can't.
    ///
    /// Deleting one that has logged sets would orphan them: `SetEntry.exercise`
    /// is nullify-on-delete, so the sets survive but lose their identity, which
    /// silently corrupts volume-by-pattern and every e1RM history.
    @MainActor
    static func loggedSetCount(for exercise: Exercise, in context: ModelContext) -> Int {
        exercise.sets.count
    }
}

extension Exercise {
    /// Typed accessor over the raw string the model stores.
    var categoryValue: ExerciseLibrary.Category {
        get { ExerciseLibrary.Category(rawValue: category) ?? .accessory }
        set { category = newValue.rawValue }
    }

    /// Form notes, when there are any worth showing.
    var formNote: String? {
        guard let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return notes
    }
}
