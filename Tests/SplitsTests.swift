import XCTest
@testable import FitnessTracker

final class SplitsTests: XCTestCase {

    /// Build a constant-pace stream: `paceSecPerKm` over `totalMeters`,
    /// sampled every `stepSeconds`.
    private func stream(
        totalMeters: Double,
        paceSecPerKm: Double,
        stepSeconds: Double = 10,
        hr: Int? = 150
    ) -> [FITSample] {
        let speed = 1000 / paceSecPerKm      // m/s
        let totalTime = totalMeters / speed
        var out: [FITSample] = []
        var t: Double = 0
        while t < totalTime {
            out.append(FITSample(t: t, lat: nil, lon: nil, hr: hr, alt: nil,
                                 speed: speed, cadence: nil, dist: t * speed))
            t += stepSeconds
        }
        // Exact endpoint so the final partial split is precise.
        out.append(FITSample(t: totalTime, lat: nil, lon: nil, hr: hr, alt: nil,
                             speed: speed, cadence: nil, dist: totalMeters))
        return out
    }

    func testConstantPaceProducesEqualSplits() {
        let samples = stream(totalMeters: 5000, paceSecPerKm: 300)   // 5:00/km
        let splits = SplitCalculator.splits(from: samples)

        XCTAssertEqual(splits.count, 5)
        XCTAssertTrue(splits.allSatisfy { !$0.isPartial })
        for split in splits {
            XCTAssertEqual(split.distance, 1000, accuracy: 1)
            XCTAssertEqual(split.duration, 300, accuracy: 1.0)
            XCTAssertEqual(try! XCTUnwrap(split.paceSecPerKm), 300, accuracy: 1.0)
        }
    }

    func testTrailingPartialSplit() {
        let samples = stream(totalMeters: 5400, paceSecPerKm: 300)
        let splits = SplitCalculator.splits(from: samples)

        XCTAssertEqual(splits.count, 6)
        let last = splits.last!
        XCTAssertTrue(last.isPartial)
        XCTAssertEqual(last.distance, 400, accuracy: 2)
        XCTAssertEqual(last.duration, 120, accuracy: 2)
        // Pace of a partial split is still per-km normalized.
        XCTAssertEqual(try XCTUnwrap(last.paceSecPerKm), 300, accuracy: 3)
    }

    func testNegligibleRemainderIsDropped() {
        // 5 km + 5 m: the remainder is under the 10 m noise floor.
        let samples = stream(totalMeters: 5005, paceSecPerKm: 300)
        let splits = SplitCalculator.splits(from: samples)
        XCTAssertEqual(splits.count, 5, "sub-10m remainder should not create a split")
    }

    func testVaryingPaceIsAttributedPerSplit() {
        // km 1 at 6:00, km 2 at 4:00.
        var samples = stream(totalMeters: 1000, paceSecPerKm: 360)
        let firstEnd = samples.last!
        let fastSpeed = 1000.0 / 240.0
        var t = firstEnd.t
        var d = 1000.0
        while d < 2000 {
            t += 10
            d += fastSpeed * 10
            samples.append(FITSample(t: t, lat: nil, lon: nil, hr: 165, alt: nil,
                                     speed: fastSpeed, cadence: nil, dist: min(d, 2000)))
        }

        let splits = SplitCalculator.splits(from: samples)
        XCTAssertGreaterThanOrEqual(splits.count, 2)
        XCTAssertEqual(try XCTUnwrap(splits[0].paceSecPerKm), 360, accuracy: 5)
        XCTAssertEqual(try XCTUnwrap(splits[1].paceSecPerKm), 240, accuracy: 8)
    }

    func testFastestSplitDetection() {
        var samples = stream(totalMeters: 1000, paceSecPerKm: 330)
        let fastSpeed = 1000.0 / 250.0
        var t = samples.last!.t
        var d = 1000.0
        while d < 2000 {
            t += 10
            d += fastSpeed * 10
            samples.append(FITSample(t: t, lat: nil, lon: nil, hr: 170, alt: nil,
                                     speed: fastSpeed, cadence: nil, dist: min(d, 2000)))
        }

        let splits = SplitCalculator.splits(from: samples)
        let fastest = SplitCalculator.fastest(splits)
        XCTAssertEqual(fastest?.index, 1, "second km is faster")
    }

    func testGapSpanningMultipleBoundaries() {
        // GPS dropout: one 900 s jump covering 3 km.
        let samples = [
            FITSample(t: 0, lat: nil, lon: nil, hr: 140, alt: nil, speed: nil, cadence: nil, dist: 0),
            FITSample(t: 900, lat: nil, lon: nil, hr: 150, alt: nil, speed: nil, cadence: nil, dist: 3000),
        ]
        let splits = SplitCalculator.splits(from: samples)
        XCTAssertEqual(splits.count, 3, "each crossed boundary should still emit a split")
        for split in splits {
            XCTAssertEqual(split.duration, 300, accuracy: 1)
        }
    }

    func testAverageHRPerSplit() {
        let samples = stream(totalMeters: 2000, paceSecPerKm: 300, hr: 152)
        let splits = SplitCalculator.splits(from: samples)
        XCTAssertEqual(splits.first?.avgHR, 152)
    }

    func testEmptyAndUnusableInput() {
        XCTAssertTrue(SplitCalculator.splits(from: []).isEmpty)

        // No cumulative distance → cannot compute splits.
        let noDist = [
            FITSample(t: 0, lat: nil, lon: nil, hr: 140, alt: nil, speed: nil, cadence: nil, dist: nil),
            FITSample(t: 10, lat: nil, lon: nil, hr: 141, alt: nil, speed: nil, cadence: nil, dist: nil),
        ]
        XCTAssertTrue(SplitCalculator.splits(from: noDist).isEmpty)

        // Single sample is not enough to interpolate.
        let one = [FITSample(t: 0, lat: nil, lon: nil, hr: nil, alt: nil, speed: nil, cadence: nil, dist: 0)]
        XCTAssertTrue(SplitCalculator.splits(from: one).isEmpty)
    }

    func testCustomSplitDistance() {
        let samples = stream(totalMeters: 2000, paceSecPerKm: 300)
        let splits = SplitCalculator.splits(from: samples, splitMeters: 500)
        XCTAssertEqual(splits.count, 4)
        XCTAssertEqual(splits[0].distance, 500, accuracy: 2)
        XCTAssertEqual(splits[0].duration, 150, accuracy: 2)
    }

    func testFormattingHelpers() {
        XCTAssertEqual(Fmt.duration(3725), "1:02:05")
        XCTAssertEqual(Fmt.duration(125), "2:05")
        XCTAssertEqual(Fmt.pace(275), "4:35")
        XCTAssertEqual(Fmt.pace(nil), "–")
        XCTAssertEqual(Fmt.pace(0), "–")
        XCTAssertEqual(Fmt.km(8240), "8.24 km")
        XCTAssertEqual(Fmt.meters(41.6), "42 m")
        XCTAssertEqual(Fmt.bpm(nil), "–")
    }
}
