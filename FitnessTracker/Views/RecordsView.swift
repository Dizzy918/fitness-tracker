import SwiftUI
import SwiftData

/// Personal bests and lifetime milestones.
///
/// Best efforts require decoding every workout's sample stream, so the work runs
/// off the main actor and the result is cached in state.
struct RecordsView: View {
    @Environment(\.units) private var units

    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]

    @State private var records: [PersonalRecord] = []
    @State private var predictions: [RacePrediction.Prediction] = []
    @State private var paces: RacePrediction.TrainingPaces?
    @State private var milestones = PersonalRecords.Milestones()
    @State private var computing = true

    var body: some View {
        List {
            if computing {
                Section { HStack { ProgressView(); Text("Scanning workouts…") } }
            }

            Section("Best efforts") {
                if records.isEmpty && !computing {
                    Text("No stream data yet. Best efforts need per-second data from a .fit import or Strava sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(records) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.label).font(.headline)
                                Text(record.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(units.duration(record.time))
                                    .font(.title3.monospacedDigit())
                                Text(units.pace(record.paceSecPerKm))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(record.label) best \(units.duration(record.time))")
                    }
                }
            }

            if !predictions.isEmpty {
                Section {
                    ForEach(predictions) { prediction in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prediction.label).font(.headline)
                                Text(units.pace(prediction.paceSecPerKm))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(units.duration(prediction.time))
                                .font(.title3.monospacedDigit())
                                .foregroundStyle(prediction.isSpeculative ? .secondary : .primary)
                            if prediction.isSpeculative {
                                Image(systemName: "questionmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } header: {
                    Text("Predicted times")
                } footer: {
                    Text("Riegel extrapolation from your longest best effort. Marked entries extrapolate a long way and tend to be optimistic — marathon predictions especially assume endurance you may not have trained.")
                }
            }

            if let paces {
                Section {
                    ForEach(Array(paces.bands.enumerated()), id: \.offset) { _, band in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(band.name).font(.subheadline.weight(.medium))
                                Text(band.purpose).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Fmt.clock(units.paceValue(band.range.upperBound)))–\(Fmt.clock(units.paceValue(band.range.lowerBound)))")
                                .font(.callout.monospacedDigit())
                        }
                    }
                } header: {
                    Text("Training paces (per \(units.paceUnit))")
                } footer: {
                    Text("Derived from your best effort converted to a 10 km equivalent. A lab or field test would be more accurate.")
                }
            }

            Section("Milestones") {
                if let longest = milestones.longestRun {
                    milestoneRow("Longest run", units.distance(longest.distance), longest.date)
                }
                if let longest = milestones.longestRide {
                    milestoneRow("Longest ride", units.distance(longest.distance), longest.date)
                }
                if let longest = milestones.longestSwim {
                    milestoneRow("Longest swim", units.elevation(longest.distance), longest.date)
                }
                if let week = milestones.biggestWeek {
                    milestoneRow("Biggest running week", units.distance(week.distance), week.weekStart)
                }
                if let climb = milestones.mostElevation {
                    milestoneRow("Most climbing", units.elevation(climb.gain), climb.date)
                }
                LabeledContent("Lifetime distance", value: units.distance(milestones.totalDistance, decimals: 0))
                LabeledContent("Workouts", value: "\(milestones.totalWorkouts)")
            }
        }
        .navigationTitle("Records")
        .task(id: workouts.count) { await recompute() }
    }

    private func milestoneRow(_ title: LocalizedStringKey, _ value: String, _ date: Date) -> some View {
        HStack {
            Text(title)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: value).monospacedDigit()
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func recompute() async {
        computing = true
        // Copy to Sendable snapshots on the main actor before leaving it —
        // SwiftData models can't be touched from another task.
        let snapshots = workouts.map(\.snapshot)
        let computed = await Task.detached(priority: .userInitiated) {
            (PersonalRecords.compute(from: snapshots),
             PersonalRecords.milestones(from: snapshots))
        }.value
        records = computed.0
        milestones = computed.1
        predictions = RacePrediction.predictions(from: computed.0)
        paces = RacePrediction.trainingPaces(from: computed.0)
        computing = false
    }
}
