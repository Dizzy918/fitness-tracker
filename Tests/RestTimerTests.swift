import XCTest
@testable import FitnessTracker

final class RestTimerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testStartsAndCountsDown() {
        let timer = RestTimer()
        XCTAssertFalse(timer.isRunning)
        XCTAssertNil(timer.remaining(at: t0))

        timer.start(120, from: t0)
        XCTAssertTrue(timer.isRunning)
        XCTAssertEqual(timer.remaining(at: t0) ?? -1, 120, accuracy: 0.001)
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(30)) ?? -1, 90, accuracy: 0.001)
    }

    func testRemainingClampsAtZeroRatherThanGoingNegative() {
        let timer = RestTimer()
        timer.start(60, from: t0)
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(500)) ?? -1, 0, accuracy: 0.001)
        XCTAssertTrue(timer.hasFinished(at: t0.addingTimeInterval(500)))
    }

    /// The point of a deadline: time passes while nothing is ticking.
    func testTimePassesWhileNothingIsObserving() {
        let timer = RestTimer()
        timer.start(90, from: t0)
        // Nothing read the timer in between; it's still correct.
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(89)) ?? -1, 1, accuracy: 0.001)
    }

    func testProgressRunsZeroToOne() {
        let timer = RestTimer()
        timer.start(100, from: t0)
        XCTAssertEqual(timer.progress(at: t0), 0, accuracy: 0.001)
        XCTAssertEqual(timer.progress(at: t0.addingTimeInterval(25)), 0.25, accuracy: 0.001)
        XCTAssertEqual(timer.progress(at: t0.addingTimeInterval(1000)), 1, accuracy: 0.001)
    }

    func testStopClearsEverything() {
        let timer = RestTimer()
        timer.start(60, label: "Bench", from: t0)
        XCTAssertEqual(timer.label, "Bench")
        timer.stop()
        XCTAssertFalse(timer.isRunning)
        XCTAssertNil(timer.remaining(at: t0))
        XCTAssertNil(timer.label)
        XCTAssertFalse(timer.hasFinished(at: t0))
    }

    func testExtendPushesTheDeadlineAndTheDenominator() {
        let timer = RestTimer()
        timer.start(60, from: t0)
        let now = t0.addingTimeInterval(20)
        timer.extend(by: 30, from: now)
        XCTAssertEqual(timer.remaining(at: now) ?? -1, 70, accuracy: 0.001)
        // Progress must not jump backwards past what's already been waited.
        XCTAssertEqual(timer.elapsed(at: now), 20, accuracy: 0.001)
        XCTAssertEqual(timer.progress(at: now), 20.0 / 90.0, accuracy: 0.001)
    }

    /// Extending after it ran out should give the full extra wait, not a
    /// deadline still in the past.
    func testExtendingAnExpiredTimerGivesTheWholeExtension() {
        let timer = RestTimer()
        timer.start(60, from: t0)
        let late = t0.addingTimeInterval(200)
        timer.extend(by: 30, from: late)
        XCTAssertEqual(timer.remaining(at: late) ?? -1, 30, accuracy: 0.001)
        XCTAssertFalse(timer.hasFinished(at: late))
    }

    func testExtendDoesNothingWhenNotRunning() {
        let timer = RestTimer()
        timer.extend(by: 30, from: t0)
        XCTAssertFalse(timer.isRunning)
    }

    func testZeroOrNegativeDurationIsIgnored() {
        let timer = RestTimer()
        timer.start(0, from: t0)
        XCTAssertFalse(timer.isRunning)
        timer.start(-10, from: t0)
        XCTAssertFalse(timer.isRunning)
    }

    func testDisplayRoundsUpSoItNeverShowsZeroEarly() {
        let timer = RestTimer()
        timer.start(90, from: t0)
        XCTAssertEqual(timer.display(at: t0), "1:30")
        XCTAssertEqual(timer.display(at: t0.addingTimeInterval(30.4)), "1:00")
        XCTAssertEqual(timer.display(at: t0.addingTimeInterval(89.5)), "0:01")
        XCTAssertEqual(timer.display(at: t0.addingTimeInterval(90)), "0:00")
    }
}
