import Foundation
import SwiftData
import OSLog

/// Builds the app's `ModelContainer`, with iCloud sync when it's available.
///
/// Sync is attempted, not assumed. A build signed ad-hoc has no iCloud
/// entitlement, a simulator may have no account, and a user may simply be
/// signed out — in every one of those cases the container init throws. Treating
/// that as fatal would mean the app refuses to open someone's local training
/// history because a *remote* feature isn't available, which is the wrong
/// trade every time. So it falls back to a local store and says so.
enum StoreConfiguration {

    private static let log = Logger(subsystem: "com.slavov.fitnesstracker", category: "store")

    static let cloudContainerIdentifier = "iCloud.com.slavov.fitnesstracker"
    static let syncEnabledKey = "iCloudSyncEnabled"

    /// Whether the athlete has asked for sync. Defaults to on: two devices
    /// disagreeing about your training history is a worse surprise than sync
    /// you didn't explicitly request, and it degrades silently when unavailable.
    static func syncRequested(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: syncEnabledKey) as? Bool ?? true
    }

    static func setSyncRequested(_ enabled: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: syncEnabledKey)
    }

    /// What actually happened when the store opened, for Settings to report.
    enum Status: Equatable, Sendable {
        case syncing
        case localOnly(reason: String)
        case syncDisabled

        var isSyncing: Bool { self == .syncing }

        var label: String {
            switch self {
            case .syncing:      return "Syncing with iCloud"
            case .localOnly:    return "This device only"
            case .syncDisabled: return "Sync turned off"
            }
        }

        var detail: String {
            switch self {
            case .syncing:
                return "Workouts, metrics and routes are shared with your other devices through your private iCloud database. Nothing goes to any server of ours."
            case .localOnly(let reason):
                return "iCloud sync isn't available, so everything is stored on this device. \(reason)"
            case .syncDisabled:
                return "Everything is stored on this device. Turn sync on to share it with your other devices."
            }
        }
    }

    struct Result {
        let container: ModelContainer
        let status: Status
    }

    /// Open the store: CloudKit first when requested, local as the fallback.
    ///
    /// - Throws: only when the *local* store can't be opened either, which is a
    ///   genuine failure worth showing the user.
    static func open(
        schema: Schema,
        syncRequested: Bool = StoreConfiguration.syncRequested(),
        inMemory: Bool = false
    ) throws -> Result {
        guard syncRequested, !inMemory else {
            let configuration = ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
            return Result(container: try ModelContainer(for: schema, configurations: configuration),
                          status: inMemory ? .localOnly(reason: "Running in memory.") : .syncDisabled)
        }

        let cloudConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private(cloudContainerIdentifier)
        )
        do {
            let container = try ModelContainer(for: schema, configurations: cloudConfiguration)
            log.info("store opened with iCloud sync")
            return Result(container: container, status: .syncing)
        } catch {
            // Most likely a missing entitlement (ad-hoc signing) or no iCloud
            // account. Either way the local store is still perfectly usable.
            log.notice("iCloud unavailable, falling back to local: \(error.localizedDescription, privacy: .public)")
            let localConfiguration = ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: localConfiguration)
            return Result(container: container, status: .localOnly(reason: explain(error)))
        }
    }

    /// Turns a CloudKit failure into something worth reading.
    ///
    /// The raw errors here are unusually bad. A missing entitlement surfaces as
    /// `SwiftDataError error 1` with the generic "operation couldn't be
    /// completed" text, which tells the athlete nothing at all — so an
    /// unrecognised failure names the two things that actually cause it rather
    /// than echoing the string.
    static func explain(_ error: Error) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("entitlement") || text.contains("not authorized") {
            return "This build isn't signed with an iCloud entitlement — set your development team in Xcode."
        }
        if text.contains("account") || text.contains("signed in") {
            return "Sign in to iCloud in system Settings to enable it."
        }
        if text.contains("network") || text.contains("offline") {
            return "Couldn't reach iCloud. It'll retry on its own."
        }
        if text.contains("swiftdataerror") || text.contains("couldn't be completed") {
            return "Usually that means the build has no iCloud entitlement, or this device isn't signed in to iCloud."
        }
        return error.localizedDescription
    }
}
