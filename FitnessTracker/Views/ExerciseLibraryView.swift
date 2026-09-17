import SwiftUI
import SwiftData

/// Browse, add and edit the exercises sets are logged against.
///
/// Grouped by movement pattern rather than listed alphabetically, because that's
/// how a program is written and how this app attributes volume — seeing that
/// you have six pushes and one pull is the point.
struct ExerciseLibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Exercise.name) private var exercises: [Exercise]

    @State private var search = ""
    @State private var editing: Exercise?
    @State private var creating = false
    @State private var message: String?

    private var filtered: [Exercise] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return exercises }
        return exercises.filter {
            $0.name.lowercased().contains(query)
                || $0.category.lowercased().contains(query)
                || $0.primaryMuscles.contains { $0.lowercased().contains(query) }
        }
    }

    private var grouped: [(ExerciseLibrary.Category, [Exercise])] {
        ExerciseLibrary.Category.allCases.compactMap { category in
            let matching = filtered.filter { $0.categoryValue == category }
            return matching.isEmpty ? nil : (category, matching)
        }
    }

    var body: some View {
        Group {
            if exercises.isEmpty {
                ContentUnavailableView {
                    Label("No exercises yet", systemImage: "dumbbell")
                } description: {
                    Text("Sets are logged against an exercise, so you need at least one. Start from the built-in list and edit it, or add your own.")
                } actions: {
                    VStack(spacing: 8) {
                        Button("Add the starter list") { seedStarter() }
                            .buttonStyle(.borderedProminent)
                        Button("Create one…") { creating = true }
                    }
                }
            } else {
                List {
                    ForEach(grouped, id: \.0) { category, items in
                        Section {
                            ForEach(items) { exercise in
                                Button { editing = exercise } label: {
                                    ExerciseRow(exercise: exercise)
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { offsets in
                                delete(offsets.map { items[$0] })
                            }
                        } header: {
                            Label(category.displayName, systemImage: category.symbolName)
                        } footer: {
                            if search.isEmpty { Text(category.detail) }
                        }
                    }

                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: search)
                    }
                }
                .searchable(text: $search, prompt: "Search name, pattern, or muscle")
            }
        }
        .navigationTitle("Exercises")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        creating = true
                    } label: {
                        Label("New exercise…", systemImage: "plus")
                    }
                    if !exercises.isEmpty {
                        Button {
                            seedStarter()
                        } label: {
                            Label("Add missing starter exercises", systemImage: "square.and.arrow.down")
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $creating) { ExerciseEditor(exercise: nil) }
        .sheet(item: $editing) { ExerciseEditor(exercise: $0) }
        .alert("Exercises", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func seedStarter() {
        let added = (try? ExerciseLibrary.seedStarter(into: context)) ?? 0
        message = added > 0
            ? "Added \(added) exercise\(added == 1 ? "" : "s")."
            : "You already have all of them."
    }

    /// Refuses to delete anything with logged sets.
    ///
    /// `SetEntry.exercise` nullifies on delete, so the sets would survive
    /// without an identity — quietly wrong volume-by-pattern and a broken e1RM
    /// history, with no visible cause.
    private func delete(_ targets: [Exercise]) {
        var blocked: [String] = []
        for exercise in targets {
            let count = ExerciseLibrary.loggedSetCount(for: exercise, in: context)
            if count > 0 {
                blocked.append("\(exercise.name) (\(count) set\(count == 1 ? "" : "s"))")
            } else {
                context.delete(exercise)
            }
        }
        if !blocked.isEmpty {
            message = "Kept \(blocked.joined(separator: ", ")) — deleting an exercise with logged sets would leave them without one, which breaks its progress history. Rename it instead."
        }
    }
}

private struct ExerciseRow: View {
    let exercise: Exercise

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(exercise.name)
                .font(.body)
                .foregroundStyle(.primary)
            if !exercise.primaryMuscles.isEmpty {
                Text(exercise.primaryMuscles.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = exercise.formNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Create or edit one exercise.
struct ExerciseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    /// Nil when creating.
    let exercise: Exercise?

    @State private var name = ""
    @State private var category: ExerciseLibrary.Category = .accessory
    @State private var muscles = ""
    @State private var formNote = ""
    @State private var loaded = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Pattern", selection: $category) {
                        ForEach(ExerciseLibrary.Category.allCases) { category in
                            Label(category.displayName, systemImage: category.symbolName)
                                .tag(category)
                        }
                    }
                } footer: {
                    Text(category.detail + ". Volume and weekly tonnage are grouped by pattern, so this is what decides which bucket the work lands in.")
                }

                Section {
                    TextField("quads, glutes", text: $muscles)
                } header: {
                    Text("Primary muscles")
                } footer: {
                    Text("Comma-separated. Optional — used for searching.")
                }

                Section {
                    TextField("One cue that keeps the rep honest", text: $formNote, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Form notes")
                } footer: {
                    Text("Shown when you pick this exercise while logging a set.")
                }
            }
            .navigationTitle(exercise == nil ? "New Exercise" : "Edit Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(trimmedName.isEmpty)
                }
            }
            .task {
                guard !loaded, let exercise else { loaded = true; return }
                loaded = true
                name = exercise.name
                category = exercise.categoryValue
                muscles = exercise.primaryMuscles.joined(separator: ", ")
                formNote = exercise.notes ?? ""
            }
        }
    }

    private func save() {
        let parsedMuscles = muscles
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let note = formNote.trimmingCharacters(in: .whitespacesAndNewlines)

        if let exercise {
            // Editing in place rather than replacing keeps every logged set
            // pointing at the same row, so renaming a lift doesn't split its
            // progress history in two.
            exercise.name = trimmedName
            exercise.categoryValue = category
            exercise.primaryMuscles = parsedMuscles
            exercise.notes = note.isEmpty ? nil : note
        } else {
            let created = Exercise(name: trimmedName,
                                   category: category.rawValue,
                                   primaryMuscles: parsedMuscles)
            created.notes = note.isEmpty ? nil : note
            context.insert(created)
        }
        dismiss()
    }
}
