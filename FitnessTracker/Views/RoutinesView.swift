import SwiftUI
import SwiftData

/// Saved sessions you can run again.
struct RoutinesView: View {
    @Environment(\.units) private var units
    @Environment(\.modelContext) private var context
    @Query(sort: \Routine.name) private var routines: [Routine]
    @Query(sort: \Exercise.name) private var exercises: [Exercise]

    /// Set when a routine has just been started, so the caller can push
    /// straight into the session rather than making you find it in the list.
    var onStart: (StrengthSession) -> Void

    @State private var editing: Routine?

    var body: some View {
        Group {
            if routines.isEmpty {
                ContentUnavailableView {
                    Label("No routines", systemImage: "square.stack.3d.up")
                } description: {
                    Text(exercises.isEmpty
                         ? "A routine is a session you can run again. Set up your exercise library first."
                         : "Save a session once — the exercises, sets, reps and rest — and start it with one tap on the day.")
                } actions: {
                    if !exercises.isEmpty {
                        Button("Create a routine") { create() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                List {
                    ForEach(byRecency) { routine in
                        RoutineRow(routine: routine, units: units) {
                            start(routine)
                        } edit: {
                            editing = routine
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { context.delete(byRecency[index]) }
                    }
                }
            }
        }
        .navigationTitle("Routines")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { create() } label: { Label("New routine", systemImage: "plus") }
                    .disabled(exercises.isEmpty)
            }
        }
        .sheet(item: $editing) { RoutineEditor(routine: $0) }
    }

    /// Most recently run first, then never-run ones alphabetically. The routine
    /// you're on today is the one you want at the top, not the one starting
    /// with "A".
    private var byRecency: [Routine] {
        routines.sorted { lhs, rhs in
            switch (lhs.lastUsedAt, rhs.lastUsedAt) {
            case let (l?, r?): return l > r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return lhs.displayName < rhs.displayName
            }
        }
    }

    private func create() {
        let routine = Routine(name: "")
        context.insert(routine)
        editing = routine
    }

    private func start(_ routine: Routine) {
        let session = StrengthSession(startedAt: .now)
        session.routineID = routine.id
        session.routineName = routine.displayName
        context.insert(session)

        for set in routine.plannedSets() {
            context.insert(set)
            set.session = session
        }

        routine.lastUsedAt = .now
        routine.useCount += 1
        onStart(session)
    }
}

private struct RoutineRow: View {
    let routine: Routine
    let units: UnitFormatter
    let start: () -> Void
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.displayName).font(.headline)
                    Text(routine.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(action: start) {
                    Label("Start", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(.circle)
                .disabled(routine.plannedSetCount == 0)
            }

            HStack(spacing: 10) {
                Text("\(routine.plannedSetCount) sets")
                if routine.plannedVolume > 0 {
                    Text(units.volume(routine.plannedVolume))
                }
                if let last = routine.lastUsedAt {
                    Text("last " + last.formatted(.relative(presentation: .named)))
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .onTapGesture(perform: edit)
    }
}

// MARK: - Editing

struct RoutineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units
    @Environment(\.modelContext) private var context

    @Bindable var routine: Routine
    @Query(sort: \Exercise.name) private var exercises: [Exercise]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name, e.g. Push Day A", text: $routine.name)
                    TextField("Notes", text: Binding(
                        get: { routine.notes ?? "" },
                        set: { routine.notes = $0.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                }

                ForEach(routine.orderedItems) { item in
                    RoutineItemRow(item: item, units: units, exercises: exercises) {
                        remove(item)
                    }
                }

                Section {
                    Button { addItem() } label: {
                        Label("Add an exercise", systemImage: "plus.circle")
                    }
                    if routine.orderedItems.count >= 2 {
                        Button { pairLastTwo() } label: {
                            Label("Superset the last two", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                } footer: {
                    Text(routine.orderedItems.contains { $0.supersetGroup != nil }
                         ? "Superset exercises alternate: a set of each, then rest."
                         : "Exercises run in order, resting after every set.")
                }

                if routine.plannedSetCount > 0 {
                    Section("Session") {
                        LabeledContent("Sets", value: "\(routine.plannedSetCount)")
                        if routine.plannedVolume > 0 {
                            LabeledContent("Planned volume",
                                           value: units.volume(routine.plannedVolume))
                        }
                    }
                }
            }
            .navigationTitle(routine.name.isEmpty ? "New Routine" : routine.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func addItem() {
        let next = (routine.orderedItems.map(\.order).max() ?? -1) + 1
        let previous = routine.orderedItems.last
        let item = RoutineItem(
            order: next,
            exercise: exercises.first,
            restSeconds: exercises.first?.defaultRestSeconds ?? 120)
        // A new exercise after a superset starts on its own rather than joining
        // it — pairing is something you ask for, not something that spreads.
        _ = previous
        context.insert(item)
        item.routine = routine
    }

    private func remove(_ item: RoutineItem) {
        context.delete(item)
        // Close the gap so orders stay contiguous; a hole would make the next
        // "add" collide with an existing position.
        for (index, remaining) in routine.orderedItems.filter({ $0 !== item })
            .enumerated() {
            remaining.order = index
        }
    }

    /// Pair the last two exercises into a superset, or split them if they
    /// already are.
    private func pairLastTwo() {
        let items = routine.orderedItems
        guard items.count >= 2 else { return }
        let last = items[items.count - 1]
        let previous = items[items.count - 2]

        if let group = last.supersetGroup, group == previous.supersetGroup {
            last.supersetGroup = nil
            if !items.dropLast().contains(where: { $0.supersetGroup == group && $0 !== previous }) {
                previous.supersetGroup = nil
            }
            return
        }
        let group = (items.compactMap(\.supersetGroup).max() ?? 0) + 1
        previous.supersetGroup = group
        last.supersetGroup = group
    }
}

private struct RoutineItemRow: View {
    @Bindable var item: RoutineItem
    let units: UnitFormatter
    let exercises: [Exercise]
    let delete: () -> Void

    private var weight: Binding<Double> {
        Binding(
            get: { units.displayedWeight(fromKilograms: item.targetWeightKg ?? 0) },
            set: { item.targetWeightKg = $0 <= 0 ? nil : units.kilograms(fromDisplayed: $0) }
        )
    }

    var body: some View {
        Section {
            Picker("Exercise", selection: Binding(
                get: { item.exercise },
                set: { newValue in
                    item.exercise = newValue
                    if let rest = newValue?.defaultRestSeconds { item.restSeconds = rest }
                }
            )) {
                Text("Select…").tag(Exercise?.none)
                ForEach(exercises) { Text($0.name).tag(Exercise?.some($0)) }
            }

            Stepper("Sets: \(item.targetSets)", value: $item.targetSets, in: 1...12)
            Stepper("Reps: \(item.targetReps)", value: $item.targetReps, in: 1...50)

            HStack {
                Text("Weight")
                Spacer()
                Text(item.targetWeightKg.map { units.weight($0, decimals: 1) } ?? "Not set")
                    .foregroundStyle(.secondary)
            }
            Slider(value: weight,
                   in: 0...(units.system == .metric ? 300 : 660),
                   step: units.system == .metric ? 2.5 : 5)

            Stepper("Rest: \(Fmt.duration(Double(item.restSeconds)))",
                    value: $item.restSeconds, in: 0...600, step: 15)
        } header: {
            HStack {
                Text(item.displayName)
                if item.supersetGroup != nil {
                    Image(systemName: "link").foregroundStyle(.tint)
                }
                Spacer()
                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text(item.shorthand { units.weight($0, decimals: 1) })
        }
    }
}
