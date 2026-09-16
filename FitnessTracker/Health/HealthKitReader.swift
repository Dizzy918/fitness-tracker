import Foundation
import SwiftData
import OSLog

#if canImport(HealthKit) && !os(macOS)
import HealthKit
#endif

/// Reads passive health metrics into `DailyMetric` rows.
///
/// HealthKit does not exist on macOS, so the whole implementation is compiled
/// out there and `isAvailable` reports false — the Mac build falls back to manual
/// entry and (once CloudKit is wired) whatever the iPhone synced.
///
/// Deliberately thin: it fetches numbers and writes rows. All the interpretation
/// lives in `Readiness`, which is pure and unit-tested.
struct HealthKitReader {

    private static let log = Logger(subsystem: "com.slavov.fitnesstracker", category: "healthkit")

    static var isAvailable: Bool {
        #if canImport(HealthKit) && !os(macOS)
        return HKHealthStore.isHealthDataAvailable()
        #else
        return false
        #endif
    }

    enum HealthError: LocalizedError {
        case unavailable
        case denied

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Health data isn't available on this device. (HealthKit is iOS-only.)"
            case .denied:
                return "Health access was denied. Enable it in Settings → Privacy → Health."
            }
        }
    }

    #if canImport(HealthKit) && !os(macOS)

    private let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
            types.insert(hrv)
        }
        if let rhr = HKObjectType.quantityType(forIdentifier: .restingHeartRate) {
            types.insert(rhr)
        }
        if let weight = HKObjectType.quantityType(forIdentifier: .bodyMass) {
            types.insert(weight)
        }
        if let vo2 = HKObjectType.quantityType(forIdentifier: .vo2Max) {
            types.insert(vo2)
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        return types
    }

    /// Ask for read access. Returns without throwing if the user declines —
    /// HealthKit deliberately doesn't reveal denial, so a later empty read is
    /// indistinguishable from "no data".
    func requestAuthorization() async throws {
        guard Self.isAvailable else { throw HealthError.unavailable }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Import the last `days` days of metrics, upserting one row per day.
    @discardableResult
    @MainActor
    func importMetrics(days: Int = 30, into context: ModelContext) async throws -> Int {
        guard Self.isAvailable else { throw HealthError.unavailable }
        try await requestAuthorization()

        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: .now))!

        // Each of these is a daily-statistics query; sleep is summed per night.
        async let hrv = dailyAverages(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), since: start)
        async let rhr = dailyAverages(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), since: start)
        async let weight = dailyAverages(.bodyMass, unit: .gramUnit(with: .kilo), since: start)
        async let vo2 = dailyAverages(.vo2Max, unit: HKUnit(from: "ml/kg*min"), since: start)
        async let sleep = dailySleepHours(since: start)

        let (hrvByDay, rhrByDay, weightByDay, vo2ByDay, sleepByDay) =
            try await (hrv, rhr, weight, vo2, sleep)

        let allDays = Set(hrvByDay.keys)
            .union(rhrByDay.keys)
            .union(weightByDay.keys)
            .union(vo2ByDay.keys)
            .union(sleepByDay.keys)

        var written = 0
        for day in allDays.sorted() {
            let metric = try Self.upsert(day: day, in: context)
            // Never clobber a value with nil: a day may be partially covered.
            if let v = hrvByDay[day] { metric.hrvSDNN = v }
            if let v = rhrByDay[day] { metric.restingHR = v }
            if let v = weightByDay[day] { metric.weightKg = v }
            if let v = vo2ByDay[day] { metric.vo2Max = v }
            if let v = sleepByDay[day] { metric.sleepHours = v }
            metric.source = metric.hasCheckIn ? "mixed" : "healthkit"
            written += 1
        }
        Self.log.info("Imported HealthKit metrics for \(written, privacy: .public) days")
        return written
    }

    /// Daily average of a quantity type.
    private func dailyAverages(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        since start: Date
    ) async throws -> [Date: Double] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [:] }
        let calendar = Calendar.current

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(
                    withStart: start, end: .now, options: .strictStartDate
                ),
                options: .discreteAverage,
                anchorDate: calendar.startOfDay(for: start),
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    // A missing permission reads as an error; treat it as no data
                    // rather than failing the whole import.
                    Self.log.notice("\(identifier.rawValue, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: [:])
                    return
                }
                var out: [Date: Double] = [:]
                collection?.enumerateStatistics(from: start, to: .now) { stats, _ in
                    if let value = stats.averageQuantity()?.doubleValue(for: unit) {
                        out[calendar.startOfDay(for: stats.startDate)] = value
                    }
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }

    /// Hours actually asleep per night, attributed to the wake-up day.
    private func dailySleepHours(since start: Date) async throws -> [Date: Double] {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            return [:]
        }
        let calendar = Calendar.current

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: HKQuery.predicateForSamples(withStart: start, end: .now),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    Self.log.notice("sleep unavailable: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: [:])
                    return
                }
                var totals: [Date: Double] = [:]
                for case let sample as HKCategorySample in samples ?? [] {
                    // Only count actual asleep stages, not time in bed.
                    let asleepValues: Set<Int> = [
                        HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                        HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                        HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                        HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                    ]
                    guard asleepValues.contains(sample.value) else { continue }
                    // A night spanning midnight belongs to the day you woke up.
                    let day = calendar.startOfDay(for: sample.endDate)
                    let hours = sample.endDate.timeIntervalSince(sample.startDate) / 3600
                    totals[day, default: 0] += hours
                }
                continuation.resume(returning: totals)
            }
            store.execute(query)
        }
    }

    #else

    func requestAuthorization() async throws {
        throw HealthError.unavailable
    }

    @discardableResult
    @MainActor
    func importMetrics(days: Int = 30, into context: ModelContext) async throws -> Int {
        throw HealthError.unavailable
    }

    #endif

    /// Find the row for a day without creating one.
    ///
    /// Matched by half-open day range, not `date == start`. Stored dates are
    /// start-of-day *in the time zone that wrote them*, so after travel an exact
    /// comparison misses the existing row and the caller quietly creates a
    /// second one for the same calendar day.
    @MainActor
    static func metric(for day: Date, in context: ModelContext) throws -> DailyMetric? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        var descriptor = FetchDescriptor<DailyMetric>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Fetch-or-create the row for a day. Shared by HealthKit import and the
    /// manual check-in so they can't create duplicate rows for one date.
    ///
    /// This inserts. Anything that only wants to *read* today's values — a sheet
    /// that might be cancelled, say — must use `metric(for:in:)` instead, or it
    /// leaves an empty row behind.
    @MainActor
    static func upsert(day: Date, in context: ModelContext) throws -> DailyMetric {
        if let existing = try metric(for: day, in: context) { return existing }
        let metric = DailyMetric(date: Calendar.current.startOfDay(for: day))
        context.insert(metric)
        return metric
    }
}
