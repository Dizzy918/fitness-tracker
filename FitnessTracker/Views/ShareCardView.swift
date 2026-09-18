import SwiftUI
import Charts

/// A workout rendered as a single image.
///
/// Every other app in this category has this, and the reason isn't vanity —
/// it's that a screenshot of a scrolling detail view is a bad artefact. This
/// is drawn at a fixed size for the purpose, so what's shared is legible
/// rather than whatever happened to be on screen.
///
/// Composed of plain shapes and text on purpose: `ImageRenderer` can't
/// snapshot a `Map`, so the route is drawn from the stored polyline. That also
/// means no tile provider's terms apply to the result.
struct ShareCardView: View {
    let workout: WorkoutSnapshot
    let coordinates: [[Double]]
    let splits: [Split]
    let units: UnitFormatter
    /// Not on `WorkoutSnapshot`, so passed in rather than widening it for one
    /// caller.
    var load: Double?
    var source: String?
    /// Off by default. A route traced from someone's front door is exactly the
    /// thing not to post, so including it is a decision rather than a default.
    var includeRoute: Bool = false

    static let size = CGSize(width: 1080, height: 1350)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsRoute {
                RouteShape(coordinates: coordinates)
                    .stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round,
                                                       lineJoin: .round))
                    .padding(28)
                    .frame(height: 430)
            } else {
                Spacer(minLength: 0)
            }
            stats
            if !splits.isEmpty {
                splitChart
            } else if !showsRoute {
                // Balance the spacer above, so a card with neither a route nor
                // splits centres its numbers instead of leaving a void in the
                // middle and the stats pinned near the bottom.
                Spacer(minLength: 0)
            }
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            LinearGradient(colors: [Color(red: 0.08, green: 0.11, blue: 0.20),
                                    Color(red: 0.16, green: 0.09, blue: 0.26)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .foregroundStyle(.white)
    }

    private var showsRoute: Bool {
        includeRoute && RouteGeometry.isDrawable(coordinates)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Image(systemName: workout.sport.symbolName)
                    .font(.system(size: 44, weight: .semibold))
                Text(workout.sport.displayName.uppercased())
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .tracking(4)
                Spacer()
            }
            Text(workout.startedAt.formatted(date: .complete, time: .shortened))
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(.horizontal, 56)
        .padding(.top, 56)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                bigStat(units.autoDistance(workout.distance), "distance")
                Spacer()
                bigStat(units.duration(workout.duration), "time")
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                bigStat(paceText, paceLabel)
                Spacer()
                if let hr = workout.avgHeartRate {
                    bigStat("\(hr)", "avg bpm")
                } else if let gain = workout.elevationGain, gain > 0 {
                    bigStat(units.elevation(gain), "climb")
                }
            }
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 30)
    }

    private func bigStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 76, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(label.uppercased())
                .font(.system(size: 22, weight: .semibold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    /// Splits as bars, shortest bar for the fastest — the shape of the session
    /// at a glance, which a table of numbers isn't.
    private var splitChart: some View {
        Chart(splits) { split in
            BarMark(
                x: .value("Split", split.label),
                y: .value("Pace", units.paceValue(split.paceSecPerKm) ?? 0))
                .foregroundStyle(.white.opacity(split.isPartial ? 0.35 : 0.8))
                .cornerRadius(4)
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        // Pace: lower is faster, so the axis runs the other way and a short
        // bar reads as a quick split.
        .chartYScale(domain: .automatic(includesZero: false, reversed: true))
        .frame(height: 210)
        .padding(.horizontal, 56)
    }

    private var footer: some View {
        HStack {
            if let load, load > 0 {
                Text("LOAD \(Int(load.rounded()))")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(2)
            }
            Spacer()
            if let source, !source.isEmpty {
                Text(source.uppercased())
                    .font(.system(size: 22, weight: .medium))
                    .tracking(2)
            }
        }
        .foregroundStyle(.white.opacity(0.45))
        .padding(.horizontal, 56)
        .padding(.bottom, 48)
        .padding(.top, 18)
    }

    // MARK: - Text

    private var paceText: String {
        guard workout.distance > 0, workout.duration > 0 else { return "–" }
        return units.rate(workout.duration / (workout.distance / 1000),
                          sport: workout.sport)
    }

    private var paceLabel: String {
        "avg " + units.rateLabel(for: workout.sport).lowercased()
    }
}

/// The stored polyline, fitted to the frame.
struct RouteShape: Shape {
    let coordinates: [[Double]]

    func path(in rect: CGRect) -> Path {
        let points = RouteGeometry.path(for: coordinates, in: rect)
        guard let first = points.first else { return Path() }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}
