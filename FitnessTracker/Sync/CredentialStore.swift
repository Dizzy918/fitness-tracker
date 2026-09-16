import Foundation
import Security

/// Keychain-backed storage for provider secrets.
///
/// Secrets never touch UserDefaults, never get logged, and never appear in
/// SwiftData. Values are namespaced by `Key` so one provider's tokens can be
/// revoked without disturbing another's.
enum CredentialStore {

    enum Key: String, CaseIterable {
        case stravaClientID
        case stravaClientSecret
        case stravaAccessToken
        case stravaRefreshToken
        case stravaTokenExpiry        // stored as epoch seconds string
        case intervalsAPIKey
        case intervalsAthleteID
        case anthropicAPIKey

        /// True for values that are secrets rather than identifiers. Only used
        /// to decide how the Settings UI masks them.
        var isSecret: Bool {
            switch self {
            case .stravaClientID, .intervalsAthleteID: return false
            default: return true
            }
        }
    }

    private static let service = "com.slavov.fitnesstracker.credentials"

    /// Stores a credential, trimming surrounding whitespace.
    ///
    /// Keys get pasted, and a paste very often carries a trailing newline. A key
    /// that differs from the real one by one invisible character fails auth with
    /// a plain 401 and no hint about why, so trim at the boundary.
    static func set(_ value: String?, for key: Key) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = trimmed, !value.isEmpty else { remove(key); return }

        let data = Data(value.utf8)
        var query = baseQuery(key)

        // Try update first; fall back to add.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func get(_ key: Key) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    static func remove(_ key: Key) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    static func has(_ key: Key) -> Bool {
        guard let v = get(key) else { return false }
        return !v.isEmpty
    }

    /// Wipe every stored credential — used by "Disconnect all" in Settings.
    static func removeAll() {
        for key in Key.allCases { remove(key) }
    }

    private static func baseQuery(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}

// MARK: - Token expiry helpers

extension CredentialStore {
    static var stravaTokenExpiryDate: Date? {
        get {
            guard let raw = get(.stravaTokenExpiry), let seconds = Double(raw) else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        set {
            set(newValue.map { String($0.timeIntervalSince1970) }, for: .stravaTokenExpiry)
        }
    }
}
