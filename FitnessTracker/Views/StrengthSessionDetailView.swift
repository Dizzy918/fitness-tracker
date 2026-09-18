import SwiftUI
import SwiftData

/// Identity for `.sheet(item:)`. A bare `Double` would need a retroactive
/// `Identifiable` conformance on a stdlib type, which leaks everywhere.
private struct PlateTarget: Identifiable {
    let id = UUID()
    let kilograms: Double
}

struct StrengthSessionDetailView: View {
    @Environment(\.units) private var units
    @Environment(\.modelContext) private var context
    @Bindable var session: StrengthSession
    @Query(sort: \Exercise.name) private var exercises: [Exercise]

    @State private var showAddSet = false
    @State private var platesFor: PlateTarget?
    @State private var timer = RestTimer()

    var body: some View {
        List {
            summarySection

            if let next = session.nextPendingSet {
                upNextSection(next)
            }

            if session.pendingSets.count > 1 {
                remainingSection
            }

            ForEach(groupedByExercise, id: \.0) { name, sets in
                Section(name) {
                    ForEach(sets) { set in
                        SetRow(set: set, units: units) { platesFor = PlateTarget(kilograms: set.weightKg) }
                    }
                    .onDelete { offsets in
                        for index in offsets { context.delete(sets[index]) }
                    }
                }
            }

            if let notes = session.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if timer.isRunning {
                RestTimerBar(timer: timer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: timer.isRunning)
        .navigationTitle(session.routineName ?? session.startedAt
            .formatted(date: .abbreviated, time: .omitted))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddSet = true } label: {
                    Label("Add set", systemImage: "plus")
                }
                .disabled(exercises.isEmpty)
            }
        }
        .sheet(isPresented: $showAddSet) { AddSetSheet(session: session) }
        .sheet(item: $platesFor) { PlateCalculatorView(target: $0.kilograms) }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            if let fraction = session.completionFraction {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Progress")
                        Spacer()
                        Text("\(session.completedWorkingSets.count) of \(session.workingSets.count) sets")
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: fraction)
                }
            }
            LabeledContent("Sets", value: "\(session.completedWorkingSets.count)")
            LabeledContent("Volume", value: units.volume(session.totalVolume))
            if let duration = session.duration {
                LabeledContent("Duration", value: units.duration(duration))
            }
        }
    }

    /// The set you're about to do, given its own card.
    ///
    /// Mid-set you want one number and one button, not a list to navigate. This
    /// is the whole reason a routine is worth having over a note on your phone.
    private func upNextSection(_ set: SetEntry) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(set.exercise?.name ?? "Set")
                    .font(.title3.weight(.semibold))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(set.reps)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("reps")
                        .foregroundStyle(.secondary)
                    if set.weightKg > 0 {
                        Text("@").foregroundStyle(.tertiary)
                        Text(units.weight(set.weightKg, decimals: 1))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                    }
                }

                HStack {
                    Button {
                        complete(set)
                    } label: {
                        Label("Done", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if set.weightKg > 0 {
                        Button { platesFor = PlateTarget(kilograms: set.weightKg) } label: {
                            Label("Plates", systemImage: "circle.hexagongrid")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            HStack {
                Text("Up next")
                if set.supersetGroup != nil {
                    Label("Superset", systemImage: "link")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.tint)
                }
            }
        } footer: {
            if let rest = set.restSeconds, rest > 0 {
                Text("Rests \(Fmt.duration(Double(rest))) after this set.")
            } else if set.supersetGroup != nil {
                Text("Straight into the next exercise — the rest comes at the end of the round.")
            }
        }
    }

    private var remainingSection: some View {
        Section("Still to do") {
            ForEach(session.pendingSets.dropFirst()) { set in
                HStack {
                    Text(set.exercise?.name ?? "Set")
                    Spacer()
                    Text(set.weightKg > 0
                         ? "\(set.reps) × \(units.weight(set.weightKg, decimals: 1))"
                         : "\(set.reps) reps")
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func complete(_ set: SetEntry) {
        set.complete()
        // Whether there's rest owed is already decided: a set inside a superset
        // round carries none, the set that ends the round carries the lot.
        guard let rest = set.restSeconds, rest > 0 else { return }
        timer.start(Double(rest), label: set.exercise?.name)
    }

    /// Completed sets grouped by exercise, preserving performance order.
    /// Pending sets are shown above rather than mixed in here.
    private var groupedByExercise: [(String, [SetEntry])] {
        let sorted = session.sets.filter { !$0.isPending }.sorted { $0.order < $1.order }
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

// MARK: - Rows

private struct SetRow: View {
    let set: SetEntry
    let units: UnitFormatter
    let showPlates: () -> Void

    var body: some View {
        HStack {
            Text(set.isWarmup ? "warmup" : "\(set.order + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text("\(set.reps) × \(units.weight(set.weightKg, decimals: 1))")
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
        .swipeActions(edge: .leading) {
            if set.weightKg > 0 {
                Button { showPlates() } label: {
                    Label("Plates", systemImage: "circle.hexagongrid")
                }
                .tint(.indigo)
            }
        }
    }
}

/// The countdown that sits above the list while you're resting.
private struct RestTimerBar: View {
    @Bindable var timer: RestTimer

    var body: some View {
        // Driven by the clock rather than by a stored counter, so it stays
        // right when the view stops updating.
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let now = context.date
            let finished = timer.hasFinished(at: now)

            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    Text(timer.display(at: now))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(finished ? Color.green : Color.primary)
                        .contentTransition(.numericText())

                    VStack(alignment: .leading, spacing: 1) {
                        Text(finished ? "Rest's up" : "Resting")
                            .font(.subheadline.weight(.medium))
                        if let label = timer.label {
                            Text(label).font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button("+30s") { timer.extend(by: 30) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button { timer.stop() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                ProgressView(value: timer.progress(at: now))
                    .tint(finished ? .green : .accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}
