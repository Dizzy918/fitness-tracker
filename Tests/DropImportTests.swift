import XCTest
@testable import FitnessTracker

/// Expanding a drop into the files to import.
///
/// Dropping a *folder* is the common case on a Mac — watch apps export a
/// directory of `.fit` files — and a drop hands over the folder URL rather than
/// its contents, so the expansion is the whole feature.
final class DropImportTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL.temporaryDirectory
            .appendingPathComponent("DropImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? root).appendingPathComponent(name)
        try Data("fit bytes".utf8).write(to: url)
        return url
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Extension matching

    func testExtensionMatchIsCaseInsensitive() {
        XCTAssertTrue(FITImporter.isFIT(URL(filePath: "/tmp/ride.fit")))
        XCTAssertTrue(FITImporter.isFIT(URL(filePath: "/tmp/RIDE.FIT")))
        XCTAssertTrue(FITImporter.isFIT(URL(filePath: "/tmp/Ride.Fit")))
        XCTAssertFalse(FITImporter.isFIT(URL(filePath: "/tmp/ride.gpx")))
        XCTAssertFalse(FITImporter.isFIT(URL(filePath: "/tmp/fit")))
        XCTAssertFalse(FITImporter.isFIT(URL(filePath: "/tmp/notes.fit.txt")))
    }

    // MARK: - Files

    func testDroppedFilesAreFilteredToFITOnly() throws {
        let fit = try write("ride.fit")
        let gpx = try write("route.gpx")
        let readme = try write("README.md")

        let found = FITImporter.fitFiles(in: [fit, gpx, readme])
        XCTAssertEqual(found.map(\.lastPathComponent), ["ride.fit"])
    }

    func testDroppingNothingUsableReturnsNothing() throws {
        let gpx = try write("route.gpx")
        XCTAssertTrue(FITImporter.fitFiles(in: [gpx]).isEmpty)
        XCTAssertTrue(FITImporter.fitFiles(in: []).isEmpty)
    }

    // MARK: - Folders

    func testDroppedFolderIsExpandedToItsFITFiles() throws {
        let folder = try makeDirectory("exports")
        try write("b.fit", in: folder)
        try write("a.fit", in: folder)
        try write("notes.txt", in: folder)

        let found = FITImporter.fitFiles(in: [folder])
        XCTAssertEqual(found.map(\.lastPathComponent), ["a.fit", "b.fit"])
    }

    /// Shallow by design: recursing into a whole home directory because someone
    /// aimed badly is not a favour.
    func testFolderExpansionDoesNotRecurse() throws {
        let folder = try makeDirectory("exports")
        try write("top.fit", in: folder)
        let nested = folder.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("buried.fit", in: nested)

        let found = FITImporter.fitFiles(in: [folder])
        XCTAssertEqual(found.map(\.lastPathComponent), ["top.fit"])
    }

    func testHiddenFilesAreSkipped() throws {
        let folder = try makeDirectory("exports")
        try write("real.fit", in: folder)
        try write(".hidden.fit", in: folder)

        let found = FITImporter.fitFiles(in: [folder])
        XCTAssertEqual(found.map(\.lastPathComponent), ["real.fit"])
    }

    func testEmptyFolderYieldsNothing() throws {
        let folder = try makeDirectory("empty")
        XCTAssertTrue(FITImporter.fitFiles(in: [folder]).isEmpty)
    }

    // MARK: - Mixed drops

    /// Dropping a file *and* the folder containing it must not import it twice —
    /// the content hash would dedupe it on persist, but reporting "added 2" for
    /// one workout is a lie.
    func testAFileAndItsFolderDoNotYieldItTwice() throws {
        let folder = try makeDirectory("exports")
        let file = try write("ride.fit", in: folder)

        let found = FITImporter.fitFiles(in: [file, folder])
        XCTAssertEqual(found.count, 1)
    }

    func testMixedDropCombinesFilesAndFolders() throws {
        let loose = try write("loose.fit")
        let folder = try makeDirectory("exports")
        try write("inside.fit", in: folder)

        let found = FITImporter.fitFiles(in: [loose, folder])
        XCTAssertEqual(Set(found.map(\.lastPathComponent)), ["loose.fit", "inside.fit"])
    }

    /// Sorted so a batch import is deterministic, and naturally — "10.fit" after
    /// "9.fit", which a plain string sort gets backwards.
    func testResultsAreSortedNaturally() throws {
        let folder = try makeDirectory("exports")
        for name in ["10.fit", "9.fit", "1.fit"] { try write(name, in: folder) }

        let found = FITImporter.fitFiles(in: [folder])
        XCTAssertEqual(found.map(\.lastPathComponent), ["1.fit", "9.fit", "10.fit"])
    }

    func testNonexistentPathsAreJudgedByExtensionAlone() {
        // A security-scoped URL may not stat, but its name still tells us enough.
        let phantom = URL(filePath: "/nowhere/ride.fit")
        XCTAssertEqual(FITImporter.fitFiles(in: [phantom]).count, 1)
        XCTAssertTrue(FITImporter.fitFiles(in: [URL(filePath: "/nowhere/notes.txt")]).isEmpty)
    }

    // MARK: - End to end

    /// A dropped batch has to actually decode and persist.
    @MainActor
    func testADroppedFolderImportsAndDedupes() throws {
        let folder = try makeDirectory("exports")
        let encoded = try FITFixture.encodedRun()
        try encoded.write(to: folder.appendingPathComponent("run.fit"))
        // The same bytes under a second name: content-hashed, so one workout.
        try encoded.write(to: folder.appendingPathComponent("run-copy.fit"))

        let files = FITImporter.fitFiles(in: [folder])
        XCTAssertEqual(files.count, 2)

        let context = try FITFixture.makeContext()
        let importer = FITImporter()
        var added = 0, duplicates = 0
        for file in files {
            do {
                try importer.persist(try importer.decode(url: file), in: context)
                added += 1
            } catch FITPersistError.duplicate {
                duplicates += 1
            }
        }
        XCTAssertEqual(added, 1)
        XCTAssertEqual(duplicates, 1, "identical bytes are one workout, however many names")
    }
}
