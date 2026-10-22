import Foundation
import Security

/// The hotspot's Wi-Fi password, kept in the login keychain. Both calls can block while macOS asks to allow access
/// (the ad-hoc signature changes with every install), so never call them on the main actor.
public enum HotspotPasswordStore {
    private static let service = "Awake Hotspot"
    private static let account = "hotspot"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The saved password, "" when none is saved, or nil when it couldn't be read (access denied).
    public static func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(lookup as CFDictionary, &item) {
        case errSecSuccess:
            return (item as? Data).map { String(decoding: $0, as: UTF8.self) }
        case errSecItemNotFound:
            return ""
        default:
            return nil
        }
    }

    /// Saves the password; an empty string deletes it.
    public static func save(_ password: String) {
        guard !password.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
