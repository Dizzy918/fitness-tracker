import XCTest

/// The list the app advertises, against the list it actually has.
///
/// A language is only offered to the user if it appears in
/// `CFBundleLocalizations`. Translate all 716 strings, forget that line in
/// `project.yml`, and the work ships inside the binary while iOS keeps handing
/// the person English — with nothing failing, nothing warning, and no way to
/// tell from inside the app. The reverse is worse: a code advertised but never
/// translated makes the language picker offer a language the app can't speak.
///
/// Both directions are one `sed` line away from being wrong, so both are
/// checked here rather than remembered.
final class BundleLocalizationsTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The language codes under `CFBundleLocalizations:` in `project.yml`.
    ///
    /// Read from the manifest rather than the generated `.xcodeproj`, because
    /// the manifest is what a person edits and the project file is a build
    /// product that may not have been regenerated yet.
    private func advertisedLanguages() throws -> [String] {
        let manifest = try String(contentsOf: Self.root.appendingPathComponent("project.yml"),
                                  encoding: .utf8)
        var found: [String] = []
        var inList = false
        for line in manifest.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("CFBundleLocalizations:") {
                inList = true
                continue
            }
            guard inList else { continue }
            // The list ends at the first line that isn't one of its items.
            guard trimmed.hasPrefix("- ") else { break }
            found.append(String(trimmed.dropFirst(2)))
        }
        return found
    }

    /// Every language with at least one translation in the String Catalog.
    private func translatedLanguages() throws -> Set<String> {
        let url = Self.root.appendingPathComponent("FitnessTracker/Resources/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        guard let catalog = catalog as? [String: Any],
              let strings = catalog["strings"] as? [String: Any]
        else { return [] }

        var languages: Set<String> = []
        for entry in strings.values {
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any]
            else { continue }
            languages.formUnion(localizations.keys)
        }
        return languages
    }

    func testEveryTranslatedLanguageIsAdvertised() throws {
        let advertised = Set(try advertisedLanguages())
        let missing = try translatedLanguages().subtracting(advertised).sorted()
        XCTAssertTrue(missing.isEmpty,
                      "translated but not in CFBundleLocalizations, so iOS will never "
                      + "offer them: \(missing.joined(separator: ", "))")
    }

    func testEveryAdvertisedLanguageIsTranslated() throws {
        let translated = try translatedLanguages()
        // The development language has no entries of its own — the keys are it.
        let empty = try advertisedLanguages()
            .filter { $0 != "en" && !translated.contains($0) }
        XCTAssertTrue(empty.isEmpty,
                      "advertised with nothing translated: \(empty.joined(separator: ", "))")
    }

    /// The generated `Info.plist` is what actually ships, and it's committed —
    /// so a language added to `project.yml` without re-running `xcodegen
    /// generate` is advertised in the manifest and absent from the binary.
    func testTheGeneratedInfoPlistMatchesTheManifest() throws {
        let url = Self.root.appendingPathComponent("FitnessTracker/Info.plist")
        let plist = try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: url), format: nil) as? [String: Any]
        let shipped = plist?["CFBundleLocalizations"] as? [String] ?? []

        XCTAssertEqual(shipped, try advertisedLanguages(),
                       "Info.plist is out of date — re-run `xcodegen generate`")
    }

    /// A code the catalog and the manifest spell differently is the same bug in
    /// a form neither list can see: `pt-BR` in one and `pt_BR` in the other
    /// leaves Brazilian Portuguese untranslated and unadvertised at once.
    func testAdvertisedCodesAreWellFormedAndUnique() throws {
        let advertised = try advertisedLanguages()
        XCTAssertEqual(Set(advertised).count, advertised.count,
                       "a language is listed twice in CFBundleLocalizations")
        XCTAssertTrue(advertised.contains("en"), "the development language must be advertised")

        for code in advertised {
            XCTAssertNotNil(code.range(of: "^[a-z]{2,3}(-[A-Za-z]{2,4})?$", options: .regularExpression),
                            "\(code) isn't a BCP 47 code Apple will match against")
        }
    }
}
