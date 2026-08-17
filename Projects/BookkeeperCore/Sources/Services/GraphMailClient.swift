import Foundation
import Security

// MARK: - Tokens

public struct GraphTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    /// Refresh a minute early so an in-flight request can't race expiry.
    public func needsRefresh(now: Date = Date()) -> Bool {
        now >= expiresAt.addingTimeInterval(-60)
    }
}

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

// MARK: - Errors

public enum GraphError: LocalizedError, Sendable {
    case notSignedIn(mailbox: String)
    case authorizationDeclined
    case deviceCodeExpired
    case tokenRequestFailed(String)
    case requestFailed(status: Int, body: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case let .notSignedIn(mailbox):
            return "Not signed in for \(mailbox). Run `zoho-bookkeeper receipts login` first."
        case .authorizationDeclined:
            return "Sign-in was declined."
        case .deviceCodeExpired:
            return "The sign-in code expired before it was used. Run login again."
        case let .tokenRequestFailed(message):
            return "Microsoft sign-in failed: \(message)"
        case let .requestFailed(status, body):
            return "Microsoft Graph error (\(status)): \(body.prefix(300))"
        case .invalidResponse:
            return "Unexpected response from Microsoft Graph."
        }
    }
}

// MARK: - Client

/// Minimal Microsoft Graph client for reading a (shared) mailbox via
/// delegated `Mail.Read.Shared`, authenticated with the device-code flow
/// (public client — no secret; tokens live in the Keychain).
public actor GraphMailClient {
    public struct DeviceCode: Sendable {
        public let userCode: String
        public let verificationURI: String
        public let message: String
        let deviceCode: String
        let interval: TimeInterval
        let expiresAt: Date
    }

    public struct MailMessage: Sendable {
        /// Graph ID (immutable format — survives folder moves).
        public let id: String
        /// RFC 822 Message-ID header: stable dedupe key independent of Graph IDs.
        public let internetMessageId: String?
        public let subject: String
        public let from: String
        public let receivedAt: Date?
        public let hasAttachments: Bool
    }

    public struct Attachment: Sendable {
        public let name: String
        public let contentType: String
        public let data: Data
    }

    // ReadWrite (not just Read): filing processed emails into state folders
    // needs folder creation + message moves. The pipeline never deletes mail.
    private static let scope = "https://graph.microsoft.com/Mail.ReadWrite.Shared offline_access"

    public let config: GraphMailboxConfig
    private let tokenStore: GraphTokenStore

    public init(config: GraphMailboxConfig) {
        self.config = config
        self.tokenStore = GraphTokenStore(mailbox: config)
    }

    public var isSignedIn: Bool {
        tokenStore.load() != nil
    }

    public func signOut() {
        tokenStore.clear()
    }

    // MARK: Device-code sign-in

    public func beginDeviceLogin() async throws -> DeviceCode {
        let body = [
            "client_id": config.clientId,
            "scope": Self.scope,
        ]
        let data = try await postForm(
            url: "https://login.microsoftonline.com/\(config.tenantId)/oauth2/v2.0/devicecode",
            body: body
        )
        struct Response: Decodable {
            let deviceCode: String
            let userCode: String
            let verificationUri: String
            let expiresIn: TimeInterval
            let interval: TimeInterval?
            let message: String?

            enum CodingKeys: String, CodingKey {
                case deviceCode = "device_code"
                case userCode = "user_code"
                case verificationUri = "verification_uri"
                case expiresIn = "expires_in"
                case interval
                case message
            }
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return DeviceCode(
            userCode: response.userCode,
            verificationURI: response.verificationUri,
            message: response.message ?? "Visit \(response.verificationUri) and enter code \(response.userCode)",
            deviceCode: response.deviceCode,
            interval: response.interval ?? 5,
            expiresAt: Date().addingTimeInterval(response.expiresIn)
        )
    }

    /// Poll until the user completes sign-in in their browser (or the code expires).
    public func waitForLogin(_ code: DeviceCode) async throws {
        while Date() < code.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(code.interval * 1_000_000_000))

            let body = [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": config.clientId,
                "device_code": code.deviceCode,
            ]
            let (data, status) = try await postFormRaw(
                url: "https://login.microsoftonline.com/\(config.tenantId)/oauth2/v2.0/token",
                body: body
            )

            if status == 200 {
                try storeTokens(from: data)
                return
            }

            struct ErrorResponse: Decodable { let error: String? }
            let error = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error ?? ""
            switch error {
            case "authorization_pending", "slow_down":
                continue
            case "authorization_declined":
                throw GraphError.authorizationDeclined
            case "expired_token":
                throw GraphError.deviceCodeExpired
            default:
                throw GraphError.tokenRequestFailed(String(data: data, encoding: .utf8) ?? error)
            }
        }
        throw GraphError.deviceCodeExpired
    }

    // MARK: Mail

    /// Messages currently in the Inbox — the "to process" queue. Processed
    /// messages are moved to state folders and thus leave this listing.
    public func fetchInboxMessages(since: Date?) async throws -> [MailMessage] {
        var url = "https://graph.microsoft.com/v1.0/users/\(encodePath(config.address))/mailFolders/inbox/messages"
            + "?$select=id,internetMessageId,subject,from,receivedDateTime,hasAttachments"
            + "&$orderby=receivedDateTime%20desc&$top=50"
        if let since {
            let iso = Self.isoFormatter.string(from: since)
            url += "&$filter=receivedDateTime%20ge%20\(iso)"
        }

        var messages: [MailMessage] = []
        var next: String? = url
        while let page = next {
            let data = try await get(url: page)
            struct Page: Decodable {
                let value: [Message]
                let nextLink: String?
                enum CodingKeys: String, CodingKey {
                    case value
                    case nextLink = "@odata.nextLink"
                }
            }
            struct Message: Decodable {
                struct From: Decodable {
                    struct EmailAddress: Decodable { let address: String? }
                    let emailAddress: EmailAddress?
                }
                let id: String
                let internetMessageId: String?
                let subject: String?
                let from: From?
                let receivedDateTime: String?
                let hasAttachments: Bool?
            }
            let decoded = try JSONDecoder().decode(Page.self, from: data)
            messages += decoded.value.map { message in
                MailMessage(
                    id: message.id,
                    internetMessageId: message.internetMessageId,
                    subject: message.subject ?? "(no subject)",
                    from: message.from?.emailAddress?.address ?? "",
                    receivedAt: message.receivedDateTime.flatMap { Self.isoFormatter.date(from: $0) },
                    hasAttachments: message.hasAttachments ?? false
                )
            }
            next = decoded.nextLink
        }
        return messages
    }

    // MARK: - Folders & moves

    /// Find or create `parent/child` and return the child folder's ID.
    /// Results are cached for the life of this client.
    public func ensureFolder(parent: String, child: String) async throws -> String {
        let cacheKey = "\(parent)/\(child)"
        if let cached = folderIdCache[cacheKey] { return cached }

        let parentId = try await ensureTopLevelFolder(named: parent)
        let base = "https://graph.microsoft.com/v1.0/users/\(encodePath(config.address))/mailFolders/\(parentId)/childFolders"
        let childId: String
        if let existing = try await findFolder(named: child, listURL: base) {
            childId = existing
        } else {
            childId = try await createFolder(named: child, createURL: base)
        }
        folderIdCache[cacheKey] = childId
        return childId
    }

    /// Move a message into a folder. With immutable IDs the message keeps its ID.
    public func moveMessage(id: String, toFolderId folderId: String) async throws {
        let url = "https://graph.microsoft.com/v1.0/users/\(encodePath(config.address))/messages/\(id)/move"
        _ = try await postJSON(url: url, body: ["destinationId": folderId])
    }

    private var folderIdCache: [String: String] = [:]

    private func ensureTopLevelFolder(named name: String) async throws -> String {
        if let cached = folderIdCache[name] { return cached }
        let base = "https://graph.microsoft.com/v1.0/users/\(encodePath(config.address))/mailFolders"
        let id: String
        if let existing = try await findFolder(named: name, listURL: base) {
            id = existing
        } else {
            id = try await createFolder(named: name, createURL: base)
        }
        folderIdCache[name] = id
        return id
    }

    private func findFolder(named name: String, listURL: String) async throws -> String? {
        let escaped = name.replacingOccurrences(of: "'", with: "''")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let data = try await get(url: "\(listURL)?$filter=displayName%20eq%20'\(escaped)'")
        struct Page: Decodable {
            struct Folder: Decodable { let id: String }
            let value: [Folder]
        }
        return try JSONDecoder().decode(Page.self, from: data).value.first?.id
    }

    private func createFolder(named name: String, createURL: String) async throws -> String {
        let data = try await postJSON(url: createURL, body: ["displayName": name])
        struct Folder: Decodable { let id: String }
        return try JSONDecoder().decode(Folder.self, from: data).id
    }

    public func fetchAttachments(messageId: String) async throws -> [Attachment] {
        let url = "https://graph.microsoft.com/v1.0/users/\(encodePath(config.address))/messages/\(messageId)/attachments"
        let data = try await get(url: url)
        struct Page: Decodable { let value: [Item] }
        struct Item: Decodable {
            let name: String?
            let contentType: String?
            let contentBytes: String?
            let isInline: Bool?
        }
        let decoded = try JSONDecoder().decode(Page.self, from: data)
        return decoded.value.compactMap { item in
            guard item.isInline != true,
                  let bytes = item.contentBytes,
                  let data = Data(base64Encoded: bytes) else { return nil }
            return Attachment(
                name: item.name ?? "attachment",
                contentType: item.contentType ?? "application/octet-stream",
                data: data
            )
        }
    }

    public func fetchBodyHTML(messageId: String) async throws -> String? {
        let url = "https://graph.microsoft.com/v1.0/users/\(encodePath(config.address))/messages/\(messageId)?$select=body"
        let data = try await get(url: url)
        struct Message: Decodable {
            struct Body: Decodable { let content: String? }
            let body: Body?
        }
        return try JSONDecoder().decode(Message.self, from: data).body?.content
    }

    // MARK: - HTTP plumbing

    // ISO8601DateFormatter is documented thread-safe but not marked Sendable.
    private static nonisolated(unsafe) let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func validAccessToken() async throws -> String {
        guard var tokens = tokenStore.load() else {
            throw GraphError.notSignedIn(mailbox: config.address)
        }
        if tokens.needsRefresh() {
            let body = [
                "grant_type": "refresh_token",
                "client_id": config.clientId,
                "refresh_token": tokens.refreshToken,
                "scope": Self.scope,
            ]
            let (data, status) = try await postFormRaw(
                url: "https://login.microsoftonline.com/\(config.tenantId)/oauth2/v2.0/token",
                body: body
            )
            guard status == 200 else {
                tokenStore.clear()
                throw GraphError.notSignedIn(mailbox: config.address)
            }
            try storeTokens(from: data)
            tokens = tokenStore.load() ?? tokens
        }
        return tokens.accessToken
    }

    private func storeTokens(from data: Data) throws {
        struct TokenResponse: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: TimeInterval

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        let existing = tokenStore.load()
        try tokenStore.save(GraphTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? existing?.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(response.expiresIn)
        ))
    }

    private func get(url: String) async throws -> Data {
        try await send(url: url, method: "GET", jsonBody: nil)
    }

    private func postJSON(url: String, body: [String: String]) async throws -> Data {
        try await send(url: url, method: "POST", jsonBody: body)
    }

    private func send(url: String, method: String, jsonBody: [String: String]?) async throws -> Data {
        guard let requestURL = URL(string: url) else { throw GraphError.invalidResponse }
        let token = try await validAccessToken()
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Immutable IDs survive folder moves, so stored message IDs stay valid
        // after we file messages into state folders.
        request.setValue("IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(jsonBody)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GraphError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            throw GraphError.requestFailed(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }

    private func postForm(url: String, body: [String: String]) async throws -> Data {
        let (data, status) = try await postFormRaw(url: url, body: body)
        guard status == 200 else {
            throw GraphError.tokenRequestFailed(String(data: data, encoding: .utf8) ?? "HTTP \(status)")
        }
        return data
    }

    private func postFormRaw(url: String, body: [String: String]) async throws -> (Data, Int) {
        guard let requestURL = URL(string: url) else { throw GraphError.invalidResponse }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    private func encodePath(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
