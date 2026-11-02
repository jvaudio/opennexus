import Foundation
import Security

// Secrets on both platforms (M47b): the Mac's login Keychain and the iPad's own.

/// The Keychain: generic passwords, this app only (the login Keychain on the Mac).
public struct KeychainSecrets: SecretStore {
    public var service: String
    public init(service: String = "org.opennexus.sharing") { self.service = service }

    func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func secret(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public func setSecret(_ data: Data, _ account: String) {
        deleteSecret(account)
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = "OpenNexus sharing"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(q as CFDictionary, nil)
    }

    public func deleteSecret(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
