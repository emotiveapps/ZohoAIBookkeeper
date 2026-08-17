import Foundation
import Security


/// Stores the entire `FullConfiguration` as a single generic-password Keychain item.
public struct KeychainCredentialsStore: CredentialsStore {
    private let service: String
    private let account: String

    public init(
        service: String = "com.emotiveapps.ZohoBookkeeper",
        account: String = "configuration"
    ) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> FullConfiguration? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try JSONDecoder().decode(FullConfiguration.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialsStoreError.keychainStatus(status)
        }
    }

    public func save(_ configuration: FullConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)

        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialsStoreError.keychainStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw CredentialsStoreError.keychainStatus(updateStatus)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialsStoreError.keychainStatus(status)
        }
    }
}

