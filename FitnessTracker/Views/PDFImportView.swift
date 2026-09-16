import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Pick a PDF → extract with Claude → review → import.
///
/// The review step is not optional. Model extraction from arbitrary documents
/// can misread a table, so nothing reaches the database until you approve it.
struct PDFImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var picking = false
    @State private var extracting = false
    @State private var result: ExtractionResult?
    @State private var documentData: Data?
    @State private var documentName: String?
    @State private var selected: Set<String> = []
    @State private var errorMessage: String?
    @State private var importedMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if extracting {
                    extractingState
                } else if let result {
                    reviewList(result)
                } else {
                    emptyState
                }
            }
            .navigationTitle("PDF Import")
            .toolbar {
                if result != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Import \(selected.count)") { importSelected() }
                            .disabled(selected.isEmpty)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Discard") { reset() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            }
            .fileImporter(
                isPresented: $picking,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false,
                onCompletion: handlePick
            )
            .alert("Extraction failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Imported", isPresented: Binding(
                get: { importedMessage != nil },
                set: { if !$0 { importedMessage = nil } }
            )) {
                Button("OK") { importedMessage = nil; reset() }
            } message: {
                Text(importedMessage ?? "")
            }
        }
    }

    // MARK: - States

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Read workouts from a PDF", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("""
                Pick a PDF — a coach's plan, a race result, a training log export — \
                and Claude will pull the workouts out. You review everything before \
                anything is saved.
                """)
        } actions: {
            Button("Choose PDF…") { picking = true }
                .buttonStyle(.borderedProminent)
                .disabled(!CredentialStore.has(.anthropicAPIKey))

            if !CredentialStore.has(.anthropicAPIKey) {
                Text("Add an Anthropic API key in Settings first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var extractingState: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Reading \(documentName ?? "document")…")
                .font(.headline)
            Text("Claude is extracting workouts. This can take a minute on a long PDF.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    private func reviewList(_ result: ExtractionResult) -> some View {
        List {
            if let summary = result.documentSummary, !summary.isEmpty {
                Section("Document") {
                    Text(summary).font(.subheadline)
                }
            }

            Section {
                ForEach(result.workouts) { workout in
                    ExtractedRow(
                        workout: workout,
                        isSelected: selected.contains(workout.id),
                        toggle: { toggle(workout) }
                    )
                }
            } header: {
                HStack {
                    Text("\(result.workouts.count) found")
                    Spacer()
                    Button(selected.count == importable(result).count ? "None" : "All") {
                        let all = importable(result).map(\.id)
                        selected = selected.count == all.count ? [] : Set(all)
                    }
                    .font(.caption)
                }
            } footer: {
                Text("Check each row against the PDF before importing — extraction can misread tables.")
            }
        }
    }

    private func importable(_ result: ExtractionResult) -> [ExtractedWorkout] {
        result.workouts.filter(\.isImportable)
    }

    // MARK: - Actions

    private func toggle(_ workout: ExtractedWorkout) {
        if selected.contains(workout.id) {
            selected.remove(workout.id)
        } else if workout.isImportable {
            selected.insert(workout.id)
        }
    }

    private func handlePick(_ pick: Result<[URL], Error>) {
        guard case .success(let urls) = pick, let url = urls.first else {
            if case .failure(let error) = pick { errorMessage = error.localizedDescription }
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Could not read that file."
            return
        }
        documentData = data
        documentName = url.lastPathComponent
        Task { await extract(data: data, filename: url.lastPathComponent) }
    }

    private func extract(data: Data, filename: String) async {
        extracting = true
        defer { extracting = false }
        do {
            let extracted = try await PDFWorkoutExtractor().extract(pdf: data, filename: filename)
            result = extracted
            // Pre-select only rows the model was confident about.
            selected = Set(
                extracted.workouts
                    .filter { $0.isImportable && ($0.confidence ?? 1) >= 0.5 }
                    .map(\.id)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importSelected() {
        guard let result, let documentData else { return }
        var added = 0, skipped = 0

        for workout in result.workouts where selected.contains(workout.id) {
            guard let startedAt = workout.startedAt else { skipped += 1; continue }
            let externalID = PDFWorkoutExtractor.externalID(
                for: workout, documentData: documentData
            )
            var descriptor = FetchDescriptor<Workout>(
                predicate: #Predicate<Workout> { $0.externalID == externalID }
            )
            descriptor.fetchLimit = 1
            if (try? context.fetch(descriptor).first) != nil { skipped += 1; continue }

            let new = Workout(
                sport: workout.mappedSport,
                startedAt: startedAt,
                duration: workout.durationSeconds ?? 0,
                distance: workout.distanceMeters ?? 0,
                source: "pdf",
                externalID: externalID
            )
            new.avgHeartRate = workout.avgHeartRate
            new.maxHeartRate = workout.maxHeartRate
            new.elevationGain = workout.elevationGainMeters
            new.calories = workout.calories
            // Keep provenance on the record itself.
            new.notes = [workout.notes, workout.sourceHint.map { "From \($0)" }]
                .compactMap { $0 }
                .joined(separator: " · ")
            context.insert(new)
            added += 1
        }

        importedMessage = skipped > 0
            ? "Added \(added). Skipped \(skipped) already-imported or undated."
            : "Added \(added) workouts."
    }

    private func reset() {
        result = nil
        documentData = nil
        documentName = nil
        selected = []
    }
}

private struct ExtractedRow: View {
    let workout: ExtractedWorkout
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(workout.date).font(.headline)
                        Text(workout.mappedSport.displayName)
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    if let hint = workout.sourceHint {
                        Text(hint).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if !workout.isImportable {
                        Text("Not enough data to import")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                if let confidence = workout.confidence, confidence < 0.5 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Low confidence — verify against the PDF")
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!workout.isImportable)
    }

    private var detail: String {
        var parts: [String] = []
        if let d = workout.distanceMeters, d > 0 { parts.append(Fmt.km(d)) }
        if let s = workout.durationSeconds, s > 0 { parts.append(Fmt.duration(s)) }
        if let hr = workout.avgHeartRate { parts.append("\(hr) bpm") }
        if let gain = workout.elevationGainMeters, gain > 0 { parts.append("↑\(Int(gain)) m") }
        return parts.isEmpty ? "No metrics stated" : parts.joined(separator: " · ")
    }
}
