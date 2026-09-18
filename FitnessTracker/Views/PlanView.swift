import SwiftUI
import SwiftData

/// A week of plan against a week of training.
///
/// One week at a time on purpose. A month view invites planning further ahead
/// than anyone's form can be predicted, and the useful question is always the
/// same one: what's left this week, and am I keeping up.
struct PlanView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.units) private var units

    @Query(sort: \PlannedWorkout.scheduledFor) private var planned: [PlannedWorkout]
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]
    @Query(sort: \DailyMetric.date, order: .reverse) private var metrics: [DailyMetric]
    @Query(sort: \Race.date) private var races: [Race]

    @State private var weekOffset = 0
    @State private var week = TrainingPlan.Week(start: .now)
    @State private var ramp: TrainingPlan.RampVerdict?
    @State private var editing: PlannedWorkout?
    @State private var creatingOn: Date?

    private var calendar: Calendar { .current }

    private var weekStart: Date {
        let base = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        return calendar.date(byAdding: .weekOfYear, value: weekOffset, to: base) ?? base
    }

    private var days: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    /// The link doubles as the countdown, so the goal race is visible from the
    /// week view without a second screen.
    private var seasonLabel: String {
        guard let focus = SeasonPlan.focus(among: races.map(\.snapshot)) else {
            return "Season & races"
        }
        let days = Calendar.current.dateComponents(
            [.day], from: calendar.startOfDay(for: .now),
            to: calendar.startOfDay(for: focus.date)).day ?? 0
        if days == 0 { return "\(focus.name) — today" }
        return "\(focus.name) — \(days) \(days == 1 ? "day" : "days")"
    }

    var body: some View {
        List {
            weekHeader

            ForEach(days, id: \.self) { day in
                Section {
                    let entries = week.entries.filter {
                        calendar.isDate($0.planned.scheduledFor, inSameDayAs: day)
                    }
                    let extras = week.unplanned.filter {
                        calendar.isDate($0.startedAt, inSameDayAs: day)
                    }

                    if entries.isEmpty && extras.isEmpty {
                        Button { creatingOn = day } label: {
                            Label("Add a session", systemImage: "plus.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(entries) { entry in
                            Button {
                                editing = plannedModel(for: entry.planned.id)
                            } label: {
                                PlanEntryRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(entry.planned.id)
                                } label: { Label("Delete", systemImage: "trash") }

                                if entry.planned.isOutstanding {
                                    Button {
                                        skip(entry.planned.id)
                                    } label: { Label("Skip", systemImage: "moon.zzz") }
                                    .tint(.orange)
                                }
                            }
                        }
                        ForEach(extras, id: \.id) { workout in
                            UnplannedRow(workout: workout)
                        }
                    }
                } header: {
                    HStack {
                        Text(day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                        if calendar.isDateInToday(day) {
                            Text("today")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.tint, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Button { creatingOn = day } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle("Plan")
        .safeAreaInset(edge: .bottom) {
            NavigationLink { SeasonView() } label: {
                Label(seasonLabel, systemImage: "flag.checkered")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { weekOffset -= 1 } label: { Image(systemName: "chevron.left") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { weekOffset += 1 } label: { Image(systemName: "chevron.right") }
            }
            if weekOffset != 0 {
                ToolbarItem(placement: .principal) {
                    Button("This week") { weekOffset = 0 }
                }
            }
        }
        .task(id: reloadToken) { await reload() }
        .sheet(item: $editing) { PlannedWorkoutEditor(existing: $0, day: $0.scheduledFor) }
        .sheet(item: $creatingOn) { day in
            PlannedWorkoutEditor(existing: nil, day: day)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var weekHeader: some View {
        Section {
            HStack(spacing: 12) {
                StatTile(label: "Planned", value: loadText(week.plannedLoad))
                StatTile(label: "Done", value: loadText(week.completedLoad))
                if let fraction = week.completionFraction {
                    StatTile(label: "Progress", value: "\(Int((fraction * 100).rounded()))%")
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

            if let ramp {
                VStack(alignment: .leading, spacing: 3) {
                    Label(ramp.label, systemImage: rampSymbol(ramp))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(rampColor(ramp))
                    Text(ramp.guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text(weekOffset == 0 ? "This week" : weekStart.formatted(
                .dateTime.day().month(.wide).year()))
        } footer: {
            Text(week.summary + " Load is training stress — the same scale the Dashboard uses.")
        }
    }

    private func loadText(_ value: Double) -> String {
        value > 0 ? "\(Int(value.rounded()))" : "–"
    }

    private func rampSymbol(_ verdict: TrainingPlan.RampVerdict) -> String {
        switch verdict {
        case .light:       return "arrow.down.circle"
        case .sustainable: return "checkmark.circle"
        case .ambitious:   return "arrow.up.circle"
        case .reckless:    return "exclamationmark.triangle"
        }
    }

    private func rampColor(_ verdict: TrainingPlan.RampVerdict) -> Color {
        switch verdict {
        case .light:       return .blue
        case .sustainable: return .green
        case .ambitious:   return .orange
        case .reckless:    return .red
        }
    }

    // MARK: - Data

    private var reloadToken: String {
        "\(weekOffset)-\(planned.count)-\(workouts.count)-\(planned.map(\.completedWorkoutID).count)"
    }

    private func reload() async {
        let plans = planned.map(\.snapshot)
        let snapshots = workouts.map(\.snapshot)
        let restingHR = metrics.first(where: { $0.restingHR != nil })?.restingHR
        let athlete = AthleteProfile.make(workouts: snapshots, restingHR: restingHR)
        let start = weekStart

        let built = await Task.detached(priority: .userInitiated) {
            let week = TrainingPlan.week(containing: start, planned: plans,
                                         workouts: snapshots, athlete: athlete)
            let recent = TrainingPlan.recentWeeklyLoad(workouts: snapshots,
                                                       athlete: athlete, before: start)
            return (week, TrainingPlan.ramp(plannedLoad: week.plannedLoad,
                                            recentWeeklyLoad: recent))
        }.value

        week = built.0
        ramp = built.1
    }

    private func plannedModel(for id: UUID) -> PlannedWorkout? {
        planned.first { $0.id == id }
    }

    private func delete(_ id: UUID) {
        guard let model = plannedModel(for: id) else { return }
        context.delete(model)
    }

    private func skip(_ id: UUID) {
        guard let model = plannedModel(for: id) else { return }
        model.skippedAt = .now
    }
}

// MARK: - Rows

private struct PlanEntryRow: View {
    @Environment(\.units) private var units
    let entry: TrainingPlan.Entry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.planned.title)
                    .font(.body)
                    .foregroundStyle(entry.planned.isSkipped ? .secondary : .primary)
                    .strikethrough(entry.planned.isSkipped)
                if let target = targetText {
                    Text(target).font(.caption).foregroundStyle(.secondary)
                }
                if let actual = actualText {
                    Text(actual).font(.caption).foregroundStyle(.green)
                }
            }

            Spacer()

            if let load = entry.planned.estimatedLoad {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int(load.rounded()))")
                        .font(.callout.monospacedDigit())
                    Text("load").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        if entry.isCompleted { return "checkmark.circle.fill" }
        if entry.planned.isSkipped { return "moon.zzz.fill" }
        return entry.planned.sport.symbolName
    }

    private var statusColor: Color {
        if entry.isCompleted { return .green }
        if entry.planned.isSkipped { return .secondary }
        return .accentColor
    }

    private var targetText: String? {
        var parts: [String] = []
        if let distance = entry.planned.targetDistance, distance > 0 {
            parts.append(units.autoDistance(distance))
        }
        if let duration = entry.planned.targetDuration, duration > 0 {
            parts.append(units.duration(duration))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var actualText: String? {
        guard let actual = entry.actual else { return nil }
        var parts = ["Done"]
        if actual.distance > 0 { parts.append(units.autoDistance(actual.distance)) }
        parts.append(units.duration(actual.duration))
        if let load = entry.actualLoad { parts.append("\(Int(load.rounded())) load") }
        return parts.joined(separator: " · ")
    }
}

private struct UnplannedRow: View {
    @Environment(\.units) private var units
    let workout: WorkoutSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: workout.sport.symbolName)
                .foregroundStyle(.secondary)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.sport.displayName)
                Text("Unplanned · " + units.autoDistance(workout.distance))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Editor

struct PlannedWorkoutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.units) private var units

    let existing: PlannedWorkout?
    let day: Date

    @State private var sport: WorkoutSport = .run
    @State private var title = ""
    @State private var scheduledFor: Date = .now
    @State private var hasDuration = true
    @State private var minutes = 60
    @State private var hasDistance = false
    @State private var distanceValue: Double = 10
    @State private var hasLoad = false
    @State private var load: Double = 60
    @State private var notes = ""
    @State private var loaded = false
    @State private var editingSteps = false

    private var duration: TimeInterval? {
        hasDuration ? TimeInterval(minutes) * 60 : nil
    }

    private var distanceMeters: Double? {
        guard hasDistance else { return nil }
        return units.system == .metric
            ? distanceValue * 1000
            : distanceValue * UnitConversion.metersPerMile
    }

    /// What the week's total will actually use, shown so the number in the
    /// header is never a surprise.
    private var effectiveLoad: Double? {
        if hasLoad { return load }
        guard let duration else { return nil }
        let intensity = TrainingLoad.defaultIntensity(for: sport)
        return duration / 3600 * intensity * intensity * 100
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What is it? e.g. 8 × 400 m", text: $title)
                    Picker("Sport", selection: $sport) {
                        ForEach(WorkoutSport.allCases, id: \.self) { sport in
                            Label(sport.displayName, systemImage: sport.symbolName).tag(sport)
                        }
                    }
                    DatePicker("Day", selection: $scheduledFor,
                               displayedComponents: [.date])
                }

                Section {
                    Toggle("Target a duration", isOn: $hasDuration)
                    if hasDuration {
                        Stepper(value: $minutes, in: 5...600, step: 5) {
                            LabeledContent("Minutes", value: "\(minutes)")
                        }
                    }
                    Toggle("Target a distance", isOn: $hasDistance)
                    if hasDistance {
                        Stepper(value: $distanceValue,
                                in: 0...(units.system == .metric ? 500 : 310), step: 0.5) {
                            LabeledContent("Distance",
                                           value: units.distance(distanceMeters ?? 0))
                        }
                    }
                } header: {
                    Text("Target")
                } footer: {
                    Text("Both are optional — a plan can just be a name on a day.")
                }

                Section {
                    Toggle("Set the load myself", isOn: $hasLoad)
                    if hasLoad {
                        Stepper(value: $load, in: 0...400, step: 5) {
                            LabeledContent("Load", value: "\(Int(load))")
                        }
                    }
                    LabeledContent("Counts as",
                                   value: effectiveLoad.map { "\(Int($0.rounded())) load" } ?? "–")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Training stress")
                } footer: {
                    Text("Left alone, it's estimated from the duration using the same per-sport assumption the load model makes for an unmeasured session — so a planned week and a completed one compare on one scale. Set it yourself for a session you know is harder or easier than that.")
                }

                if let existing {
                    Section {
                        Button {
                            editingSteps = true
                        } label: {
                            HStack {
                                Label(existing.hasStructure ? "Edit steps" : "Add steps…",
                                      systemImage: "list.number")
                                Spacer()
                                if let shorthand = existing.structure?.shorthand,
                                   !shorthand.isEmpty {
                                    Text(shorthand)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    } header: {
                        Text("Structure")
                    } footer: {
                        Text("Steps can be sent to your watch as a .fit workout, so the session runs itself rather than being a name you have to remember.")
                    }
                }

                Section("Notes") {
                    TextField("Anything worth remembering", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle(existing == nil ? "Plan a Session" : "Edit Plan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .task { load_() }
            .sheet(isPresented: $editingSteps) {
                if let existing { WorkoutStructureEditor(plan: existing) }
            }
        }
    }

    private func load_() {
        guard !loaded else { return }
        loaded = true
        scheduledFor = day

        guard let existing else { return }
        sport = existing.sport
        title = existing.title
        scheduledFor = existing.scheduledFor
        if let target = existing.targetDuration, target > 0 {
            hasDuration = true
            minutes = Int(target / 60)
        } else {
            hasDuration = false
        }
        if let target = existing.targetDistance, target > 0 {
            hasDistance = true
            distanceValue = units.system == .metric
                ? target / 1000
                : target / UnitConversion.metersPerMile
        }
        if let target = existing.targetLoad, target > 0 {
            hasLoad = true
            load = target
        }
        notes = existing.notes ?? ""
    }

    private func save() {
        let plan = existing ?? PlannedWorkout(scheduledFor: scheduledFor, sport: sport)
        plan.scheduledFor = Calendar.current.startOfDay(for: scheduledFor)
        plan.sport = sport
        plan.title = title
        plan.targetDuration = duration
        plan.targetDistance = distanceMeters
        plan.targetLoad = hasLoad ? load : nil
        plan.notes = notes.isEmpty ? nil : notes
        if existing == nil { context.insert(plan) }
        dismiss()
    }
}

/// `sheet(item:)` needs an Identifiable, and a bare `Date` isn't one.
extension Date: @retroactive Identifiable {
    public var id: TimeInterval { timeIntervalSince1970 }
}
