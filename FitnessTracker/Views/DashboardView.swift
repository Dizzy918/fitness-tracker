import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Environment(\.units) private var units

    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]
    @Query(filter: #Predicate<Shoe> { $0.retiredAt == nil }) private var shoes: [Shoe]
    @Query private var strengthSessions: [StrengthSession]
    @Query(sort: \DailyMetric.date, order: .reverse) private var metrics: [DailyMetric]
    @Query(sort: \PlannedWorkout.scheduledFor) private var plannedWorkouts: [PlannedWorkout]

    /// Training load decodes every sample stream, so it's computed off the main
    /// actor once per data change rather than inside `body`.
    @State private var training = TrainingState()
    /// Whether the curve is still being built.
    ///
    /// Without this the section says "No scored sessions yet" while it works,
    /// which isn't a missing spinner — it's a false statement about the
    /// athlete's data, shown for however long the first build takes.
    @State private var buildingTrainingState = true
    @State private var planWeek = TrainingPlan.Week(start: .now)

    var body: some View {
        NavigationStack {
            ScrollView {
                if workouts.isEmpty {
                    ContentUnavailableView(
                        "Nothing to chart yet",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Import workouts or seed demo data first.")
                    )
                    .padding(.top, 60)
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        thisWeek
                        planLink
                        intensityLink
                        durationCurveLink
                        recordsLink
                        shoesLink
                        loadSection
                        if let week = training.currentStrain { strainSection(week) }
                        weeklyMileageChart
                        paceTrendChart
                        if !shoeWarnings.isEmpty { shoeWarningSection }
                    }
                    .padding()
                }
            }
            .navigationTitle("Dashboard")
            .task(id: reloadToken) { await reloadTrainingState() }
        }
    }

    /// Changes whenever anything load-bearing changes, so the curve recomputes
    /// after a sync or an import but not on every unrelated redraw.
    private var reloadToken: String {
        "\(workouts.count)-\(strengthSessions.count)-\(plannedWorkouts.count)-\(workouts.first?.id.uuidString ?? "")"
    }

    private func reloadTrainingState() async {
        // Snapshot on the main actor: SwiftData models can't cross actors.
        //
        // Streams are external storage, so building a full snapshot reads a
        // file per workout — right here, on the main actor, before any of the
        // work is handed off. That is what used to leave this screen blank
        // rather than merely slow. Only workouts the cache can't already answer
        // need theirs.
        let restingHR = metrics.first(where: { $0.restingHR != nil })?.restingHR
        let athlete = AthleteProfile.make(workouts: workouts.map(\.lightSnapshot),
                                          restingHR: restingHR)
        let cache = TrainingLoad.ScoreCache.shared
        let snapshots = workouts.map { workout -> WorkoutSnapshot in
            let light = workout.lightSnapshot
            return cache.canAnswer(light, athlete: athlete) ? light : workout.snapshot
        }
        let strength = strengthSessions.map(\.snapshot)
        let plans = plannedWorkouts.map(\.snapshot)
        buildingTrainingState = true
        defer { buildingTrainingState = false }

        let built = await Task.detached(priority: .userInitiated) {
            (TrainingState.build(workouts: snapshots, strength: strength, athlete: athlete),
             TrainingPlan.week(containing: .now, planned: plans,
                               workouts: snapshots, athlete: athlete))
        }.value
        training = built.0
        planWeek = built.1
    }

    // MARK: - This week

    private var thisWeek: some View {
        let cal = Calendar.current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        let thisWeekRuns = workouts.filter { $0.startedAt >= weekStart }
        let km = thisWeekRuns.reduce(0) { $0 + $1.distance }
        let time = thisWeekRuns.reduce(0) { $0 + $1.duration }
        let gain = thisWeekRuns.reduce(0.0) { $0 + ($1.elevationGain ?? 0) }

        return VStack(alignment: .leading, spacing: 8) {
            Text("This week").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                StatTile(label: "Distance", value: units.distance(km))
                StatTile(label: "Time", value: units.duration(time))
                StatTile(label: "Sessions", value: "\(thisWeekRuns.count)")
                StatTile(label: "Elev gain", value: units.elevation(gain))
            }
        }
    }

    private var planLink: some View {
        NavigationLink {
            PlanView()
        } label: {
            HStack {
                Image(systemName: "calendar")
                Text("Plan").font(.subheadline.weight(.medium))
                Spacer()
                if outstandingThisWeek > 0 {
                    Text("\(outstandingThisWeek) to go")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.forward").font(.caption)
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    /// Planned sessions left this week, so the row is worth glancing at.
    ///
    /// Comes from the matched week rather than the plans' stored flags: matching
    /// is inferred at read time, so a plan you already fulfilled still has no
    /// completedWorkoutID and would otherwise be nagged about all week.
    private var outstandingThisWeek: Int { planWeek.outstandingCount }

    private var intensityLink: some View {
        NavigationLink {
            IntensityView()
        } label: {
            HStack {
                Image(systemName: "chart.bar.doc.horizontal")
                Text("Intensity distribution").font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: "chevron.forward").font(.caption)
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var durationCurveLink: some View {
        NavigationLink {
            DurationCurveView()
        } label: {
            HStack {
                Image(systemName: "chart.xyaxis.line")
                Text("Duration curve").font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: "chevron.forward").font(.caption)
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var recordsLink: some View {
        NavigationLink {
            RecordsView()
        } label: {
            HStack {
                Image(systemName: "trophy")
                Text("Personal records").font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: "chevron.forward").font(.caption)
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var shoesLink: some View {
        NavigationLink {
            ShoeListView()
        } label: {
            HStack {
                Image(systemName: "shoe")
                Text("Shoes & gear").font(.subheadline.weight(.medium))
                Spacer()
                if !shoeWarnings.isEmpty {
                    Text("\(shoeWarnings.count) worn")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Image(systemName: "chevron.forward").font(.caption)
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Fitness, fatigue, form

    /// Training stress across every sport, not distance.
    ///
    /// The previous version summed raw metres, which made an 80 km ride worth
    /// four hard runs and a brutal 2 km swim worth nothing. This is the standard
    /// impulse-response model over per-session TSS: fitness is a 42-day
    /// exponential average, fatigue a 7-day one, form the gap between them.
    @ViewBuilder
    /// Foster's monotony and strain for the week just gone.
    ///
    /// Sits under the fitness curves because it answers the question they
    /// can't: two weeks with the same total load can be a well-shaped week and
    /// a grinding one, and only this tells them apart.
    private func strainSection(_ week: TrainingStrain.Week) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Week shape").font(.headline)
                Spacer()
                Text(week.verdict.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(week.verdict == .undifferentiated ? .orange : .secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                StatTile(label: "Monotony", value: String(format: "%.2f", week.monotony))
                StatTile(label: "Strain", value: "\(Int(week.strain.rounded()))")
                StatTile(label: "Rest days", value: "\(week.restDays)")
            }
            Text(week.verdict.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Fitness & fatigue").font(.headline)
                Spacer()
                if let ramp = training.weeklyRamp, training.isEstablished {
                    Text("\(Fmt.signed(ramp))/week")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ramp > 7 ? .orange : .secondary)
                }
            }

            if buildingTrainingState && training.today == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Working out your fitness and fatigue…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if training.today == nil {
                Text("No scored sessions yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    StatTile(label: "Fitness (42d)",
                             value: String(format: "%.0f", training.fitness))
                    StatTile(label: "Fatigue (7d)",
                             value: String(format: "%.0f", training.fatigue))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Form").font(.caption).foregroundStyle(.secondary)
                        Text(Fmt.signed(training.form))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                        Text(training.verdict.label)
                            .font(.caption2).foregroundStyle(formColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(formColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }

                Text(training.verdict.guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !training.isEstablished {
                    Text("Still warming up — the 42-day average needs about three weeks of history before it settles.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if training.estimatedSessionCount > 0 {
                    Text("\(training.estimatedSessionCount) session\(training.estimatedSessionCount == 1 ? "" : "s") this week had no power or heart rate, so its load is estimated from duration.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                loadChart
            }
        }
    }

    private var formColor: Color {
        switch training.verdict {
        case .fresh:        return .blue
        case .neutral:      return .secondary
        case .productive:   return .green
        case .overreaching: return .red
        }
    }

    /// The last 120 days of the curve — far enough back to show a build and a
    /// taper, close enough that the current block is still readable.
    private var loadChart: some View {
        let window = Array(training.series.suffix(120))
        return Chart {
            ForEach(window) { point in
                AreaMark(x: .value("Date", point.date),
                         y: .value("Fitness", point.fitness))
                    .foregroundStyle(.blue.opacity(0.15))
            }
            ForEach(window) { point in
                LineMark(x: .value("Date", point.date),
                         y: .value("Fitness", point.fitness),
                         series: .value("Series", "Fitness"))
                    .foregroundStyle(.blue)
            }
            ForEach(window) { point in
                LineMark(x: .value("Date", point.date),
                         y: .value("Fatigue", point.fatigue),
                         series: .value("Series", "Fatigue"))
                    .foregroundStyle(.pink)
            }
        }
        .chartForegroundStyleScale(["Fitness": Color.blue, "Fatigue": Color.pink])
        .frame(height: 160)
        .accessibilityLabel("Fitness and fatigue over the last \(window.count) days")
    }

    // MARK: - Charts

    private struct WeekBucket: Identifiable {
        let weekStart: Date
        let km: Double
        var id: Date { weekStart }
    }

    private var weeklyBuckets: [WeekBucket] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: workouts) { w in
            cal.dateInterval(of: .weekOfYear, for: w.startedAt)?.start ?? w.startedAt
        }
        return grouped
            .map { WeekBucket(weekStart: $0.key, km: $0.value.reduce(0) { $0 + $1.distanceKm }) }
            .sorted { $0.weekStart < $1.weekStart }
    }

    private var weeklyMileageChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weekly volume").font(.headline)
            Chart(weeklyBuckets) { bucket in
                BarMark(
                    x: .value("Week", bucket.weekStart, unit: .weekOfYear),
                    y: .value(units.distanceUnit, displayDistance(bucket.km * 1000))
                )
                .foregroundStyle(.tint)
            }
            .chartYAxisLabel(units.distanceUnit)
            .frame(height: 180)
        }
    }

    private var paceTrendChart: some View {
        // Only flat road runs — trail pace would muddy the trend.
        let roadRuns = workouts
            .filter { $0.sport == .run }
            .compactMap { w -> (Date, Double)? in
                guard let pace = w.paceSecPerKm else { return nil }
                return (w.startedAt, pace)
            }
            .sorted { $0.0 < $1.0 }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Road pace trend").font(.headline)
            if roadRuns.count < 2 {
                Text("Need at least two road runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(Array(roadRuns.enumerated()), id: \.offset) { _, point in
                        PointMark(
                            x: .value("Date", point.0),
                            y: .value("Pace", (units.paceValue(point.1) ?? point.1) / 60)
                        )
                        .foregroundStyle(.secondary)
                    }
                    ForEach(Array(movingAverage(roadRuns, window: 5).enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Date", point.0),
                            y: .value("Pace", (units.paceValue(point.1) ?? point.1) / 60)
                        )
                        .foregroundStyle(.tint)
                        .interpolationMethod(.monotone)
                    }
                }
                .chartYAxisLabel("min/\(units.paceUnit)")
                // Faster is better, so invert the axis: down = slower.
                .chartYScale(domain: .automatic(reversed: true))
                .frame(height: 180)
            }
        }
    }

    private func movingAverage(_ points: [(Date, Double)], window: Int) -> [(Date, Double)] {
        guard points.count >= window else { return points }
        return (0...(points.count - window)).map { i in
            let slice = points[i..<(i + window)]
            let avg = slice.reduce(0.0) { $0 + $1.1 } / Double(window)
            return (slice[slice.startIndex + window / 2].0, avg)
        }
    }

    // MARK: - Shoes

    /// Metres in, chart-axis number out.
    private func displayDistance(_ meters: Double) -> Double {
        units.system == .metric ? meters / 1000 : meters / UnitConversion.metersPerMile
    }

    private var shoeWarnings: [Shoe] {
        shoes.filter { $0.wearFraction > 0.85 }
    }

    private var shoeWarningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shoe alerts").font(.headline)
            ForEach(shoeWarnings) { shoe in
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(shoe.displayName) at \(Int(shoe.totalDistanceKm)) km")
                    Spacer()
                    Text("\(Int(shoe.wearFraction * 100))%")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
    }
}
