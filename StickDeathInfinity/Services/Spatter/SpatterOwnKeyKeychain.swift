import Foundation
import Security

/// The production own-key store (#209). One generic-password item per signed-in
/// account. The item is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
/// explicitly not synchronizable, so it is excluded from iCloud Keychain and
/// from device-to-device migration and backups. Nothing here logs, and errors
/// carry no key material or OSStatus text.
struct KeychainSpatterOwnKeyStore: SpatterOwnKeyStore {
    static let service = "com.stickdeath.infinity.spatter.own-ai-key"

    private func query(_ account: String) throws -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: try SpatterOwnKeyAccount.validated(account),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    func load(account: String) throws -> SpatterOwnKeyCredential? {
        var request = try query(account)
        request[kSecReturnData as String] = kCFBooleanTrue
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let stored = try? JSONDecoder().decode(SpatterOwnKeyCredential.self, from: data) else {
            throw SpatterOwnKeyError.storageFailed
        }
        // Re-validate on read so a damaged item is never sent anywhere.
        return try SpatterOwnKeyCredential.validated(provider: stored.provider, model: stored.model, key: stored.key)
    }

    func save(_ credential: SpatterOwnKeyCredential, account: String) throws {
        let base = try query(account)
        let validated = try SpatterOwnKeyCredential.validated(provider: credential.provider, model: credential.model, key: credential.key)
        guard let data = try? JSONEncoder().encode(validated) else { throw SpatterOwnKeyError.storageFailed }
        let deleted = SecItemDelete(base as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw SpatterOwnKeyError.storageFailed }
        var add = base
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecValueData as String] = data
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw SpatterOwnKeyError.storageFailed }
    }

    func remove(account: String) throws {
        let status = SecItemDelete(try query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SpatterOwnKeyError.storageFailed }
    }
}
