import Foundation
import SwiftUI

/// Metric or imperial, as a display concern only.
///
/// **Everything is stored in SI** — metres, seconds, kilograms, seconds per
/// kilometre — and converted at the last possible moment. That's the only way
/// to keep the analysis honest: a threshold pace, a 42-day load average and a
/// personal best all have to stay comparable across a preference the athlete can
/// flip at any time, and re-deriving them in whatever unit was selected last
/// would make history disagree with itself.
enum UnitSystem: String, CaseIterable, Codable, Sendable, Identifiable {
    case metric
    case imperial

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .metric:   return "Metric"
        case .imperial: return "Imperial"
        }
    }

    var detail: String {
        switch self {
        case .metric:   return "km, metres, kilograms"
        case .imperial: return "miles, feet, pounds"
        }
    }

    /// The stored preference. Defaults to metric, which is what the FIT format,
    /// every analysis in this app, and most of the world already use.
    static let defaultsKey = "unitSystem"

    static func current(_ defaults: UserDefaults = .standard) -> UnitSystem {
        defaults.string(forKey: defaultsKey).flatMap(UnitSystem.init) ?? .metric
    }
}

// MARK: - Conversion constants

enum UnitConversion {
    static let metersPerMile = 1_609.344
    static let metersPerYard = 0.9144
    static let metersPerFoot = 0.3048
    static let kilogramsPerPound = 0.45359237
    static let centimetresPerInch = 2.54
}

/// Formats stored SI values for display in the athlete's chosen units.
///
/// A value type rather than a global so it can be injected through the SwiftUI
/// environment: views read it, so they redraw when the preference changes, and
/// tests construct one directly instead of mutating `UserDefaults`.
struct UnitFormatter: Sendable, Equatable {
    let system: UnitSystem

    init(_ system: UnitSystem = .metric) {
        self.system = system
    }

    private var isMetric: Bool { system == .metric }

    // MARK: - Distance

    /// Long distances: "8.24 km" / "5.12 mi".
    func distance(_ meters: Double, decimals: Int = 2) -> String {
        guard meters.isFinite else { return "–" }
        let value = isMetric ? meters / 1000 : meters / UnitConversion.metersPerMile
        return String(format: "%.\(decimals)f %@", value, distanceUnit)
    }

    var distanceUnit: String { isMetric ? "km" : "mi" }

    /// Short distances, the ones measured on a track: "400 m" / "437 yd".
    ///
    /// Yards rather than feet, because that's how intervals are written in
    /// imperial-speaking athletics and pools.
    func shortDistance(_ meters: Double) -> String {
        guard meters.isFinite else { return "–" }
        let value = isMetric ? meters : meters / UnitConversion.metersPerYard
        return "\(Int(value.rounded())) \(shortDistanceUnit)"
    }

    var shortDistanceUnit: String { isMetric ? "m" : "yd" }

    /// Picks the sensible scale: a 400 m rep reads in metres, a 10 km run in km.
    func autoDistance(_ meters: Double, decimals: Int = 2) -> String {
        let threshold = isMetric ? 1_000.0 : UnitConversion.metersPerMile
        return meters < threshold ? shortDistance(meters) : distance(meters, decimals: decimals)
    }

    // MARK: - Elevation

    /// Climb is quoted in feet by imperial athletes, never yards.
    func elevation(_ meters: Double?) -> String {
        guard let meters, meters.isFinite else { return "–" }
        let value = isMetric ? meters : meters / UnitConversion.metersPerFoot
        return "\(Int(value.rounded())) \(elevationUnit)"
    }

    var elevationUnit: String { isMetric ? "m" : "ft" }

    // MARK: - Pace

    /// Pace from the stored seconds per kilometre: "4:35/km" / "7:23/mi".
    func pace(_ secPerKm: Double?) -> String {
        guard let converted = paceValue(secPerKm) else { return "–" }
        return "\(Fmt.clock(converted))/\(paceUnit)"
    }

    /// Without the unit suffix, for tables that label their own column.
    func paceValue(_ secPerKm: Double?) -> Double? {
        guard let secPerKm, secPerKm.isFinite, secPerKm > 0 else { return nil }
        return isMetric ? secPerKm : secPerKm * UnitConversion.metersPerMile / 1000
    }

    var paceUnit: String { isMetric ? "km" : "mi" }

    /// Speed from metres per second: "31.4 km/h" / "19.5 mph". Riders think in
    /// speed; nobody quotes a bike split in minutes per kilometre.
    func speed(_ metresPerSecond: Double?) -> String {
        guard let metresPerSecond, metresPerSecond.isFinite, metresPerSecond > 0
        else { return "–" }
        let value = isMetric
            ? metresPerSecond * 3.6
            : metresPerSecond / UnitConversion.metersPerMile * 3600
        return String(format: "%.1f %@", value, speedUnit)
    }

    var speedUnit: String { isMetric ? "km/h" : "mph" }

    /// How a given sport states its rate, from seconds per kilometre.
    ///
    /// Riders read speed, swimmers read per 100, everyone else reads pace. A
    /// ride labelled "3:13/mi" is arithmetically correct and unreadable — no
    /// cyclist has ever quoted a bike split in minutes per mile.
    func rate(_ secPerKm: Double?, sport: WorkoutSport) -> String {
        guard let secPerKm, secPerKm.isFinite, secPerKm > 0 else { return "–" }
        switch sport {
        case .swim: return swimPace(secPerKm / 10)
        case .bike: return speed(1000 / secPerKm)
        default:    return pace(secPerKm)
        }
    }

    /// The label that goes with `rate(_:sport:)`.
    func rateLabel(for sport: WorkoutSport) -> String {
        sport == .bike ? "Speed" : "Pace"
    }

    /// Swimmers read per 100 m; imperial pools are 25 yd, so per 100 yd.
    func swimPace(_ secPer100m: Double?) -> String {
        guard let secPer100m, secPer100m.isFinite, secPer100m > 0 else { return "–" }
        let value = isMetric ? secPer100m : secPer100m * UnitConversion.metersPerYard
        return "\(Fmt.clock(value))/\(swimPaceUnit)"
    }

    var swimPaceUnit: String { isMetric ? "100 m" : "100 yd" }

    // MARK: - Mass

    func weight(_ kilograms: Double?, decimals: Int = 1) -> String {
        guard let kilograms, kilograms.isFinite else { return "–" }
        let value = isMetric ? kilograms : kilograms / UnitConversion.kilogramsPerPound
        return String(format: "%.\(decimals)f %@", value, weightUnit)
    }

    var weightUnit: String { isMetric ? "kg" : "lb" }

    /// Lifting tonnage, which runs to five figures and doesn't want decimals.
    func volume(_ kilograms: Double) -> String {
        guard kilograms.isFinite else { return "–" }
        let value = isMetric ? kilograms : kilograms / UnitConversion.kilogramsPerPound
        return "\(Int(value.rounded())) \(weightUnit)"
    }

    /// Converts a displayed weight back to the stored kilograms, for input.
    func kilograms(fromDisplayed value: Double) -> Double {
        isMetric ? value : value * UnitConversion.kilogramsPerPound
    }

    /// Converts stored kilograms into the number an input field should show.
    func displayedWeight(fromKilograms value: Double) -> Double {
        isMetric ? value : value / UnitConversion.kilogramsPerPound
    }

    // MARK: - Body measurements

    /// A circumference or a body-fat percentage, whichever the site is.
    ///
    /// Takes the site rather than a flag because body fat is a percentage in
    /// both unit systems and converting it would be nonsense — a mistake that
    /// a generic "length" formatter invites.
    func bodyMeasurement(_ value: Double?, site: BodyMeasurement.Site) -> String {
        guard let value, value.isFinite else { return "–" }
        if site.isPercentage { return String(format: "%.1f%%", value) }
        return isMetric
            ? String(format: "%.1f cm", value)
            : String(format: "%.1f in", value / UnitConversion.centimetresPerInch)
    }

    /// The same, signed, for a change.
    func bodyMeasurementDelta(_ value: Double, site: BodyMeasurement.Site) -> String {
        guard value.isFinite else { return "–" }
        if site.isPercentage { return Fmt.signed(value, decimals: 1) + "%" }
        return isMetric
            ? Fmt.signed(value, decimals: 1) + " cm"
            : Fmt.signed(value / UnitConversion.centimetresPerInch, decimals: 1) + " in"
    }

    // MARK: - Unit-independent passthroughs
    //
    // Here so a view needs one dependency rather than two.

    func duration(_ seconds: TimeInterval) -> String { Fmt.duration(seconds) }
    func bpm(_ value: Int?) -> String { Fmt.bpm(value) }
    func kcal(_ value: Double?) -> String { Fmt.kcal(value) }
}

// MARK: - Environment

private struct UnitFormatterKey: EnvironmentKey {
    static let defaultValue = UnitFormatter(.metric)
}

extension EnvironmentValues {
    /// Injected once at the root from the stored preference. Views that read it
    /// redraw when the athlete changes the setting.
    var units: UnitFormatter {
        get { self[UnitFormatterKey.self] }
        set { self[UnitFormatterKey.self] = newValue }
    }
}
