import XCTest
import SwiftData
@testable import FitnessTracker

/// The folder the app re-checks for new `.fit` files.
///
/// The design rests on one property: re-importing is free, because FIT files
/// dedupe on a content hash. If that stopped holding, every scan would duplicate
/// the whole folder — so it's what these test hardest.
@MainActor
final class WatchedFolderTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var folder: URL!

    override func setUpWithError() throws {
        suite = "WatchedFolderTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        folder = URL.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func writeFIT(_ name: String, start: TimeInterval = 1_700_000_000) throws {
        let data = try FITFixture.encodedRun(start: Date(timeIntervalSince1970: start))
        try data.write(to: folder.appendingPathComponent(name))
    }

    // MARK: - Remembering a folder

    func testRememberAndResolveRoundTrip() throws {
        XCTAssertFalse(WatchedFolder.hasFolder(defaults))
        XCTAssertNil(WatchedFolder.resolve(defaults))

        try WatchedFolder.remember(folder, defaults)

        XCTAssertTrue(WatchedFolder.hasFolder(defaults))
        let resolved = try XCTUnwrap(WatchedFolder.resolve(defaults))
        XCTAssertEqual(resolved.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertNotNil(WatchedFolder.displayPath(defaults))
    }

    func testForgettingClearsIt() throws {
        try WatchedFolder.remember(folder, defaults)
        WatchedFolder.forget(defaults)

        XCTAssertFalse(WatchedFolder.hasFolder(defaults))
        XCTAssertNil(WatchedFolder.resolve(defaults))
        XCTAssertNil(WatchedFolder.displayPath(defaults))
    }

    /// A folder can be deleted between launches. That has to report itself
    /// rather than silently doing nothing, or "auto-import stopped working" has
    /// no visible cause.
    func testADeletedFolderReportsAsUnavailable() async throws {
        try WatchedFolder.remember(folder, defaults)
        try FileManager.default.removeItem(at: folder)

        let report = await WatchedFolder.scan(into: try FITFixture.makeContext(),
                                              defaults: defaults)
        XCTAssertTrue(report.unavailable)
        XCTAssertTrue(report.summary.contains("moved, renamed or deleted"))
    }

    /// No folder set is not an error — it's the default state.
    func testNoFolderIsNotAnError() async throws {
        let report = await WatchedFolder.scan(into: try FITFixture.makeContext(),
                                              defaults: defaults)
        XCTAssertFalse(report.unavailable)
        XCTAssertEqual(report.imported, 0)
    }

    // MARK: - The enable switch

    func testWatchingDefaultsOnButRespectsBeingTurnedOff() async throws {
        XCTAssertTrue(WatchedFolder.isEnabled(defaults))

        try writeFIT("run.fit")
        try WatchedFolder.remember(folder, defaults)
        WatchedFolder.setEnabled(false, defaults)

        let context = try FITFixture.makeContext()
        let report = await WatchedFolder.scan(into: context, defaults: defaults)
        XCTAssertEqual(report.imported, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Workout>()).isEmpty)
    }

    /// Turning it off must not lose which folder was chosen.
    func testDisablingKeepsTheChosenFolder() throws {
        try WatchedFolder.remember(folder, defaults)
        WatchedFolder.setEnabled(false, defaults)

        XCTAssertTrue(WatchedFolder.hasFolder(defaults))
        XCTAssertNotNil(WatchedFolder.resolve(defaults))
    }

    // MARK: - Scanning

    func testScanImportsEveryFITFileInTheFolder() async throws {
        try writeFIT("a.fit", start: 1_700_000_000)
        try writeFIT("b.fit", start: 1_700_100_000)
        try Data("not a fit file".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try WatchedFolder.remember(folder, defaults)

        let context = try FITFixture.makeContext()
        let report = await WatchedFolder.scan(into: context, defaults: defaults)

        XCTAssertEqual(report.imported, 2)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 2)
    }

    /// The property the whole design rests on: scanning the same folder again
    /// adds nothing. If this broke, every launch would duplicate the library.
    func testRescanningImportsNothingNew() async throws {
        try writeFIT("a.fit", start: 1_700_000_000)
        try writeFIT("b.fit", start: 1_700_100_000)
        try WatchedFolder.remember(folder, defaults)

        let context = try FITFixture.makeContext()
        let first = await WatchedFolder.scan(into: context, defaults: defaults)
        try context.save()
        XCTAssertEqual(first.imported, 2)

        let second = await WatchedFolder.scan(into: context, defaults: defaults)
        try context.save()

        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.alreadyHad, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 2)
        XCTAssertTrue(second.summary.contains("Nothing new"))
    }

    func testOnlyTheNewFileIsImportedOnASubsequentScan() async throws {
        try writeFIT("a.fit", start: 1_700_000_000)
        try WatchedFolder.remember(folder, defaults)

        let context = try FITFixture.makeContext()
        _ = await WatchedFolder.scan(into: context, defaults: defaults)
        try context.save()

        // A new export lands in the folder.
        try writeFIT("b.fit", start: 1_700_200_000)
        let report = await WatchedFolder.scan(into: context, defaults: defaults)
        try context.save()

        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.alreadyHad, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 2)
    }

    /// The same ride exported twice under different names is one workout, and
    /// the report must say so rather than claiming two.
    func testIdenticalBytesUnderTwoNamesAreOneWorkout() async throws {
        let data = try FITFixture.encodedRun()
        try data.write(to: folder.appendingPathComponent("run.fit"))
        try data.write(to: folder.appendingPathComponent("run (1).fit"))
        try WatchedFolder.remember(folder, defaults)

        let context = try FITFixture.makeContext()
        let report = await WatchedFolder.scan(into: context, defaults: defaults)

        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.alreadyHad, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 1)
    }

    /// A corrupt file must cost itself, not the rest of the scan.
    func testAnUndecodableFileDoesNotStopTheScan() async throws {
        try Data("garbage".utf8).write(to: folder.appendingPathComponent("broken.fit"))
        try writeFIT("good.fit")
        try WatchedFolder.remember(folder, defaults)

        let context = try FITFixture.makeContext()
        let report = await WatchedFolder.scan(into: context, defaults: defaults)

        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.failed, 1)
        XCTAssertTrue(report.summary.contains("1 failed"))
    }

    func testAnEmptyFolderSaysSo() async throws {
        try WatchedFolder.remember(folder, defaults)
        let report = await WatchedFolder.scan(into: try FITFixture.makeContext(),
                                              defaults: defaults)
        XCTAssertEqual(report.imported, 0)
        XCTAssertTrue(report.summary.contains("No .fit files"))
    }

    /// Shallow, like the drop path — walking an entire home directory because
    /// someone picked it by mistake is not a favour.
    func testScanDoesNotRecurseIntoSubfolders() async throws {
        let archive = folder.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FITFixture.encodedRun().write(to: archive.appendingPathComponent("buried.fit"))
        try writeFIT("top.fit", start: 1_700_300_000)
        try WatchedFolder.remember(folder, defaults)

        let report = await WatchedFolder.scan(into: try FITFixture.makeContext(),
                                              defaults: defaults)
        XCTAssertEqual(report.imported, 1)
    }

    // MARK: - Reporting

    func testSummaryReadsNaturallyForEachOutcome() {
        XCTAssertTrue(WatchedFolder.Report(unavailable: true).summary.contains("couldn't be opened"))
        XCTAssertTrue(WatchedFolder.Report().summary.contains("No .fit files"))
        XCTAssertTrue(WatchedFolder.Report(alreadyHad: 12).summary.contains("Nothing new"))

        let mixed = WatchedFolder.Report(imported: 3, alreadyHad: 40, failed: 1)
        XCTAssertTrue(mixed.summary.contains("Imported 3"))
        XCTAssertTrue(mixed.summary.contains("skipped 40"))
        XCTAssertTrue(mixed.summary.contains("1 failed"))
        XCTAssertTrue(mixed.foundAnything)
        XCTAssertFalse(WatchedFolder.Report(alreadyHad: 5).foundAnything)
    }
}
