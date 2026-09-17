import SwiftUI
import SwiftData

/// Daily check-in: how you feel, plus the objective numbers when nothing
/// measured them for you.
///
/// Upserts into the same `DailyMetric` row HealthKit writes to, so both sources
/// coexist. The objective section exists because HealthKit is iOS-only — on the
/// Mac the readiness score could never see HRV or resting heart rate at all, and
/// those are 50% of its weight, so it was permanently stuck below the confidence
/// floor. It's equally the answer for anyone whose watch doesn't report them.
struct CheckInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.units) private var units

    @State private var sleepQuality = 3
    @State private var soreness = 2
    @State private var mood = 3
    @State private var motivation = 3
    @State private var sleepHours: Double = 8
    @State private var enterSleepHours = false
    @State private var notes = ""
    @State private var loaded = false

    @State private var hrv: Double = 0
    @State private var restingHR = 0
    @State private var weight: Double = 0
    /// True when HealthKit already filled these in, so the UI can say the values
    /// are measured rather than inviting you to retype them.
    @State private var measuredObjectively = false

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

                Section {
                    Stepper(value: $hrv, in: 0...300, step: 1) {
                        LabeledContent("HRV (SDNN)",
                                       value: hrv > 0 ? String(format: "%.0f ms", hrv) : "–")
                    }
                    Stepper(value: $restingHR, in: 0...120) {
                        LabeledContent("Resting HR",
                                       value: restingHR > 0 ? "\(restingHR) bpm" : "–")
                    }
                    Stepper(value: displayedWeight,
                            in: 0...(units.system == .metric ? 250 : 550), step: 0.1) {
                        LabeledContent("Weight",
                                       value: weight > 0 ? units.weight(weight) : "–")
                    }
                } header: {
                    Text("Measurements")
                } footer: {
                    Text(measuredObjectively
                         ? "Already read from Health for today. Changing a value here overrides it."
                         : (HealthKitReader.isAvailable
                            ? "Optional — import from Health instead if your watch records them. HRV and resting heart rate are half the readiness score's weight."
                            : "Health data is iOS-only, so on this Mac these have to be entered by hand. HRV and resting heart rate are half the readiness score's weight."))
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
                    hrv = existing.hrvSDNN ?? 0
                    restingHR = Int(existing.restingHR ?? 0)
                    weight = existing.weightKg ?? 0
                    measuredObjectively = existing.source != "manual" && existing.hasObjectiveData
                    notes = existing.notes ?? ""
                }
            }
        }
    }

    /// The stepper works in the shown unit; `weight` stays kilograms.
    private var displayedWeight: Binding<Double> {
        Binding(
            get: { units.displayedWeight(fromKilograms: weight) },
            set: { weight = units.kilograms(fromDisplayed: $0) }
        )
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
        // Zero means "not entered", not "measured as zero" — writing it would
        // put a resting heart rate of 0 into the baseline and poison every
        // subsequent z-score.
        if hrv > 0 { metric.hrvSDNN = hrv }
        if restingHR > 0 { metric.restingHR = Double(restingHR) }
        if weight > 0 { metric.weightKg = weight }
        metric.notes = notes.isEmpty ? nil : notes
        metric.source = measuredObjectively ? "mixed" : "manual"
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
