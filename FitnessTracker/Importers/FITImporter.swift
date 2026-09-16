import Foundation
import CryptoKit
import FitDataProtocol
import AntMessageProtocol

enum FITImportError: Error, LocalizedError {
    case unreadable
    case noSession
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:          return "Could not read the FIT file."
        case .noSession:           return "The FIT file has no Session message."
        case .decodeFailed(let m): return "FIT decode failed: \(m)"
        }
    }
}

/// One trackpoint from a FIT `RecordMessage`.
struct FITSample: Codable, Sendable {
    let t: TimeInterval    // seconds from workout start
    let lat: Double?       // degrees
    let lon: Double?       // degrees
    let hr: Int?           // bpm
    let alt: Double?       // meters
    let speed: Double?     // m/s
    let cadence: Int?      // rpm (running: spm; swimming: stroke rate)
    let dist: Double?      // cumulative meters — drives accurate splits
    let power: Int?        // watts — drives NP/IF/TSS for cycling

    /// Explicit initializer with defaults for every optional field, so adding a
    /// new channel later doesn't break every construction site.
    init(
        t: TimeInterval,
        lat: Double? = nil,
        lon: Double? = nil,
        hr: Int? = nil,
        alt: Double? = nil,
        speed: Double? = nil,
        cadence: Int? = nil,
        dist: Double? = nil,
        power: Int? = nil
    ) {
        self.t = t
        self.lat = lat
        self.lon = lon
        self.hr = hr
        self.alt = alt
        self.speed = speed
        self.cadence = cadence
        self.dist = dist
        self.power = power
    }
}

/// A lap from a FIT `LapMessage` — what the watch recorded when you pressed the
/// button, or when it auto-lapped.
///
/// Every field past `avgHR` is optional so blobs written by the earlier,
/// four-field version still decode: the synthesized decoder uses
/// `decodeIfPresent` for optionals, so a missing key costs that field rather
/// than the whole workout.
struct FITLap: Codable, Sendable, Identifiable {
    let index: Int
    /// Elapsed time, wall clock.
    let duration: TimeInterval
    let distance: Double        // meters
    let avgHR: Int?

    /// Seconds from the start of the workout, for lining a lap up with the
    /// heart-rate chart.
    var startOffset: TimeInterval?
    /// Timer time — excludes auto-pause. Differs from `duration` at traffic
    /// lights and during long recoveries.
    var movingTime: TimeInterval?
    var maxHR: Int?
    var avgCadence: Int?
    var avgPower: Int?
    var maxPower: Int?
    var elevationGain: Double?
    var calories: Double?
    /// FIT `Intensity`: active, rest, warmup, cooldown. This is what makes a
    /// structured session readable — a recovery jog between reps is *not* a
    /// slow interval, and the watch already knows the difference.
    var intensity: String?
    /// FIT `LapTrigger`: manual, distance, time… Distinguishes "I pressed the
    /// button" from "the watch ticked over another kilometre".
    var trigger: String?

    var id: Int { index }

    init(index: Int,
         duration: TimeInterval,
         distance: Double,
         avgHR: Int? = nil,
         startOffset: TimeInterval? = nil,
         movingTime: TimeInterval? = nil,
         maxHR: Int? = nil,
         avgCadence: Int? = nil,
         avgPower: Int? = nil,
         maxPower: Int? = nil,
         elevationGain: Double? = nil,
         calories: Double? = nil,
         intensity: String? = nil,
         trigger: String? = nil) {
        self.index = index
        self.duration = duration
        self.distance = distance
        self.avgHR = avgHR
        self.startOffset = startOffset
        self.movingTime = movingTime
        self.maxHR = maxHR
        self.avgCadence = avgCadence
        self.avgPower = avgPower
        self.maxPower = maxPower
        self.elevationGain = elevationGain
        self.calories = calories
        self.intensity = intensity
        self.trigger = trigger
    }

    var paceSecPerKm: Double? {
        guard distance > 0, duration > 0 else { return nil }
        return duration / (distance / 1000)
    }

    /// Swimmers read per-100 m, never per-km.
    var pacePer100m: Double? {
        guard distance > 0, duration > 0 else { return nil }
        return duration / (distance / 100)
    }

    /// True for recovery, warmup and cooldown laps — everything that isn't a
    /// working effort.
    var isRecovery: Bool {
        guard let intensity else { return false }
        return intensity != "active"
    }

    /// Short badge for the UI. Nil for ordinary working laps, which are the
    /// majority and don't need labelling.
    var intensityBadge: String? {
        switch intensity {
        case "rest":     return "rest"
        case "warmup":   return "w-up"
        case "cooldown": return "c-dn"
        default:         return nil
        }
    }
}

/// Reading the *shape* of a lap set.
///
/// The question the detail view has to answer is "did the athlete structure this
/// session, or did the watch just tick over kilometres?" — because if it's the
/// latter, laps and computed splits say the same thing and showing both is
/// noise.
enum LapAnalysis {

    /// Distances a watch auto-laps at, with a 3% tolerance for GPS drift.
    static let autoLapDistances: [Double] = [400, 500, 1_000, 1_609.34, 5_000]

    /// True when these laps are the watch ticking over a round distance.
    ///
    /// Prefers the recorded `LapTrigger`, which says so outright. Falls back to
    /// geometry for files that don't carry one: laps all within 3% of the same
    /// round distance are an auto-lap by any reasonable reading.
    static func areAutoLaps(_ laps: [FITLap]) -> Bool {
        guard laps.count >= 2 else { return false }

        // A single manual press, or any intensity marking, means structure.
        if laps.contains(where: { $0.trigger == "manual" }) { return false }
        if laps.contains(where: { $0.isRecovery }) { return false }

        let triggers = Set(laps.compactMap(\.trigger).filter { $0 != "sessionEnd" })
        if !triggers.isEmpty {
            return triggers.isSubset(of: ["distance", "time"])
        }

        // No trigger recorded — judge by the distances themselves. The last lap
        // is the remainder and is expected to be short, so it doesn't vote.
        let full = laps.dropLast().map(\.distance).filter { $0 > 0 }
        guard full.count >= 2 else { return false }
        return autoLapDistances.contains { target in
            full.allSatisfy { abs($0 - target) / target <= 0.03 }
        }
    }

    /// True when the watch marked recovery, warmup or cooldown — a session that
    /// was structured in advance.
    static func hasStructure(_ laps: [FITLap]) -> Bool {
        laps.contains { $0.isRecovery }
    }

    /// The working laps of a structured session — what you actually want the
    /// average of, the way warmups are excluded from strength volume.
    static func workingLaps(_ laps: [FITLap]) -> [FITLap] {
        let working = laps.filter { !$0.isRecovery }
        return working.isEmpty ? laps : working
    }

    /// Fastest working lap, for highlighting. Compared on pace, and only among
    /// laps long enough for pace to mean anything.
    static func fastest(_ laps: [FITLap]) -> FITLap? {
        workingLaps(laps)
            .filter { $0.distance >= 100 }
            .min { ($0.paceSecPerKm ?? .infinity) < ($1.paceSecPerKm ?? .infinity) }
    }
}

/// Result of decoding a `.fit` file. Pure value type — no persistence coupling.
struct FITDecoded: Sendable {
    let sport: WorkoutSport
    let startedAt: Date
    let duration: TimeInterval
    let distance: Double        // meters
    let avgHR: Int?
    let maxHR: Int?
    let elevationGain: Double?  // meters
    let calories: Double?       // kcal
    let coordinates: [[Double]] // [[lat, lon], ...] — JSON-friendly
    let samples: [FITSample]
    let laps: [FITLap]
    let avgPower: Int?          // watts, session-reported
    let poolLength: Double?     // meters, for pool swims
    let externalID: String      // SHA-256 of file bytes, for dedupe

    var distanceKm: Double { distance / 1000 }
}

struct FITImporter {

    /// Parse a `.fit` file. Pure function, no side effects.
    func decode(url: URL) throws -> FITDecoded {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw FITImportError.unreadable }
        return try decode(data: data)
    }

    /// Parse raw FIT bytes.
    func decode(data: Data) throws -> FITDecoded {
        // Accumulate into a reference box: the decoder's callback is an
        // escaping optional closure, so a class keeps capture semantics clear.
        let acc = Accumulator()

        // `decode` is declared `mutating`, so the decoder must be a `var`.
        var decoder = FitFileDecoder(crcCheckingStrategy: .throws)
        do {
            try decoder.decode(data: data, messages: FitFileDecoder.defaultMessages) { message in
                acc.ingest(message)
            }
        } catch {
            throw FITImportError.decodeFailed(String(describing: error))
        }

        guard let started = acc.startedAt else { throw FITImportError.noSession }

        return FITDecoded(
            sport: acc.resolvedSport,
            startedAt: started,
            duration: acc.duration,
            distance: acc.distance,
            avgHR: acc.avgHR,
            maxHR: acc.maxHR,
            // Prefer the watch's reported ascent; fall back to summing deltas.
            elevationGain: acc.totalAscent ?? (acc.computedGain > 0 ? acc.computedGain : nil),
            calories: acc.calories,
            coordinates: acc.coordinates,
            samples: acc.samples,
            laps: acc.laps,
            avgPower: acc.avgPower,
            poolLength: acc.poolLength,
            externalID: Self.stableID(from: data)
        )
    }

    /// SHA-256 of the file bytes so re-importing the same file dedupes cleanly.
    /// Namespaced like provider IDs (`strava:123`) so every `externalID` in the
    /// store says where it came from.
    static func stableID(from data: Data) -> String {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "fit:\(hex)"
    }
}

// MARK: - Message accumulator

private final class Accumulator {
    var sport: Sport?
    var subSport: SubSport?
    var startedAt: Date?
    var duration: TimeInterval = 0
    var distance: Double = 0
    var avgHR: Int?
    var maxHR: Int?
    var totalAscent: Double?
    var calories: Double?
    var avgPower: Int?
    var poolLength: Double?

    var coordinates: [[Double]] = []
    var samples: [FITSample] = []
    var laps: [FITLap] = []

    private var lastAltitude: Double?
    var computedGain: Double = 0

    /// Records can precede the Session message, so keep raw timestamps and
    /// rebase to the true start once everything is parsed.
    private var pendingRecords: [(Date?, FITSample)] = []
    /// Same treatment for laps: their start offsets need the session start too.
    private var pendingLaps: [(Date?, FITLap)] = []

    var resolvedSport: WorkoutSport {
        switch sport {
        case .running:  return subSport == .trail ? .trailRun : .run
        case .cycling:  return .bike
        case .swimming: return .swim
        case .hiking:   return .hike
        case .walking:  return .walk
        default:        return .other
        }
    }

    func ingest(_ message: FitMessage) {
        switch message {
        case let s as SessionMessage: ingestSession(s)
        case let r as RecordMessage:  ingestRecord(r)
        case let l as LapMessage:     ingestLap(l)
        default: break
        }
    }

    private func ingestSession(_ s: SessionMessage) {
        sport = s.sport ?? sport
        subSport = s.subSport ?? subSport
        if let d = s.startTime?.recordDate { startedAt = d }
        if let v = s.totalElapsedTime?.converted(to: .seconds).value { duration = v }
        if let v = s.totalDistance?.converted(to: .meters).value { distance = v }
        if let v = s.averageHeartRate?.value { avgHR = Int(v) }
        if let v = s.maximumHeartRate?.value { maxHR = Int(v) }
        if let v = s.totalAscent?.converted(to: .meters).value { totalAscent = v }
        if let v = s.totalCalories?.converted(to: .kilocalories).value { calories = v }
        if let v = s.averagePower?.converted(to: .watts).value { avgPower = Int(v) }
        if let v = s.poolLength?.converted(to: .meters).value, v > 0 { poolLength = v }
        rebasePendingRecords()
        rebasePendingLaps()
    }

    private func ingestRecord(_ r: RecordMessage) {
        let lat = r.position?.latitude?.converted(to: .degrees).value
        let lon = r.position?.longitude?.converted(to: .degrees).value
        let hr = r.heartRate?.value
        let alt = r.altitude?.converted(to: .meters).value
        let spd = r.speed?.converted(to: .metersPerSecond).value
        let cad = r.cadence?.value
        let dst = r.distance?.converted(to: .meters).value
        let pwr = r.power?.converted(to: .watts).value

        if let lat, let lon { coordinates.append([lat, lon]) }
        if let alt {
            if let prev = lastAltitude, alt > prev { computedGain += (alt - prev) }
            lastAltitude = alt
        }

        let sample = FITSample(
            t: 0,   // filled in by rebase
            lat: lat, lon: lon,
            hr: hr.map { Int($0) },
            alt: alt,
            speed: spd,
            cadence: cad.map { Int($0) },
            dist: dst,
            power: pwr.map { Int($0) }
        )
        pendingRecords.append((r.timeStamp?.recordDate, sample))
        rebasePendingRecords()
    }

    private func ingestLap(_ l: LapMessage) {
        let dur = l.totalElapsedTime?.converted(to: .seconds).value ?? 0
        let dist = l.totalDistance?.converted(to: .meters).value ?? 0

        // Laps can arrive before the Session message, so the start offset can't
        // be computed yet. Keep the absolute time and rebase with the records.
        pendingLaps.append((
            l.startTime?.recordDate,
            FITLap(
                index: pendingLaps.count,
                duration: dur,
                distance: dist,
                avgHR: l.averageHeartRate?.value.map { Int($0) },
                movingTime: l.totalTimerTime?.converted(to: .seconds).value,
                maxHR: l.maximumHeartRate?.value.map { Int($0) },
                avgCadence: l.averageCadence?.value.map { Int($0) },
                avgPower: l.averagePower?.converted(to: .watts).value.map { Int($0) },
                maxPower: l.maximumPower?.converted(to: .watts).value.map { Int($0) },
                elevationGain: l.totalAscent?.converted(to: .meters).value,
                calories: l.totalCalories?.converted(to: .kilocalories).value,
                intensity: Self.name(of: l.intensity),
                trigger: Self.name(of: l.lapTrigger)
            )
        ))
        rebasePendingLaps()
    }

    /// FIT enums come through as cases; store the name so `FITLap` stays free of
    /// the FIT library and the blob stays readable.
    private static func name(of intensity: Intensity?) -> String? {
        switch intensity {
        case .active:   return "active"
        case .rest:     return "rest"
        case .warmup:   return "warmup"
        case .cooldown: return "cooldown"
        default:        return nil
        }
    }

    private static func name(of trigger: LapTrigger?) -> String? {
        switch trigger {
        case .manual:           return "manual"
        case .time:             return "time"
        case .distance:         return "distance"
        case .positionStart:    return "positionStart"
        case .positionLap:      return "positionLap"
        case .positionWaypoint: return "positionWaypoint"
        case .positionMarked:   return "positionMarked"
        case .sessionEnd:       return "sessionEnd"
        case .fitnessEquipment: return "fitnessEquipment"
        default:                return nil
        }
    }

    private func rebasePendingLaps() {
        guard let start = startedAt, !pendingLaps.isEmpty else { return }
        for (lapStart, lap) in pendingLaps {
            var rebased = lap
            rebased.startOffset = lapStart.map { $0.timeIntervalSince(start) }
            laps.append(rebased)
        }
        pendingLaps.removeAll(keepingCapacity: true)
    }

    /// Once we know the start time, convert absolute record timestamps into
    /// offsets. No-op until a Session message has been seen.
    private func rebasePendingRecords() {
        guard let start = startedAt, !pendingRecords.isEmpty else { return }
        for (ts, sample) in pendingRecords {
            let offset = ts.map { $0.timeIntervalSince(start) } ?? 0
            samples.append(FITSample(
                t: offset,
                lat: sample.lat, lon: sample.lon,
                hr: sample.hr, alt: sample.alt,
                speed: sample.speed, cadence: sample.cadence,
                dist: sample.dist, power: sample.power
            ))
        }
        pendingRecords.removeAll(keepingCapacity: true)
    }
}
