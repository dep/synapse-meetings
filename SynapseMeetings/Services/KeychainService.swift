import Foundation
import Security

enum KeychainKey: String, CaseIterable {
    case anthropicAPIKey = "anthropic.api.key"
    case openRouterAPIKey = "openrouter.api.key"
    case githubPAT = "github.pat"
}

extension Notification.Name {
    static let synapseKeychainChanged = Notification.Name("SynapseMeetingsKeychainChanged")
}

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

struct KeychainService {
    static let shared = KeychainService()

    static let serviceID = "com.synapsemeetings.app"
    private let service = KeychainService.serviceID

    func set(_ value: String?, for key: KeychainKey) throws {
        if let value, !value.isEmpty {
            try save(value, for: key)
        } else {
            try delete(key)
        }
        NotificationCenter.default.post(name: .synapseKeychainChanged, object: key.rawValue)
    }

    func get(_ key: KeychainKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    func has(_ key: KeychainKey) -> Bool {
        guard let v = get(key) else { return false }
        return !v.isEmpty
    }

    private func save(_ value: String, for key: KeychainKey) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw KeychainError.unexpectedStatus(addStatus)
            }
            return
        }
        throw KeychainError.unexpectedStatus(updateStatus)
    }

    private func delete(_ key: KeychainKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
