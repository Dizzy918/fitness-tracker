import Foundation

/// How a block of training was distributed across intensities.
///
/// The app could already show the zone breakdown of one session, which answers
/// nothing on its own — the question that actually changes what you do next week
/// is whether the *block* was distributed right. Most endurance athletes go too
/// hard on easy days and not hard enough on hard ones, and the only way to see
/// it is to add the time up.
enum IntensityDistribution {

    /// The three-zone model the polarization question is asked in.
    ///
    /// Five-zone percent-of-max is what the app records; this collapses it,
    /// because "80/20" has never meant anything in five zones. The boundaries
    /// are the two lactate thresholds, approximated from percent of max:
    /// LT1 around 80%, LT2 around 90%.
    ///
    /// That approximation is the weak link and the UI says so. A real athlete's
    /// thresholds can sit several percent either side, which moves time between
    /// bands — the *shape* is reliable, a single percentage point is not.
    enum Band: String, CaseIterable, Identifiable, Sendable {
        case easy       // below LT1 — zones 1–3
        case moderate   // between the thresholds — zone 4
        case hard       // above LT2 — zone 5

        var id: String { rawValue }

        /// Five-zone indices that fold into this band.
        var zones: [Int] {
            switch self {
            case .easy:     return [1, 2, 3]
            case .moderate: return [4]
            case .hard:     return [5]
            }
        }

        var displayName: String {
            switch self {
            case .easy:     return "Easy"
            case .moderate: return "Moderate"
            case .hard:     return "Hard"
            }
        }

        var detail: String {
            switch self {
            case .easy:     return "Below the aerobic threshold — conversational"
            case .moderate: return "Between the thresholds — comfortably hard"
            case .hard:     return "Above the anaerobic threshold — interval effort"
            }
        }

        static func containing(zone: Int) -> Band? {
            allCases.first { $0.zones.contains(zone) }
        }
    }

    struct Slice: Sendable, Identifiable {
        let band: Band
        let seconds: TimeInterval
        let fraction: Double    // 0–1 of the measured total
        var id: String { band.rawValue }

        var percent: Int { Int((fraction * 100).rounded()) }
    }

    struct Summary: Sendable {
        let slices: [Slice]
        /// Time that had a heart rate to classify.
        let measuredSeconds: TimeInterval
        /// Sessions that contributed.
        let measuredSessions: Int
        /// Sessions with no usable heart-rate stream, so not represented at all.
        let unmeasuredSessions: Int

        func seconds(_ band: Band) -> TimeInterval {
            slices.first { $0.band == band }?.seconds ?? 0
        }

        func fraction(_ band: Band) -> Double {
            slices.first { $0.band == band }?.fraction ?? 0
        }

        var isEmpty: Bool { measuredSeconds <= 0 }

        /// Fraction of sessions that had heart rate at all.
        ///
        /// A distribution built from a third of your training describes that
        /// third, and saying so is the difference between an insight and a
        /// confidently wrong number.
        var coverage: Double {
            let total = measuredSessions + unmeasuredSessions
            guard total > 0 else { return 0 }
            return Double(measuredSessions) / Double(total)
        }

        /// Below this, the shape isn't worth drawing conclusions from.
        var isRepresentative: Bool { coverage >= 0.6 && measuredSessions >= 3 }
    }

    /// Add up time in band across a set of workouts.
    ///
    /// Expensive — decodes every sample stream — so call it off the main actor.
    static func summarize(
        workouts: [WorkoutSnapshot],
        zones: HRZones
    ) -> Summary {
        var totals: [Band: TimeInterval] = [:]
        var measuredSessions = 0
        var unmeasuredSessions = 0

        for workout in workouts {
            let inZone = zones.timeInZones(workout.samples)
            let sessionTotal = inZone.values.reduce(0, +)
            guard sessionTotal > 0 else {
                unmeasuredSessions += 1
                continue
            }
            measuredSessions += 1
            for (zone, seconds) in inZone {
                guard let band = Band.containing(zone: zone) else { continue }
                totals[band, default: 0] += seconds
            }
        }

        let measured = totals.values.reduce(0, +)
        let slices = Band.allCases.map { band in
            Slice(band: band,
                  seconds: totals[band] ?? 0,
                  fraction: measured > 0 ? (totals[band] ?? 0) / measured : 0)
        }

        return Summary(slices: slices, measuredSeconds: measured,
                       measuredSessions: measuredSessions,
                       unmeasuredSessions: unmeasuredSessions)
    }

    // MARK: - Reading the shape

    /// What the distribution looks like, in the terms coaches use.
    enum Shape: String, Sendable {
        /// Mostly easy with a real hard slice: the classic polarized week.
        case polarized
        /// Mostly easy, almost nothing hard. Sustainable, but nothing is
        /// driving adaptation upward.
        case allEasy
        /// Too much time in the middle — the "grey zone" that's too hard to
        /// recover from and too easy to drive much adaptation.
        case threshold
        /// Not enough easy work to support the hard work.
        case tooHard

        var label: String {
            switch self {
            case .polarized: return "Polarized"
            case .allEasy:   return "All easy"
            case .threshold: return "Grey zone"
            case .tooHard:   return "Too hard"
            }
        }

        var guidance: String {
            switch self {
            case .polarized:
                return "Mostly easy with genuinely hard sessions on top. This is the distribution most endurance research points at."
            case .allEasy:
                return "Plenty of easy volume but almost nothing hard. Sustainable, and it builds a base — but something has to be driving the top end."
            case .threshold:
                return "A lot of time in the middle: too hard to recover from easily, not hard enough to drive much adaptation. The usual fix is to make easy days genuinely easy."
            case .tooHard:
                return "Not enough easy work to support this much intensity. This is the pattern that precedes stagnation and injury."
            }
        }
    }

    /// The conventional target: about 80% of time easy.
    static let easyTarget = 0.80

    /// Classify a distribution.
    ///
    /// Thresholds are deliberately coarse. The band boundaries are already an
    /// approximation of two thresholds nobody has measured, so pretending to
    /// distinguish 78% from 82% would be false precision dressed up as advice.
    static func shape(of summary: Summary) -> Shape? {
        guard !summary.isEmpty else { return nil }
        let easy = summary.fraction(.easy)
        let moderate = summary.fraction(.moderate)
        let hard = summary.fraction(.hard)

        // Grey zone is checked first, and this ordering matters. A block of
        // 42% easy / 57% moderate / 2% hard has *barely any* hard work in it —
        // testing `easy < 0.6` first labelled that "too hard" and told the
        // athlete to cut intensity they weren't doing. The defining failure is
        // the time in the middle, so that's what gets named.
        if moderate > 0.25 { return .threshold }
        // Easy is low and it isn't moderate, so it's genuinely hard work.
        if easy < 0.6 { return .tooHard }
        if hard < 0.05 { return .allEasy }
        return .polarized
    }

    /// One line naming the gap between where you are and the 80/20 convention,
    /// or nil when there isn't a meaningful one.
    static func advice(for summary: Summary) -> String? {
        guard !summary.isEmpty else { return nil }
        let easy = summary.fraction(.easy)
        let gap = easyTarget - easy
        guard abs(gap) >= 0.05 else { return nil }

        let points = Int((abs(gap) * 100).rounded())
        return gap > 0
            ? "About \(points) points short of the usual 80% easy."
            : "Easier than the usual 80/20 split by about \(points) points."
    }
}
