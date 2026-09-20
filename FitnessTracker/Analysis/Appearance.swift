import SwiftUI

/// Light, dark, or whatever the device is set to.
///
/// Every colour in the app is already a semantic one — `.primary`,
/// `.secondary`, `.quaternary`, the materials — so both appearances have always
/// rendered correctly. What was missing is the choice: the app had no way to
/// be dark on a light Mac, or light on a dark phone, which is the one case
/// where a training log actually differs from the rest of the system. Reading
/// numbers on a bright screen at 6 a.m. is not the same as reading them in the
/// evening, and people have a settled preference about it.
///
/// Stored as a plain string in defaults, like ``UnitSystem``, so it survives
/// launches without earning a row in the database.
enum Appearance: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .light:  return String(localized: "Light")
        case .dark:   return String(localized: "Dark")
        }
    }

    /// What SwiftUI should be told to prefer.
    ///
    /// `nil` is not "no preference stored" — it's the instruction to follow the
    /// device, which is exactly what `.preferredColorScheme(nil)` means.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    static let defaultsKey = "appearance"

    /// Defaults to following the device, which is what someone who has never
    /// opened Settings expects.
    static func current(_ defaults: UserDefaults = .standard) -> Appearance {
        defaults.string(forKey: defaultsKey).flatMap(Appearance.init) ?? .system
    }
}
