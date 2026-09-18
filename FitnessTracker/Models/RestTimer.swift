import Foundation
import Observation

/// Counts down the rest between sets.
///
/// Holds a *deadline*, not a decrementing counter. A counter only stays true
/// while something is ticking it, which means it drifts when the view stops
/// updating and lies outright when the phone locks mid-rest — and the phone
/// locking mid-rest is the normal case, not the edge case. A deadline is
/// correct whenever you next look at it.
@Observable
final class RestTimer {

    private(set) var endsAt: Date?
    private(set) var duration: TimeInterval = 0
    /// What the timer was counting down for, so the UI can say so.
    private(set) var label: String?

    /// Rest lengths the buttons offer, in seconds.
    static let presets: [Int] = [60, 90, 120, 180, 300]

    var isRunning: Bool { endsAt != nil }

    func start(_ seconds: TimeInterval, label: String? = nil, from now: Date = .now) {
        guard seconds > 0 else { return }
        duration = seconds
        endsAt = now.addingTimeInterval(seconds)
        self.label = label
    }

    func stop() {
        endsAt = nil
        duration = 0
        label = nil
    }

    /// Push the deadline out, keeping the ring's denominator honest — a rest
    /// you extended to three minutes is three minutes long, not two minutes
    /// that overran.
    func extend(by seconds: TimeInterval, from now: Date = .now) {
        guard let current = endsAt else { return }
        // Read how long you've already waited *before* moving the deadline;
        // `elapsed` is derived from it, so doing this the other way round
        // measures the extension against itself and always answers zero.
        let alreadyWaited = elapsed(at: now)
        // Extending a timer that already ran out should give the full extra
        // wait from now, not a deadline still in the past.
        let extended = max(current.addingTimeInterval(seconds),
                           now.addingTimeInterval(seconds))
        endsAt = extended
        duration = alreadyWaited + extended.timeIntervalSince(now)
    }

    /// Seconds left, clamped at zero. Nil when nothing is running.
    func remaining(at now: Date = .now) -> TimeInterval? {
        guard let endsAt else { return nil }
        return max(0, endsAt.timeIntervalSince(now))
    }

    func elapsed(at now: Date = .now) -> TimeInterval {
        guard let endsAt else { return 0 }
        return max(0, duration - max(0, endsAt.timeIntervalSince(now)))
    }

    /// 0 at the start of the rest, 1 when it's up.
    func progress(at now: Date = .now) -> Double {
        guard duration > 0, let remaining = remaining(at: now) else { return 0 }
        return min(1, max(0, 1 - remaining / duration))
    }

    func hasFinished(at now: Date = .now) -> Bool {
        guard let remaining = remaining(at: now) else { return false }
        return remaining <= 0
    }

    /// "1:30", counting down.
    func display(at now: Date = .now) -> String {
        guard let remaining = remaining(at: now) else { return "–" }
        let whole = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
