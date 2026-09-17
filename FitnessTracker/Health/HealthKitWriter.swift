import Foundation
import SwiftData
import CoreLocation
import OSLog

#if canImport(HealthKit) && !os(macOS)
import HealthKit
#endif

/// Writes imported workouts back to Apple Health at full fidelity.
///
/// This is the other half of the FIT-first design. Suunto's own Health sync
/// writes a summary and drops the GPS track and per-second heart rate — which is
/// exactly why this app reads `.fit` files directly. But that leaves Apple
/// Health, the Fitness rings and every other health app looking at the degraded
/// copy. Pushing the decoded workout back gives the rest of the system the good
/// data, with the route and the heart-rate series intact.
///
/// Nothing is written without an explicit tap, and nothing is written twice.
enum HealthKitWriter {

    private static let log = Logger(subsystem: "com.slavov.fitnesstracker", category: "healthwrite")

    /// Marks a workout as ours when reading Health back, and is the key the
    /// dedupe relies on.
    static let externalIDMetadataKey = "com.slavov.fitnesstracker.externalID"

    static var isAvailable: Bool { HealthKitReader.isAvailable }

    enum WriteError: LocalizedError {
        case unavailable
        case denied
        case nothingToWrite

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Apple Health isn't available on this device. (HealthKit is iOS-only.)"
            case .denied:
                return "Permission to write workouts was declined. Enable it in Settings → Health → Data Access & Devices."
            case .nothingToWrite:
                return "Every workout is already in Apple Health."
            }
        }
    }

    struct Report: Sendable {
        var written: Int = 0
        var skipped: Int = 0
        var failures: [String] = []

        var summary: String {
            var parts = ["Wrote \(written) workout\(written == 1 ? "" : "s") to Apple Health"]
            if skipped > 0 { parts.append("skipped \(skipped) already there") }
            if !failures.isEmpty { parts.append("\(failures.count) failed") }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// Sources that must never reach someone's real health record: workouts
    /// that came *from* Health would be duplicated back into it, and demo data
    /// isn't a real workout at all.
    static let nonExportableSources = ["healthkit", "demo"]

    /// Workouts that came from a file or a service and haven't been exported.
    @MainActor
    static func pendingExport(in context: ModelContext, limit: Int = 500) -> [Workout] {
        let excluded = Self.nonExportableSources
        var descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate {
                $0.healthKitExportedAt == nil && !excluded.contains($0.source)
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.duration > 0 }
    }

    #if canImport(HealthKit) && !os(macOS)

    private static var store: HKHealthStore { HKHealthStore() }

    private static var writeTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        for identifier: HKQuantityTypeIdentifier in [
            .heartRate, .activeEnergyBurned, .distanceWalkingRunning,
            .distanceCycling, .distanceSwimming,
        ] {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        return types
    }

    static func requestAuthorization() async throws {
        guard isAvailable else { throw WriteError.unavailable }
        try await store.requestAuthorization(toShare: writeTypes, read: [])
    }

    /// Export every pending workout.
    ///
    /// Sequential on purpose: `HKWorkoutBuilder` writes are not cheap, and a
    /// burst of concurrent builders against one store is a good way to get
    /// throttled or to interleave samples into the wrong workout.
    @MainActor
    @discardableResult
    static func exportPending(in context: ModelContext, limit: Int = 200) async throws -> Report {
        guard isAvailable else { throw WriteError.unavailable }
        try await requestAuthorization()

        // Authorization status for writing is readable, unlike reading — so a
        // declined permission can be reported honestly instead of looking like
        // a silent success that wrote nothing.
        guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
            throw WriteError.denied
        }

        let pending = Array(pendingExport(in: context).prefix(limit))
        guard !pending.isEmpty else { throw WriteError.nothingToWrite }

        var report = Report()
        for workout in pending {
            let payload = WorkoutPayload(workout)
            do {
                try await write(payload)
                workout.healthKitExportedAt = .now
                report.written += 1
            } catch {
                report.failures.append(
                    "\(workout.startedAt.formatted(date: .abbreviated, time: .shortened)): \(error.localizedDescription)"
                )
            }
        }
        log.info("exported \(report.written, privacy: .public) workouts to HealthKit")
        return report
    }

    /// A Sendable copy of everything one write needs, taken on the main actor
    /// before the SwiftData model is left behind.
    private struct WorkoutPayload: Sendable {
        let externalID: String
        let sport: WorkoutSport
        let start: Date
        let end: Date
        let distance: Double
        let calories: Double?
        let samples: [FITSample]
        let coordinates: [[Double]]
        let notes: String?

        @MainActor
        init(_ workout: Workout) {
            externalID = workout.externalID ?? workout.id.uuidString
            sport = workout.sport
            start = workout.startedAt
            end = workout.startedAt.addingTimeInterval(workout.duration)
            distance = workout.distance
            calories = workout.calories
            samples = workout.samples
            coordinates = workout.coordinates
            notes = workout.notes
        }
    }

    private static func write(_ payload: WorkoutPayload) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activityType(for: payload.sport)
        configuration.locationType = payload.coordinates.isEmpty ? .indoor : .outdoor
        if payload.sport == .swim {
            configuration.swimmingLocationType = .pool
        }

        let builder = HKWorkoutBuilder(healthStore: store,
                                       configuration: configuration,
                                       device: .local())
        try await builder.beginCollection(at: payload.start)

        var samples: [HKSample] = []
        samples.append(contentsOf: heartRateSamples(payload))
        samples.append(contentsOf: distanceSamples(payload))
        if let energy = energySample(payload) { samples.append(energy) }
        if !samples.isEmpty {
            try await builder.addSamples(samples)
        }

        var metadata: [String: Any] = [
            externalIDMetadataKey: payload.externalID,
            HKMetadataKeyExternalUUID: payload.externalID,
            HKMetadataKeyWasUserEntered: false,
        ]
        if let notes = payload.notes, !notes.isEmpty {
            metadata[HKMetadataKeyWorkoutBrandName] = String(notes.prefix(200))
        }
        try await builder.addMetadata(metadata)

        try await builder.endCollection(at: payload.end)
        guard let workout = try await builder.finishWorkout() else { return }

        // The route is a separate series, attached after the workout exists.
        let locations = self.locations(payload)
        if !locations.isEmpty {
            let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
            try await routeBuilder.insertRouteData(locations)
            try await routeBuilder.finishRoute(with: workout, metadata: nil)
        }
    }

    // MARK: - Sample construction

    /// One heart-rate sample per reading, spanning to the next one.
    ///
    /// Instantaneous samples would be defensible but lose the interval, and
    /// Health's own charts read a series better when each sample covers the time
    /// it represents. A gap longer than a minute is a recording dropout, and
    /// stretching a sample across it would invent a heart rate that was never
    /// measured.
    private static func heartRateSamples(_ payload: WorkoutPayload) -> [HKQuantitySample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let ordered = payload.samples.filter { $0.hr != nil }.sorted { $0.t < $1.t }
        guard ordered.count >= 2 else { return [] }

        var out: [HKQuantitySample] = []
        out.reserveCapacity(ordered.count)
        for index in ordered.indices.dropLast() {
            guard let bpm = ordered[index].hr, bpm > 0 else { continue }
            let dt = ordered[index + 1].t - ordered[index].t
            guard dt > 0, dt <= 60 else { continue }
            let start = payload.start.addingTimeInterval(ordered[index].t)
            out.append(HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: Double(bpm)),
                start: start,
                end: start.addingTimeInterval(dt)
            ))
        }
        return out
    }

    /// Distance as per-interval deltas from the cumulative stream, so Health
    /// gets a real distribution over time rather than one lump at the start.
    private static func distanceSamples(_ payload: WorkoutPayload) -> [HKQuantitySample] {
        guard let identifier = distanceIdentifier(for: payload.sport),
              let type = HKQuantityType.quantityType(forIdentifier: identifier)
        else { return [] }

        let ordered = payload.samples.filter { $0.dist != nil }.sorted { $0.t < $1.t }
        guard ordered.count >= 2 else {
            // No stream: one sample for the whole workout is still better than
            // a workout Health thinks covered no ground.
            guard payload.distance > 0 else { return [] }
            return [HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: .meter(), doubleValue: payload.distance),
                start: payload.start, end: payload.end
            )]
        }

        var out: [HKQuantitySample] = []
        for index in ordered.indices.dropFirst() {
            guard let previous = ordered[index - 1].dist,
                  let current = ordered[index].dist
            else { continue }
            let delta = current - previous
            let dt = ordered[index].t - ordered[index - 1].t
            // A negative delta is a distance reset; a long gap is a dropout.
            guard delta > 0, dt > 0, dt <= 60 else { continue }
            let start = payload.start.addingTimeInterval(ordered[index - 1].t)
            out.append(HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: .meter(), doubleValue: delta),
                start: start, end: start.addingTimeInterval(dt)
            ))
        }
        return out
    }

    private static func energySample(_ payload: WorkoutPayload) -> HKQuantitySample? {
        guard let calories = payload.calories, calories > 0,
              let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
        else { return nil }
        return HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: calories),
            start: payload.start, end: payload.end
        )
    }

    private static func locations(_ payload: WorkoutPayload) -> [CLLocation] {
        let timed = payload.samples.filter { $0.lat != nil && $0.lon != nil }
            .sorted { $0.t < $1.t }

        // Prefer stream points, which carry a timestamp each. Fall back to the
        // stored polyline, spreading it evenly across the workout — a route with
        // approximate times beats no route.
        if !timed.isEmpty {
            return timed.compactMap { sample in
                guard let lat = sample.lat, let lon = sample.lon,
                      (-90...90).contains(lat), (-180...180).contains(lon)
                else { return nil }
                return CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    altitude: sample.alt ?? 0,
                    horizontalAccuracy: 5, verticalAccuracy: sample.alt == nil ? -1 : 5,
                    timestamp: payload.start.addingTimeInterval(sample.t)
                )
            }
        }

        let points = payload.coordinates.filter { $0.count == 2 }
        guard points.count >= 2 else { return [] }
        let span = payload.end.timeIntervalSince(payload.start)
        return points.enumerated().compactMap { index, pair in
            guard (-90...90).contains(pair[0]), (-180...180).contains(pair[1]) else { return nil }
            let fraction = Double(index) / Double(points.count - 1)
            return CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1]),
                altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1,
                timestamp: payload.start.addingTimeInterval(span * fraction)
            )
        }
    }

    // MARK: - Mapping

    static func activityType(for sport: WorkoutSport) -> HKWorkoutActivityType {
        switch sport {
        case .run, .trailRun: return .running
        case .bike:           return .cycling
        case .swim:           return .swimming
        case .hike:           return .hiking
        case .walk:           return .walking
        case .other:          return .other
        }
    }

    static func distanceIdentifier(for sport: WorkoutSport) -> HKQuantityTypeIdentifier? {
        switch sport {
        case .run, .trailRun, .hike, .walk: return .distanceWalkingRunning
        case .bike:                         return .distanceCycling
        case .swim:                         return .distanceSwimming
        case .other:                        return nil
        }
    }

    #else

    static func requestAuthorization() async throws { throw WriteError.unavailable }

    @MainActor
    @discardableResult
    static func exportPending(in context: ModelContext, limit: Int = 200) async throws -> Report {
        throw WriteError.unavailable
    }

    #endif
}
