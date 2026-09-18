import Foundation
import SwiftData

/// Deterministic synthetic data so every screen can be exercised without a
/// real `.fit` file. Seeded LCG — same output every run, which keeps
/// screenshots and manual comparisons stable.
struct DemoData {

    private struct RNG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 11) & 0xFFFF_FFFF) / Double(0xFFFF_FFFF)
        }
        mutating func range(_ lo: Double, _ hi: Double) -> Double {
            lo + next() * (hi - lo)
        }
    }

    /// Insert a season of running plus two shoes. Idempotent-ish: call once.
    @discardableResult
    static func seed(into context: ModelContext, weeks: Int = 12) -> Int {
        var rng = RNG(state: 42)

        let daily = Shoe(brand: "Nike", model: "Pegasus 41",
                         nickname: "Daily trainer",
                         acquiredAt: .now.addingTimeInterval(-86400 * 200),
                         maxDistance: 800_000)
        let trail = Shoe(brand: "Salomon", model: "Speedcross 6",
                         nickname: "Trail pair",
                         acquiredAt: .now.addingTimeInterval(-86400 * 90),
                         maxDistance: 700_000)
        context.insert(daily)
        context.insert(trail)

        var inserted = 0
        let cal = Calendar.current

        for week in 0..<weeks {
            // 3–4 runs per week, mild upward volume trend.
            let runsThisWeek = 3 + (week % 3 == 0 ? 1 : 0)
            for run in 0..<runsThisWeek {
                let daysAgo = (weeks - week) * 7 - run * 2
                guard let date = cal.date(byAdding: .day, value: -daysAgo, to: .now) else { continue }

                let isLong = run == 0
                let isTrail = run == 2 && week % 2 == 0
                let baseKm = isLong ? rng.range(14, 20) : rng.range(6, 11)
                // Gentle fitness improvement over the season.
                let trend = 1.0 - Double(week) * 0.004
                let paceSecPerKm = (isTrail ? rng.range(330, 390) : rng.range(270, 315)) * trend

                let distance = baseKm * 1000
                let duration = distance / 1000 * paceSecPerKm

                let w = Workout(
                    sport: isTrail ? .trailRun : .run,
                    startedAt: date,
                    duration: duration,
                    distance: distance,
                    source: "demo",
                    externalID: "demo-\(week)-\(run)"
                )
                w.avgHeartRate = Int(rng.range(139, 158))
                w.maxHeartRate = (w.avgHeartRate ?? 150) + Int(rng.range(10, 22))
                w.elevationGain = isTrail ? rng.range(300, 700) : rng.range(30, 120)
                w.calories = distance / 1000 * rng.range(58, 72)
                w.shoe = isTrail ? trail : daily

                let (coords, samples) = track(
                    distance: distance,
                    duration: duration,
                    avgHR: w.avgHeartRate ?? 150,
                    climb: w.elevationGain ?? 50,
                    isTrail: isTrail,
                    rng: &rng
                )
                let enc = JSONEncoder()
                w.polylineData = try? enc.encode(coords)
                w.streamsData = try? enc.encode(samples)

                context.insert(w)
                inserted += 1
            }
        }

        inserted += seedRidesAndSwims(into: context, weeks: weeks, daily: daily, rng: &rng)
        inserted += seedIntervalSessions(into: context, weeks: weeks, daily: daily, rng: &rng)
        seedStrength(into: context, rng: &rng)
        seedDailyMetrics(into: context, days: weeks * 7, rng: &rng)
        return inserted
    }

    /// One ride and one swim most weeks, so the cycling-power and swim-pace
    /// views have something real to render.
    private static func seedRidesAndSwims(
        into context: ModelContext,
        weeks: Int,
        daily: Shoe,
        rng: inout RNG
    ) -> Int {
        var inserted = 0
        let calendar = Calendar.current

        for week in 0..<weeks {
            // Ride: every week.
            if let date = calendar.date(byAdding: .day, value: -((weeks - week) * 7 - 5), to: .now) {
                let km = rng.range(35, 85)
                let speedKmh = rng.range(26, 33)
                let distance = km * 1000
                let duration = km / speedKmh * 3600
                let ftpish = Int(rng.range(190, 240))

                let ride = Workout(
                    sport: .bike, startedAt: date, duration: duration,
                    distance: distance, source: "demo",
                    externalID: "demo-ride-\(week)"
                )
                ride.avgHeartRate = Int(rng.range(132, 148))
                ride.maxHeartRate = (ride.avgHeartRate ?? 140) + Int(rng.range(14, 28))
                ride.elevationGain = rng.range(300, 1100)
                ride.calories = duration / 3600 * rng.range(600, 800)
                ride.avgPower = ftpish

                let (coords, samples) = track(
                    distance: distance, duration: duration,
                    avgHR: ride.avgHeartRate ?? 140,
                    climb: ride.elevationGain ?? 400,
                    isTrail: false, rng: &rng, basePower: ftpish
                )
                let enc = JSONEncoder()
                ride.polylineData = try? enc.encode(coords)
                ride.streamsData = try? enc.encode(samples)
                context.insert(ride)
                inserted += 1
            }

            // Swim: every other week, pool.
            if week % 2 == 0,
               let date = calendar.date(byAdding: .day, value: -((weeks - week) * 7 - 6), to: .now) {
                let meters = (rng.range(1200, 2600) / 50).rounded() * 50
                let pacePer100 = rng.range(96, 118)
                let duration = meters / 100 * pacePer100

                let swim = Workout(
                    sport: .swim, startedAt: date, duration: duration,
                    distance: meters, source: "demo",
                    externalID: "demo-swim-\(week)"
                )
                swim.avgHeartRate = Int(rng.range(126, 142))
                swim.maxHeartRate = (swim.avgHeartRate ?? 132) + Int(rng.range(10, 20))
                swim.calories = duration / 3600 * rng.range(500, 650)
                swim.poolLength = 25

                // Pool swims have no GPS; stroke rate lands in cadence.
                var samples: [FITSample] = []
                let steps = max(20, Int(duration / 15))
                for i in 0...steps {
                    let t = Double(i) * (duration / Double(steps))
                    samples.append(FITSample(
                        t: t, lat: nil, lon: nil,
                        hr: Int(rng.range(120, 145)),
                        alt: nil,
                        speed: meters / duration,
                        cadence: Int(rng.range(28, 38)),
                        dist: t / duration * meters,
                        power: nil
                    ))
                }
                swim.streamsData = try? JSONEncoder().encode(samples)
                context.insert(swim)
                inserted += 1
            }
        }
        return inserted
    }

    /// A track session every third week: warmup, 8 × 400 m with 200 m floats,
    /// cooldown — with real `FITLap` records carrying intensity and a manual
    /// trigger, the way a watch writes them.
    ///
    /// The lap view is unusable without a structured session to show, and this
    /// is the shape of workout it exists for: kilometre splits smear each rep
    /// into its recovery and tell you nothing.
    private static func seedIntervalSessions(
        into context: ModelContext,
        weeks: Int,
        daily: Shoe,
        rng: inout RNG
    ) -> Int {
        var inserted = 0
        let calendar = Calendar.current

        for week in stride(from: 1, to: weeks, by: 3) {
            guard let date = calendar.date(
                byAdding: .day, value: -((weeks - week) * 7 - 3), to: .now
            ) else { continue }

            let reps = 8
            let repDistance = 400.0
            let floatDistance = 200.0
            let warmup = rng.range(2200, 2800)
            let cooldown = rng.range(1400, 1900)

            var laps: [FITLap] = []
            var samples: [FITSample] = []
            var clock: TimeInterval = 0
            var covered: Double = 0
            var peakHR = 0

            /// Appends one lap plus a 1 Hz stream for it.
            func addLap(distance: Double, pace: Double, hr: Int, intensity: String) {
                let duration = distance / 1000 * pace
                var lap = FITLap(index: laps.count, duration: duration,
                                 distance: distance, avgHR: hr)
                lap.startOffset = clock
                lap.movingTime = duration
                lap.maxHR = hr + Int(rng.range(2, 6))
                lap.avgCadence = Int(rng.range(intensity == "active" ? 92 : 80,
                                               intensity == "active" ? 98 : 86))
                lap.intensity = intensity
                // A track session is lapped by hand, every time.
                lap.trigger = "manual"
                laps.append(lap)
                peakHR = max(peakHR, lap.maxHR ?? hr)

                // 1 Hz for a rep, coarser for a fifteen-minute warmup. Capped
                // because the seeder runs on-device too, and tripling the
                // store's stream volume for one demo session is a real cost to
                // whoever taps the button. Well inside the 60 s gap that load
                // scoring treats as a dropout.
                let steps = min(max(2, Int(duration)), 90)
                for step in 1...steps {
                    let fraction = Double(step) / Double(steps)
                    samples.append(FITSample(
                        t: clock + duration * fraction,
                        hr: hr + Int(rng.range(-4, 5)),
                        alt: 550 + rng.range(-2, 2),
                        speed: 1000 / pace,
                        cadence: lap.avgCadence,
                        dist: covered + distance * fraction
                    ))
                }
                clock += duration
                covered += distance
            }

            addLap(distance: warmup, pace: rng.range(330, 360), hr: 132, intensity: "warmup")
            for rep in 0..<reps {
                // Fade a little across the set, the way a real session goes.
                let pace = rng.range(196, 206) + Double(rep) * 0.8
                addLap(distance: repDistance, pace: pace,
                       hr: 168 + Int(rng.range(0, 6)), intensity: "active")
                if rep < reps - 1 {
                    addLap(distance: floatDistance, pace: rng.range(390, 430),
                           hr: 148 + Int(rng.range(0, 5)), intensity: "rest")
                }
            }
            addLap(distance: cooldown, pace: rng.range(345, 375), hr: 136, intensity: "cooldown")

            let session = Workout(
                sport: .run, startedAt: date, duration: clock,
                distance: covered, source: "demo",
                externalID: "demo-intervals-\(week)"
            )
            session.avgHeartRate = 152
            session.maxHeartRate = peakHR
            session.elevationGain = rng.range(8, 20)
            session.calories = covered / 1000 * rng.range(60, 72)
            session.notes = "\(reps) × 400 m off 200 m float"
            session.shoe = daily

            let encoder = JSONEncoder()
            session.streamsData = try? encoder.encode(samples)
            session.lapsData = try? encoder.encode(laps)
            context.insert(session)
            inserted += 1
        }
        return inserted
    }

    /// Build a plausible out-and-back around Sofia.
    ///
    /// Distance does NOT advance linearly: per-step speed carries a negative-split
    /// trend, an undulation wave, and jitter, then the accumulated distance is
    /// rescaled to hit the target exactly. That makes per-km splits genuinely
    /// differ, which is what the splits view is meant to show.
    private static func track(
        distance: Double,
        duration: TimeInterval,
        avgHR: Int,
        climb: Double,
        isTrail: Bool,
        rng: inout RNG,
        basePower: Int? = nil
    ) -> ([[Double]], [FITSample]) {
        let steps = max(30, Int(duration / 10))
        let dt = duration / Double(steps)

        // Per-step speed multipliers.
        var mults: [Double] = [0]   // index 0 unused (no distance covered at t=0)
        for i in 1...steps {
            let frac = Double(i) / Double(steps)
            // Finish faster than you started: ±4% across the run.
            let negativeSplit = 1.0 - 0.08 * (frac - 0.5)
            // Terrain / effort waves — bigger swings on trail.
            let amplitude = isTrail ? 0.14 : 0.06
            let wave = 1.0 + amplitude * sin(frac * .pi * 3.0)
            let jitter = rng.range(0.97, 1.03)
            mults.append(negativeSplit * wave * jitter)
        }

        // Accumulate, then rescale so the final distance matches exactly.
        var raw: [Double] = [0]
        for i in 1...steps { raw.append(raw[i - 1] + mults[i] * dt) }
        let scale = raw[steps] > 0 ? distance / raw[steps] : 1
        let dists = raw.map { $0 * scale }

        let originLat = 42.6977, originLon = 23.3219
        let avgSpeedForPower = distance / duration
        var coords: [[Double]] = []
        var samples: [FITSample] = []

        for i in 0...steps {
            let frac = Double(i) / Double(steps)
            let t = Double(i) * dt
            let d = dists[i]

            // Out-and-back, returning on a parallel line so both legs are visible.
            let leg = frac < 0.5 ? frac * 2 : (1 - frac) * 2
            let lat = originLat + leg * 0.035 + (frac >= 0.5 ? 0.0015 : 0)
            let lon = originLon + leg * 0.028 * 0.7

            let stepSpeed = i > 0 ? (dists[i] - dists[i - 1]) / dt : 0

            // HR ramps over the first 5 min, drifts up, and tracks effort.
            let warmup = min(1, t / 300)
            let drift = frac * 6
            let avgSpeed = distance / duration
            let effort = avgSpeed > 0 ? (stepSpeed / avgSpeed - 1) * 18 : 0
            let hr = Int(Double(avgHR) * (0.82 + 0.18 * warmup) + drift + effort + rng.range(-2, 2))

            // Altitude: one hump scaled to total climb.
            let alt = 550 + sin(frac * .pi) * climb * 0.8

            // Power tracks effort: surges on climbs, drops on descents.
            let power: Int? = basePower.map { base in
                let effortRatio = avgSpeedForPower > 0 ? stepSpeed / avgSpeedForPower : 1
                return max(0, Int(Double(base) * pow(effortRatio, 2.0) + rng.range(-18, 18)))
            }

            coords.append([lat, lon])
            samples.append(FITSample(
                t: t,
                lat: lat, lon: lon,
                hr: hr,
                alt: alt,
                speed: stepSpeed,
                cadence: Int(rng.range(82, 90)),
                dist: d,
                power: power
            ))
        }
        return (coords, samples)
    }

    /// Plausible daily wellness data so the Recovery tab has trends to draw.
    /// HRV and resting HR drift together and worsen after hard days.
    private static func seedDailyMetrics(into context: ModelContext, days: Int, rng: inout RNG) {
        let calendar = Calendar.current
        var hrvBase = 62.0
        var rhrBase = 48.0

        for offset in stride(from: days, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: .now)
            else { continue }

            // Slow fitness drift plus day-to-day noise.
            hrvBase += rng.range(-0.4, 0.45)
            rhrBase += rng.range(-0.2, 0.18)
            hrvBase = min(max(hrvBase, 40), 90)
            rhrBase = min(max(rhrBase, 40), 60)

            let metric = DailyMetric(date: date, source: "demo")
            metric.hrvSDNN = (hrvBase + rng.range(-5, 5)).rounded()
            metric.restingHR = (rhrBase + rng.range(-2, 2)).rounded()
            metric.sleepHours = (rng.range(6.0, 8.6) * 10).rounded() / 10
            metric.weightKg = (72 + rng.range(-0.8, 0.8) * 10).rounded() / 10 + 0.0
            metric.vo2Max = 52 + rng.range(-1, 1)

            // Only a subset of days get a subjective check-in — realistic, and it
            // exercises the partial-data path in the readiness score.
            if rng.next() > 0.35 {
                metric.sleepQuality = Int(rng.range(2.5, 5.4))
                metric.soreness = Int(rng.range(1, 4.4))
                metric.mood = Int(rng.range(2.5, 5.4))
                metric.motivation = Int(rng.range(2.5, 5.4))
                metric.source = "demo"
            }
            context.insert(metric)
        }
    }

    /// An exercise with this name, reusing the library's if it's already there.
    ///
    /// `ExerciseLibrary.seedStarter` skips names that exist, but this ran the
    /// other way round and inserted its own "Back Squat" regardless — so the
    /// library's and the demo's sat side by side in the picker and in the
    /// progress list, one of them permanently empty, and any set you logged
    /// went to whichever you happened to pick.
    private static func exercise(
        named name: String, category: String, muscles: [String],
        in context: ModelContext
    ) -> Exercise {
        let wanted = name.lowercased()
        if let existing = (try? context.fetch(FetchDescriptor<Exercise>()))?
            .first(where: { $0.name.lowercased() == wanted }) {
            return existing
        }
        let exercise = Exercise(name: name, category: category, primaryMuscles: muscles)
        context.insert(exercise)
        return exercise
    }

    private static func seedStrength(into context: ModelContext, rng: inout RNG) {
        let squat = exercise(named: "Back Squat", category: "squat",
                             muscles: ["quads", "glutes"], in: context)
        let dead = exercise(named: "Deadlift", category: "hinge",
                            muscles: ["hamstrings", "back"], in: context)
        let bench = exercise(named: "Bench Press", category: "push",
                             muscles: ["chest", "triceps"], in: context)
        let row = exercise(named: "Barbell Row", category: "pull",
                           muscles: ["lats", "biceps"], in: context)

        // 8 weeks of simple linear progression, twice a week.
        for week in 0..<8 {
            for day in [0, 3] {
                let daysAgo = (8 - week) * 7 - day
                guard let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)
                else { continue }

                let session = StrengthSession(startedAt: date)
                session.endedAt = date.addingTimeInterval(rng.range(3300, 4500))
                context.insert(session)

                let plan: [(Exercise, Double, Int)] = day == 0
                    ? [(squat, 90 + Double(week) * 2.5, 5), (bench, 70 + Double(week) * 1.25, 5)]
                    : [(dead, 110 + Double(week) * 2.5, 5), (row, 60 + Double(week) * 1.25, 8)]

                var order = 0
                for (exercise, topWeight, reps) in plan {
                    for warm in [0.5, 0.75] {
                        let s = SetEntry(order: order, reps: 5,
                                         weightKg: (topWeight * warm / 2.5).rounded() * 2.5,
                                         rpe: nil, isWarmup: true, exercise: exercise)
                        s.session = session
                        context.insert(s)
                        order += 1
                    }
                    for _ in 0..<3 {
                        let s = SetEntry(order: order, reps: reps, weightKg: topWeight,
                                         rpe: (rng.range(7, 9) * 2).rounded() / 2,
                                         isWarmup: false, exercise: exercise)
                        s.session = session
                        context.insert(s)
                        order += 1
                    }
                }
            }
        }
    }
}
