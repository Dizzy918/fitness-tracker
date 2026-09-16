import Foundation

/// Shared value formatters. Kept in one place so units read consistently
/// across every screen.
enum Fmt {

    /// "1:23:45" or "23:45"
    static func duration(_ s: TimeInterval) -> String {
        guard s.isFinite, s >= 0 else { return "–" }
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    /// "4:35" from seconds-per-km.
    static func pace(_ secPerKm: Double?) -> String {
        guard let secPerKm, secPerKm.isFinite, secPerKm > 0 else { return "–" }
        let total = Int(secPerKm.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "8.24 km"
    static func km(_ meters: Double, decimals: Int = 2) -> String {
        String(format: "%.\(decimals)f km", meters / 1000)
    }

    static func meters(_ m: Double?) -> String {
        guard let m else { return "–" }
        return "\(Int(m.rounded())) m"
    }

    static func bpm(_ v: Int?) -> String {
        guard let v else { return "–" }
        return "\(v) bpm"
    }

    static func kcal(_ v: Double?) -> String {
        guard let v else { return "–" }
        return "\(Int(v.rounded())) kcal"
    }
}
