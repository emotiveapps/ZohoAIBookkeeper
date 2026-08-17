import Foundation
import Security


/// Keychain storage for Graph tokens, one item per (tenant, mailbox).
public struct GraphTokenStore: Sendable {
    private let service = "com.emotiveapps.ZohoBookkeeper.graph"
    private let account: String

    public init(mailbox: GraphMailboxConfig) {
        self.account = "\(mailbox.tenantId)|\(mailbox.address)"
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() -> GraphTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(GraphTokens.self, from: data)
    }

    public func save(_ tokens: GraphTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let add = SecItemAdd(addQuery as CFDictionary, nil)
            guard add == errSecSuccess else {
                throw CredentialsStoreError.keychainStatus(add)
            }
        } else if update != errSecSuccess {
            throw CredentialsStoreError.keychainStatus(update)
        }
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

