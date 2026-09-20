import SwiftUI
import SwiftData
import OSLog

@main
struct FitnessTrackerApp: App {

    private static let log = Logger(subsystem: "com.slavov.fitnesstracker", category: "store")

    /// Every model the store holds. Listed once so the app and the recovery
    /// path can't drift apart.
    static let schema = Schema([
        Workout.self,
        Shoe.self,
        StrengthSession.self,
        SetEntry.self,
        Exercise.self,
        Routine.self,
        RoutineItem.self,
        BodyMeasurement.self,
        ProgressPhoto.self,
        DailyMetric.self,
        Route.self,
        PlannedWorkout.self,
        Race.self,
    ])

    /// The live container, or `nil` if the store could not be opened.
    ///
    /// `.modelContainer(for:)` traps on failure, which turns any store problem —
    /// a migration that can't be inferred, a corrupt file, a full disk — into a
    /// launch crash with no explanation and no way out. Years of training
    /// history deserve better than that, so failure is caught and reported with
    /// the file still on disk for recovery.
    private let container: ModelContainer?
    private let failure: String?
    private let syncStatus: StoreConfiguration.Status

    /// Light/dark/system, applied to the whole window.
    ///
    /// It lives here rather than on `RootView` so the recovery screen obeys it
    /// too: the one moment you are certainly reading carefully is the moment
    /// the database wouldn't open.
    @AppStorage(Appearance.defaultsKey) private var appearance: Appearance = .system

    init() {
        do {
            let opened = try StoreConfiguration.open(schema: Self.schema)
            container = opened.container
            syncStatus = opened.status
            failure = nil
        } catch {
            Self.log.error("store failed to open: \(error.localizedDescription, privacy: .public)")
            container = nil
            syncStatus = .localOnly(reason: "The store couldn't be opened.")
            failure = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container {
                    RootView()
                        .modelContainer(container)
                        .environment(\.syncStatus, syncStatus)
                } else {
                    StoreFailureView(message: failure ?? "Unknown error")
                }
            }
            .preferredColorScheme(appearance.colorScheme)
            // A Mac window opens at whatever its content will tolerate, and
            // this content tolerates far too little: five tabs of charts and
            // tables collapsed into 900×450, where onboarding arrives already
            // scrolled and the dashboard's curves have no room to say anything.
            // A floor, and a first-launch size with space for a chart.
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 560)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1_180, height: 820)
        // Honour the minimum above rather than letting the window shrink past
        // the point where the layout stops working.
        .windowResizability(.contentMinSize)
        #endif
    }
}

private struct SyncStatusKey: EnvironmentKey {
    static let defaultValue = StoreConfiguration.Status.syncDisabled
}

extension EnvironmentValues {
    /// What the store actually opened as, so Settings can report the truth
    /// rather than the preference.
    var syncStatus: StoreConfiguration.Status {
        get { self[SyncStatusKey.self] }
        set { self[SyncStatusKey.self] = newValue }
    }
}

/// Shown instead of crashing when the database can't be opened.
///
/// It deliberately offers no "reset" button: the store file is still there, and
/// silently deleting someone's training history to get past an error screen is
/// the worst possible response to a problem that's usually recoverable.
struct StoreFailureView: View {
    /// The underlying error's own description — already resolved text, not a
    /// key, so it goes into `Text(verbatim:)`.
    let message: String

    private var storeLocation: String {
        URL.applicationSupportDirectory.appendingPathComponent("default.store").path
    }

    var body: some View {
        ContentUnavailableView {
            Label("Can't open your training database", systemImage: "externaldrive.badge.xmark")
        } description: {
            VStack(spacing: 12) {
                Text(verbatim: message)
                Text("""
                    Your data hasn't been deleted. The file is still at:
                    \(storeLocation)

                    Quit and reopen the app first. If that doesn't help, copy that \
                    file somewhere safe before trying anything else.
                    """)
                .font(.caption)
            }
        }
        .padding()
    }
}
