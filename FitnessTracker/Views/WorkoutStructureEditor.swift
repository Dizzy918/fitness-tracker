import SwiftUI
import SwiftData

/// Build the steps of a planned session, and send them to a watch.
struct WorkoutStructureEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units

    @Bindable var plan: PlannedWorkout
    @AppStorage(AthleteProfile.Key.maxHeartRate) private var maxHeartRate = 0

    @State private var structure = WorkoutStructure()
    @State private var loaded = false
    @State private var exportURL: URL?
    @State private var exportError: String?

    private var zones: HRZones? {
        maxHeartRate >= 100 ? HRZones(maxHR: maxHeartRate) : nil
    }

    var body: some View {
        NavigationStack {
            List {
                if structure.blocks.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No steps yet", systemImage: "list.number")
                        } description: {
                            Text("Add the steps and the session can go to your watch as a structured workout rather than a name you have to remember.")
                        } actions: {
                            VStack(spacing: 8) {
                                Button("Start from an interval session") {
                                    structure = .intervals(reps: 8, workMetres: 400,
                                                           recoveryMetres: 200)
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Start from a steady session") {
                                    structure = .steady(minutes: 45, zone: 2)
                                }
                                Button("Add a step") { addBlock() }
                            }
                        }
                    }
                } else {
                    summarySection
                    ForEach($structure.blocks) { $block in
                        BlockSection(block: $block, units: units) {
                            structure.blocks.removeAll { $0.id == block.id }
                        }
                    }
                    Section {
                        Button { addBlock() } label: {
                            Label("Add a block", systemImage: "plus.circle")
                        }
                    }
                    exportSection
                }
            }
            .navigationTitle("Steps")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                structure = plan.structure ?? WorkoutStructure()
            }
            .sheet(item: $exportURL) { ShareLinkSheet(url: $0) }
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            Text(structure.shorthand)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let duration = structure.totalDuration {
                LabeledContent("Total time", value: units.duration(duration))
            }
            if let distance = structure.totalDistance {
                LabeledContent("Total distance", value: units.autoDistance(distance))
            }
        } header: {
            Text("Session")
        } footer: {
            if structure.totalDuration == nil && structure.totalDistance == nil {
                Text("Mixed time and distance steps, so there's no single total until it's run.")
            }
        }
    }

    private var exportSection: some View {
        Section {
            Button {
                export()
            } label: {
                Label("Send to watch…", systemImage: "square.and.arrow.up")
            }
            .disabled(structure.isEmpty)

            if let exportError {
                Text(exportError).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Export")
        } footer: {
            Text(zones == nil
                 ? "Writes a .fit workout file — AirDrop it or hand it to your watch's app. Set your max heart rate in Settings and zone targets will be written as real bpm ranges; without it the steps go out untargeted."
                 : "Writes a .fit workout file — AirDrop it or hand it to your watch's app. Zone targets are written as bpm ranges from your max of \(maxHeartRate).")
        }
    }

    // MARK: - Actions

    private func addBlock() {
        structure.blocks.append(
            WorkoutStructure.Block(steps: [WorkoutStructure.Step()]))
    }

    private func save() {
        plan.structure = structure
        // Keep the plan's own targets in step with what was actually built, so
        // the week's load total reflects the session rather than a stale guess.
        if let duration = structure.totalDuration { plan.targetDuration = duration }
        if let distance = structure.totalDistance { plan.targetDistance = distance }
        dismiss()
    }

    private func export() {
        do {
            let data = try FITWorkoutEncoder.encode(
                structure, name: plan.displayTitle, sport: plan.sport, zones: zones)
            let url = URL.temporaryDirectory
                .appendingPathComponent(FITWorkoutEncoder.filename(for: plan.displayTitle))
            try data.write(to: url, options: .atomic)
            exportURL = url
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }
}

// MARK: - One block

private struct BlockSection: View {
    @Binding var block: WorkoutStructure.Block
    let units: UnitFormatter
    let delete: () -> Void

    var body: some View {
        Section {
            if block.steps.count > 1 || block.repeatCount > 1 {
                Stepper(value: $block.repeatCount, in: 1...50) {
                    LabeledContent("Repeat",
                                   value: block.repeatCount > 1 ? "\(block.repeatCount) ×" : "once")
                }
            }

            ForEach($block.steps) { $step in
                StepRow(step: $step, units: units)
            }
            .onDelete { offsets in
                block.steps.remove(atOffsets: offsets)
            }
            .onMove { from, to in
                block.steps.move(fromOffsets: from, toOffset: to)
            }

            Button {
                block.steps.append(WorkoutStructure.Step())
            } label: {
                Label("Add a step here", systemImage: "plus")
                    .font(.caption)
            }
        } header: {
            HStack {
                Text(block.isRepeat ? "\(block.repeatCount) × block" : "Block")
                Spacer()
                Button(role: .destructive) { delete() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

private struct StepRow: View {
    @Binding var step: WorkoutStructure.Step
    let units: UnitFormatter

    @State private var expanded = false

    /// The duration kinds, as a picker can't bind to an enum with payloads.
    private enum Kind: String, CaseIterable, Identifiable {
        case time, distance, open
        var id: String { rawValue }
        var label: String {
            switch self {
            case .time:     return "Time"
            case .distance: return "Distance"
            case .open:     return "Open"
            }
        }
    }

    private var kind: Binding<Kind> {
        Binding(
            get: {
                switch step.duration {
                case .time:     return .time
                case .distance: return .distance
                case .open:     return .open
                }
            },
            set: { new in
                switch new {
                case .time:     step.duration = .time(300)
                case .distance: step.duration = .distance(1_000)
                case .open:     step.duration = .open
                }
            }
        )
    }

    private var minutes: Binding<Double> {
        Binding(
            get: { if case .time(let s) = step.duration { return s / 60 } else { return 5 } },
            set: { step.duration = .time($0 * 60) }
        )
    }

    private var distance: Binding<Double> {
        Binding(
            get: {
                guard case .distance(let m) = step.duration else { return 1_000 }
                return units.system == .metric ? m : m / UnitConversion.metersPerYard
            },
            set: {
                step.duration = .distance(
                    units.system == .metric ? $0 : $0 * UnitConversion.metersPerYard)
            }
        )
    }

    private var zone: Binding<Int> {
        Binding(
            get: { if case .heartRateZone(let z) = step.target { return z } else { return 0 } },
            set: { step.target = $0 == 0 ? WorkoutStructure.StepTarget.none : .heartRateZone($0) }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Picker("Kind", selection: kind) {
                ForEach(Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            switch step.duration {
            case .time:
                Stepper(value: minutes, in: 0.5...240, step: 0.5) {
                    LabeledContent("Minutes", value: String(format: "%.1f", minutes.wrappedValue))
                }
            case .distance:
                Stepper(value: distance, in: 50...42_000, step: 50) {
                    LabeledContent("Distance",
                                   value: "\(Int(distance.wrappedValue)) \(units.shortDistanceUnit)")
                }
            case .open:
                Text("Runs until you press lap on the watch.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("Effort", selection: $step.intensity) {
                ForEach(WorkoutStructure.StepIntensity.allCases) {
                    Text($0.displayName).tag($0)
                }
            }

            Stepper(value: zone, in: 0...5) {
                LabeledContent("Target",
                               value: zone.wrappedValue == 0
                                   ? "None" : "Zone \(zone.wrappedValue)")
            }

            TextField("Name (optional)", text: Binding(
                get: { step.name ?? "" },
                set: { step.name = $0.isEmpty ? nil : $0 }
            ))
        } label: {
            HStack {
                Text(step.name ?? step.intensity.displayName)
                Spacer()
                Text(step.shorthand)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
