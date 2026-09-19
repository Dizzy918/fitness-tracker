import XCTest
@testable import FitnessTracker

/// Aerobic decoupling.
///
/// The measurement is a ratio of ratios, so the failure mode isn't a crash —
/// it's a plausible-looking number computed from a session that shouldn't have
/// been scored at all. Most of these tests are about the refusals.
final class DecouplingTests: XCTestCase {

    // MARK: - Builders

    /// A one-sample-per-second stream.
    private func stream(
        seconds: Int,
        power: (Int) -> Int? = { _ in nil },
        speed: (Int) -> Double? = { _ in nil },
        hr: (Int) -> Int? = { _ in nil },
        alt: (Int) -> Double? = { _ in nil },
        dist: (Int) -> Double? = { _ in nil }
    ) -> [FITSample] {
        (0..<seconds).map { t in
            FITSample(t: TimeInterval(t), hr: hr(t), alt: alt(t),
                      speed: speed(t), dist: dist(t), power: power(t))
        }
    }

    /// 70 minutes: 10 trimmed as warm-up, 60 scored.
    private let long = 4_200

    // MARK: - The measurement

    func testASteadyRideWithSteadyHeartRateDoesNotDecouple() throws {
        let samples = stream(seconds: long,
                             power: { _ in 200 },
                             hr: { _ in 140 })
        let result = try XCTUnwrap(Decoupling.analyse(samples: samples, sport: .bike))

        XCTAssertEqual(result.percent, 0, accuracy: 0.001)
        XCTAssertEqual(result.verdict, .coupled)
        XCTAssertEqual(result.basis, .power)
    }

    func testRisingHeartRateAtConstantPowerReadsAsDecoupling() throws {
        // 140 bpm at the start, 165 at the end: across the scored window the
        // second half averages around 7% more beats for the same watts.
        let samples = stream(seconds: long,
                             power: { _ in 200 },
                             hr: { t in 140 + Int(Double(t) / Double(self.long) * 25) })
        let result = try XCTUnwrap(Decoupling.analyse(samples: samples, sport: .bike))

        XCTAssertGreaterThan(result.percent, 4)
        XCTAssertLessThan(result.percent, 8)
        XCTAssertEqual(result.verdict, .drifting)
    }

    func testABigDriftIsCalledDecoupled() throws {
        let samples = stream(seconds: long,
                             power: { _ in 200 },
                             hr: { t in 130 + Int(Double(t) / Double(self.long) * 40) })
        let result = try XCTUnwrap(Decoupling.analyse(samples: samples, sport: .bike))

        XCTAssertGreaterThan(result.percent, 10)
        XCTAssertEqual(result.verdict, .decoupled)
    }

    func testEfficiencyRisingIsReportedAsAnIncompleteWarmup() throws {
        // Heart rate settling downwards across the scored window — the classic
        // shape of a warm-up that ran past the trim.
        let samples = stream(seconds: long,
                             power: { _ in 200 },
                             hr: { t in 165 - Int(Double(t) / Double(self.long) * 25) })
        let result = try XCTUnwrap(Decoupling.analyse(samples: samples, sport: .bike))

        XCTAssertLessThan(result.percent, -2)
        XCTAssertEqual(result.verdict, .warmupIncluded)
    }

    // MARK: - The refusals

    func testAShortSessionIsNotScored() {
        let samples = stream(seconds: 1_500,      // 25 min: trim leaves 15
                             power: { _ in 200 },
                             hr: { _ in 140 })
        XCTAssertNil(Decoupling.analyse(samples: samples, sport: .bike))
    }

    func testAnIntervalSessionIsNotScored() {
        // 3 min at 350 W, 3 min at 120 W. Its two halves contain different work,
        // so any "decoupling" would be an artefact of where the split landed.
        let samples = stream(seconds: long,
                             power: { t in (t / 180) % 2 == 0 ? 350 : 120 },
                             hr: { _ in 150 })
        XCTAssertNil(Decoupling.analyse(samples: samples, sport: .bike))
    }

    func testAStreamWithoutHeartRateIsNotScored() {
        let samples = stream(seconds: long, power: { _ in 200 })
        XCTAssertNil(Decoupling.analyse(samples: samples, sport: .bike))
    }

    func testAStreamWithoutOutputIsNotScored() {
        let samples = stream(seconds: long, hr: { _ in 140 })
        XCTAssertNil(Decoupling.analyse(samples: samples, sport: .bike))
    }

    func testSparseHeartRateIsNotScored() {
        // Heart rate on one sample in five: not enough of the window survives
        // pairing to call either side a half.
        let samples = stream(seconds: long,
                             power: { _ in 200 },
                             hr: { t in t % 5 == 0 ? 140 : nil })
        XCTAssertNil(Decoupling.analyse(samples: samples, sport: .bike))
    }

    func testAHillyRunIsNotScoredOnSpeed() {
        // 3 m of climbing every 100 m of running — 30 m/km, well past the
        // ceiling. Speed per beat would fall on the climbs for reasons that
        // aren't aerobic durability.
        let samples = stream(seconds: long,
                             speed: { _ in 3.0 },
                             hr: { _ in 150 },
                             alt: { t in Double(t) * 0.09 },
                             dist: { t in Double(t) * 3.0 })
        XCTAssertNil(Decoupling.analyse(samples: samples, sport: .trailRun))
    }

    func testAFlatRunIsScoredOnSpeed() throws {
        let samples = stream(seconds: long,
                             speed: { _ in 3.0 },
                             hr: { _ in 150 },
                             alt: { _ in 100 },
                             dist: { t in Double(t) * 3.0 })
        let result = try XCTUnwrap(Decoupling.analyse(samples: samples, sport: .run))

        XCTAssertEqual(result.basis, .speed)
        XCTAssertEqual(result.verdict, .coupled)
    }

    func testSwimmingIsNotScored() {
        // Pool speed is a sawtooth of walls and turns; open water has none.
        let samples = stream(seconds: long, speed: { _ in 1.2 }, hr: { _ in 150 })
        XCTAssertNil(Decoupling.analyse(samples: samples, sport: .swim))
    }

    func testPowerIsPreferredOverSpeedWhenBothArePresent() throws {
        let samples = stream(seconds: long,
                             power: { _ in 200 },
                             speed: { _ in 8.0 },
                             hr: { _ in 140 })
        let result = try XCTUnwrap(Decoupling.analyse(samples: samples, sport: .bike))

        XCTAssertEqual(result.basis, .power)
    }

    // MARK: - The warm-up trim

    func testTheWarmupIsExcludedFromTheScore() throws {
        // Heart rate climbs steeply for the first ten minutes and then holds.
        // Scoring the whole stream would read as strong decoupling; scoring
        // only what follows the trim reads as flat, which is the truth.
        let samples = stream(seconds: long,
                             power: { _ in 200 },
                             hr: { t in t < 600 ? 100 + t / 10 : 160 })
        let result = try XCTUnwrap(Decoupling.analyse(samples: samples, sport: .bike))

        XCTAssertEqual(result.percent, 0, accuracy: 0.01)
        XCTAssertEqual(result.analysedSeconds,
                       TimeInterval(long - 1) - Decoupling.warmupTrim,
                       accuracy: 1)
    }

    // MARK: - Variability index

    func testAConstantStreamHasAVariabilityIndexOfOne() {
        let times = (0..<600).map(TimeInterval.init)
        let values = [Double](repeating: 200, count: 600)

        XCTAssertEqual(Decoupling.variabilityIndex(of: values, at: times), 1.0, accuracy: 0.001)
    }

    func testSurgingRaisesTheVariabilityIndex() {
        let times = (0..<1_200).map(TimeInterval.init)
        // Surges long enough to survive the 30-second rolling average.
        let values = (0..<1_200).map { Double(($0 / 60) % 2 == 0 ? 400 : 100) }

        XCTAssertGreaterThan(Decoupling.variabilityIndex(of: values, at: times),
                             Decoupling.steadinessCeiling)
    }
}
