import CryptoKit
import Foundation
import Security

@MainActor
protocol ChatStorage {
    func load(key: String) throws -> StoredChat
    func save(_ state: StoredChat, key: String) throws
    func remove(key: String) throws
}

/// Only the conversation ID and one pending send are persisted. Tokens and history
/// stay in memory. ThisDeviceOnly prevents restoring a pending send onto another device.
@MainActor
final class KeychainChatStorage: ChatStorage {
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.barky.sdk.chat.v1",
         kSecAttrAccount as String: key]
    }

    func load(key: String) throws -> StoredChat {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return StoredChat() }
        guard status == errSecSuccess, let data = result as? Data,
              let state = try? JSONDecoder().decode(StoredChat.self, from: data)
        else { throw BarkyError.storageUnavailable }
        return state
    }

    func save(_ state: StoredChat, key: String) throws {
        let data = try JSONEncoder().encode(state)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query(key).merging(attributes) { _, new in new }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw BarkyError.storageUnavailable
            }
        } else if status != errSecSuccess { throw BarkyError.storageUnavailable }
    }

    func remove(key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BarkyError.storageUnavailable
        }
    }

    static func key(configuration: BarkyConfiguration, customerID: String) -> String {
        let components = [configuration.apiURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                          configuration.storageNamespace, customerID]
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
