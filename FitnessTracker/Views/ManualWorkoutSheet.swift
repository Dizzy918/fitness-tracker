import SwiftUI
import SwiftData

/// Log a workout by hand, or correct one.
///
/// The app is built around importing full-fidelity files, but not everything
/// gets recorded: a treadmill run, a gym class, a ride on a bike without a
/// computer, or a session whose `.fit` file went missing. Without this those
/// sessions are simply absent from the training load, which makes the fitness
/// curve wrong in the one direction that matters — it under-reports.
///
/// The same form edits an existing workout, because a hand-typed distance with
/// a typo in it was otherwise permanent — and a wrong distance doesn't just look
/// wrong, it feeds pace, training load and the fitness curve.
///
/// Editing deliberately covers only the summary fields. Recorded streams, laps
/// and the GPS track belong to whatever device produced them, and letting the UI
/// contradict them would make a workout's own numbers disagree with each other.
struct ManualWorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.units) private var units

    @Query(filter: #Predicate<Shoe> { $0.retiredAt == nil },
           sort: \Shoe.acquiredAt, order: .reverse)
    private var activeShoes: [Shoe]

    /// Nil when logging a new one.
    var existing: Workout?

    @State private var sport: WorkoutSport = .run
    @State private var startedAt: Date = .now
    @State private var hours = 0
    @State private var minutes = 45
    @State private var distanceValue: Double = 10
    @State private var hasDistance = true
    @State private var avgHR = 0
    @State private var maxHR = 0
    @State private var elevation = 0
    @State private var calories = 0
    @State private var shoe: Shoe?
    @State private var notes = ""

    private var duration: TimeInterval {
        TimeInterval(hours) * 3600 + TimeInterval(minutes) * 60
    }

    /// Typed in the athlete's own units, stored in metres.
    private var distanceMeters: Double {
        guard hasDistance else { return 0 }
        return units.system == .metric
            ? distanceValue * 1000
            : distanceValue * UnitConversion.metersPerMile
    }

    @State private var loaded = false

    private var canSave: Bool {
        duration > 0 && (!hasDistance || distanceValue > 0)
    }

    /// True when the workout carries recorded data the summary should agree
    /// with, so the UI can warn rather than silently letting them diverge.
    private var hasRecordedData: Bool {
        guard let existing else { return false }
        return existing.hasStreams || existing.hasRoute || !existing.laps.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sport", selection: $sport) {
                        ForEach(WorkoutSport.allCases, id: \.self) { sport in
                            Label(sport.displayName, systemImage: sport.symbolName)
                                .tag(sport)
                        }
                    }
                    DatePicker("Started", selection: $startedAt,
                               in: ...Date.now,
                               displayedComponents: [.date, .hourAndMinute])
                }

                Section("Duration") {
                    Stepper(value: $hours, in: 0...24) {
                        LabeledContent("Hours", value: "\(hours)")
                    }
                    Stepper(value: $minutes, in: 0...59, step: 1) {
                        LabeledContent("Minutes", value: "\(minutes)")
                    }
                    LabeledContent("Total", value: units.duration(duration))
                        .foregroundStyle(duration > 0 ? Color.secondary : Color.red)
                }

                Section("Distance") {
                    Toggle("Recorded a distance", isOn: $hasDistance)
                    if hasDistance {
                        Stepper(value: $distanceValue,
                                in: 0...(units.system == .metric ? 500 : 310),
                                step: 0.1) {
                            LabeledContent("Distance", value: units.distance(distanceMeters))
                        }
                        if duration > 0, distanceMeters > 0 {
                            LabeledContent("Pace",
                                            value: units.pace(duration / (distanceMeters / 1000)))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Stepper(value: $avgHR, in: 0...230) {
                        LabeledContent("Average", value: avgHR > 0 ? "\(avgHR) bpm" : "–")
                    }
                    Stepper(value: $maxHR, in: 0...230) {
                        LabeledContent("Maximum", value: maxHR > 0 ? "\(maxHR) bpm" : "–")
                    }
                } header: {
                    Text("Heart rate")
                } footer: {
                    Text("Optional, but an average heart rate is what lets this session be scored for training load rather than estimated from its duration.")
                }

                Section("Other") {
                    Stepper(value: $elevation, in: 0...9000, step: 10) {
                        LabeledContent("Climb",
                                        value: elevation > 0 ? units.elevation(Double(elevation)) : "–")
                    }
                    Stepper(value: $calories, in: 0...5000, step: 10) {
                        LabeledContent("Calories", value: calories > 0 ? "\(calories) kcal" : "–")
                    }
                    if !activeShoes.isEmpty, sport == .run || sport == .trailRun
                        || sport == .walk || sport == .hike {
                        Picker("Shoe", selection: $shoe) {
                            Text("None").tag(Shoe?.none)
                            ForEach(activeShoes) { Text($0.displayName).tag(Shoe?.some($0)) }
                        }
                    }
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }

                if hasRecordedData {
                    Section {
                        Label("""
                            This workout has recorded data — a GPS track, laps or a \
                            sensor stream. Those aren't changed here, so editing the \
                            summary can make it disagree with them.
                            """, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(existing == nil ? "Log Workout" : "Edit Workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .task { load() }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let existing else { return }

        sport = existing.sport
        startedAt = existing.startedAt
        hours = Int(existing.duration) / 3600
        minutes = (Int(existing.duration) % 3600) / 60
        hasDistance = existing.distance > 0
        if hasDistance {
            distanceValue = units.system == .metric
                ? existing.distance / 1000
                : existing.distance / UnitConversion.metersPerMile
        }
        avgHR = existing.avgHeartRate ?? 0
        maxHR = existing.maxHeartRate ?? 0
        elevation = Int(existing.elevationGain ?? 0)
        calories = Int(existing.calories ?? 0)
        shoe = existing.shoe
        notes = existing.notes ?? ""
    }

    private func save() {
        // Editing in place rather than replacing keeps the row id, the source
        // and any recorded streams — and keeps it out of the sync watermark's
        // way, since a new row would look like a workout that had never synced.
        let workout = existing ?? Workout(
            sport: sport,
            startedAt: startedAt,
            duration: duration,
            distance: distanceMeters,
            source: "manual",
            // Namespaced like every other source so it can't collide with an
            // imported ID, and unique so two hand-logged sessions on the same
            // day stay two rows.
            externalID: "manual:\(UUID().uuidString)"
        )
        workout.sport = sport
        workout.startedAt = startedAt
        workout.duration = duration
        workout.distance = distanceMeters
        workout.avgHeartRate = avgHR > 0 ? avgHR : nil
        workout.maxHeartRate = maxHR > 0 ? maxHR : nil
        workout.elevationGain = elevation > 0 ? Double(elevation) : nil
        workout.calories = calories > 0 ? Double(calories) : nil
        workout.notes = notes.isEmpty ? nil : notes
        workout.shoe = shoe

        if existing == nil {
            // Hand-logged sessions have no detail to fetch; saying so keeps them
            // out of the provider backfill queue.
            workout.detailFetchedAt = .now
            context.insert(workout)
        }
        dismiss()
    }
}
