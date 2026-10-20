import Foundation
import Security

/// Where the phone and the watch keep the key they share for signing a request's answer.
protocol AIRequestKeychain {
    func data(for account: String) -> Data?
    /// Setting `nil` removes the item. Returns whether the change was made. A failed write leaves the old item
    /// as it was.
    @discardableResult func set(_ data: Data?, for account: String) -> Bool
}

/// The system Keychain. Items stay on this device (never in iCloud Keychain, never restored onto another
/// device) and are readable once it has been unlocked after a restart, so a request that arrives in the
/// background can be answered.
struct SystemAIRequestKeychain: AIRequestKeychain {
    private let service = "\(Bundle.main.bundleIdentifier ?? "trio").ai-requests"

    func data(for account: String) -> Data? {
        var query = identity(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult func set(_ data: Data?, for account: String) -> Bool {
        let query = identity(for: account)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private func identity(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}
