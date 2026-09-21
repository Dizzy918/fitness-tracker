import XCTest

/// Stat grids must size their columns with the text, not against it.
///
/// `GridItem(.adaptive(minimum: 110))` reads as harmless and is not: the
/// minimum is in points and the text inside it is not, so at the accessibility
/// sizes the grid still fits three columns of roughly 110pt while `.title3`
/// renders about three times larger. The values lose. "40.36 mi" came out as
/// "40.…", 2:09:41 as "2:0…", and "Speed" broke across two lines mid-word —
/// on the screen whose entire purpose is those numbers.
///
/// `StatGrid` scales its minimum with `@ScaledMetric`, so the grid drops to two
/// columns and then one as the text grows. This keeps anyone from quietly
/// going back to a constant.
final class DynamicTypeLintTests: XCTestCase {

    private static let viewsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("FitnessTracker/Views")

    func testNoGridUsesAConstantAdaptiveMinimum() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: Self.viewsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "found no view sources to lint")

        // `.adaptive(minimum:` followed by a literal number.
        let literalMinimum = try NSRegularExpression(
            pattern: #"\.adaptive\(minimum:\s*[0-9]"#)

        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard literalMinimum.firstMatch(in: line, range: range) != nil else { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1) — \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertTrue(offenders.isEmpty,
                      "a grid column minimum is a constant, so it will not grow with "
                      + "Dynamic Type and its contents will truncate at the accessibility "
                      + "sizes. Use StatGrid, or an @ScaledMetric minimum:\n"
                      + offenders.joined(separator: "\n"))
    }
}
