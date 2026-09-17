import SwiftUI
import SwiftData
import Charts

struct StrengthListView: View {
    @Environment(\.units) private var units

    @Environment(\.modelContext) private var context
    @Query(sort: \StrengthSession.startedAt, order: .reverse) private var sessions: [StrengthSession]
    @Query(sort: \Exercise.name) private var exercises: [Exercise]

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No lifts logged", systemImage: "dumbbell")
                    } description: {
                        Text(exercises.isEmpty
                             ? "Sets are logged against an exercise, so start by setting up your library."
                             : "Start a session and add your first set.")
                    } actions: {
                        VStack(spacing: 8) {
                            if exercises.isEmpty {
                                NavigationLink("Set up exercises…") { ExerciseLibraryView() }
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Button("Start a session") { startSession() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                } else {
                    List {
                        if !exercises.isEmpty {
                            let cache = bestE1RMByExercise
                            Section("Progress") {
                                ForEach(exercises) { exercise in
                                    NavigationLink {
                                        ExerciseProgressView(exercise: exercise)
                                    } label: {
                                        HStack {
                                            Text(exercise.name)
                                            Spacer()
                                            Text(bestE1RMText(for: exercise, cache: cache))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }

                        Section {
                            NavigationLink {
                                ExerciseLibraryView()
                            } label: {
                                Label("Exercise library", systemImage: "list.bullet.rectangle")
                                Spacer()
                                Text("\(exercises.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Section("Sessions") {
                            ForEach(sessions) { session in
                                NavigationLink {
                                    StrengthSessionDetailView(session: session)
                                } label: {
                                    SessionRow(session: session)
                                }
                            }
                            .onDelete { offsets in
                                for i in offsets { context.delete(sessions[i]) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Strength")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { startSession() } label: {
                        Label("New session", systemImage: "plus")
                    }
                }
            }
        }
    }

    private func startSession() {
        context.insert(StrengthSession(startedAt: .now))
    }

    /// One pass over every working set, keyed by exercise. Computing this per
    /// row rescanned the whole history for each exercise.
    private var bestE1RMByExercise: [UUID: Double] {
        var best: [UUID: Double] = [:]
        for session in sessions {
            for set in session.workingSets {
                guard let id = set.exercise?.id else { continue }
                let estimate = set.estimated1RM
                if estimate > (best[id] ?? 0) { best[id] = estimate }
            }
        }
        return best
    }

    private func bestE1RMText(for exercise: Exercise, cache: [UUID: Double]) -> String {
        guard let best = cache[exercise.id] else { return "–" }
        return "e1RM " + units.volume(best)
    }
}

struct SessionRow: View {
    @Environment(\.units) private var units
    let session: StrengthSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.headline)
            Text(session.exerciseNames.isEmpty
                 ? "Empty session"
                 : session.exerciseNames.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(session.workingSets.count) sets · \(Int(session.totalVolume)) kg volume")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

struct StrengthSessionDetailView: View {
    @Environment(\.units) private var units
    @Environment(\.modelContext) private var context
    @Bindable var session: StrengthSession
    @Query(sort: \Exercise.name) private var exercises: [Exercise]

    @State private var showAddSet = false

    var body: some View {
        List {
            Section {
                LabeledContent("Sets", value: "\(session.workingSets.count)")
                LabeledContent("Volume", value: units.volume(session.totalVolume))
                if let d = session.duration {
                    LabeledContent("Duration", value: units.duration(d))
                }
            }

            ForEach(groupedByExercise, id: \.0) { name, sets in
                Section(name) {
                    ForEach(sets) { set in
                        HStack {
                            Text(set.isWarmup ? "warmup" : "\(set.order + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                            Text("\(set.reps) × \(set.displayWeight)")
                            Spacer()
                            if let rpe = set.rpe {
                                Text("RPE \(String(format: "%.1f", rpe))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !set.isWarmup {
                                Text(String(format: "e1RM %.0f", set.estimated1RM))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { context.delete(sets[i]) }
                    }
                }
            }

            if let notes = session.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }
        }
        .navigationTitle(session.startedAt.formatted(date: .abbreviated, time: .omitted))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddSet = true } label: {
                    Label("Add set", systemImage: "plus")
                }
                .disabled(exercises.isEmpty)
            }
        }
        .sheet(isPresented: $showAddSet) {
            AddSetSheet(session: session)
        }
    }

    /// Sets grouped by exercise, preserving performance order.
    private var groupedByExercise: [(String, [SetEntry])] {
        let sorted = session.sets.sorted { $0.order < $1.order }
        var order: [String] = []
        var buckets: [String: [SetEntry]] = [:]
        for set in sorted {
            let name = set.exercise?.name ?? "Unassigned"
            if buckets[name] == nil { order.append(name) }
            buckets[name, default: []].append(set)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

struct AddSetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.units) private var units
    let session: StrengthSession

    /// Queried rather than passed in: creating an exercise from this sheet has
    /// to make it selectable immediately, and a snapshot array taken when the
    /// sheet opened never updates.
    @Query(sort: \Exercise.name) private var exercises: [Exercise]

    @State private var selected: Exercise?
    @State private var reps = 5
    @State private var weight: Double = 60
    @State private var rpe: Double = 8
    @State private var isWarmup = false
    @State private var creatingExercise = false

    /// The slider works in whatever unit is shown; `weight` stays kilograms.
    private var displayedWeight: Binding<Double> {
        Binding(
            get: { units.displayedWeight(fromKilograms: weight) },
            set: { weight = units.kilograms(fromDisplayed: $0) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Exercise", selection: $selected) {
                        Text("Select…").tag(Exercise?.none)
                        ForEach(exercises) { Text($0.name).tag(Exercise?.some($0)) }
                    }
                    Button {
                        creatingExercise = true
                    } label: {
                        Label("New exercise…", systemImage: "plus.circle")
                    }
                } footer: {
                    if let note = selected?.formNote {
                        Label(note, systemImage: "lightbulb")
                            .font(.caption)
                    } else if exercises.isEmpty {
                        Text("No exercises yet — create one to log a set against.")
                    }
                }
                Stepper("Reps: \(reps)", value: $reps, in: 1...30)
                HStack {
                    Text("Weight")
                    Spacer()
                    Text(units.weight(weight))
                        .foregroundStyle(.secondary)
                }
                Slider(value: displayedWeight,
                       in: 0...(units.system == .metric ? 300 : 660),
                       step: units.system == .metric ? 2.5 : 5)
                Toggle("Warmup set", isOn: $isWarmup)
                if !isWarmup {
                    HStack {
                        Text("RPE")
                        Spacer()
                        Text(String(format: "%.1f", rpe)).foregroundStyle(.secondary)
                    }
                    Slider(value: $rpe, in: 6...10, step: 0.5)
                }
            }
            .navigationTitle("Add Set")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let set = SetEntry(
                            order: (session.sets.map(\.order).max() ?? -1) + 1,
                            reps: reps,
                            weightKg: weight,
                            rpe: isWarmup ? nil : rpe,
                            isWarmup: isWarmup,
                            exercise: selected
                        )
                        set.session = session
                        context.insert(set)
                        dismiss()
                    }
                    .disabled(selected == nil)
                }
            }
            .onAppear { if selected == nil { selected = exercises.first } }
            .sheet(isPresented: $creatingExercise) { ExerciseEditor(exercise: nil) }
            // A newly created exercise is the one you meant to use, so select it
            // rather than making the picker a second step. The list is sorted by
            // name, so the new one isn't simply the last — diff the ids.
            .onChange(of: exercises.map(\.id)) { previous, current in
                let added = Set(current).subtracting(previous)
                if let id = added.first, let match = exercises.first(where: { $0.id == id }) {
                    selected = match
                }
            }
        }
    }
}

struct ExerciseProgressView: View {
    @Environment(\.units) private var units
    let exercise: Exercise
    @Query(sort: \StrengthSession.startedAt) private var sessions: [StrengthSession]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if points.isEmpty {
                    ContentUnavailableView(
                        "No sets yet",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Log a working set for \(exercise.name).")
                    )
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Estimated 1RM").font(.headline)
                        Chart(points, id: \.date) { point in
                            LineMark(x: .value("Date", point.date),
                                     y: .value("e1RM", point.e1rm))
                                .foregroundStyle(.tint)
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("Date", point.date),
                                      y: .value("e1RM", point.e1rm))
                                .foregroundStyle(.tint)
                        }
                        .chartYAxisLabel(units.weightUnit)
                        .frame(height: 200)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                        StatTile(label: "Best e1RM",
                                 value: units.volume(points.map(\.e1rm).max() ?? 0))
                        StatTile(label: "Sessions", value: "\(points.count)")
                        StatTile(label: "Category", value: exercise.category.capitalized)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(exercise.name)
    }

    private struct Point { let date: Date; let e1rm: Double }

    /// Best working-set e1RM per session, chronologically.
    private var points: [Point] {
        sessions.compactMap { session in
            let best = session.workingSets
                .filter { $0.exercise?.id == exercise.id }
                .map(\.estimated1RM)
                .max()
            guard let best else { return nil }
            return Point(date: session.startedAt, e1rm: best)
        }
    }
}
