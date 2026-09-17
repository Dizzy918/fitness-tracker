import SwiftUI
import SwiftData

/// Where a block of training actually sat on the intensity scale.
struct IntensityView: View {
    @Environment(\.units) private var units
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]

    @AppStorage(AthleteProfile.Key.maxHeartRate) private var storedMaxHR = 0

    @State private var window: Window = .fourWeeks
    @State private var summary: IntensityDistribution.Summary?
    @State private var computing = true

    /// Windows a block is actually judged over. A single week is too noisy —
    /// one interval session swings it — and a year hides the block you're in.
    enum Window: String, CaseIterable, Identifiable {
        case fourWeeks, twelveWeeks, year

        var id: String { rawValue }

        var label: String {
            switch self {
            case .fourWeeks:   return "4 weeks"
            case .twelveWeeks: return "12 weeks"
            case .year:        return "Year"
            }
        }

        var days: Int {
            switch self {
            case .fourWeeks:   return 28
            case .twelveWeeks: return 84
            case .year:        return 365
            }
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Window", selection: $window) {
                    ForEach(Window.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            if computing {
                Section { HStack { ProgressView(); Text("Adding up time in zone…") } }
            } else if let summary, !summary.isEmpty {
                distributionSection(summary)
                verdictSection(summary)
                coverageSection(summary)
            } else {
                Section {
                    ContentUnavailableView {
                        Label("No heart-rate data yet", systemImage: "waveform.path.ecg")
                    } description: {
                        Text("Time in zone needs per-second heart rate, which comes from a .fit import or a synced activity with streams.")
                    }
                }
            }
        }
        .navigationTitle("Intensity")
        .task(id: "\(window.rawValue)-\(workouts.count)-\(storedMaxHR)") { await recompute() }
    }

    // MARK: - Sections

    private func distributionSection(_ summary: IntensityDistribution.Summary) -> some View {
        Section {
            // One stacked bar: the shape is the point, and three separate bars
            // make you do the comparison yourself.
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(summary.slices) { slice in
                        if slice.fraction > 0 {
                            Rectangle()
                                .fill(color(slice.band))
                                .frame(width: geo.size.width * slice.fraction)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 22)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))

            ForEach(summary.slices) { slice in
                HStack(spacing: 10) {
                    Circle().fill(color(slice.band)).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(slice.band.displayName)
                        Text(slice.band.detail)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(units.duration(slice.seconds))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("\(slice.percent)%")
                        .font(.callout.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(slice.band.displayName), \(slice.percent) percent, \(units.duration(slice.seconds))")
            }
        } header: {
            Text("Time in each band")
        } footer: {
            Text("Bands are the two lactate thresholds, approximated at 80% and 90% of your max heart rate. Real thresholds sit either side of that, so the shape is reliable and any single percentage point isn't.")
        }
    }

    @ViewBuilder
    private func verdictSection(_ summary: IntensityDistribution.Summary) -> some View {
        if let shape = IntensityDistribution.shape(of: summary) {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(shape.label, systemImage: symbol(shape))
                        .font(.headline)
                        .foregroundStyle(color(shape))
                    Text(shape.guidance)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let advice = IntensityDistribution.advice(for: summary) {
                        Text(advice)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("Reading")
            } footer: {
                Text("\"80/20\" is a convention, not a law — it describes what most successful endurance athletes are measured doing, over a block, not every week.")
            }
        }
    }

    private func coverageSection(_ summary: IntensityDistribution.Summary) -> some View {
        Section {
            LabeledContent("Sessions counted", value: "\(summary.measuredSessions)")
            if summary.unmeasuredSessions > 0 {
                LabeledContent("No heart rate", value: "\(summary.unmeasuredSessions)")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Total time", value: units.duration(summary.measuredSeconds))
        } header: {
            Text("Coverage")
        } footer: {
            Text(summary.isRepresentative
                 ? "Based on \(Int((summary.coverage * 100).rounded()))% of the sessions in this window."
                 : "Only \(Int((summary.coverage * 100).rounded()))% of sessions in this window had heart rate, so this describes that slice rather than your training as a whole.")
        }
    }

    // MARK: - Styling

    private func color(_ band: IntensityDistribution.Band) -> Color {
        switch band {
        case .easy:     return .green
        case .moderate: return .orange
        case .hard:     return .red
        }
    }

    private func color(_ shape: IntensityDistribution.Shape) -> Color {
        switch shape {
        case .polarized: return .green
        case .allEasy:   return .blue
        case .threshold: return .orange
        case .tooHard:   return .red
        }
    }

    private func symbol(_ shape: IntensityDistribution.Shape) -> String {
        switch shape {
        case .polarized: return "checkmark.circle"
        case .allEasy:   return "tortoise"
        case .threshold: return "exclamationmark.triangle"
        case .tooHard:   return "flame"
        }
    }

    // MARK: - Data

    private func recompute() async {
        computing = true
        let cutoff = Calendar.current.date(byAdding: .day, value: -window.days, to: .now) ?? .now
        let snapshots = workouts
            .filter { $0.startedAt >= cutoff }
            .map(\.snapshot)
        let maxHR = storedMaxHR >= 100
            ? storedMaxHR
            : (snapshots.compactMap(\.maxHeartRate).max() ?? 190)

        summary = await Task.detached(priority: .userInitiated) {
            IntensityDistribution.summarize(workouts: snapshots,
                                            zones: HRZones(maxHR: maxHR))
        }.value
        computing = false
    }
}
