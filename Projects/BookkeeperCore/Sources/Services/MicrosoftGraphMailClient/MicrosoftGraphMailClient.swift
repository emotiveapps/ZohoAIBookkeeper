import Foundation
import Security

/// Minimal Microsoft Graph client for reading a (shared) mailbox via
/// delegated `Mail.Read.Shared`, authenticated with the device-code flow
/// (public client — no secret; tokens live in the Keychain).
public actor MicrosoftGraphMailClient {
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
    // Files.ReadWrite: sweeping the signed-in user's OneDrive receipts folder
    // (list/download + moves into state subfolders). Adding a scope requires
    // the matching Entra delegated permission and a fresh `receipts login`.
    private static let scope = "https://graph.microsoft.com/Mail.ReadWrite.Shared "
        + "https://graph.microsoft.com/Files.ReadWrite offline_access"

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
            "scope": Self.scope
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
                "device_code": code.deviceCode
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

    // MARK: - OneDrive
    //
    // Drive operations run against the *signed-in user's* OneDrive (`/me/drive`)
    // using the same token as the mailbox — this client is really "the Graph
    // client for one signed-in account", the mailbox is just its main job.

    public struct DriveItem: Sendable {
        /// driveItem ID — stable across renames and moves within the drive.
        public let id: String
        public let name: String
        /// Path relative to the swept base folder, e.g. "2025-Q2/receipt.pdf".
        public let relativePath: String
        public let size: Int
        public let lastModified: Date?
        /// Change tag — differs whenever content or metadata changes.
        public let eTag: String?

        public init(
            id: String, name: String, relativePath: String,
            size: Int, lastModified: Date?, eTag: String? = nil
        ) {
            self.id = id
            self.name = name
            self.relativePath = relativePath
            self.size = size
            self.lastModified = lastModified
            self.eTag = eTag
        }
    }

    /// One entry from a drive delta response. `parentPath` is the raw Graph
    /// parentReference path (e.g. "/drive/root:/03_Finance/…").
    public struct DeltaItem: Sendable {
        public let id: String
        public let name: String
        public let parentPath: String?
        public let isFolder: Bool
        public let isDeleted: Bool
        public let size: Int
        public let lastModified: Date?
        public let eTag: String?
    }

    public struct DeltaPage: Sendable {
        public let items: [DeltaItem]
        /// Token to persist for the next incremental pull (present when the
        /// enumeration is complete).
        public let nextToken: String?
    }

    /// All files under `folderPath` (recursively), excluding the given
    /// top-level subfolder names (the state folders processed files move into).
    public func listDriveFiles(
        folderPath: String,
        excludingTopLevelFolders excluded: Set<String>
    ) async throws -> [DriveItem] {
        let baseId = try await driveFolderId(path: folderPath)
        var files: [DriveItem] = []
        // (folderId, path relative to base)
        var pending: [(id: String, prefix: String)] = [(baseId, "")]

        while let (folderId, prefix) = pending.popLast() {
            var next: String? = "https://graph.microsoft.com/v1.0/me/drive/items/\(folderId)/children"
                + "?$select=id,name,size,folder,file,lastModifiedDateTime,eTag&$top=200"
            while let page = next {
                let data = try await get(url: page)
                struct Page: Decodable {
                    let value: [Item]
                    let nextLink: String?
                    enum CodingKeys: String, CodingKey {
                        case value
                        case nextLink = "@odata.nextLink"
                    }
                }
                struct Item: Decodable {
                    struct Folder: Decodable {}
                    struct File: Decodable {}
                    let id: String
                    let name: String
                    let size: Int?
                    let folder: Folder?
                    let file: File?
                    let lastModifiedDateTime: String?
                    let eTag: String?
                }
                let decoded = try JSONDecoder().decode(Page.self, from: data)
                for item in decoded.value {
                    if item.folder != nil {
                        if prefix.isEmpty && excluded.contains(item.name) { continue }
                        // Hidden/tooling folders (".claude" etc.) are not receipts.
                        if item.name.hasPrefix(".") { continue }
                        pending.append((item.id, prefix.isEmpty ? item.name : "\(prefix)/\(item.name)"))
                    } else if item.file != nil {
                        files.append(DriveItem(
                            id: item.id,
                            name: item.name,
                            relativePath: prefix.isEmpty ? item.name : "\(prefix)/\(item.name)",
                            size: item.size ?? 0,
                            lastModified: item.lastModifiedDateTime.flatMap { Self.isoFormatter.date(from: $0) },
                            eTag: item.eTag
                        ))
                    }
                }
                next = decoded.nextLink
            }
        }
        return files
    }

    public func downloadDriveItem(id: String) async throws -> Data {
        try await get(url: "https://graph.microsoft.com/v1.0/me/drive/items/\(id)/content")
    }

    /// Find or create `subPath` (may be nested, e.g. "Matched/2025-Q2") under
    /// the base folder and return its folder ID. Results are cached.
    public func ensureDriveFolder(subPath: String, under basePath: String) async throws -> String {
        let cacheKey = "drive:\(basePath)/\(subPath)"
        if let cached = folderIdCache[cacheKey] { return cached }

        var parentId = try await driveFolderId(path: basePath)
        for segment in subPath.split(separator: "/").map(String.init) {
            parentId = try await ensureDriveChild(named: segment, parentId: parentId)
        }
        folderIdCache[cacheKey] = parentId
        return parentId
    }

    /// Move a drive item into a folder. Never overwrites: name collisions at
    /// the destination are auto-renamed by Graph.
    public func moveDriveItem(id: String, toFolderId folderId: String) async throws {
        let body: [String: Any] = [
            "parentReference": ["id": folderId],
            "@microsoft.graph.conflictBehavior": "rename"
        ]
        _ = try await send(
            url: "https://graph.microsoft.com/v1.0/me/drive/items/\(id)",
            method: "PATCH",
            bodyData: try JSONSerialization.data(withJSONObject: body)
        )
    }

    public struct UploadedItem: Sendable {
        public let id: String
        public let eTag: String?
    }

    public enum DriveConflictBehavior: String, Sendable {
        case fail, replace, rename
    }

    /// Create or replace a file at `path` (drive-root-relative) with a single
    /// PUT. Graph's simple-upload limit is 4 MB; callers with larger payloads
    /// must not use this (receipts are far below it, enforced here).
    public func uploadDriveItem(
        path: String,
        data: Data,
        conflictBehavior: DriveConflictBehavior,
        ifMatch: String? = nil
    ) async throws -> UploadedItem {
        guard data.count < 4_000_000 else {
            throw GraphError.requestFailed(status: 413, body: "File exceeds the 4 MB simple-upload limit")
        }
        let url = "https://graph.microsoft.com/v1.0/me/drive/root:/\(encodePath(path)):/content"
            + "?@microsoft.graph.conflictBehavior=\(conflictBehavior.rawValue)"
        var headers: [String: String] = [:]
        if let ifMatch { headers["If-Match"] = ifMatch }
        let response = try await send(
            url: url, method: "PUT", bodyData: data,
            contentType: "application/octet-stream", extraHeaders: headers
        )
        struct Item: Decodable {
            let id: String
            let eTag: String?
        }
        let item = try JSONDecoder().decode(Item.self, from: response)
        return UploadedItem(id: item.id, eTag: item.eTag)
    }

    /// Walk the drive delta stream to completion. Pass a stored token for
    /// incremental changes, `"latest"` to establish a baseline without
    /// enumerating, or nil for a full enumeration of the drive.
    /// OneDrive for Business only supports delta on the drive *root*, so
    /// callers filter results by `parentPath` themselves. A 410 response
    /// means the token expired — fall back to a listing and re-baseline.
    public func driveDelta(token: String?) async throws -> DeltaPage {
        var url = "https://graph.microsoft.com/v1.0/me/drive/root/delta"
            + "?$select=id,name,size,folder,file,deleted,parentReference,lastModifiedDateTime,eTag&$top=200"
        if let token {
            let escaped = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token
            url += "&token=\(escaped)"
        }

        var items: [DeltaItem] = []
        var deltaToken: String?
        var next: String? = url
        while let page = next {
            let data = try await get(url: page)
            struct Page: Decodable {
                let value: [Item]
                let nextLink: String?
                let deltaLink: String?
                enum CodingKeys: String, CodingKey {
                    case value
                    case nextLink = "@odata.nextLink"
                    case deltaLink = "@odata.deltaLink"
                }
            }
            struct Item: Decodable {
                struct Folder: Decodable {}
                struct Deleted: Decodable {}
                struct Parent: Decodable { let path: String? }
                let id: String
                let name: String?
                let size: Int?
                let folder: Folder?
                let deleted: Deleted?
                let parentReference: Parent?
                let lastModifiedDateTime: String?
                let eTag: String?
            }
            let decoded = try JSONDecoder().decode(Page.self, from: data)
            items += decoded.value.map { item in
                DeltaItem(
                    id: item.id,
                    name: item.name ?? "",
                    parentPath: item.parentReference?.path,
                    isFolder: item.folder != nil,
                    isDeleted: item.deleted != nil,
                    size: item.size ?? 0,
                    lastModified: item.lastModifiedDateTime.flatMap { Self.isoFormatter.date(from: $0) },
                    eTag: item.eTag
                )
            }
            if let deltaLink = decoded.deltaLink {
                deltaToken = Self.token(fromDeltaLink: deltaLink)
            }
            next = decoded.nextLink
        }
        return DeltaPage(items: items, nextToken: deltaToken)
    }

    /// A token representing "now", without enumerating the drive.
    public func driveDeltaBaseline() async throws -> String? {
        try await driveDelta(token: "latest").nextToken
    }

    static func token(fromDeltaLink link: String) -> String? {
        URLComponents(string: link)?.queryItems?.first { $0.name == "token" }?.value
    }

    /// Resolve a path in the signed-in user's OneDrive to a folder ID.
    private func driveFolderId(path: String) async throws -> String {
        let cacheKey = "drive:\(path)"
        if let cached = folderIdCache[cacheKey] { return cached }
        let data = try await get(
            url: "https://graph.microsoft.com/v1.0/me/drive/root:/\(encodePath(path))"
        )
        struct Item: Decodable { let id: String }
        let id = try JSONDecoder().decode(Item.self, from: data).id
        folderIdCache[cacheKey] = id
        return id
    }

    private func ensureDriveChild(named name: String, parentId: String) async throws -> String {
        let listURL = "https://graph.microsoft.com/v1.0/me/drive/items/\(parentId)/children"
            + "?$select=id,name,folder&$top=200"
        struct Page: Decodable {
            struct Item: Decodable {
                struct Folder: Decodable {}
                let id: String
                let name: String
                let folder: Folder?
            }
            let value: [Item]
            let nextLink: String?
            enum CodingKeys: String, CodingKey {
                case value
                case nextLink = "@odata.nextLink"
            }
        }
        var next: String? = listURL
        while let page = next {
            let decoded = try JSONDecoder().decode(Page.self, from: try await get(url: page))
            if let match = decoded.value.first(where: { $0.name == name && $0.folder != nil }) {
                return match.id
            }
            next = decoded.nextLink
        }

        let body: [String: Any] = [
            "name": name,
            "folder": [String: String](),
            "@microsoft.graph.conflictBehavior": "fail"
        ]
        let data = try await send(
            url: "https://graph.microsoft.com/v1.0/me/drive/items/\(parentId)/children",
            method: "POST",
            bodyData: try JSONSerialization.data(withJSONObject: body)
        )
        struct Created: Decodable { let id: String }
        return try JSONDecoder().decode(Created.self, from: data).id
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
                "scope": Self.scope
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
        try await send(url: url, method: "GET", bodyData: nil)
    }

    private func postJSON(url: String, body: [String: String]) async throws -> Data {
        try await send(url: url, method: "POST", bodyData: try JSONEncoder().encode(body))
    }

    private func send(
        url: String,
        method: String,
        bodyData: Data?,
        contentType: String = "application/json",
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        guard let requestURL = URL(string: url) else { throw GraphError.invalidResponse }
        let token = try await validAccessToken()
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Immutable IDs survive folder moves, so stored message IDs stay valid
        // after we file messages into state folders.
        request.setValue("IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer")
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let bodyData {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
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
