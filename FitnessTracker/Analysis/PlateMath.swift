import Foundation

/// What to hang on each end of the bar to make a given weight.
///
/// Arithmetic everyone does in their head between sets and a fair number get
/// wrong — the failure mode is loading 102.5 when you meant 105 and recording
/// the number you meant.
enum PlateMath {

    /// A plate denomination and how many of them you have *per side*.
    struct Plate: Hashable, Sendable {
        var kilograms: Double
        var countPerSide: Int

        init(_ kilograms: Double, countPerSide: Int = 10) {
            self.kilograms = kilograms
            self.countPerSide = countPerSide
        }
    }

    /// A run of identical plates on one end of the bar.
    struct Stack: Hashable, Sendable {
        let kilograms: Double
        let count: Int
    }

    struct Loading: Equatable, Sendable {
        /// Heaviest first, which is also loading order.
        let perSide: [Stack]
        let barKilograms: Double
        /// What the bar actually weighs once loaded.
        let total: Double
        /// How far short of the target this lands. Never negative: the search
        /// will not go over by anything you could load, because a bar you can't
        /// lift is worse than one that's 1.25 kg light.
        let shortfall: Double

        var isExact: Bool { shortfall < 0.0001 }
        var isBarOnly: Bool { perSide.isEmpty }
        var plateCountPerSide: Int { perSide.reduce(0) { $0 + $1.count } }
    }

    /// The set a commercial gym has, in kilos.
    static let metricGym: [Plate] = [
        Plate(25, countPerSide: 8), Plate(20, countPerSide: 4), Plate(15, countPerSide: 2),
        Plate(10, countPerSide: 2), Plate(5, countPerSide: 2), Plate(2.5, countPerSide: 2),
        Plate(1.25, countPerSide: 2),
    ]

    /// The same, in pounds, converted so the maths stays in one unit.
    static let imperialGym: [Plate] = {
        let pounds: [Double] = [45, 35, 25, 10, 5, 2.5]
        return pounds.enumerated().map { index, value in
            Plate(value * UnitConversion.kilogramsPerPound,
                  countPerSide: index == 0 ? 8 : (index < 3 ? 4 : 2))
        }
    }()

    static let defaultBarKilograms: Double = 20
    static let imperialBarKilograms: Double = 45 * UnitConversion.kilogramsPerPound

    /// Work out the loading for a target weight.
    ///
    /// Exhaustive rather than greedy, because greedy is wrong on real plate
    /// sets: for 30 kg a side from 25/20/15/10 it takes the 25, finds nothing
    /// to pair with the remaining 5, and reports 25 — when 20 + 10 is exact.
    /// The search space is tiny (a few hundred states), so there's no reason to
    /// accept an answer that's merely usually right.
    static func load(target: Double, bar: Double, inventory: [Plate] = metricGym) -> Loading {
        let perSideTarget = (target - bar) / 2
        guard perSideTarget > 0 else {
            return Loading(perSide: [], barKilograms: bar, total: bar,
                           shortfall: max(0, target - bar))
        }

        // Integer grams, so floating-point drift can't make 2.5 + 2.5 ≠ 5.
        let plates = inventory
            .filter { $0.kilograms > 0 && $0.countPerSide > 0 }
            .map { (grams: Int(($0.kilograms * 1000).rounded()), count: $0.countPerSide) }
            .sorted { $0.grams > $1.grams }
        guard !plates.isEmpty else {
            return Loading(perSide: [], barKilograms: bar, total: bar,
                           shortfall: target - bar)
        }

        // Collapse the search onto the coarsest grid the plates can land on.
        // With 1.25 kg as the smallest, a 100 kg side is 80 states, not 100,000.
        let step = plates.map(\.grams).reduce(0) { gcd($0, $1) }
        // A few grams of slack. Plate weights are rounded to whole grams, so an
        // imperial set misses its own exact loads without it: 90 lb a side is
        // 40823.31 g, two 45s round to 40824, and a strict ceiling rejects the
        // one answer that's right. The slack is three orders of magnitude below
        // the smallest plate, so it can't admit a wrong one.
        let slackGrams = 10
        let capacity = (Int((perSideTarget * 1000).rounded()) + slackGrams) / step
        guard capacity > 0 else {
            return Loading(perSide: [], barKilograms: bar, total: bar,
                           shortfall: target - bar)
        }

        // dp[s] = fewest plates summing to exactly s. Fewest, because two 25s
        // beat four 10s plus a 10 — less to load and less to get wrong.
        var dp = [Int?](repeating: nil, count: capacity + 1)
        dp[0] = 0
        // taken[i][s] = how many of plate i the best solution for s uses.
        var taken = [[Int]](repeating: [Int](repeating: 0, count: capacity + 1),
                            count: plates.count)

        for (index, plate) in plates.enumerated() {
            let units = plate.grams / step
            var next = dp
            for sum in 0...capacity {
                guard let base = dp[sum] else { continue }
                for k in 1...plate.count {
                    let reached = sum + k * units
                    guard reached <= capacity else { break }
                    let cost = base + k
                    if next[reached] == nil || cost < next[reached]! {
                        next[reached] = cost
                        // Sums this plate didn't improve keep their 0, which is
                        // exactly "the best answer here uses none of these".
                        taken[index][reached] = k
                    }
                }
            }
            dp = next
        }

        guard let best = (0...capacity).reversed().first(where: { dp[$0] != nil }) else {
            return Loading(perSide: [], barKilograms: bar, total: bar,
                           shortfall: target - bar)
        }

        var stacks: [Stack] = []
        var remaining = best
        for index in plates.indices.reversed() {
            let count = taken[index][remaining]
            guard count > 0 else { continue }
            stacks.append(Stack(kilograms: Double(plates[index].grams) / 1000,
                                count: count))
            remaining -= count * (plates[index].grams / step)
        }
        stacks.sort { $0.kilograms > $1.kilograms }

        let perSideKg = Double(best * step) / 1000
        let total = bar + perSideKg * 2
        return Loading(perSide: stacks, barKilograms: bar, total: total,
                       shortfall: max(0, target - total))
    }

    /// The default inventory and bar for a unit system.
    static func inventory(metric: Bool) -> [Plate] { metric ? metricGym : imperialGym }
    static func bar(metric: Bool) -> Double { metric ? defaultBarKilograms : imperialBarKilograms }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (abs(a), abs(b))
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}
