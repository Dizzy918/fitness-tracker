import XCTest
@testable import FitnessTracker

/// The String Catalog itself.
///
/// A translation with the wrong format specifiers doesn't look wrong — it
/// crashes, at runtime, only for the people using that language, which is the
/// worst possible place to find out. These checks read the catalog as shipped.
final class LocalizationCatalogTests: XCTestCase {

    private struct Catalog: Decodable {
        let sourceLanguage: String
        let strings: [String: Entry]

        struct Entry: Decodable {
            let localizations: [String: Localization]?
        }
        struct Localization: Decodable {
            let stringUnit: Unit?
        }
        struct Unit: Decodable {
            let state: String
            let value: String
        }
    }

    private static let catalog: Catalog = {
        // Read from source rather than the bundle: the bundle has the compiled
        // form, and this test is about what gets shipped into it.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FitnessTracker/Resources/Localizable.xcstrings")
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(Catalog.self, from: data)
    }()

    private var catalog: Catalog { Self.catalog }

    /// One format specifier: which argument it consumes and what type it wants.
    private struct Specifier: Equatable, CustomStringConvertible {
        let position: Int?   // nil when the specifier is implicitly positional
        let type: String     // "@", "lld", "f" …

        var description: String {
            position.map { "%\($0)$\(type)" } ?? "%\(type)"
        }
    }

    /// Every `%@`, `%lld`, `%2$@` and friends, in order.
    ///
    /// Positional forms matter: a language whose word order differs from
    /// English can't simply move `%@` around — the arguments are consumed in
    /// the order they appear unless the translation says otherwise. Japanese
    /// needs exactly this.
    private func specifiers(in text: String) -> [Specifier] {
        let pattern = "%(?:%|(?:([0-9]+)\\$)?[0-9]*\\.?[0-9]*(ll|l|h|hh|z|q)?([@dioufFeEgGxXcsSpaA]))"
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)

        return regex.matches(in: text, range: range).compactMap { match in
            guard let whole = Range(match.range, in: text) else { return nil }
            // "%%" is a literal percent, not an argument.
            guard String(text[whole]) != "%%" else { return nil }

            func group(_ index: Int) -> String? {
                guard let r = Range(match.range(at: index), in: text) else { return nil }
                return String(text[r])
            }
            let position = group(1).flatMap(Int.init)
            let type = (group(2) ?? "") + (group(3) ?? "")
            return Specifier(position: position, type: type)
        }
    }

    /// The type each argument index must receive, resolved through positional
    /// specifiers where they're used.
    ///
    /// Returns nil when a string mixes positional and implicit forms, which is
    /// undefined behaviour rather than a reordering.
    private func argumentTypes(in text: String) -> [Int: String]? {
        let found = specifiers(in: text)
        let positional = found.filter { $0.position != nil }
        guard positional.isEmpty || positional.count == found.count else { return nil }

        var types: [Int: String] = [:]
        for (index, specifier) in found.enumerated() {
            let position = specifier.position ?? index + 1
            // The same argument used twice must be used as the same type.
            if let existing = types[position], existing != specifier.type { return nil }
            types[position] = specifier.type
        }
        return types
    }

    func testSourceLanguageIsEnglish() {
        XCTAssertEqual(catalog.sourceLanguage, "en")
    }

    func testCatalogIsNotEmpty() {
        XCTAssertGreaterThan(catalog.strings.count, 500,
                             "extraction produced far fewer keys than expected")
    }

    /// The one that prevents crashes.
    /// Each argument must keep its type, whatever order the words end up in.
    ///
    /// A translation that puts `%lld` where the source had `%@` doesn't look
    /// wrong — it prints nonsense or crashes, at runtime, only for people using
    /// that language. Reordering is allowed, but only through positional
    /// specifiers, which is what they're for.
    func testEveryTranslationTakesTheSameArgumentsAsItsSource() {
        var problems: [String] = []
        for (key, entry) in catalog.strings {
            guard let expected = argumentTypes(in: key) else {
                problems.append("[source] \(key.prefix(60)) mixes positional and implicit specifiers")
                continue
            }
            for (language, localization) in entry.localizations ?? [:] {
                guard let value = localization.stringUnit?.value else { continue }
                guard let actual = argumentTypes(in: value) else {
                    problems.append("[\(language)] \(key.prefix(60))\n"
                                    + "    mixes positional and implicit specifiers")
                    continue
                }
                if actual != expected {
                    problems.append(
                        "[\(language)] \(key.prefix(60))\n"
                        + "    source: \(expected.sorted { $0.key < $1.key })\n"
                        + "    \(language): \(actual.sorted { $0.key < $1.key })")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty,
                      "arguments differ from the source:\n"
                      + problems.joined(separator: "\n"))
    }

    /// The reordering mechanism itself, so the rule above is understood rather
    /// than merely satisfied.
    func testPositionalSpecifiersAreAcceptedAsAReordering() {
        // Same two arguments, opposite order.
        XCTAssertEqual(argumentTypes(in: "%@ at %lld km"),
                       argumentTypes(in: "%2$lld km 地点で %1$@"))
        // Different types in the same slot is not a reordering.
        XCTAssertNotEqual(argumentTypes(in: "%@ at %lld km"),
                          argumentTypes(in: "%1$lld km 地点で %2$@"))
        // Mixing the two forms is undefined, not clever.
        XCTAssertNil(argumentTypes(in: "%1$@ and %lld"))
    }

    /// An empty translation renders as an empty label, which reads as a bug.
    func testNoTranslationIsBlank() {
        for (key, entry) in catalog.strings {
            for (language, localization) in entry.localizations ?? [:] {
                guard let value = localization.stringUnit?.value else { continue }
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "[\(language)] blank translation for \(key.prefix(60))")
            }
        }
    }

    /// A translation identical to its source is usually one that was skipped.
    /// Proper nouns, units and symbols are legitimately identical, so this only
    /// fails when most of a language is untouched.
    func testLanguagesAreActuallyTranslated() {
        for language in languages {
            let values = catalog.strings.compactMap { key, entry -> (String, String)? in
                guard let value = entry.localizations?[language]?.stringUnit?.value
                else { return nil }
                return (key, value)
            }
            guard values.count > 50 else { continue }
            let identical = values.filter { $0.0 == $0.1 }.count
            let fraction = Double(identical) / Double(values.count)
            XCTAssertLessThan(fraction, 0.5,
                              "\(language) is \(Int(fraction * 100))% identical to English")
        }
    }

    /// Newlines carry layout. A translation that drops them reflows a message
    /// into one run-on paragraph.
    func testLineBreaksArePreserved() {
        for (key, entry) in catalog.strings where key.contains("\n") {
            let expected = key.filter { $0 == "\n" }.count
            for (language, localization) in entry.localizations ?? [:] {
                guard let value = localization.stringUnit?.value else { continue }
                XCTAssertEqual(value.filter { $0 == "\n" }.count, expected,
                               "[\(language)] line breaks changed in \(key.prefix(40))")
            }
        }
    }

    /// Coverage, reported rather than asserted — a partly translated language
    /// falls back per string and is not a failure.
    func testReportCoverage() throws {
        let total = catalog.strings.count
        var report: [(String, Int)] = []
        for language in languages {
            let done = catalog.strings.values.filter {
                $0.localizations?[language]?.stringUnit != nil
            }.count
            report.append((language, done * 100 / total))
        }
        for (language, percent) in report.sorted(by: { $0.1 > $1.1 }) {
            print("  \(language): \(percent)% of \(total)")
        }
        XCTAssertFalse(report.isEmpty, "no languages in the catalog at all")
    }

    private var languages: [String] {
        Set(catalog.strings.values.flatMap { ($0.localizations ?? [:]).keys }).sorted()
    }
}
