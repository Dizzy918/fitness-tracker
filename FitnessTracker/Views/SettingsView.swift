import SwiftUI
import SwiftData
import AuthenticationServices

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var stravaClientID = CredentialStore.get(.stravaClientID) ?? ""
    @State private var stravaClientSecret = CredentialStore.get(.stravaClientSecret) ?? ""
    @State private var intervalsKey = CredentialStore.get(.intervalsAPIKey) ?? ""
    @State private var intervalsAthlete = CredentialStore.get(.intervalsAthleteID) ?? ""
    @State private var anthropicKey = CredentialStore.get(.anthropicAPIKey) ?? ""
    @AppStorage("maxHeartRate") private var maxHeartRate = 0
    @AppStorage("restingHeartRate") private var restingHeartRate = 0
    @AppStorage("ftpWatts") private var ftp = 0
    @AppStorage("bodyWeightKg") private var bodyWeight = 0.0

    @State private var stravaConnected = StravaProvider().isConfigured
    @State private var syncing = false
    @State private var message: String?
    @State private var messageTitle = ""

    private let authController = WebAuthController()

    var body: some View {
        NavigationStack {
            Form {
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
            Stepper(value: $bodyWeight, in: 0...250, step: 0.5) {
                LabeledContent("Body weight",
                               value: bodyWeight > 0 ? String(format: "%.1f kg", bodyWeight) : "Not set")
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
