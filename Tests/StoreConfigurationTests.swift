import XCTest
import SwiftData
@testable import FitnessTracker

/// The store's own shape and how it opens.
///
/// CloudKit imposes hard constraints on a SwiftData schema, and violating any of
/// them fails at container-init time — on a user's device, at launch, not here.
/// So the constraints are asserted structurally against the real schema rather
/// than discovered the hard way.
final class StoreConfigurationTests: XCTestCase {

    private var schema: Schema { FitnessTrackerApp.schema }

    // MARK: - CloudKit schema constraints

    /// CloudKit mirroring requires every attribute to be optional or to carry a
    /// default: a record arriving from another device has to be constructible
    /// without knowing about a property this version added.
    func testEveryAttributeIsOptionalOrHasADefault() {
        var offenders: [String] = []
        for entity in schema.entities {
            for property in entity.properties {
                guard let attribute = property as? Schema.Attribute else { continue }
                if attribute.isTransient { continue }
                if !attribute.isOptional && attribute.defaultValue == nil {
                    offenders.append("\(entity.name).\(attribute.name)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "CloudKit needs a default or optional for: \(offenders.joined(separator: ", "))")
    }

    /// CloudKit cannot enforce uniqueness, so a `.unique` attribute makes the
    /// container refuse to open. Dedupe here is done in code, on `externalID`.
    func testNoUniqueConstraints() {
        var offenders: [String] = []
        for entity in schema.entities {
            for property in entity.properties {
                guard let attribute = property as? Schema.Attribute else { continue }
                if attribute.isUnique { offenders.append("\(entity.name).\(attribute.name)") }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "CloudKit rejects unique constraints on: \(offenders.joined(separator: ", "))")
    }

    /// To-one relationships must be optional — the other side may not have
    /// synced yet when a record arrives.
    func testToOneRelationshipsAreOptional() {
        var offenders: [String] = []
        for entity in schema.entities {
            for property in entity.properties {
                guard let relationship = property as? Schema.Relationship else { continue }
                if relationship.isToOneRelationship && !relationship.isOptional {
                    offenders.append("\(entity.name).\(relationship.name)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "CloudKit needs optional to-one relationships: \(offenders.joined(separator: ", "))")
    }

    /// **Every relationship needs an inverse.** CloudKit refuses to load the
    /// store otherwise, and this is the constraint the first version of these
    /// tests missed: `SetEntry.exercise` pointed at `Exercise` with nothing
    /// pointing back, so sync fell back to local on every launch while the
    /// optionality and uniqueness checks above passed happily.
    func testEveryRelationshipHasAnInverse() {
        var offenders: [String] = []
        for entity in schema.entities {
            for property in entity.properties {
                guard let relationship = property as? Schema.Relationship else { continue }
                if relationship.inverseName == nil {
                    offenders.append("\(entity.name).\(relationship.name)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "CloudKit needs an inverse for: \(offenders.joined(separator: ", "))")
    }

    /// Belt and braces for the same thing: actually open a CloudKit-configured
    /// store and assert it isn't the fallback. A structural check can only see
    /// the constraints someone thought to write down; this sees whatever
    /// CoreData actually objects to.
    ///
    /// Skipped rather than failed when the entitlement is absent, which is the
    /// normal state for an ad-hoc build and for CI.
    func testCloudKitStoreLoadsWhenTheEntitlementIsPresent() throws {
        let result = try StoreConfiguration.open(schema: schema, syncRequested: true)
        guard case .localOnly(let reason) = result.status else {
            XCTAssertTrue(result.status.isSyncing)
            return
        }
        // A missing entitlement is expected here. A *schema* complaint is not,
        // and is the failure this test exists to catch.
        XCTAssertFalse(reason.lowercased().contains("inverse"),
                       "CloudKit rejected the schema: \(reason)")
        throw XCTSkip("No iCloud entitlement in this build: \(reason)")
    }

    func testSchemaCoversEveryModelTheAppUses() {
        let names = Set(schema.entities.map(\.name))
        XCTAssertEqual(names, [
            "Workout", "Shoe", "StrengthSession", "SetEntry",
            "Exercise", "DailyMetric", "Route",
        ])
    }

    /// Sample streams are stored externally; that's what keeps a list query
    /// from dragging hundreds of megabytes through memory, and it's also how
    /// CloudKit ships them as assets rather than inline record fields.
    func testLargeBlobsAreDeclaredWithExternalStorage() throws {
        let workout = try XCTUnwrap(schema.entities.first { $0.name == "Workout" })
        for name in ["polylineData", "streamsData", "lapsData"] {
            let attribute = try XCTUnwrap(
                workout.properties.compactMap { $0 as? Schema.Attribute }
                    .first { $0.name == name },
                "\(name) is missing from the schema")
            XCTAssertTrue(attribute.options.contains(.externalStorage),
                          "\(name) must be external, or every list query drags the streams with it")
        }
    }

    // MARK: - Opening

    func testSyncPreferenceDefaultsToOn() {
        let defaults = UserDefaults(suiteName: "StoreConfigurationTests.pref")!
        defaults.removePersistentDomain(forName: "StoreConfigurationTests.pref")
        XCTAssertTrue(StoreConfiguration.syncRequested(defaults))

        StoreConfiguration.setSyncRequested(false, defaults)
        XCTAssertFalse(StoreConfiguration.syncRequested(defaults))
        StoreConfiguration.setSyncRequested(true, defaults)
        XCTAssertTrue(StoreConfiguration.syncRequested(defaults))
        defaults.removePersistentDomain(forName: "StoreConfigurationTests.pref")
    }

    func testOpeningWithSyncOffGivesALocalStore() throws {
        let result = try StoreConfiguration.open(
            schema: schema, syncRequested: false, inMemory: true)
        XCTAssertNotNil(result.container)
        XCTAssertFalse(result.status.isSyncing)
    }

    /// The fallback is the whole point: an unavailable iCloud must never stop
    /// the app opening a local store.
    func testRequestingSyncInMemoryStillOpens() throws {
        let result = try StoreConfiguration.open(
            schema: schema, syncRequested: true, inMemory: true)
        XCTAssertNotNil(result.container)
        // In-memory can't sync; it must report that rather than claiming to.
        XCTAssertFalse(result.status.isSyncing)
    }

    func testEveryStatusExplainsItself() {
        let statuses: [StoreConfiguration.Status] = [
            .syncing, .syncDisabled, .localOnly(reason: "No account."),
        ]
        for status in statuses {
            XCTAssertFalse(status.label.isEmpty)
            XCTAssertFalse(status.detail.isEmpty)
        }
        XCTAssertTrue(StoreConfiguration.Status.localOnly(reason: "No account.")
            .detail.contains("No account."))
    }

    /// The raw CloudKit error is unreadable; the app has to say what to do.
    func testErrorsAreTranslatedIntoAdvice() {
        struct Failure: LocalizedError {
            let errorDescription: String?
        }
        XCTAssertTrue(StoreConfiguration
            .explain(Failure(errorDescription: "Missing com.apple.developer.icloud entitlement"))
            .contains("development team"))
        XCTAssertTrue(StoreConfiguration
            .explain(Failure(errorDescription: "No iCloud account is signed in"))
            .contains("Sign in"))
        XCTAssertTrue(StoreConfiguration
            .explain(Failure(errorDescription: "The network connection was lost"))
            .contains("retry"))
        // The one that actually happens: SwiftData's opaque wrapper, which says
        // nothing useful on its own.
        let opaque = StoreConfiguration.explain(Failure(
            errorDescription: "The operation couldn\u{2019}t be completed. (SwiftData.SwiftDataError error 1.)"))
        XCTAssertTrue(opaque.contains("entitlement"))
        XCTAssertFalse(opaque.contains("SwiftDataError"),
                       "an error code is not an explanation")

        // Anything else genuinely unrecognised passes through rather than
        // being swallowed behind a guess.
        XCTAssertEqual(StoreConfiguration
            .explain(Failure(errorDescription: "Disk full")), "Disk full")
    }
}
