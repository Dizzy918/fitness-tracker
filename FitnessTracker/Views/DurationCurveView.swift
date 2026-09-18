import SwiftUI
import SwiftData
import Charts

/// Best effort at every duration, this window against the one before it.
struct DurationCurveView: View {
    @Environment(\.units) private var units
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]

    @State private var metric: DurationCurve.Metric = .pace
    @State private var window: Window = .ninetyDays
    @State private var comparison: DurationCurve.Comparison?
    @State private var computing = true

    enum Window: Int, CaseIterable, Identifiable {
        case fortyTwoDays = 42, ninetyDays = 90, year = 365
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .fortyTwoDays: return "6 weeks"
            case .ninetyDays:   return "90 days"
            case .year:         return "Year"
            }
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Metric", selection: $metric) {
                    ForEach(DurationCurve.Metric.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Window", selection: $window) {
                    ForEach(Window.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

            if computing {
                Section { HStack { ProgressView(); Text("Sweeping every effort…") } }
            } else if let comparison, !comparison.current.isEmpty {
                chartSection(comparison)
                tableSection(comparison)
            } else {
                Section {
                    ContentUnavailableView {
                        Label("Nothing to plot yet", systemImage: "chart.xyaxis.line")
                    } description: {
                        Text(metric == .power
                             ? "Needs rides with a power meter. Power comes from a .fit import or a synced activity with streams."
                             : "Needs runs with per-second data, from a .fit import or a synced activity with streams.")
                    }
                }
            }
        }
        .navigationTitle("Duration curve")
        .task(id: "\(metric.rawValue)-\(window.rawValue)-\(workouts.count)") { await recompute() }
    }

    /// The full sampled range, bound once — an inline range operator split
    /// across two lines doesn't parse inside the modifier chain.
    private static let durationDomain: ClosedRange<Double> =
        DurationCurve.durations.first!...DurationCurve.durations.last!

    // MARK: - Chart

    private func chartSection(_ comparison: DurationCurve.Comparison) -> some View {
        Section {
            Chart {
                ForEach(comparison.previous) { point in
                    LineMark(x: .value("Duration", point.duration),
                             y: .value("Value", chartValue(point)),
                             series: .value("Series", "Previous"))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4]))
                }
                ForEach(comparison.current) { point in
                    LineMark(x: .value("Duration", point.duration),
                             y: .value("Value", chartValue(point)),
                             series: .value("Series", "Current"))
                        .foregroundStyle(.tint)
                        .symbol(.circle)
                }
            }
            // Log scale: the interesting distinctions are 5s vs 30s and 20min
            // vs 60min. On a linear axis everything under five minutes collapses
            // into the y-axis.
            .chartXScale(domain: Self.durationDomain, type: .log)
            .chartXAxis {
                AxisMarks(values: DurationCurve.durations) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let seconds = value.as(TimeInterval.self) {
                            Text(DurationCurve.label(for: seconds)).font(.caption2)
                        }
                    }
                }
            }
            .chartYAxisLabel(metric == .power ? "W" : "min/\(units.paceUnit)")
            .frame(height: 220)
            .accessibilityLabel("Duration curve, \(comparison.current.count) points")
        } header: {
            Text("Best effort at each duration")
        } footer: {
            Text(footerText(comparison))
        }
    }

    /// Pace is plotted in minutes so the axis reads naturally; power is watts.
    private func chartValue(_ point: DurationCurve.Point) -> Double {
        metric == .power ? point.value : (units.paceValue(point.value) ?? point.value) / 60
    }

    private func footerText(_ comparison: DurationCurve.Comparison) -> String {
        var text = "Solid is the last \(window.label.lowercased()); dashed is the \(window.label.lowercased()) before it."
        if let gain = comparison.largestGain {
            text += " Biggest gain at \(DurationCurve.label(for: gain.duration)) — \(Int((gain.change * 100).rounded()))% better."
        } else if !comparison.previous.isEmpty {
            text += " Nothing has moved much between the two."
        }
        return text
    }

    // MARK: - Table

    private func tableSection(_ comparison: DurationCurve.Comparison) -> some View {
        Section("Every duration") {
            ForEach(comparison.current) { point in
                HStack(spacing: 10) {
                    Text(point.label)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(width: 44, alignment: .leading)

                    Text(valueText(point))
                        .font(.callout.monospacedDigit())

                    Spacer()

                    if let change = comparison.change(at: point.duration) {
                        Text(String(format: "%+.0f%%", change * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(change > 0.01 ? Color.green
                                             : change < -0.01 ? Color.orange : Color.secondary)
                    }

                    Text(point.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func valueText(_ point: DurationCurve.Point) -> String {
        metric == .power ? "\(Int(point.value.rounded())) W" : units.pace(point.value)
    }

    // MARK: - Data

    private func recompute() async {
        computing = true
        let snapshots = workouts.map(\.snapshot)
        let metric = metric
        let days = window.rawValue
        comparison = await Task.detached(priority: .userInitiated) {
            DurationCurve.compare(workouts: snapshots, metric: metric, days: days)
        }.value
        computing = false
    }
}
