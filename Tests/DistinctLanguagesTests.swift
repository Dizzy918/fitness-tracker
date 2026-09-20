import XCTest

/// That each language is its own translation, and not a copy of its neighbour.
///
/// The catalog now holds several pairs that are genuinely close: Bokmål and
/// Nynorsk, Indonesian and Malay, Simplified and Traditional Chinese, European
/// and Brazilian Portuguese, Croatian and Serbian, Spanish and Galician. Adding
/// one of a pair by copying the other and changing a few words is a real
/// temptation, and every other test in this suite would pass: the format
/// specifiers match, nothing is blank, the line breaks survive, and
/// `testLanguagesAreActuallyTranslated` only compares against *English*.
///
/// So compare the languages against each other instead.
final class DistinctLanguagesTests: XCTestCase {

    /// Only long source strings count.
    ///
    /// Short labels collide honestly all the time — "Start", "Sett", "Puls",
    /// "km", "TSS" are the same word in several languages, and a button that
    /// matches its neighbour proves nothing. A whole sentence matching is a
    /// different claim: two translators working independently do not produce
    /// the same 40-character sentence by accident, except where the two
    /// standards really are identical there.
    private static let minimumLength = 40

    /// The ceiling on how much of a language may be identical to another.
    ///
    /// The worst honest pair in the catalog today is 2.5% — three sentences
    /// shared between Bokmål and Nynorsk, and three between the two
    /// Portuguese variants, each of which is correct in both. A copied
    /// language would sit near 100%. 25% is a tenfold margin over the real
    /// data, which is the point: this should fire on a copy and never on a
    /// translation.
    private static let limit = 0.25

    private struct Catalog: Decodable {
        let strings: [String: Entry]
        struct Entry: Decodable { let localizations: [String: Localization]? }
        struct Localization: Decodable { let stringUnit: Unit? }
        struct Unit: Decodable { let value: String }
    }

    private static let catalog: Catalog = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FitnessTracker/Resources/Localizable.xcstrings")
        return try! JSONDecoder().decode(Catalog.self, from: try! Data(contentsOf: url))
    }()

    func testNoLanguageIsACopyOfAnother() {
        // Long source strings, grouped by language.
        var byLanguage: [String: [String: String]] = [:]
        for (key, entry) in Self.catalog.strings where key.count > Self.minimumLength {
            for (language, localization) in entry.localizations ?? [:] {
                guard let value = localization.stringUnit?.value else { continue }
                byLanguage[language, default: [:]][key] = value
            }
        }

        let languages = byLanguage.keys.sorted()
        XCTAssertGreaterThan(languages.count, 1, "nothing to compare")

        var problems: [String] = []
        for (index, a) in languages.enumerated() {
            for b in languages[(index + 1)...] {
                let shared = Set(byLanguage[a]!.keys).intersection(byLanguage[b]!.keys)
                // Too little overlap to say anything either way.
                guard shared.count >= 50 else { continue }

                let identical = shared.filter { byLanguage[a]![$0] == byLanguage[b]![$0] }
                let fraction = Double(identical.count) / Double(shared.count)
                if fraction > Self.limit {
                    problems.append("\(a) and \(b) share \(identical.count) of \(shared.count) "
                                    + "long strings (\(Int(fraction * 100))%) — is one a copy?")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }
}
