import SwiftUI
import SwiftData
import Charts

/// Races, and what shape the plan says you'll arrive in.
struct SeasonView: View {
    @Environment(\.units) private var units
    @Environment(\.modelContext) private var context

    @Query(sort: \Race.date) private var races: [Race]
    @Query(sort: \PlannedWorkout.scheduledFor) private var planned: [PlannedWorkout]
    @Query(sort: \Workout.startedAt) private var workouts: [Workout]
    @Query(sort: \StrengthSession.startedAt) private var strength: [StrengthSession]
    @Query(sort: \DailyMetric.date, order: .reverse) private var metrics: [DailyMetric]

    @State private var editing: Race?
    @State private var history: [TrainingLoad.Point] = []
    @State private var loading = true

    private var split: (upcoming: [RaceSnapshot], past: [RaceSnapshot]) {
        SeasonPlan.split(races.map(\.snapshot))
    }

    private var focus: Race? {
        guard let snapshot = SeasonPlan.focus(among: races.map(\.snapshot)) else { return nil }
        return races.first { $0.id == snapshot.id }
    }

    var body: some View {
        List {
            if races.isEmpty {
                emptyState
            } else {
                if let focus { focusSection(focus) }

                let upcoming = split.upcoming
                if upcoming.count > 1 || (focus == nil && !upcoming.isEmpty) {
                    Section("Upcoming") {
                        ForEach(upcoming.filter { $0.id != focus?.id }) { snapshot in
                            raceRow(snapshot)
                        }
                    }
                }

                if !split.past.isEmpty {
                    Section("Done") {
                        ForEach(split.past) { raceRow($0) }
                    }
                }
            }
        }
        .navigationTitle("Season")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { create() } label: { Label("Add a race", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { RaceEditor(race: $0) }
        .task(id: workouts.count + strength.count) { await loadHistory() }
    }

    // MARK: - Sections

    private var emptyState: some View {
        Section {
            ContentUnavailableView {
                Label("No races", systemImage: "flag.checkered")
            } description: {
                Text("The fitness and fatigue curves say what shape you're in today. Give them a date to aim at and they'll say what shape you'll be in on the day.")
            } actions: {
                Button("Add a race") { create() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func focusSection(_ race: Race) -> some View {
        let days = race.daysAway()
        let projection = SeasonPlan.project(
            history: history,
            plans: planned.map(\.snapshot),
            through: race.date)

        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(days)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(days == 1 ? "day to go" : "days to go")
                            .font(.subheadline)
                        Text(race.date.formatted(date: .complete, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(race.displayName).font(.headline)
                if let goal = goalText(for: race) {
                    Text(goal).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            if let arrival = projection.arrival, let verdict = projection.verdict() {
                arrivalRow(arrival: arrival, verdict: verdict,
                           retained: projection.fitnessRetained,
                           isMostlyAssumed: projection.isMostlyAssumed)
            } else if loading {
                Text("Working out the projection…").foregroundStyle(.secondary)
            } else if history.isEmpty {
                Text("Import or log some training and the projection will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !projection.points.isEmpty {
                projectionChart(projection, race: race)
            }

            if let taper = race.taperStart() {
                LabeledContent("Taper starts",
                               value: taper.formatted(date: .abbreviated, time: .omitted))
                    .font(.callout)
            }

            Button { editing = race } label: {
                Label("Edit race", systemImage: "pencil")
            }
        } header: {
            Text(race.priority == .a ? "Goal race" : "Next up")
        }
    }

    @ViewBuilder
    private func arrivalRow(arrival: TrainingLoad.Point,
                            verdict: SeasonPlan.TaperVerdict,
                            retained: Double?,
                            isMostlyAssumed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(verdict.label, systemImage: verdict.isGood
                      ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.headline)
                    .foregroundStyle(verdict.isGood ? Color.green : Color.orange)
                Spacer()
                Text("form \(Fmt.signed(arrival.form))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(verdict.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Text("Fitness \(Int(arrival.fitness.rounded()))")
                Text("Fatigue \(Int(arrival.fatigue.rounded()))")
                if let retained {
                    // The number the verdict actually turns on, so "Losing
                    // fitness" next to a healthy-looking form isn't a mystery.
                    Text("\(Int((retained * 100).rounded()))% of today's fitness")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)

            if isMostlyAssumed {
                // Said plainly, because otherwise the number looks like a
                // forecast about the athlete when it's a statement about an
                // empty calendar.
                Label("Most of those days have nothing planned, so this assumes you rest through them.",
                      systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func projectionChart(_ projection: SeasonPlan.Projection, race: Race) -> some View {
        // A tail of real history so the projection is read as a continuation
        // rather than as a separate claim.
        let tail = history.suffix(28)
        Chart {
            ForEach(Array(tail)) { point in
                LineMark(x: .value("Date", point.date),
                         y: .value("Fitness", point.fitness),
                         series: .value("Series", "Fitness"))
                    .foregroundStyle(.blue)
                LineMark(x: .value("Date", point.date),
                         y: .value("Fatigue", point.fatigue),
                         series: .value("Series", "Fatigue"))
                    .foregroundStyle(.orange)
            }
            ForEach(projection.points) { point in
                LineMark(x: .value("Date", point.date),
                         y: .value("Fitness", point.fitness),
                         series: .value("Series", "Projected fitness"))
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                LineMark(x: .value("Date", point.date),
                         y: .value("Fatigue", point.fatigue),
                         series: .value("Series", "Projected fatigue"))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            if let today = history.last {
                RuleMark(x: .value("Today", today.date))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top, alignment: .leading) {
                        Text("today").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            RuleMark(x: .value("Race", race.date))
                .foregroundStyle(.green.opacity(0.6))
        }
        .chartLegend(position: .bottom, spacing: 6)
        .frame(height: 200)
        .padding(.vertical, 4)
    }

    private func raceRow(_ snapshot: RaceSnapshot) -> some View {
        Button {
            editing = races.first { $0.id == snapshot.id }
        } label: {
            HStack(spacing: 10) {
                Text(snapshot.priority.shortName)
                    .font(.caption.weight(.bold))
                    .frame(width: 22, height: 22)
                    .background(priorityColor(snapshot.priority).opacity(0.18), in: .circle)
                    .foregroundStyle(priorityColor(snapshot.priority))

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.name)
                    Text(subtitle(for: snapshot))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: snapshot.sport.symbolName)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) {
                if let race = races.first(where: { $0.id == snapshot.id }) {
                    context.delete(race)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Helpers

    private func priorityColor(_ priority: Race.Priority) -> Color {
        switch priority {
        case .a: return .red
        case .b: return .orange
        case .c: return .secondary
        }
    }

    private func subtitle(for snapshot: RaceSnapshot) -> String {
        var parts = [snapshot.date.formatted(date: .abbreviated, time: .omitted)]
        if let distance = snapshot.distance, distance > 0 {
            parts.append(units.autoDistance(distance))
        }
        if let goal = snapshot.goalDuration, goal > 0 {
            parts.append("goal " + units.duration(goal))
        }
        return parts.joined(separator: " · ")
    }

    /// Swimmers read per 100 m, everyone else per km or mile.
    private func paceText(_ secondsPerKm: Double, sport: WorkoutSport) -> String {
        sport == .swim ? units.swimPace(secondsPerKm / 10) : units.pace(secondsPerKm)
    }

    private func goalText(for race: Race) -> String? {
        var parts: [String] = []
        if let distance = race.distance, distance > 0 {
            parts.append(units.autoDistance(distance))
        }
        if let goal = race.goalDuration, goal > 0 {
            parts.append("goal " + units.duration(goal))
            if let pace = race.goalPace {
                parts.append(paceText(pace, sport: race.sport))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func create() {
        let race = Race(date: Calendar.current.date(byAdding: .month, value: 3, to: .now) ?? .now)
        context.insert(race)
        editing = race
    }

    /// The actual series, computed off the main actor — it walks every day
    /// since the first workout.
    private func loadHistory() async {
        let workoutSnapshots = workouts.map(\.snapshot)
        let strengthSnapshots = strength.map(\.snapshot)
        let restingHR = metrics.compactMap(\.restingHR).first
        let athlete = AthleteProfile.make(workouts: workoutSnapshots, restingHR: restingHR)

        let points = await Task.detached(priority: .userInitiated) {
            let totals = TrainingLoad.dailyTotals(
                workouts: workoutSnapshots, strength: strengthSnapshots, athlete: athlete)
            return TrainingLoad.series(dailyTotals: totals)
        }.value

        history = points
        loading = false
    }
}

// MARK: - Editing

struct RaceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units
    @Environment(\.modelContext) private var context

    @Bindable var race: Race

    /// Common distances, so nobody types 42195.
    private static let presets: [(String, Double)] = [
        ("5 km", 5_000), ("10 km", 10_000), ("Half", 21_097.5),
        ("Marathon", 42_195), ("50 km", 50_000), ("100 km", 100_000),
    ]

    private var goalHours: Binding<Double> {
        Binding(
            get: { (race.goalDuration ?? 0) / 3600 },
            set: { race.goalDuration = $0 <= 0 ? nil : $0 * 3600 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Berlin Marathon", text: $race.name)
                    DatePicker("Date", selection: $race.date,
                               displayedComponents: .date)
                    Picker("Sport", selection: $race.sport) {
                        ForEach(WorkoutSport.allCases, id: \.self) { sport in
                            Text(sport.displayName).tag(sport)
                        }
                    }
                }

                Section {
                    Picker("Priority", selection: $race.priority) {
                        ForEach(Race.Priority.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Priority")
                } footer: {
                    Text(race.priority.taperDays > 0
                         ? "Plans a \(race.priority.taperDays)-day taper before this date."
                         : "No taper — this one is a hard training day with a number on your chest.")
                }

                Section("Distance") {
                    Picker("Preset", selection: Binding(
                        get: { race.distance ?? 0 },
                        set: { race.distance = $0 <= 0 ? nil : $0 }
                    )) {
                        Text("Not set").tag(0.0)
                        ForEach(Self.presets, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    if let distance = race.distance, distance > 0 {
                        LabeledContent("Distance", value: units.autoDistance(distance))
                    }
                }

                Section {
                    HStack {
                        Text("Goal time")
                        Spacer()
                        Text(race.goalDuration.map { units.duration($0) } ?? "Not set")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: goalHours, in: 0...12, step: 1.0 / 60)
                    if let pace = race.goalPace {
                        LabeledContent("Goal pace",
                                       value: paceText(pace, sport: race.sport))
                    }
                } footer: {
                    Text("Optional. Used to show the pace the goal implies.")
                }

                if race.daysAway() <= 0 {
                    Section("Result") {
                        HStack {
                            Text("Finish time")
                            Spacer()
                            Text(race.resultDuration.map { units.duration($0) } ?? "Not entered")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { (race.resultDuration ?? 0) / 3600 },
                            set: { race.resultDuration = $0 <= 0 ? nil : $0 * 3600 }
                        ), in: 0...12, step: 1.0 / 60)
                        if let delta = race.resultVersusGoal {
                            LabeledContent(
                                delta <= 0 ? "Under goal" : "Over goal",
                                value: units.duration(abs(delta)))
                                .foregroundStyle(delta <= 0 ? Color.green : Color.orange)
                        }
                    }
                }

                Section("Notes") {
                    TextField("Course, conditions, plan…", text: Binding(
                        get: { race.notes ?? "" },
                        set: { race.notes = $0.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                }
            }
            .navigationTitle(race.name.isEmpty ? "New Race" : race.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { dismiss() }
                }
            }
        }
    }

    private func paceText(_ secondsPerKm: Double, sport: WorkoutSport) -> String {
        sport == .swim ? units.swimPace(secondsPerKm / 10) : units.pace(secondsPerKm)
    }

    /// A brand-new race abandoned without a name shouldn't persist as a blank
    /// row on the calendar.
    private func cancel() {
        if race.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && race.distance == nil && race.goalDuration == nil && race.notes == nil {
            context.delete(race)
        }
        dismiss()
    }
}
