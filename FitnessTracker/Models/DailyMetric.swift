import Foundation
import SwiftData

/// One day's wellness snapshot: objective values read from HealthKit plus an
/// optional subjective check-in. One row per calendar day, upserted.
@Model
final class DailyMetric {
    var id: UUID = UUID()
    /// Normalized to the start of the day in the current calendar.
    var date: Date = Date.distantPast

    // Objective (HealthKit on iOS, manual entry elsewhere)
    var hrvSDNN: Double?        // ms
    var restingHR: Double?      // bpm
    var sleepHours: Double?
    var weightKg: Double?
    var vo2Max: Double?         // mL/kg/min

    // Subjective check-in, 1–5 scales
    var sleepQuality: Int?      // 1 terrible … 5 excellent
    var soreness: Int?          // 1 none … 5 very sore  (higher is worse)
    var mood: Int?              // 1 poor … 5 great
    var motivation: Int?        // 1 none … 5 eager

    var notes: String?
    var source: String = "manual"   // "healthkit" | "manual" | "mixed"

    init(id: UUID = UUID(), date: Date, source: String = "manual") {
        self.id = id
        self.date = Calendar.current.startOfDay(for: date)
        self.source = source
    }

    var hasObjectiveData: Bool {
        hrvSDNN != nil || restingHR != nil || sleepHours != nil
    }

    var hasCheckIn: Bool {
        sleepQuality != nil || soreness != nil || mood != nil || motivation != nil
    }
}

/// A plain snapshot of a day, so scoring can be tested without SwiftData.
struct MetricSnapshot: Sendable, Equatable, Hashable {
    var date: Date
    var hrvSDNN: Double?
    var restingHR: Double?
    var sleepHours: Double?
    var sleepQuality: Int?
    var soreness: Int?
    var mood: Int?
    var motivation: Int?

    init(date: Date,
         hrvSDNN: Double? = nil,
         restingHR: Double? = nil,
         sleepHours: Double? = nil,
         sleepQuality: Int? = nil,
         soreness: Int? = nil,
         mood: Int? = nil,
         motivation: Int? = nil) {
        self.date = Calendar.current.startOfDay(for: date)
        self.hrvSDNN = hrvSDNN
        self.restingHR = restingHR
        self.sleepHours = sleepHours
        self.sleepQuality = sleepQuality
        self.soreness = soreness
        self.mood = mood
        self.motivation = motivation
    }
}

extension DailyMetric {
    var snapshot: MetricSnapshot {
        MetricSnapshot(
            date: date, hrvSDNN: hrvSDNN, restingHR: restingHR,
            sleepHours: sleepHours, sleepQuality: sleepQuality,
            soreness: soreness, mood: mood, motivation: motivation
        )
    }
}
