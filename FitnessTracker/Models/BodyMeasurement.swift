import Foundation
import SwiftData

/// A tape-measure session.
///
/// Weight alone is a bad progress signal and everyone who has tracked it knows
/// why: it moves several kilos on water and glycogen, and it can't tell a kilo
/// of muscle from a kilo of anything else. Waist and arm don't move on water,
/// and they answer the question weight can't — whether the shape is changing.
///
/// Separate from `DailyMetric` rather than more columns on it. Measurements are
/// taken weekly or monthly, not daily, and `DailyMetric` is fetched for every
/// day in the readiness window — widening that row to carry eight
/// circumferences that are nil on 95% of days is the wrong trade.
///
/// Weight deliberately isn't here. It already lives on `DailyMetric`, the
/// readiness model reads it there, and a second copy would immediately disagree
/// with the first.
@Model
final class BodyMeasurement {
    var id: UUID = UUID()
    /// Normalized to the start of the day: one measurement per day at most.
    var date: Date = Date.distantPast

    /// Percent, however it was arrived at — calipers, a smart scale, a DEXA.
    var bodyFatPercent: Double?

    // Circumferences, centimetres. Stored metric like every other length in
    // the app; the formatter converts for display.
    var neck: Double?
    var shoulders: Double?
    var chest: Double?
    var waist: Double?
    var hips: Double?
    var thighLeft: Double?
    var thighRight: Double?
    var armLeft: Double?
    var armRight: Double?
    var calfLeft: Double?
    var calfRight: Double?

    var notes: String?

    init(id: UUID = UUID(), date: Date) {
        self.id = id
        self.date = Calendar.current.startOfDay(for: date)
    }

    /// Every site this model knows about, in the order a tape goes down a body.
    ///
    /// A single list so the editor, the chart picker, the backup and the trend
    /// maths can't disagree about what exists or what it's called.
    enum Site: String, CaseIterable, Identifiable, Sendable {
        case bodyFat, neck, shoulders, chest, waist, hips
        case thighLeft, thighRight, armLeft, armRight, calfLeft, calfRight

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .bodyFat:    return "Body fat"
            case .neck:       return "Neck"
            case .shoulders:  return "Shoulders"
            case .chest:      return "Chest"
            case .waist:      return "Waist"
            case .hips:       return "Hips"
            case .thighLeft:  return "Thigh (L)"
            case .thighRight: return "Thigh (R)"
            case .armLeft:    return "Arm (L)"
            case .armRight:   return "Arm (R)"
            case .calfLeft:   return "Calf (L)"
            case .calfRight:  return "Calf (R)"
            }
        }

        /// Body fat is a percentage; everything else is a length.
        var isPercentage: Bool { self == .bodyFat }

        /// Whether a rise is progress. Deliberately absent for most sites: a
        /// bigger arm is usually the goal and a bigger waist usually isn't, but
        /// "usually" is doing a lot of work — someone in a bulk wants both to
        /// go up. Only body fat has an answer that holds for everyone.
        var lowerIsBetter: Bool? { self == .bodyFat ? true : nil }

        /// A plausible range, so a slipped decimal point is caught at entry
        /// rather than distorting a chart for good.
        var range: ClosedRange<Double> {
            switch self {
            case .bodyFat:                        return 3...60
            case .neck:                           return 25...60
            case .shoulders:                      return 80...180
            case .chest:                          return 60...180
            case .waist:                          return 50...200
            case .hips:                           return 60...200
            case .thighLeft, .thighRight:         return 30...100
            case .armLeft, .armRight:             return 15...70
            case .calfLeft, .calfRight:           return 20...70
            }
        }
    }

    subscript(site: Site) -> Double? {
        get {
            switch site {
            case .bodyFat:    return bodyFatPercent
            case .neck:       return neck
            case .shoulders:  return shoulders
            case .chest:      return chest
            case .waist:      return waist
            case .hips:       return hips
            case .thighLeft:  return thighLeft
            case .thighRight: return thighRight
            case .armLeft:    return armLeft
            case .armRight:   return armRight
            case .calfLeft:   return calfLeft
            case .calfRight:  return calfRight
            }
        }
        set {
            switch site {
            case .bodyFat:    bodyFatPercent = newValue
            case .neck:       neck = newValue
            case .shoulders:  shoulders = newValue
            case .chest:      chest = newValue
            case .waist:      waist = newValue
            case .hips:       hips = newValue
            case .thighLeft:  thighLeft = newValue
            case .thighRight: thighRight = newValue
            case .armLeft:    armLeft = newValue
            case .armRight:   armRight = newValue
            case .calfLeft:   calfLeft = newValue
            case .calfRight:  calfRight = newValue
            }
        }
    }

    /// Sites actually recorded, in tape order.
    var recordedSites: [Site] { Site.allCases.filter { self[$0] != nil } }

    var isEmpty: Bool { recordedSites.isEmpty }

    /// Waist-to-hip ratio, where both were taken.
    ///
    /// Worth surfacing because it's the one derived number here with an
    /// established association with health outcomes, rather than a number that
    /// only means something relative to your own last one.
    var waistToHip: Double? {
        guard let waist, let hips, hips > 0 else { return nil }
        return waist / hips
    }
}

// MARK: - Trends

/// Change at one site over a window.
enum MeasurementTrend {

    struct Change: Identifiable, Sendable, Equatable {
        let site: BodyMeasurement.Site
        let first: Double
        let last: Double
        let firstDate: Date
        let lastDate: Date

        var id: String { site.rawValue }
        var delta: Double { last - first }

        /// Per cent of the starting value, which is how a 2 cm change on an arm
        /// and on a waist stop looking like the same thing.
        var percentChange: Double? {
            guard first != 0 else { return nil }
            return delta / first * 100
        }

        var days: Int {
            Calendar.current.dateComponents([.day], from: firstDate, to: lastDate).day ?? 0
        }

        /// Whether this counts as progress, where the site has an opinion.
        var isImprovement: Bool? {
            guard let lowerIsBetter = site.lowerIsBetter, delta != 0 else { return nil }
            return lowerIsBetter ? delta < 0 : delta > 0
        }
    }

    /// Change per site between the earliest and latest measurement in `window`.
    ///
    /// Earliest-to-latest per site independently, not between two whole
    /// sessions: people measure their waist every week and their calves twice
    /// a year, and pinning every site to one pair of dates would either discard
    /// most of the data or invent it.
    static func changes(
        in measurements: [BodyMeasurement],
        since start: Date? = nil
    ) -> [Change] {
        let inWindow = measurements
            .filter { start == nil || $0.date >= start! }
            .sorted { $0.date < $1.date }
        guard inWindow.count >= 1 else { return [] }

        return BodyMeasurement.Site.allCases.compactMap { site in
            let points = inWindow.compactMap { measurement -> (Date, Double)? in
                guard let value = measurement[site] else { return nil }
                return (measurement.date, value)
            }
            // One reading is a record, not a trend.
            guard let first = points.first, let last = points.last,
                  points.count >= 2 else { return nil }
            return Change(site: site, first: first.1, last: last.1,
                          firstDate: first.0, lastDate: last.0)
        }
    }

    /// The series for one site, oldest first, for charting.
    static func series(
        for site: BodyMeasurement.Site,
        in measurements: [BodyMeasurement]
    ) -> [(date: Date, value: Double)] {
        measurements
            .compactMap { measurement in
                measurement[site].map { (date: measurement.date, value: $0) }
            }
            .sorted { $0.date < $1.date }
    }
}
