import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct WorkoutListView: View {
    @Environment(\.units) private var units

    @Environment(\.modelContext) private var context
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]

    @State private var searchText = ""
    @State private var sportFilter: WorkoutSport?
    @State private var importing = false
    @State private var importingFiles = false
    @State private var showSettings = false
    @State private var showPDFImport = false
    @State private var showManualEntry = false
    @State private var dropTargeted = false
    @State private var syncing = false
    @State private var alertMessage: String?
    @State private var alertTitle = ""

    /// First launch. Presented from here because this is the tab the app opens
    /// on, and the flow's last step hands off to this view's own importer.
    @AppStorage(AthleteProfile.Key.hasOnboarded) private var hasOnboarded = false
    @State private var showOnboarding = false

    /// `.fit` has no registered system UTI, so match on the extension.
    private static let fitType = UTType(filenameExtension: "fit") ?? .data

    var body: some View {
        NavigationStack {
            Group {
                if workouts.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            ForEach(filtered) { w in
                                NavigationLink(value: w) { WorkoutRow(workout: w) }
                            }
                            .onDelete(perform: delete)
                        } header: {
                            Text(headerText)
                        } footer: {
                            if filtered.isEmpty {
                                Text("No workouts match. Clear the search or filter.")
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search notes, sport, or source")
                }
            }
            .navigationTitle("Workouts")
            .navigationDestination(for: Workout.self) { WorkoutDetailView(workout: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Section {
                            Button {
                                showManualEntry = true
                            } label: {
                                Label("Log a workout by hand…", systemImage: "square.and.pencil")
                            }
                        }
                        Section("Import") {
                            Button {
                                importing = true
                            } label: {
                                Label(importingFiles ? "Importing…" : ".fit file from watch…",
                                      systemImage: "square.and.arrow.down")
                            }
                            .disabled(importingFiles)
                            Button {
                                showPDFImport = true
                            } label: {
                                Label("Read a PDF with AI…", systemImage: "doc.text.magnifyingglass")
                            }
                        }
                        Section("Sync") {
                            Button {
                                Task { await sync() }
                            } label: {
                                Label(syncing ? "Syncing…" : "Sync connected services",
                                      systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(syncing || !anyProviderConfigured)
                        }
                        Section {
                            Button {
                                let n = DemoData.seed(into: context)
                                show("Demo data",
                                     "Seeded \(n) workouts, 2 shoes, and 16 lifting sessions.")
                            } label: {
                                Label("Seed demo data", systemImage: "wand.and.stars")
                            }
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { showSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button {
                            sportFilter = nil
                        } label: {
                            Label("All sports", systemImage: sportFilter == nil ? "checkmark" : "")
                        }
                        ForEach(availableSports, id: \.self) { sport in
                            Button {
                                sportFilter = sport
                            } label: {
                                Label(sport.displayName,
                                      systemImage: sportFilter == sport ? "checkmark" : sport.symbolName)
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: sportFilter == nil
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingView { outcome in
                    switch outcome {
                    case .importFile:     importing = true
                    case .connectService: showSettings = true
                    case .seedDemo:
                        let n = DemoData.seed(into: context)
                        show("Sample data",
                             "Seeded \(n) workouts, 2 shoes, and 16 lifting sessions. You can delete it from Settings when you're done looking.")
                    case .nothing:        break
                    }
                }
            }
            .task {
                // Only on a genuinely empty store. Someone restoring a backup
                // onto a new device has no use for an introduction, and being
                // shown one would suggest their data hadn't arrived.
                if !hasOnboarded && workouts.isEmpty { showOnboarding = true }
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [Self.fitType],
                allowsMultipleSelection: true,
                onCompletion: handleImport
            )
            // Dropping files onto the window is how importing a folder of
            // watch exports is actually bearable on a Mac — the file picker
            // means navigating to them one batch at a time.
            .dropDestination(for: URL.self) { urls, _ in
                // Folders are expanded: dropping a directory of watch exports is
                // the whole reason this exists.
                let fitFiles = FITImporter.fitFiles(in: urls)
                guard !fitFiles.isEmpty else {
                    show("Nothing to import",
                         "No .fit files there. Drop the exports from your watch's app, or the folder containing them.")
                    return false
                }
                Task { await runImport(fitFiles) }
                return true
            } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .background(Color.accentColor.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            Label("Drop .fit files to import", systemImage: "square.and.arrow.down")
                                .font(.headline)
                                .padding()
                                .background(.regularMaterial, in: Capsule())
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showPDFImport) { PDFImportView() }
            .sheet(isPresented: $showManualEntry) { ManualWorkoutSheet() }
            .alert(alertTitle, isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK") { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No workouts yet", systemImage: "figure.run")
        } description: {
            Text("""
                Import a .fit file from your Suunto — or drag a folder's worth onto \
                this window — connect Strava or intervals.icu, read a PDF with AI, \
                or seed demo data to explore the app.
                """)
        } actions: {
            VStack(spacing: 8) {
                Button("Import .fit…") { importing = true }
                    .buttonStyle(.borderedProminent)
                Button("Log one by hand…") { showManualEntry = true }
                Button("Connect a service…") { showSettings = true }
                Button("Seed demo data") {
                    let n = DemoData.seed(into: context)
                    show("Demo data", "Seeded \(n) workouts, 2 shoes, and 16 lifting sessions.")
                }
            }
        }
    }

    /// Sports actually present, so the filter never offers an empty option.
    private var availableSports: [WorkoutSport] {
        let present = Set(workouts.map(\.sport))
        return WorkoutSport.allCases.filter { present.contains($0) }
    }

    private var filtered: [Workout] {
        var result = workouts
        if let sportFilter {
            result = result.filter { $0.sport == sportFilter }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            result = result.filter { w in
                w.sport.displayName.lowercased().contains(query)
                    || w.source.lowercased().contains(query)
                    || (w.notes ?? "").lowercased().contains(query)
                    || (w.shoe?.displayName ?? "").lowercased().contains(query)
            }
        }
        return result
    }

    private var headerText: String {
        let shown = filtered.count
        let total = units.distance(filtered.reduce(0) { $0 + $1.distance }, decimals: 0)
        guard shown == workouts.count else {
            return String(localized: "\(shown) of \(workouts.count) · \(total)")
        }
        // Singular and plural are separate keys rather than a noun picked in
        // code: a translator can't reach a word that was chosen by a ternary,
        // and "1 workouts" is what you get when nobody can.
        return shown == 1
            ? String(localized: "1 workout · \(total) total")
            : String(localized: "\(shown) workouts · \(total) total")
    }

    private var totalDistance: Double {
        workouts.reduce(0) { $0 + $1.distance }
    }

    private var anyProviderConfigured: Bool {
        StravaProvider().isConfigured || IntervalsICUProvider().isConfigured
    }

    private func sync() async {
        syncing = true
        defer { syncing = false }
        let report = await SyncEngine(context: context).syncAll()
        show("Sync complete", report.failures.isEmpty
             ? report.summary
             : report.summary + "\n\n" + report.failures.joined(separator: "\n"))
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            show("Import failed", error.localizedDescription)
        case .success(let urls):
            Task { await runImport(urls) }
        }
    }

    /// Decode off the main actor, persist on it.
    ///
    /// A five-hour ride is ~18 000 records; parsing it and re-encoding the
    /// streams to JSON took long enough to visibly freeze the UI, and picking
    /// several files multiplied that. Only the SwiftData writes have to be on
    /// the main actor, so only they stay there.
    private func runImport(_ urls: [URL]) async {
        importingFiles = true
        defer { importingFiles = false }

        var added = 0, duplicates = 0
        var failures: [String] = []

        for url in urls {
            do {
                let decoded = try await Task.detached(priority: .userInitiated) {
                    // Sandboxed builds need explicit scoped access to picked files.
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try FITImporter().decode(url: url)
                }.value
                try FITImporter().persist(decoded, in: context)
                added += 1
            } catch FITPersistError.duplicate {
                duplicates += 1
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        var lines = ["Added \(added)."]
        if duplicates > 0 { lines.append("Skipped \(duplicates) already-imported.") }
        if !failures.isEmpty {
            lines.append("Failed \(failures.count):")
            lines.append(contentsOf: failures.prefix(5))
        }
        show("Import complete", lines.joined(separator: "\n"))
    }

    private func delete(_ offsets: IndexSet) {
        // Index into the visible list — deleting by unfiltered index would
        // remove the wrong rows whenever a filter is active.
        let visible = filtered
        for i in offsets where visible.indices.contains(i) {
            context.delete(visible[i])
        }
    }

    private func show(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
    }
}

struct WorkoutRow: View {
    @Environment(\.units) private var units
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The icon is `.title2`, so it grows with the text — a fixed 30-point
    /// frame stops holding it at accessibility sizes and the glyph spills over
    /// the date beside it. Scaling the frame with the same text style keeps
    /// them apart.
    @ScaledMetric(relativeTo: .title2) private var iconWidth: CGFloat = 30

    let workout: Workout

    /// At accessibility text sizes the row's own layout is the problem, not the
    /// font. Side by side, a date and its time wrap to one word per line and a
    /// single workout fills the screen — the list stops being scannable for
    /// exactly the people who turned the text up. Stacked, with the time on the
    /// line below, it stays a list.
    private var isAccessibilitySize: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: workout.sport.symbolName)
                .font(.title2)
                .frame(width: iconWidth)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(workout.startedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.headline)
                if isAccessibilitySize {
                    Text(workout.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let shoe = workout.shoe {
                        Text(shoe.displayName)
                    }
                    if let badge = sourceBadge {
                        Text(badge)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            // The map hint is decoration, and at large sizes it costs width the
            // text needs far more.
            if workout.hasRoute && !isAccessibilitySize {
                Image(systemName: "map")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        // One element to VoiceOver, spoken as a sentence, rather than five
        // fragments read in layout order.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [workout.sport.displayName,
                     workout.startedAt.formatted(date: .abbreviated, time: .shortened),
                     spokenSubtitle]
        if let shoe = workout.shoe { parts.append(shoe.displayName) }
        return parts.joined(separator: ", ")
    }

    /// Where this row came from, when it isn't a plain manual entry.
    private var sourceBadge: String? {
        switch workout.source {
        case "strava":    return "Strava"
        case "intervals": return "intervals.icu"
        case "pdf":       return "from PDF"
        case "fit":       return "watch"
        default:          return nil
        }
    }

    private var subtitle: String {
        var parts = [units.distance(workout.distance), units.duration(workout.duration)]
        if let pace = workout.paceSecPerKm {
            parts.append(units.rate(pace, sport: workout.sport))
        }
        if let hr = workout.avgHeartRate {
            parts.append("\(hr) bpm")
        }
        return parts.joined(separator: " · ")
    }

    /// The same facts without the separators, which VoiceOver reads aloud as
    /// "middle dot" between every number.
    private var spokenSubtitle: String {
        var parts = [units.distance(workout.distance), units.duration(workout.duration)]
        if let pace = workout.paceSecPerKm {
            parts.append(units.rate(pace, sport: workout.sport))
        }
        if let hr = workout.avgHeartRate {
            parts.append(String(localized: "\(hr) bpm"))
        }
        return parts.joined(separator: ", ")
    }
}
