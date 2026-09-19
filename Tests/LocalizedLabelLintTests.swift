import XCTest

/// A source-level check for the one localization mistake the catalog can't see.
///
/// `Text(someString)` compiles, renders, and looks perfectly fine — in English.
/// Because the argument is a `String` rather than a `LocalizedStringKey`, the
/// literal at the call site is never harvested into the catalog and the text
/// never goes through the bundle, so every other language shows English. The
/// catalog tests can't catch it: the key simply isn't there to be missing.
///
/// This is how the whole "This week" row on the dashboard — Sessions, Time,
/// Distance, Elev gain — stayed English in twenty-one languages. It was found
/// by looking at the Arabic build in the Simulator, which is not a repeatable
/// way to find it.
///
/// A view that genuinely holds resolved text says so with `Text(verbatim:)`.
final class LocalizedLabelLintTests: XCTestCase {

    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("FitnessTracker")

    /// Initialisers that localize their first argument, and so must not be
    /// handed a plain `String`.
    private static let localizing = ["Text", "Label", "Button", "Toggle", "Picker",
                                     "Section", "Stepper", "TextField", "Link"]

    func testNoViewRendersAPlainStringPropertyAsLocalizedText() throws {
        var offenders: [String] = []

        for file in try Self.swiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains(": View") else { continue }

            let plainStringProperties = Self.storedStringProperties(in: source)
                + Self.stringParameters(in: source)
            guard !plainStringProperties.isEmpty else { continue }

            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                for name in plainStringProperties where Self.rendersLocalized(name, in: line) {
                    offenders.append("\(file.lastPathComponent):\(index + 1): "
                                     + "`\(name)` is a String — use LocalizedStringKey, "
                                     + "or say Text(verbatim:) if it is already resolved")
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty,
                      "string properties rendered as localized text:\n"
                      + offenders.joined(separator: "\n"))
    }

    // MARK: - Reading the source

    private static func swiftFiles() throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let walker = FileManager.default.enumerator(at: sourceRoot,
                                                    includingPropertiesForKeys: keys)
        var found: [URL] = []
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension == "swift" { found.append(url) }
        }
        return found
    }

    /// `let name: String` / `var name: String` — stored, not computed, and not
    /// one of the properties that legitimately hold a symbol name or an id.
    private static func storedStringProperties(in source: String) -> [String] {
        let pattern = #"(?m)^\s*(?:private\s+)?(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*String\s*(?:=[^\n{]*)?$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        let exempt: Set<String> = ["icon", "symbol", "systemImage", "id", "rawValue"]

        return regex.matches(in: source, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: source) else { return nil }
            let name = String(source[r])
            return exempt.contains(name) ? nil : name
        }
    }

    /// `func row(_ title: String, …)` — the same mistake, one scope down. The
    /// Records milestones ("Longest run", "Biggest running week") were passed
    /// as parameters rather than held as properties, and stayed English.
    private static func stringParameters(in source: String) -> [String] {
        let pattern = #"[(,]\s*(?:_\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:\s*String\b"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        let exempt: Set<String> = ["icon", "symbol", "systemImage", "id", "rawValue", "key"]

        var names = Set<String>()
        for match in regex.matches(in: source, range: range) {
            guard let r = Range(match.range(at: 1), in: source) else { continue }
            let name = String(source[r])
            if !exempt.contains(name) { names.insert(name) }
        }
        return Array(names)
    }

    /// `Text(name)`, `Label(name, systemImage:)` and friends — the first
    /// argument, unlabelled, with nothing else wrapped around it.
    private static func rendersLocalized(_ name: String, in line: String) -> Bool {
        localizing.contains { initializer in
            line.contains("\(initializer)(\(name))") || line.contains("\(initializer)(\(name),")
        }
    }
}
