import SwiftUI
import SwiftData
import AuthenticationServices
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var stravaClientID = CredentialStore.get(.stravaClientID) ?? ""
    @State private var stravaClientSecret = CredentialStore.get(.stravaClientSecret) ?? ""
    @State private var intervalsKey = CredentialStore.get(.intervalsAPIKey) ?? ""
    @State private var intervalsAthlete = CredentialStore.get(.intervalsAthleteID) ?? ""
    @State private var anthropicKey = CredentialStore.get(.anthropicAPIKey) ?? ""
    @Environment(\.syncStatus) private var syncStatus
    @AppStorage(StoreConfiguration.syncEnabledKey) private var iCloudSyncEnabled = true
    @AppStorage(WatchedFolder.enabledKey) private var watchedFolderEnabled = true
    @AppStorage(UnitSystem.defaultsKey) private var unitSystem: UnitSystem = .metric
    @AppStorage("maxHeartRate") private var maxHeartRate = 0
    @AppStorage(AthleteProfile.Key.thresholdHeartRate) private var thresholdHeartRate = 0
    @AppStorage("restingHeartRate") private var restingHeartRate = 0
    @AppStorage("ftpWatts") private var ftp = 0
    @AppStorage("bodyWeightKg") private var bodyWeight = 0.0

    @State private var stravaConnected = StravaProvider().isConfigured
    @State private var syncing = false
    @State private var exportingHealth = false
    @State private var scanningFolder = false
    @State private var estimating = false
    @State private var estimates: ThresholdEstimator.Result?
    @State private var pickingFolder = false
    /// Mirrors the resolved bookmark so the row updates when it changes.
    @State private var watchedFolderPath: String? = WatchedFolder.displayPath()
    @State private var exportedFile: URL?
    @State private var restoring = false
    @State private var pendingHealthExport = 0
    @State private var message: String?
    @State private var messageTitle = ""

    private let authController = WebAuthController()

    var body: some View {
        NavigationStack {
            Form {
                syncStatusSection
                watchedFolderSection
                unitsSection
                backupSection
                appleHealthSection
                estimateSection
                trainingSection
                cyclingSection
                syncSection
                stravaSection
                intervalsSection
                anthropicSection
                unsupportedSection
                dangerSection
            }
            .navigationTitle("Settings")
            .task { refreshPendingCount() }
            .fileImporter(isPresented: $restoring,
                          allowedContentTypes: [.json],
                          onCompletion: handleRestore)
            .fileImporter(isPresented: $pickingFolder,
                          allowedContentTypes: [.folder],
                          onCompletion: handleFolderPick)
            .sheet(item: $exportedFile) { url in
                ShareLinkSheet(url: url)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(messageTitle, isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    // MARK: - Estimating thresholds

    /// Derive FTP, threshold HR and max HR from recorded efforts.
    ///
    /// These were all numbers the athlete had to already know. The whole load
    /// model rests on them, so someone who didn't know their FTP got
    /// duration-estimated load for every ride — a worse number, silently.
    private var estimateSection: some View {
        Section {
            Button {
                Task { await estimateThresholds() }
            } label: {
                HStack {
                    Text(estimating ? "Reading your efforts…" : "Estimate from my training")
                    if estimating { Spacer(); ProgressView() }
                }
            }
            .disabled(estimating)

            if let estimates, !estimates.isEmpty {
                ForEach(ThresholdEstimator.Kind.allCases) { kind in
                    if let estimate = ThresholdEstimator.estimate(kind, in: estimates) {
                        EstimateRow(kind: kind, estimate: estimate,
                                    current: currentValue(for: kind)) {
                            apply(kind, estimate)
                        }
                    }
                }
            } else if estimates != nil {
                Text("No efforts long enough to read a threshold from yet. These need a 20-minute stretch of recorded power or heart rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Estimate thresholds")
        } footer: {
            Text("Reads your best 20-minute efforts from the last year. Every figure is a convention applied to your own training, not a lab test — each row says what it rests on, and nothing is applied until you tap it.")
        }
    }

    private func currentValue(for kind: ThresholdEstimator.Kind) -> Int {
        switch kind {
        case .ftp:                return ftp
        case .lactateThresholdHR: return thresholdHeartRate
        case .maxHeartRate:       return maxHeartRate
        }
    }

    private func apply(_ kind: ThresholdEstimator.Kind, _ estimate: ThresholdEstimator.Estimate) {
        switch kind {
        case .ftp:                ftp = estimate.value
        case .lactateThresholdHR: thresholdHeartRate = estimate.value
        case .maxHeartRate:       maxHeartRate = estimate.value
        }
    }

    private func estimateThresholds() async {
        estimating = true
        defer { estimating = false }

        let snapshots = (try? context.fetch(FetchDescriptor<Workout>()))?.map(\.snapshot) ?? []
        let since = ThresholdEstimator.defaultWindowStart()
        estimates = await Task.detached(priority: .userInitiated) {
            ThresholdEstimator.estimate(from: snapshots, since: since)
        }.value
    }

    // MARK: - Watched folder

    /// A folder the app re-checks for new `.fit` files.
    private var watchedFolderSection: some View {
        Section {
            Toggle("Check a folder for new files", isOn: Binding(
                get: { watchedFolderEnabled },
                set: { watchedFolderEnabled = $0 }
            ))

            if let path = WatchedFolder.displayPath() {
                LabeledContent("Folder") {
                    Text(path)
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                }
                Button("Scan now") { Task { await scanWatchedFolder() } }
                    .disabled(scanningFolder || !watchedFolderEnabled)
                Button("Stop watching", role: .destructive) {
                    WatchedFolder.forget()
                    watchedFolderPath = nil
                }
            } else {
                Button("Choose a folder…") { pickingFolder = true }
            }
        } header: {
            Text("Watched folder")
        } footer: {
            Text("""
                Point this at the folder your watch app exports to and new `.fit` \
                files are imported whenever you open the app. It's checked on \
                activation rather than continuously — and re-importing is free, \
                since files dedupe on their contents.
                """)
        }
    }

    private func scanWatchedFolder() async {
        scanningFolder = true
        defer { scanningFolder = false }
        let report = await WatchedFolder.scan(into: context)
        messageTitle = "Watched folder"
        message = report.summary
    }

    private func handleFolderPick(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            messageTitle = "Watched folder"
            message = error.localizedDescription
        case .success(let url):
            do {
                try WatchedFolder.remember(url)
                watchedFolderPath = WatchedFolder.displayPath()
                Task { await scanWatchedFolder() }
            } catch {
                messageTitle = "Watched folder"
                message = "Couldn't keep access to that folder: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - iCloud

    /// Reports what the store actually opened as, not what the preference says.
    ///
    /// Those differ often — an ad-hoc build has no entitlement, an account can
    /// be signed out — and showing the preference in that situation would be a
    /// lie about where someone's data lives.
    private var syncStatusSection: some View {
        Section {
            Toggle("Sync with iCloud", isOn: Binding(
                get: { iCloudSyncEnabled },
                set: { iCloudSyncEnabled = $0 }
            ))
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Image(systemName: syncStatus.isSyncing
                          ? "checkmark.icloud.fill" : "icloud.slash")
                        .foregroundStyle(syncStatus.isSyncing ? Color.green : Color.secondary)
                    Text(syncStatus.label)
                }
            }
            if iCloudSyncEnabled != syncStatus.isSyncing {
                Text("Quit and reopen the app to apply this.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text(syncStatus.detail)
        }
    }

    // MARK: - Backup

    /// Export everything, and read it back.
    ///
    /// A backup you can't restore is only half a safety net, so both directions
    /// live here. Restore merges rather than replacing — it never deletes, and
    /// it dedupes on the same identity the importers use.
    private var backupSection: some View {
        Section {
            Button {
                exportArchive(includeStreams: true)
            } label: {
                Label("Export everything…", systemImage: "arrow.down.doc")
            }
            Button {
                exportArchive(includeStreams: false)
            } label: {
                Label("Export summary only…", systemImage: "doc.plaintext")
            }
            Button {
                exportCSV()
            } label: {
                Label("Export workouts as CSV…", systemImage: "tablecells")
            }
            Button {
                restoring = true
            } label: {
                Label("Restore from a backup…", systemImage: "arrow.up.doc")
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("""
                The full export is plain JSON and includes GPS tracks and sensor \
                streams, so it can be restored exactly — and it's large. The summary \
                leaves those out. Restoring merges into what's already here; it never \
                deletes anything.
                """)
        }
    }

    private func exportArchive(includeStreams: Bool) {
        do {
            let data = try DataArchive.exportData(from: context, includeStreams: includeStreams)
            shareFile(named: DataArchive.filename(includeStreams: includeStreams), data: data)
        } catch {
            messageTitle = "Export failed"
            message = error.localizedDescription
        }
    }

    private func exportCSV() {
        do {
            let archive = try DataArchive.archive(from: context, includeStreams: false)
            let csv = DataArchive.workoutsCSV(archive.workouts)
            shareFile(named: "fitnesstracker-workouts.csv", data: Data(csv.utf8))
        } catch {
            messageTitle = "Export failed"
            message = error.localizedDescription
        }
    }

    /// Writes to a temporary file and hands it to the share sheet — the share
    /// sheet takes a URL, and a multi-megabyte archive shouldn't be passed
    /// around in memory as a `Data` the system then copies again.
    private func shareFile(named name: String, data: Data) {
        let url = URL.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            exportedFile = url
        } catch {
            messageTitle = "Export failed"
            message = error.localizedDescription
        }
    }

    private func handleRestore(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result {
                messageTitle = "Restore failed"
                message = error.localizedDescription
            }
            return
        }
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let archive = try DataArchive.read(try Data(contentsOf: url))
            let report = try DataArchive.restore(archive, into: context)
            refreshPendingCount()
            messageTitle = "Restore complete"
            message = report.summary
        } catch {
            messageTitle = "Restore failed"
            message = error.localizedDescription
        }
    }

    // MARK: - Apple Health

    /// Push imported workouts back into Health.
    ///
    /// Only shown on iOS, and only when there's something to send. Suunto's own
    /// Health sync drops the GPS track and per-second heart rate, so for anyone
    /// importing `.fit` files this is the only way Health ends up with the real
    /// thing rather than a summary.
    @ViewBuilder
    private var appleHealthSection: some View {
        if HealthKitWriter.isAvailable {
            Section {
                Button {
                    Task { await exportToHealth() }
                } label: {
                    HStack {
                        Text(exportingHealth ? "Writing…" : "Write workouts to Apple Health")
                        if exportingHealth {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(exportingHealth || pendingHealthExport == 0)

                LabeledContent("Not yet in Health", value: "\(pendingHealthExport)")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Apple Health")
            } footer: {
                Text("""
                    Writes each imported workout with its route and heart-rate series, \
                    which is more than your watch's own Health sync carries. Demo data \
                    and workouts that came *from* Health are skipped, and nothing is \
                    written twice.
                    """)
            }
        }
    }

    private func exportToHealth() async {
        exportingHealth = true
        defer {
            exportingHealth = false
            refreshPendingCount()
        }
        do {
            let report = try await HealthKitWriter.exportPending(in: context)
            messageTitle = "Apple Health"
            message = report.failures.isEmpty
                ? report.summary
                : report.summary + "\n\n" + report.failures.prefix(5).joined(separator: "\n")
        } catch {
            messageTitle = "Apple Health"
            message = error.localizedDescription
        }
    }

    private func refreshPendingCount() {
        pendingHealthExport = HealthKitWriter.pendingExport(in: context).count
    }

    // MARK: - Units

    /// Display only. Everything is stored in SI and converted at the edge, so
    /// flipping this can't corrupt a personal best or shift a training-load
    /// curve — it re-labels the same numbers.
    private var unitsSection: some View {
        Section {
            Picker("Units", selection: $unitSystem) {
                ForEach(UnitSystem.allCases) { system in
                    Text(system.displayName).tag(system)
                }
            }
            .pickerStyle(.segmented)
            Text(unitSystem.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Units")
        } footer: {
            Text("Affects display only. Your data is stored in metric and converted for display, so switching back and forth never changes a recorded value.")
        }
    }

    /// A formatter for this sheet's own labels. Settings is presented as a
    /// sheet, which on some platforms doesn't inherit the root's environment,
    /// and it has to reflect the picker above it immediately anyway.
    private var units: UnitFormatter { UnitFormatter(unitSystem) }

    // MARK: - Training

    private var trainingSection: some View {
        Section {
            Stepper(value: $maxHeartRate, in: 0...230, step: 1) {
                LabeledContent("Maximum",
                               value: maxHeartRate >= 100 ? "\(maxHeartRate) bpm" : "Not set")
            }
            Stepper(value: $restingHeartRate, in: 0...100, step: 1) {
                LabeledContent("Resting",
                               value: restingHeartRate > 0 ? "\(restingHeartRate) bpm" : "Not set")
            }
            if maxHeartRate < 100 {
                Text("Until you set this, zones use the highest HR in your whole history — better than one session's peak, but still a guess.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Heart rate")
        } footer: {
            Text("""
                Max HR drives zone boundaries (50/60/70/80/90% of max). Use a figure \
                from a real max-effort test if you have one — age formulas are rough. \
                Resting HR sharpens training load: stress is scored against heart-rate \
                *reserve*, not raw bpm. Leave it blank on iOS and Health's measured \
                value is used instead.
                """)
        }
    }

    private var cyclingSection: some View {
        Section {
            Stepper(value: $ftp, in: 0...600, step: 5) {
                LabeledContent("FTP", value: ftp > 0 ? "\(ftp) W" : "Not set")
            }
            // A slider was a poor fit here: 0–150 kg in 0.5 kg steps is 300
            // positions to drag through, and it excluded anyone above 150 kg.
            //
            // Stepped in the displayed unit so imperial users move in pounds,
            // then converted back to the stored kilograms — a 0.5 kg step would
            // read as a bizarre 1.1 lb increment otherwise.
            Stepper(value: displayedBodyWeight, in: 0...(unitSystem == .metric ? 250 : 550), step: 0.5) {
                LabeledContent("Body weight",
                               value: bodyWeight > 0 ? units.weight(bodyWeight) : "Not set")
            }
        } header: {
            Text("Cycling")
        } footer: {
            Text("FTP unlocks Intensity Factor, TSS and power-based training load on rides. Body weight adds W/kg. Both are optional — average and normalized power work without them.")
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section("Sync") {
            Button {
                Task { await sync() }
            } label: {
                HStack {
                    Text(syncing ? "Syncing…" : "Sync now")
                    if syncing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(syncing || !anyProviderConfigured)

            if !anyProviderConfigured {
                Text("Connect Strava or intervals.icu below to enable syncing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayedBodyWeight: Binding<Double> {
        Binding(
            get: { units.displayedWeight(fromKilograms: bodyWeight) },
            set: { bodyWeight = units.kilograms(fromDisplayed: $0) }
        )
    }

    private var anyProviderConfigured: Bool {
        StravaProvider().isConfigured || IntervalsICUProvider().isConfigured
    }

    private func sync() async {
        syncing = true
        defer { syncing = false }
        let report = await SyncEngine(context: context).syncAll()
        messageTitle = "Sync complete"
        message = report.failures.isEmpty
            ? report.summary
            : report.summary + "\n\n" + report.failures.joined(separator: "\n")
    }

    // MARK: - Strava

    private var stravaSection: some View {
        Section {
            TextField("Client ID", text: $stravaClientID)
                .onChange(of: stravaClientID) { _, new in
                    CredentialStore.set(new, for: .stravaClientID)
                }
            SecureField("Client Secret", text: $stravaClientSecret)
                .onChange(of: stravaClientSecret) { _, new in
                    CredentialStore.set(new, for: .stravaClientSecret)
                }

            if stravaConnected {
                HStack {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Disconnect") {
                        StravaProvider.disconnect()
                        stravaConnected = false
                    }
                }
            } else {
                Button("Authorize with Strava") {
                    Task { await connectStrava() }
                }
                .disabled(stravaClientID.isEmpty || stravaClientSecret.isEmpty)
            }
        } header: {
            Text("Strava")
        } footer: {
            Text("""
                Create your own API application at strava.com/settings/api (free), \
                set the callback domain to `localhost`, then paste the Client ID and \
                Secret here. Requests the `activity:read_all` scope so private \
                activities sync too.
                """)
        }
    }

    private func connectStrava() async {
        guard let url = StravaProvider.authorizationURL() else { return }
        do {
            let callback = try await authController.authenticate(
                url: url, callbackScheme: "fitnesstracker"
            )
            guard let code = StravaProvider.authorizationCode(from: callback) else {
                messageTitle = "Strava"
                message = "Authorization was cancelled or returned no code."
                return
            }
            try await StravaProvider().exchange(code: code)
            stravaConnected = true
            messageTitle = "Strava"
            message = "Connected. Run Sync now to import activities."
        } catch {
            messageTitle = "Strava"
            message = error.localizedDescription
        }
    }

    // MARK: - intervals.icu

    private var intervalsSection: some View {
        Section {
            SecureField("API key", text: $intervalsKey)
                .onChange(of: intervalsKey) { _, new in
                    CredentialStore.set(new, for: .intervalsAPIKey)
                }
            TextField("Athlete ID (e.g. i123456, or 0 for yourself)", text: $intervalsAthlete)
                .onChange(of: intervalsAthlete) { _, new in
                    CredentialStore.set(new, for: .intervalsAthleteID)
                }
        } header: {
            Text("intervals.icu")
        } footer: {
            Text("""
                Your API key is at the bottom of the intervals.icu Settings page. \
                Leave Athlete ID blank to use the authenticated athlete.
                """)
        }
    }

    // MARK: - Anthropic

    private var anthropicSection: some View {
        Section {
            SecureField("Anthropic API key", text: $anthropicKey)
                .onChange(of: anthropicKey) { _, new in
                    CredentialStore.set(new, for: .anthropicAPIKey)
                }
        } header: {
            Text("AI PDF extraction")
        } footer: {
            Text("""
                Needed to read workouts out of PDFs. Get a key from \
                console.anthropic.com. Stored in the Keychain on this device — \
                extraction calls the API directly, so the key stays local and \
                usage is billed to your account.
                """)
        }
    }

    // MARK: - Not available

    private var unsupportedSection: some View {
        Section("Other services") {
            ForEach(ProviderKind.allCases.filter { !$0.isSupported }) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.displayName).font(.headline)
                    if case .unavailable(let reason) = kind.availability {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var dangerSection: some View {
        Section {
            Button("Remove all stored credentials", role: .destructive) {
                CredentialStore.removeAll()
                stravaClientID = ""; stravaClientSecret = ""
                intervalsKey = ""; intervalsAthlete = ""; anthropicKey = ""
                stravaConnected = false
            }
        }
    }
}

/// One estimated threshold, with what it rests on and a way to take it.
private struct EstimateRow: View {
    let kind: ThresholdEstimator.Kind
    let estimate: ThresholdEstimator.Estimate
    let current: Int
    let apply: () -> Void

    private var isCurrent: Bool { current == estimate.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(kind.displayName).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(estimate.value) \(kind.unit)")
                    .font(.callout.monospacedDigit())
                if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                } else {
                    Button("Use") { apply() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            Text(source)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(ThresholdEstimator.caveat(for: kind))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var source: String {
        let when = estimate.date.formatted(date: .abbreviated, time: .omitted)
        if estimate.windowSeconds > 0 {
            return "From \(estimate.observed) \(kind.unit) over \(estimate.windowMinutes) min on \(when)"
                + (current > 0 ? " · currently \(current) \(kind.unit)" : "")
        }
        return "Recorded \(when)" + (current > 0 ? " · currently \(current) \(kind.unit)" : "")
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Hands an exported file to the system share sheet.
///
/// A plain `ShareLink` in the Form row would rebuild the archive on every
/// redraw of Settings; exporting on tap and presenting the result keeps the
/// expensive part to one call.
struct ShareLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "doc.badge.arrow.up")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text(url.lastPathComponent)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size),
                                                   countStyle: .file))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Spacer()
            }
            .padding()
            .navigationTitle("Export ready")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Wraps `ASWebAuthenticationSession` in an async call.
@MainActor
final class WebAuthController: NSObject, ASWebAuthenticationPresentationContextProviding {

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(
                        throwing: error ?? ProviderError.notConfigured("OAuth")
                    )
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.windows.first { $0.isKeyWindow }
            ?? NSApplication.shared.windows.first
            ?? ASPresentationAnchor()
        #else
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
        #endif
    }
}
