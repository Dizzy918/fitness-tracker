import SwiftUI
import SwiftData
import Charts

struct RecoveryView: View {
    @Environment(\.units) private var units
    @Environment(\.modelContext) private var context
    @Query(sort: \DailyMetric.date, order: .reverse) private var metrics: [DailyMetric]
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]

    @Query private var strengthSessions: [StrengthSession]

    @State private var showCheckIn = false
    @State private var importing = false
    @State private var message: String?
    @State private var messageTitle = ""

    /// Scoring walks the whole metric history and the training-load curve
    /// decodes every sample stream. Both are computed once per data change
    /// instead of on every layout pass — `body` used to trigger four full
    /// rescores each time SwiftUI measured the view.
    @State private var result = Readiness.Result(
        score: 0, band: .moderate, contributions: [], confidence: 0, missing: []
    )
    @State private var training = TrainingState()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    readinessCard
                    if !todayContributions.isEmpty { breakdown }
                    checkInPrompt
                    if metrics.count >= 2 { trends }
                    disclaimer
                }
                .padding()
            }
            .navigationTitle("Recovery")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showCheckIn = true
                        } label: {
                            Label("Daily check-in", systemImage: "square.and.pencil")
                        }
                        if HealthKitReader.isAvailable {
                            Button {
                                Task { await importHealth() }
                            } label: {
                                Label(importing ? "Importing…" : "Import from Health",
                                      systemImage: "heart.text.square")
                            }
                            .disabled(importing)
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .task(id: reloadToken) { await reload() }
            .sheet(isPresented: $showCheckIn) { CheckInSheet() }
            .alert(messageTitle, isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } }
            )) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    // MARK: - Readiness

    private var today: Date { Calendar.current.startOfDay(for: .now) }

    /// Matched by day range rather than exact equality: a stored start-of-day
    /// from another time zone won't compare equal to today's, which used to hide
    /// the current row after travel and let a second one be created for it.
    private var todayMetric: DailyMetric? {
        let calendar = Calendar.current
        return metrics.first { calendar.isDate($0.date, inSameDayAs: today) }
    }

    private var todayContributions: [Readiness.Contribution] {
        result.contributions
    }

    private var reloadToken: String {
        "\(metrics.count)-\(workouts.count)-\(strengthSessions.count)-\(todayMetric?.snapshot.hashValue ?? 0)"
    }

    private func reload() async {
        let snapshots = workouts.map(\.snapshot)
        let strength = strengthSessions.map(\.snapshot)
        let history = metrics.map(\.snapshot)
        let day = todayMetric?.snapshot ?? MetricSnapshot(date: today)
        let restingHR = metrics.first(where: { $0.restingHR != nil })?.restingHR
        let athlete = AthleteProfile.make(workouts: snapshots, restingHR: restingHR)

        let state = await Task.detached(priority: .userInitiated) {
            TrainingState.build(workouts: snapshots, strength: strength, athlete: athlete)
        }.value

        training = state
        // Acute:chronic now comes from multi-sport training stress, so a hard
        // ride or lifting session costs readiness the way it should.
        result = Readiness.score(day: day, history: history,
                                 loadRatio: state.acuteChronicRatio)
    }

    private var readinessCard: some View {
        let r = result
        return VStack(alignment: .leading, spacing: 12) {
            Text("Today").font(.headline)

            if r.isReliable {
                HStack(spacing: 20) {
                    ReadinessRing(score: r.score, band: r.band)
                        .frame(width: 120, height: 120)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(r.band.label)
                            .font(.title3.weight(.semibold))
                        Text(r.band.guidance)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if r.confidence < 0.7 {
                            Text("Based on \(Int(r.confidence * 100))% of inputs")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Readiness \(r.score) out of 100, \(r.band.label)")
            } else {
                ContentUnavailableView {
                    Label("Not enough data yet", systemImage: "waveform.path.ecg")
                } description: {
                    Text(HealthKitReader.isAvailable
                         ? "Import from Health or do a daily check-in to get a readiness score."
                         : "Do a daily check-in to get a readiness score. (Health data is iOS-only.)")
                }
            }
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What drove it").font(.headline)
            ForEach(todayContributions) { c in
                HStack(spacing: 10) {
                    Text(c.component.displayName)
                        .font(.subheadline)
                        .frame(width: 110, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.quaternary)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(color(for: c.subscore))
                                .frame(width: max(4, geo.size.width * c.subscore))
                        }
                    }
                    .frame(height: 14)

                    Text(c.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(c.component.displayName): \(Int(c.subscore * 100)) percent, \(c.detail)")
            }

            if !result.missing.isEmpty {
                Text("Missing: " + result.missing.map(\.displayName).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func color(for subscore: Double) -> Color {
        switch subscore {
        case ..<0.4:  return .red
        case ..<0.6:  return .orange
        case ..<0.8:  return .yellow
        default:      return .green
        }
    }

    private var checkInPrompt: some View {
        Group {
            if todayMetric?.hasCheckIn != true {
                Button {
                    showCheckIn = true
                } label: {
                    HStack {
                        Image(systemName: "square.and.pencil")
                        VStack(alignment: .leading) {
                            Text("How do you feel today?").font(.subheadline.weight(.medium))
                            Text("Four taps. Sharpens the score.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .padding()
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Trends

    private var trends: some View {
        VStack(alignment: .leading, spacing: 20) {
            metricChart(title: "HRV (SDNN)", unit: "ms", values: metrics.compactMap { m in
                m.hrvSDNN.map { (m.date, $0) }
            }, color: .purple)

            metricChart(title: "Resting heart rate", unit: "bpm", values: metrics.compactMap { m in
                m.restingHR.map { (m.date, $0) }
            }, color: .red)

            metricChart(title: "Sleep", unit: "h", values: metrics.compactMap { m in
                m.sleepHours.map { (m.date, $0) }
            }, color: .indigo)

            metricChart(title: "Weight", unit: units.weightUnit, values: metrics.compactMap { m in
                m.weightKg.map { (m.date, units.displayedWeight(fromKilograms: $0)) }
            }, color: .teal)
        }
    }

    @ViewBuilder
    private func metricChart(title: String, unit: String,
                             values: [(Date, Double)], color: Color) -> some View {
        if values.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if let latest = values.first {
                        Text(String(format: "%.1f %@", latest.1, unit))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Chart {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, point in
                        LineMark(x: .value("Date", point.0), y: .value(unit, point.1))
                            .foregroundStyle(color)
                            .interpolationMethod(.monotone)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 130)
                .accessibilityLabel("\(title) trend over \(values.count) days")
            }
        }
    }

    private var disclaimer: some View {
        Text("""
            Readiness is a heuristic over your own recent trends — not a medical \
            measurement. Treat it as one input alongside how you actually feel.
            """)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }

    private func importHealth() async {
        importing = true
        defer { importing = false }
        do {
            let days = try await HealthKitReader().importMetrics(days: 60, into: context)
            messageTitle = "Health import"
            message = days > 0
                ? "Updated \(days) days of metrics."
                : "No health data found. Check permissions in Settings → Privacy → Health."
        } catch {
            messageTitle = "Health import failed"
            message = error.localizedDescription
        }
    }
}

/// Score dial. Uses a 270° arc so the gap reads as "empty" rather than looking
/// like a full ring at a low score.
struct ReadinessRing: View {
    let score: Int
    let band: Readiness.Band

    private var color: Color {
        switch band {
        case .rest:     return .red
        case .easy:     return .orange
        case .moderate: return .green
        case .primed:   return .mint
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 14, lineCap: .round))
            Circle()
                .trim(from: 0, to: 0.75 * Double(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("readiness").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .rotationEffect(.degrees(135))   // start the arc bottom-left
        .compositingGroup()
    }
}
