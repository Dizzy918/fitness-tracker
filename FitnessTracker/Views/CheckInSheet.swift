import SwiftUI
import SwiftData

/// Four-question subjective check-in for today. Upserts into the same
/// `DailyMetric` row HealthKit writes to, so both sources coexist.
struct CheckInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var sleepQuality = 3
    @State private var soreness = 2
    @State private var mood = 3
    @State private var motivation = 3
    @State private var sleepHours: Double = 8
    @State private var enterSleepHours = false
    @State private var notes = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("How did you sleep?") {
                    ScaleRow(title: "Quality", value: $sleepQuality,
                             lowLabel: "Terrible", highLabel: "Excellent")
                    Toggle("Enter hours manually", isOn: $enterSleepHours)
                    if enterSleepHours {
                        Stepper(String(format: "%.1f hours", sleepHours),
                                value: $sleepHours, in: 0...14, step: 0.5)
                    }
                }

                Section("How does your body feel?") {
                    ScaleRow(title: "Soreness", value: $soreness,
                             lowLabel: "None", highLabel: "Very sore")
                    ScaleRow(title: "Mood", value: $mood,
                             lowLabel: "Poor", highLabel: "Great")
                    ScaleRow(title: "Motivation", value: $motivation,
                             lowLabel: "None", highLabel: "Eager")
                }

                Section("Notes") {
                    TextField("Anything worth remembering", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle("Daily Check-in")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .task {
                // Editing today's entry rather than starting a second one.
                // Read-only: `upsert` here would leave an empty row behind every
                // time the sheet was opened and cancelled.
                guard !loaded else { return }
                loaded = true
                if let existing = try? HealthKitReader.metric(for: .now, in: context) {
                    sleepQuality = existing.sleepQuality ?? sleepQuality
                    soreness = existing.soreness ?? soreness
                    mood = existing.mood ?? mood
                    motivation = existing.motivation ?? motivation
                    if let hours = existing.sleepHours {
                        sleepHours = hours
                        // Only offer manual entry if nothing measured it already.
                        enterSleepHours = existing.source == "manual"
                    }
                    notes = existing.notes ?? ""
                }
            }
        }
    }

    private func save() {
        guard let metric = try? HealthKitReader.upsert(day: .now, in: context) else {
            dismiss()
            return
        }
        metric.sleepQuality = sleepQuality
        metric.soreness = soreness
        metric.mood = mood
        metric.motivation = motivation
        if enterSleepHours { metric.sleepHours = sleepHours }
        metric.notes = notes.isEmpty ? nil : notes
        metric.source = metric.hasObjectiveData ? "mixed" : "manual"
        dismiss()
    }
}

/// 1–5 picker with the ends labeled, so "3" always means the same thing.
private struct ScaleRow: View {
    let title: String
    @Binding var value: Int
    let lowLabel: String
    let highLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value)/5").foregroundStyle(.secondary).monospacedDigit()
            }
            Picker(title, selection: $value) {
                ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("\(title), 1 is \(lowLabel), 5 is \(highLabel)")
            HStack {
                Text(lowLabel)
                Spacer()
                Text(highLabel)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
