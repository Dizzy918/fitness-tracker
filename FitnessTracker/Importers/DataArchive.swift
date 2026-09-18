import Foundation
import SwiftData

/// Full export and restore of everything the app holds.
///
/// A personal training database with no way to get data out is a trap: the
/// history is only as durable as one device and one app's schema. This writes a
/// plain, self-describing JSON archive — no proprietary container, readable with
/// any tool — and reads it back.
///
/// Restore is **additive and idempotent**. It never deletes, and it dedupes on
/// the same `externalID` the importers use, so restoring an archive onto a store
/// that already has some of it merges rather than duplicating.
enum DataArchive {

    /// Bumped when the shape changes in a way a reader has to know about.
    /// Adding an optional field doesn't need a bump; removing or renaming does.
    static let currentVersion = 1

    // MARK: - Wire format

    struct Archive: Codable, Sendable {
        var version: Int = DataArchive.currentVersion
        var exportedAt: Date = .now
        var appVersion: String?
        var workouts: [WorkoutRecord] = []
        var shoes: [ShoeRecord] = []
        var strengthSessions: [StrengthSessionRecord] = []
        var exercises: [ExerciseRecord] = []
        var dailyMetrics: [DailyMetricRecord] = []
        var routes: [RouteRecord] = []
        var plannedWorkouts: [PlannedWorkoutRecord] = []
        var routines: [RoutineRecord] = []

        var isEmpty: Bool {
            workouts.isEmpty && shoes.isEmpty && strengthSessions.isEmpty
                && dailyMetrics.isEmpty && routes.isEmpty && plannedWorkouts.isEmpty
                && routines.isEmpty
        }

        var itemCount: Int {
            workouts.count + shoes.count + strengthSessions.count
                + dailyMetrics.count + routes.count + plannedWorkouts.count
                + routines.count
        }
    }

    /// Every field optional except the identity ones, so an archive written by a
    /// newer version degrades one row rather than failing the whole restore.
    struct WorkoutRecord: Codable, Sendable {
        var id: UUID
        var sport: String
        var startedAt: Date
        var duration: TimeInterval
        var distance: Double
        var source: String
        var externalID: String?
        var avgHeartRate: Int?
        var maxHeartRate: Int?
        var elevationGain: Double?
        var calories: Double?
        var avgPower: Int?
        var poolLength: Double?
        var notes: String?
        var shoeID: UUID?
        /// Base64 in JSON, courtesy of `Data`'s own coding. These are the bulk
        /// of the file — a year of 1 Hz streams is tens of megabytes — which is
        /// why the summary export exists alongside it.
        var polylineData: Data?
        var streamsData: Data?
        var lapsData: Data?
    }

    struct ShoeRecord: Codable, Sendable {
        var id: UUID
        var brand: String
        var model: String
        var nickname: String?
        var acquiredAt: Date
        var retiredAt: Date?
        var maxDistance: Double
        var notes: String?
    }

    struct ExerciseRecord: Codable, Sendable {
        var id: UUID
        var name: String
        var category: String
        var primaryMuscles: [String]
        var notes: String?
        var defaultRestSeconds: Int?
    }

    struct RoutineRecord: Codable, Sendable {
        var id: UUID
        var name: String
        var notes: String?
        var createdAt: Date
        var lastUsedAt: Date?
        var useCount: Int?
        var items: [RoutineItemRecord]
    }

    struct RoutineItemRecord: Codable, Sendable {
        var id: UUID
        var order: Int
        var exerciseID: UUID?
        var targetSets: Int
        var targetReps: Int
        var targetWeightKg: Double?
        var restSeconds: Int
        var supersetGroup: Int?
        var notes: String?
    }

    struct SetRecord: Codable, Sendable {
        var id: UUID
        var order: Int
        var reps: Int
        var weightKg: Double
        var rpe: Double?
        var isWarmup: Bool
        var exerciseID: UUID?
        var isPending: Bool?
        var completedAt: Date?
        var restSeconds: Int?
        var supersetGroup: Int?
    }

    struct StrengthSessionRecord: Codable, Sendable {
        var id: UUID
        var startedAt: Date
        var endedAt: Date?
        var notes: String?
        var sets: [SetRecord]
        var routineID: UUID?
        var routineName: String?
    }

    struct DailyMetricRecord: Codable, Sendable {
        var id: UUID
        var date: Date
        var hrvSDNN: Double?
        var restingHR: Double?
        var sleepHours: Double?
        var weightKg: Double?
        var vo2Max: Double?
        var sleepQuality: Int?
        var soreness: Int?
        var mood: Int?
        var motivation: Int?
        var notes: String?
        var source: String
    }

    struct RouteRecord: Codable, Sendable {
        var id: UUID
        var name: String
        var createdAt: Date
        var sport: String
        var notes: String?
        var distance: Double
        var elevationGain: Double?
        var isLoop: Bool
        var pointsData: Data?
        var elevationsData: Data?
    }

    struct PlannedWorkoutRecord: Codable, Sendable {
        var id: UUID
        var scheduledFor: Date
        var sport: String
        var title: String
        var notes: String?
        var targetDuration: TimeInterval?
        var targetDistance: Double?
        var targetLoad: Double?
        var completedWorkoutID: UUID?
        var skippedAt: Date?
        var order: Int
        /// The session's steps. Losing these to a restore would leave a plan
        /// that says "8 × 400 m" with nothing behind it.
        var structureData: Data?
    }

    // MARK: - Coding

    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        // ISO-8601 rather than the default epoch double: an archive should be
        // legible to a human opening it in a text editor five years from now.
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    enum ArchiveError: LocalizedError {
        case unreadable
        case futureVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "That file isn't a FitnessTracker archive."
            case .futureVersion(let version):
                return "This archive was written by a newer version of the app (format \(version)). Update the app and try again."
            }
        }
    }

    // MARK: - Export

    @MainActor
    static func archive(from context: ModelContext, includeStreams: Bool = true) throws -> Archive {
        var archive = Archive()
        archive.appVersion = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        archive.workouts = try context.fetch(FetchDescriptor<Workout>()).map { w in
            WorkoutRecord(
                id: w.id, sport: w.sportRaw, startedAt: w.startedAt,
                duration: w.duration, distance: w.distance, source: w.source,
                externalID: w.externalID,
                avgHeartRate: w.avgHeartRate, maxHeartRate: w.maxHeartRate,
                elevationGain: w.elevationGain, calories: w.calories,
                avgPower: w.avgPower, poolLength: w.poolLength, notes: w.notes,
                shoeID: w.shoe?.id,
                polylineData: includeStreams ? w.polylineData : nil,
                streamsData: includeStreams ? w.streamsData : nil,
                lapsData: includeStreams ? w.lapsData : nil
            )
        }

        archive.shoes = try context.fetch(FetchDescriptor<Shoe>()).map {
            ShoeRecord(id: $0.id, brand: $0.brand, model: $0.model,
                       nickname: $0.nickname, acquiredAt: $0.acquiredAt,
                       retiredAt: $0.retiredAt, maxDistance: $0.maxDistance,
                       notes: $0.notes)
        }

        archive.exercises = try context.fetch(FetchDescriptor<Exercise>()).map {
            ExerciseRecord(id: $0.id, name: $0.name, category: $0.category,
                           primaryMuscles: $0.primaryMuscles, notes: $0.notes,
                           defaultRestSeconds: $0.defaultRestSeconds)
        }

        archive.strengthSessions = try context.fetch(FetchDescriptor<StrengthSession>()).map { s in
            StrengthSessionRecord(
                id: s.id, startedAt: s.startedAt, endedAt: s.endedAt, notes: s.notes,
                sets: s.sets.sorted { $0.order < $1.order }.map {
                    SetRecord(id: $0.id, order: $0.order, reps: $0.reps,
                              weightKg: $0.weightKg, rpe: $0.rpe,
                              isWarmup: $0.isWarmup, exerciseID: $0.exercise?.id,
                              isPending: $0.isPending, completedAt: $0.completedAt,
                              restSeconds: $0.restSeconds, supersetGroup: $0.supersetGroup)
                },
                routineID: s.routineID, routineName: s.routineName
            )
        }

        archive.dailyMetrics = try context.fetch(FetchDescriptor<DailyMetric>()).map {
            DailyMetricRecord(
                id: $0.id, date: $0.date, hrvSDNN: $0.hrvSDNN,
                restingHR: $0.restingHR, sleepHours: $0.sleepHours,
                weightKg: $0.weightKg, vo2Max: $0.vo2Max,
                sleepQuality: $0.sleepQuality, soreness: $0.soreness,
                mood: $0.mood, motivation: $0.motivation,
                notes: $0.notes, source: $0.source)
        }

        archive.routes = try context.fetch(FetchDescriptor<Route>()).map {
            RouteRecord(id: $0.id, name: $0.name, createdAt: $0.createdAt,
                        sport: $0.sportRaw, notes: $0.notes, distance: $0.distance,
                        elevationGain: $0.elevationGain, isLoop: $0.isLoop,
                        pointsData: $0.pointsData, elevationsData: $0.elevationsData)
        }

        archive.plannedWorkouts = try context.fetch(FetchDescriptor<PlannedWorkout>()).map {
            PlannedWorkoutRecord(
                id: $0.id, scheduledFor: $0.scheduledFor, sport: $0.sportRaw,
                title: $0.title, notes: $0.notes,
                targetDuration: $0.targetDuration, targetDistance: $0.targetDistance,
                targetLoad: $0.targetLoad, completedWorkoutID: $0.completedWorkoutID,
                skippedAt: $0.skippedAt, order: $0.order,
                structureData: $0.structureData)
        }

        archive.routines = try context.fetch(FetchDescriptor<Routine>()).map { routine in
            RoutineRecord(
                id: routine.id, name: routine.name, notes: routine.notes,
                createdAt: routine.createdAt, lastUsedAt: routine.lastUsedAt,
                useCount: routine.useCount,
                items: routine.orderedItems.map {
                    RoutineItemRecord(
                        id: $0.id, order: $0.order, exerciseID: $0.exercise?.id,
                        targetSets: $0.targetSets, targetReps: $0.targetReps,
                        targetWeightKg: $0.targetWeightKg, restSeconds: $0.restSeconds,
                        supersetGroup: $0.supersetGroup, notes: $0.notes)
                }
            )
        }

        return archive
    }

    @MainActor
    static func exportData(from context: ModelContext, includeStreams: Bool = true) throws -> Data {
        try encoder().encode(archive(from: context, includeStreams: includeStreams))
    }

    static func filename(for date: Date = .now, includeStreams: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let suffix = includeStreams ? "" : "-summary"
        return "fitnesstracker-\(formatter.string(from: date))\(suffix).json"
    }

    // MARK: - Restore

    struct RestoreReport: Sendable {
        var workouts = 0
        var shoes = 0
        var strengthSessions = 0
        var dailyMetrics = 0
        var routes = 0
        var plannedWorkouts = 0
        var routines = 0
        var skipped = 0

        var total: Int {
            workouts + shoes + strengthSessions + dailyMetrics + routes
                + plannedWorkouts + routines
        }

        var summary: String {
            guard total > 0 else {
                return skipped > 0
                    ? "Everything in that archive is already here (\(skipped) items)."
                    : "That archive was empty."
            }
            var parts: [String] = []
            if workouts > 0 { parts.append("\(workouts) workouts") }
            if shoes > 0 { parts.append("\(shoes) shoes") }
            if strengthSessions > 0 { parts.append("\(strengthSessions) lifting sessions") }
            if dailyMetrics > 0 { parts.append("\(dailyMetrics) days of metrics") }
            if routes > 0 { parts.append("\(routes) routes") }
            if plannedWorkouts > 0 { parts.append("\(plannedWorkouts) planned sessions") }
            if routines > 0 { parts.append("\(routines) routines") }
            var text = "Restored " + parts.joined(separator: ", ") + "."
            if skipped > 0 { text += " Skipped \(skipped) already present." }
            return text
        }
    }

    static func read(_ data: Data) throws -> Archive {
        let archive: Archive
        do {
            archive = try decoder().decode(Archive.self, from: data)
        } catch {
            throw ArchiveError.unreadable
        }
        guard archive.version <= currentVersion else {
            throw ArchiveError.futureVersion(archive.version)
        }
        return archive
    }

    /// Merge an archive into the store.
    ///
    /// Never deletes and never overwrites: an existing row wins. Identity is the
    /// model's own `id` first, then `externalID`, so an archive restored onto a
    /// store that already synced the same Strava activity doesn't duplicate it.
    @MainActor
    @discardableResult
    static func restore(_ archive: Archive, into context: ModelContext) throws -> RestoreReport {
        var report = RestoreReport()

        // Shoes first: workouts reference them.
        var shoesByID: [UUID: Shoe] = [:]
        for existing in try context.fetch(FetchDescriptor<Shoe>()) {
            shoesByID[existing.id] = existing
        }
        for record in archive.shoes {
            if shoesByID[record.id] != nil { report.skipped += 1; continue }
            let shoe = Shoe(id: record.id, brand: record.brand, model: record.model,
                            nickname: record.nickname, acquiredAt: record.acquiredAt,
                            maxDistance: record.maxDistance)
            shoe.retiredAt = record.retiredAt
            shoe.notes = record.notes
            context.insert(shoe)
            shoesByID[record.id] = shoe
            report.shoes += 1
        }

        // Exercises before the sets that point at them.
        var exercisesByID: [UUID: Exercise] = [:]
        for existing in try context.fetch(FetchDescriptor<Exercise>()) {
            exercisesByID[existing.id] = existing
        }
        for record in archive.exercises where exercisesByID[record.id] == nil {
            let exercise = Exercise(id: record.id, name: record.name,
                                    category: record.category,
                                    primaryMuscles: record.primaryMuscles)
            exercise.notes = record.notes
            if let rest = record.defaultRestSeconds { exercise.defaultRestSeconds = rest }
            context.insert(exercise)
            exercisesByID[record.id] = exercise
        }

        let existingWorkouts = try context.fetch(FetchDescriptor<Workout>())
        let workoutIDs = Set(existingWorkouts.map(\.id))
        let workoutExternalIDs = Set(existingWorkouts.compactMap(\.externalID))

        for record in archive.workouts {
            if workoutIDs.contains(record.id) { report.skipped += 1; continue }
            if let external = record.externalID, workoutExternalIDs.contains(external) {
                report.skipped += 1
                continue
            }
            let workout = Workout(
                id: record.id,
                sport: WorkoutSport(rawValue: record.sport) ?? .other,
                startedAt: record.startedAt, duration: record.duration,
                distance: record.distance, source: record.source,
                externalID: record.externalID)
            workout.avgHeartRate = record.avgHeartRate
            workout.maxHeartRate = record.maxHeartRate
            workout.elevationGain = record.elevationGain
            workout.calories = record.calories
            workout.avgPower = record.avgPower
            workout.poolLength = record.poolLength
            workout.notes = record.notes
            workout.polylineData = record.polylineData
            workout.streamsData = record.streamsData
            workout.lapsData = record.lapsData
            workout.shoe = record.shoeID.flatMap { shoesByID[$0] }
            context.insert(workout)
            report.workouts += 1
        }

        let sessionIDs = Set(try context.fetch(FetchDescriptor<StrengthSession>()).map(\.id))
        for record in archive.strengthSessions {
            if sessionIDs.contains(record.id) { report.skipped += 1; continue }
            let session = StrengthSession(id: record.id, startedAt: record.startedAt)
            session.endedAt = record.endedAt
            session.notes = record.notes
            context.insert(session)
            for setRecord in record.sets {
                let entry = SetEntry(
                    id: setRecord.id, order: setRecord.order, reps: setRecord.reps,
                    weightKg: setRecord.weightKg, rpe: setRecord.rpe,
                    isWarmup: setRecord.isWarmup,
                    exercise: setRecord.exerciseID.flatMap { exercisesByID[$0] })
                // Absent in archives written before routines existed, where
                // every recorded set was by definition one already done.
                entry.isPending = setRecord.isPending ?? false
                entry.completedAt = setRecord.completedAt
                entry.restSeconds = setRecord.restSeconds
                entry.supersetGroup = setRecord.supersetGroup
                entry.session = session
                context.insert(entry)
            }
            session.routineID = record.routineID
            session.routineName = record.routineName
            report.strengthSessions += 1
        }

        let routineIDs = Set(try context.fetch(FetchDescriptor<Routine>()).map(\.id))
        for record in archive.routines {
            if routineIDs.contains(record.id) { report.skipped += 1; continue }
            let routine = Routine(id: record.id, name: record.name,
                                  createdAt: record.createdAt)
            routine.notes = record.notes
            routine.lastUsedAt = record.lastUsedAt
            routine.useCount = record.useCount ?? 0
            context.insert(routine)
            for itemRecord in record.items {
                let item = RoutineItem(
                    id: itemRecord.id, order: itemRecord.order,
                    exercise: itemRecord.exerciseID.flatMap { exercisesByID[$0] },
                    targetSets: itemRecord.targetSets, targetReps: itemRecord.targetReps,
                    targetWeightKg: itemRecord.targetWeightKg,
                    restSeconds: itemRecord.restSeconds,
                    supersetGroup: itemRecord.supersetGroup)
                item.notes = itemRecord.notes
                item.routine = routine
                context.insert(item)
            }
            report.routines += 1
        }

        // Metrics are keyed by day, not by row id — two devices can easily have
        // written a different `id` for the same date, and two rows for one day
        // would corrupt every baseline the readiness score computes.
        for record in archive.dailyMetrics {
            if let existing = try HealthKitReader.metric(for: record.date, in: context) {
                // Fill blanks from the archive rather than overwriting: the row
                // that's already here may be the fresher one.
                if existing.hrvSDNN == nil { existing.hrvSDNN = record.hrvSDNN }
                if existing.restingHR == nil { existing.restingHR = record.restingHR }
                if existing.sleepHours == nil { existing.sleepHours = record.sleepHours }
                if existing.weightKg == nil { existing.weightKg = record.weightKg }
                if existing.vo2Max == nil { existing.vo2Max = record.vo2Max }
                if existing.sleepQuality == nil { existing.sleepQuality = record.sleepQuality }
                if existing.soreness == nil { existing.soreness = record.soreness }
                if existing.mood == nil { existing.mood = record.mood }
                if existing.motivation == nil { existing.motivation = record.motivation }
                if existing.notes == nil { existing.notes = record.notes }
                report.skipped += 1
                continue
            }
            let metric = DailyMetric(id: record.id, date: record.date, source: record.source)
            metric.hrvSDNN = record.hrvSDNN
            metric.restingHR = record.restingHR
            metric.sleepHours = record.sleepHours
            metric.weightKg = record.weightKg
            metric.vo2Max = record.vo2Max
            metric.sleepQuality = record.sleepQuality
            metric.soreness = record.soreness
            metric.mood = record.mood
            metric.motivation = record.motivation
            metric.notes = record.notes
            context.insert(metric)
            report.dailyMetrics += 1
        }

        let routeIDs = Set(try context.fetch(FetchDescriptor<Route>()).map(\.id))
        for record in archive.routes {
            if routeIDs.contains(record.id) { report.skipped += 1; continue }
            let route = Route(id: record.id, name: record.name,
                              sport: WorkoutSport(rawValue: record.sport) ?? .run)
            route.createdAt = record.createdAt
            route.notes = record.notes
            route.distance = record.distance
            route.elevationGain = record.elevationGain
            route.isLoop = record.isLoop
            route.pointsData = record.pointsData
            route.elevationsData = record.elevationsData
            context.insert(route)
            report.routes += 1
        }

        let planIDs = Set(try context.fetch(FetchDescriptor<PlannedWorkout>()).map(\.id))
        for record in archive.plannedWorkouts {
            if planIDs.contains(record.id) { report.skipped += 1; continue }
            let plan = PlannedWorkout(
                id: record.id, scheduledFor: record.scheduledFor,
                sport: WorkoutSport(rawValue: record.sport) ?? .run,
                title: record.title, order: record.order)
            plan.notes = record.notes
            plan.targetDuration = record.targetDuration
            plan.targetDistance = record.targetDistance
            plan.targetLoad = record.targetLoad
            plan.completedWorkoutID = record.completedWorkoutID
            plan.skippedAt = record.skippedAt
            plan.structureData = record.structureData
            context.insert(plan)
            report.plannedWorkouts += 1
        }

        return report
    }

    // MARK: - CSV

    /// One row per workout, for a spreadsheet.
    ///
    /// Always metric and always ISO dates — a CSV is a data interchange format,
    /// not a view, and a locale-dependent one is a support burden. Streams are
    /// left out by definition; the JSON archive is the thing that round-trips.
    static func workoutsCSV(_ workouts: [WorkoutRecord]) -> String {
        let columns = [
            "date", "sport", "duration_s", "distance_m", "pace_s_per_km",
            "avg_hr", "max_hr", "elevation_gain_m", "calories_kcal",
            "avg_power_w", "source", "external_id", "notes",
        ]
        var lines = [columns.joined(separator: ",")]

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        for workout in workouts.sorted(by: { $0.startedAt < $1.startedAt }) {
            let pace = workout.distance > 0 && workout.duration > 0
                ? String(format: "%.1f", workout.duration / (workout.distance / 1000))
                : ""
            let fields: [String] = [
                formatter.string(from: workout.startedAt),
                workout.sport,
                String(format: "%.0f", workout.duration),
                String(format: "%.1f", workout.distance),
                pace,
                workout.avgHeartRate.map(String.init) ?? "",
                workout.maxHeartRate.map(String.init) ?? "",
                workout.elevationGain.map { String(format: "%.1f", $0) } ?? "",
                workout.calories.map { String(format: "%.0f", $0) } ?? "",
                workout.avgPower.map(String.init) ?? "",
                workout.source,
                workout.externalID ?? "",
                workout.notes ?? "",
            ]
            lines.append(fields.map(escapeCSV).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// RFC 4180: quote anything containing a comma, quote or newline, and double
    /// any embedded quotes. A workout note with a comma in it would otherwise
    /// shift every column after it.
    static func escapeCSV(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
