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

    /// Every `%@`, `%lld`, `%.1f` and friends, in order.
    private func specifiers(in text: String) -> [String] {
        let pattern = "%(?:%|[0-9]*\\.?[0-9]*(?:ll|l|h|hh|z|q)?[@dioufFeEgGxXcsSpaA])"
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            let token = String(text[r])
            // "%%" is a literal percent, not an argument.
            return token == "%%" ? nil : token
        }
    }

    func testSourceLanguageIsEnglish() {
        XCTAssertEqual(catalog.sourceLanguage, "en")
    }

    func testCatalogIsNotEmpty() {
        XCTAssertGreaterThan(catalog.strings.count, 500,
                             "extraction produced far fewer keys than expected")
    }

    /// The one that prevents crashes.
    func testEveryTranslationHasTheSameFormatSpecifiersAsItsSource() {
        var problems: [String] = []
        for (key, entry) in catalog.strings {
            let expected = specifiers(in: key)
            for (language, localization) in entry.localizations ?? [:] {
                guard let value = localization.stringUnit?.value else { continue }
                let actual = specifiers(in: value)
                if actual != expected {
                    problems.append(
                        "[\(language)] \(key.prefix(60))\n"
                        + "    source: \(expected)\n"
                        + "    \(language): \(actual)")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty,
                      "format specifiers differ from the source:\n"
                      + problems.joined(separator: "\n"))
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
