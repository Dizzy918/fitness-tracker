import XCTest

/// The short labels that name a place in the app, checked for collisions.
///
/// Long prose disambiguates itself: "Diese Einheit hat keinen GPS-Track" can
/// only mean a training session, whatever else "Einheit" might mean elsewhere.
/// A bare tab label has no such help. German translated both "Workouts" and
/// "Units" as "Einheiten" — each correct on its own, and each the right word in
/// isolation — which put a tab called *Einheiten* at the bottom of the screen
/// and a Settings section called *Einheiten* inside it, naming completely
/// different things.
///
/// That is invisible from English and invisible from reading the catalog, which
/// only ever shows one key at a time. It shows up the moment two of these land
/// on screen together, in one of fifty languages.
final class NavigationLabelTests: XCTestCase {

    /// The five tabs, and every Settings section header.
    ///
    /// These are the strings that label a destination rather than describe one,
    /// so two of them meaning the same word is a navigation problem rather than
    /// a synonym. Deliberately not the whole catalog: "Workouts" and "Sessions"
    /// collide in 31 languages and should, because they are near-synonyms in
    /// English too.
    private static let labels = [
        // Tabs
        "Workouts", "Recovery", "Routes", "Strength", "Dashboard",
        // Settings section headers
        "AI PDF extraction", "Appearance", "Apple Health", "Backup", "Cycling",
        "Estimate thresholds", "Heart rate", "Reminders", "Strava", "Units",
        "Watched folder", "iCloud", "intervals.icu",
    ]

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

    /// Every label in the list must still exist as a key.
    ///
    /// Otherwise a renamed tab silently drops out of the check and the test goes
    /// on passing while covering less than it claims.
    func testEveryLabelIsStillInTheCatalog() {
        let missing = Self.labels.filter { Self.catalog.strings[$0] == nil }
        XCTAssertTrue(missing.isEmpty,
                      "these are no longer catalog keys, so this test has stopped "
                      + "covering them: \(missing.joined(separator: ", "))")
    }

    func testNoTwoNavigationLabelsCollideInAnyLanguage() {
        var byLanguage: [String: [String: [String]]] = [:]   // language → translation → keys
        for key in Self.labels {
            for (language, localization) in Self.catalog.strings[key]?.localizations ?? [:] {
                guard let value = localization.stringUnit?.value else { continue }
                byLanguage[language, default: [:]][value.lowercased(), default: []].append(key)
            }
        }

        var problems: [String] = []
        for (language, groups) in byLanguage {
            for (translation, keys) in groups where keys.count > 1 {
                problems.append("[\(language)] \(keys.sorted().joined(separator: " and ")) "
                                + "are both \"\(translation)\"")
            }
        }
        XCTAssertTrue(problems.isEmpty,
                      "two places in the app share a name:\n"
                      + problems.sorted().joined(separator: "\n"))
    }
}
