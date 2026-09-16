import SwiftUI
import SwiftData
import MapKit
import Charts

struct WorkoutDetailView: View {
    @Bindable var workout: Workout
    @Query(filter: #Predicate<Shoe> { $0.retiredAt == nil },
           sort: \Shoe.acquiredAt, order: .reverse)
    private var activeShoes: [Shoe]

    @Environment(\.modelContext) private var context

    /// Highest HR ever recorded — a far better stand-in for true max than this
    /// one workout's peak. Fetched as a single top-1 query rather than with an
    /// unfiltered `@Query`, which materialized every workout (and, before the
    /// blobs moved to external storage, every sample stream) to read one number.
    @State private var observedMaxHR: Int?

    // Decoding the blobs is not free; do it once per appearance.
    @State private var splits: [Split] = []
    @State private var samples: [FITSample] = []
    @State private var zoneTotals: [Int: TimeInterval] = [:]
    @State private var powerSummary: CyclingPower.Summary?
    @State private var swimSummary: SwimMetrics.Summary?
    @State private var load: TrainingLoad.Score?

    /// Max HR drives zone boundaries. Set once in Recovery/Settings; falls back
    /// to the highest HR this workout recorded so zones are never nonsense.
    @AppStorage("maxHeartRate") private var storedMaxHR = 0
    @AppStorage("restingHeartRate") private var restingHR = 0
    @AppStorage("ftpWatts") private var ftp = 0
    @AppStorage("bodyWeightKg") private var bodyWeight = 0.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !routeCoordinates.isEmpty {
                    RouteMap(coordinates: routeCoordinates)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                summaryGrid
                if let load { LoadBadge(score: load) }
                shoePicker

                if !samples.isEmpty {
                    HeartRateChart(samples: samples)
                }
                // Sport-specific analysis, only where it means something.
                if workout.sport == .bike, let power = powerSummary {
                    PowerSummaryView(summary: power,
                                     ftp: ftp > 0 ? ftp : nil,
                                     bodyWeightKg: bodyWeight > 0 ? bodyWeight : nil)
                }
                if workout.sport == .swim, let swim = swimSummary {
                    SwimSummaryView(summary: swim)
                }
                if !zoneTotals.isEmpty {
                    ZoneBreakdown(
                        totals: zoneTotals,
                        zones: HRZones(maxHR: effectiveMaxHR),
                        maxIsEstimated: maxHRIsEstimated
                    )
                }
                if !splits.isEmpty, workout.sport != .swim {
                    SplitsTable(splits: splits)
                }
                if hasElevation {
                    ElevationChart(samples: samples)
                }
                if let notes = workout.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notes").font(.headline)
                        Text(notes)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(workout.startedAt.formatted(date: .abbreviated, time: .shortened))
        .task(id: workout.id) {
            observedMaxHR = Self.highestRecordedHR(in: context)
            let decoded = workout.samples
            samples = decoded
            splits = SplitCalculator.splits(from: decoded)
            zoneTotals = HRZones(maxHR: effectiveMaxHR).timeInZones(decoded)
            load = TrainingLoad.score(
                for: workout.snapshot,
                athlete: TrainingLoad.Athlete(
                    ftp: ftp, maxHR: effectiveMaxHR,
                    restingHR: restingHR > 0 ? restingHR : nil
                )
            )


            switch workout.sport {
            case .bike:
                powerSummary = CyclingPower.summary(samples: decoded, ftp: ftp > 0 ? ftp : nil)
            case .swim:
                swimSummary = SwimMetrics.summary(
                    distance: workout.distance, duration: workout.duration,
                    samples: decoded, poolLength: workout.poolLength
                )
            default:
                break
            }
        }
    }

    /// Prefer the user's configured max. Falling back to *this* workout's peak
    /// would define every session as maximal — an easy run would read as 45% in
    /// Z5 — so use the highest HR across all history instead.
    private var effectiveMaxHR: Int {
        if storedMaxHR >= 100 { return storedMaxHR }
        if let observedMaxHR, observedMaxHR >= 100 { return observedMaxHR }
        return workout.maxHeartRate ?? 190
    }

    /// Single highest `maxHeartRate` in the store, as one sorted top-1 fetch.
    private static func highestRecordedHR(in context: ModelContext) -> Int? {
        var descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { $0.maxHeartRate != nil },
            sortBy: [SortDescriptor(\.maxHeartRate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)?.maxHeartRate
    }

    /// True when zones are derived rather than user-supplied, so the UI can say so.
    private var maxHRIsEstimated: Bool { storedMaxHR < 100 }

    private var hasElevation: Bool {
        samples.contains { $0.alt != nil }
    }

    private var routeCoordinates: [CLLocationCoordinate2D] {
        workout.coordinates.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
            StatTile(label: "Distance", value: Fmt.km(workout.distance))
            StatTile(label: "Time", value: Fmt.duration(workout.duration))
            if workout.sport == .swim, let swim = swimSummary {
                StatTile(label: "Pace", value: "\(swim.pacePer100Formatted)/100m")
            } else {
                StatTile(label: "Pace", value: "\(Fmt.pace(workout.paceSecPerKm))/km")
            }
            if let power = workout.avgPower {
                StatTile(label: "Avg power", value: "\(power) W")
            }
            StatTile(label: "Avg HR", value: Fmt.bpm(workout.avgHeartRate))
            StatTile(label: "Max HR", value: Fmt.bpm(workout.maxHeartRate))
            StatTile(label: "Elev gain", value: Fmt.meters(workout.elevationGain))
            StatTile(label: "Calories", value: Fmt.kcal(workout.calories))
            StatTile(label: "Sport", value: workout.sport.displayName)
        }
    }

    private var shoePicker: some View {
        HStack {
            Text("Shoe").font(.headline)
            Spacer()
            Picker("Shoe", selection: Binding(
                get: { workout.shoe },
                set: { workout.shoe = $0 }
            )) {
                Text("None").tag(Shoe?.none)
                ForEach(activeShoes) { shoe in
                    Text(shoe.displayName).tag(Shoe?.some(shoe))
                }
            }
            .labelsHidden()
        }
    }
}

// MARK: - Pieces

struct StatTile: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// What this session cost, on the same scale as every other sport.
///
/// The method is shown next to the number on purpose: a load derived from power
/// and one guessed from duration are both "84", and the athlete deserves to know
/// which one they're looking at.
struct LoadBadge: View {
    let score: TrainingLoad.Score

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Training load").font(.caption).foregroundStyle(.secondary)
                Text("\(Int(score.value.rounded()))")
                    .font(.title2.weight(.semibold).monospacedDigit())
            }
            Divider().frame(height: 32)
            VStack(alignment: .leading, spacing: 2) {
                if let intensity = score.intensityFactor {
                    Text("Intensity \(String(format: "%.2f", intensity))")
                        .font(.caption.monospacedDigit())
                }
                Text(score.method.displayName)
                    .font(.caption2)
                    .foregroundStyle(score.method.isMeasured ? Color.secondary : Color.orange)
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Training load \(Int(score.value.rounded())), \(score.method.displayName)")
    }
}

struct RouteMap: View {
    let coordinates: [CLLocationCoordinate2D]

    var body: some View {
        Map(initialPosition: .region(region)) {
            MapPolyline(coordinates: coordinates)
                .stroke(.blue, lineWidth: 3)
            if let start = coordinates.first {
                Marker("Start", systemImage: "flag", coordinate: start)
                    .tint(.green)
            }
            if let end = coordinates.last {
                Marker("End", systemImage: "flag.checkered", coordinate: end)
                    .tint(.red)
            }
        }
    }

    /// Bounding box of the track plus 20% padding.
    private var region: MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
            )
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.2, 0.005),
                                   longitudeDelta: max((maxLon - minLon) * 1.2, 0.005))
        )
    }
}

struct HeartRateChart: View {
    let samples: [FITSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Heart rate").font(.headline)
            Chart(points, id: \.0) { point in
                LineMark(
                    x: .value("Time", point.0 / 60),
                    y: .value("HR", point.1)
                )
                .foregroundStyle(.red)
                .interpolationMethod(.monotone)
            }
            .chartXAxisLabel("minutes")
            .chartYScale(domain: yDomain)
            .frame(height: 160)
        }
    }

    private var points: [(Double, Int)] {
        samples.compactMap { s in s.hr.map { (s.t, $0) } }
    }

    private var yDomain: ClosedRange<Int> {
        let hrs = points.map(\.1)
        guard let lo = hrs.min(), let hi = hrs.max() else { return 100...180 }
        return (lo - 5)...(hi + 5)
    }
}

struct SplitsTable: View {
    let splits: [Split]

    private var fastestIndex: Int? { SplitCalculator.fastest(splits)?.index }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Splits").font(.headline)

            // Bar length is relative to the slowest split, so faster reads longer.
            let slowest = splits.compactMap(\.paceSecPerKm).max() ?? 1

            VStack(spacing: 4) {
                ForEach(splits) { split in
                    HStack(spacing: 10) {
                        Text(split.label)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(width: 38, alignment: .trailing)

                        GeometryReader { geo in
                            let pace = split.paceSecPerKm ?? slowest
                            // Invert: faster pace → wider bar.
                            let ratio = slowest > 0 ? (slowest / pace) : 1
                            let width = geo.size.width * min(1, ratio * 0.85)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(split.index == fastestIndex ? Color.green : Color.accentColor)
                                .frame(width: max(4, width))
                        }
                        .frame(height: 16)

                        Text("\(Fmt.pace(split.paceSecPerKm))/km")
                            .font(.system(.footnote, design: .monospaced))
                            .frame(width: 74, alignment: .trailing)

                        Text(Fmt.bpm(split.avgHR))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)
                    }
                }
            }
        }
    }
}


struct ZoneBreakdown: View {
    let totals: [Int: TimeInterval]
    let zones: HRZones
    var maxIsEstimated: Bool = false

    private var total: TimeInterval {
        max(totals.values.reduce(0, +), 1)
    }

    private static let colors: [Color] = [.gray, .blue, .green, .orange, .red]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Heart-rate zones").font(.headline)
                Spacer()
                Text("max \(zones.maxHR) bpm")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if maxIsEstimated {
                Text("Estimated from your highest recorded HR. Set your real max in Settings for accurate zones.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Single stacked bar reads as "how the session was distributed".
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { zone in
                        let seconds = totals[zone] ?? 0
                        if seconds > 0 {
                            Rectangle()
                                .fill(Self.colors[zone - 1])
                                .frame(width: geo.size.width * (seconds / total))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 18)

            ForEach((1...5).reversed(), id: \.self) { zone in
                let seconds = totals[zone] ?? 0
                if seconds > 0 {
                    HStack(spacing: 8) {
                        Circle().fill(Self.colors[zone - 1]).frame(width: 8, height: 8)
                        Text("Z\(zone) \(HRZones.names[zone - 1])")
                            .font(.caption)
                        if let range = zones.range(for: zone) {
                            Text("\(range.lowerBound)–\(range.upperBound)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(Fmt.duration(seconds))
                            .font(.caption.monospacedDigit())
                        Text("\(Int(seconds / total * 100))%")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Zone \(zone), \(Fmt.duration(seconds))")
                }
            }
        }
    }
}

struct ElevationChart: View {
    let samples: [FITSample]

    private var points: [(Double, Double)] {
        samples.compactMap { s in
            guard let alt = s.alt else { return nil }
            // Plot against distance when available; time otherwise.
            return (s.dist.map { $0 / 1000 } ?? s.t / 60, alt)
        }
    }

    private var usesDistance: Bool {
        samples.first?.dist != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Elevation").font(.headline)
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    AreaMark(x: .value("x", point.0), y: .value("m", point.1))
                        .foregroundStyle(.green.opacity(0.25))
                    LineMark(x: .value("x", point.0), y: .value("m", point.1))
                        .foregroundStyle(.green)
                }
            }
            .chartXAxisLabel(usesDistance ? "km" : "minutes")
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 130)
            .accessibilityLabel("Elevation profile")
        }
    }
}


struct PowerSummaryView: View {
    let summary: CyclingPower.Summary
    let ftp: Int?
    let bodyWeightKg: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Power").font(.headline)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                StatTile(label: "Average", value: "\(Int(summary.averagePower)) W")
                StatTile(label: "Normalized", value: "\(Int(summary.normalizedPower)) W")
                StatTile(label: "Max", value: "\(Int(summary.maxPower)) W")
                if let intensity = summary.intensityFactor {
                    StatTile(label: "Intensity", value: String(format: "%.2f", intensity))
                }
                if let tss = summary.trainingStressScore {
                    StatTile(label: "TSS", value: "\(Int(tss.rounded()))")
                }
                StatTile(label: "Variability", value: String(format: "%.2f", summary.variabilityIndex))
                if let perKg = summary.wattsPerKg(bodyWeightKg) {
                    StatTile(label: "W/kg", value: String(format: "%.2f", perKg))
                }
            }

            if ftp == nil {
                Text("Set your FTP in Settings to get Intensity Factor and TSS.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text(variabilityNote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Variability index says whether the ride was steady or surgey — useful for
    /// judging whether NP-based numbers are meaningful.
    private var variabilityNote: String {
        switch summary.variabilityIndex {
        case ..<1.05: return "Very steady effort — normalized and average power nearly match."
        case ..<1.15: return "Moderately variable effort, typical of rolling terrain."
        default:      return "Surgey ride — lots of hard efforts and coasting."
        }
    }
}

struct SwimSummaryView: View {
    let summary: SwimMetrics.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Swim").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                StatTile(label: "Pace", value: "\(summary.pacePer100Formatted)/100m")
                if let rate = summary.strokeRate {
                    StatTile(label: "Stroke rate", value: "\(Int(rate.rounded()))/min")
                }
                if let lengths = summary.lengths {
                    StatTile(label: "Lengths", value: "\(lengths)")
                }
                if let swolf = summary.swolf {
                    StatTile(label: "SWOLF", value: "\(Int(swolf.rounded()))")
                }
            }
            if summary.swolf != nil {
                Text("SWOLF adds length time and stroke count — lower means more efficient.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
