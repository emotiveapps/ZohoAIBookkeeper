import Foundation

// MARK: - Sync state

/// Where receipt-sync bookkeeping (last-sync timestamps) lives — deliberately
/// separate from the receipt archive, which holds only audit data.
public protocol SyncStateStore: Sendable {
    func lastSync(mailbox: String) -> Date?
    func setLastSync(mailbox: String, date: Date)
    /// Generic string state (e.g. Graph delta tokens), keyed by caller.
    func value(forKey key: String) -> String?
    func setValue(_ value: String?, forKey key: String)
}

/// iPhone/iPad: UserDefaults behind a predefined, namespaced key set. All keys
/// live in one place so the app's defaults surface stays auditable.
public struct UserDefaultsSyncState: SyncStateStore {
    /// Every UserDefaults key this wrapper may touch.
    private enum Key {
        static let lastSyncPrefix = "receipts.lastSync."
        static let valuePrefix = "receipts.state."

        static func lastSync(mailbox: String) -> String {
            lastSyncPrefix + mailbox.lowercased()
        }
    }

    public init() {}

    public func lastSync(mailbox: String) -> Date? {
        UserDefaults.standard.object(forKey: Key.lastSync(mailbox: mailbox)) as? Date
    }

    public func setLastSync(mailbox: String, date: Date) {
        UserDefaults.standard.set(date, forKey: Key.lastSync(mailbox: mailbox))
    }

    public func value(forKey key: String) -> String? {
        UserDefaults.standard.string(forKey: Key.valuePrefix + key)
    }

    public func setValue(_ value: String?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: Key.valuePrefix + key)
        } else {
            UserDefaults.standard.removeObject(forKey: Key.valuePrefix + key)
        }
    }
}

/// CLI: a small JSON file kept next to config.json in the repo (gitignored) —
/// operational state lives with the machine's working copy, never in the
/// audit archive and never in a hidden home folder.
public struct FileSyncState: SyncStateStore {
    private struct State: Codable {
        var lastSyncByMailbox: [String: Date] = [:]
        var values: [String: String]? = [:]
    }

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func lastSync(mailbox: String) -> Date? {
        load().lastSyncByMailbox[mailbox]
    }

    public func setLastSync(mailbox: String, date: Date) {
        var state = load()
        state.lastSyncByMailbox[mailbox] = date
        save(state)
    }

    public func value(forKey key: String) -> String? {
        load().values?[key]
    }

    public func setValue(_ value: String?, forKey key: String) {
        var state = load()
        var values = state.values ?? [:]
        values[key] = value
        state.values = values
        save(state)
    }

    private func save(_ state: State) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            try? data.write(to: url)
        }
    }

    private func load() -> State {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(State.self, from: data) else {
            return State()
        }
        return state
    }
}

/// The local receipt filing cabinet: original files plus JSON sidecars under
/// `<root>/<year>/`. This archive is the durable audit trail (IRS retention),
/// independent of what's attached in Zoho.
public actor ReceiptStore {
    private enum Backend {
        /// Plain directory (tests; offline fallback when Graph isn't configured).
        case local(URL)
        /// Cloud-canonical: reads/writes go through the drive sync engine.
        case engine(GraphDriveSyncEngine)
    }

    private let backend: Backend
    private nonisolated let displayRoot: URL

    /// Local-directory archive (tests and non-Graph fallback). Production
    /// clients use `init(engine:)` — the archive is cloud-canonical.
    public init(root: URL) throws {
        self.backend = .local(root)
        self.displayRoot = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Cloud-canonical archive backed by a `GraphDriveSyncEngine`.
    public init(engine: GraphDriveSyncEngine) {
        self.backend = .engine(engine)
        self.displayRoot = engine.cacheRoot
    }

    public nonisolated var rootURL: URL { displayRoot }

    /// The engine, when this store is cloud-backed (for pull/push orchestration).
    public var syncEngine: GraphDriveSyncEngine? {
        if case let .engine(engine) = backend { return engine }
        return nil
    }

    // MARK: - Ingest

    /// Store a receipt file and its sidecar. `year` and file name come from the
    /// parsed date when available, else the source received date, else today.
    public func ingest(
        fileData: Data,
        fileExtension: String,
        source: ReceiptRecord.Source,
        parsed: ParsedReceipt?
    ) async throws -> ReceiptRecord {
        let id = UUID().uuidString
        let dateString = parsed?.date
            ?? source.receivedAt.map(Self.dayFormatter.string(from:))
            ?? Self.dayFormatter.string(from: Date())
        let year = String(dateString.prefix(4))
        let slug = Self.slug(parsed?.vendor ?? source.subject ?? "receipt")
        let fileName = "\(dateString)-\(slug)-\(id.prefix(8)).\(fileExtension)"
        let relativePath = "\(year)/\(fileName)"

        try await writeFile(relativePath: relativePath, data: fileData)

        let record = ReceiptRecord(
            id: id,
            relativePath: relativePath,
            source: source,
            parsed: parsed
        )
        try await write(record)
        return record
    }

    public func fileData(for record: ReceiptRecord) async throws -> Data {
        switch backend {
        case let .local(root):
            return try Data(contentsOf: root.appendingPathComponent(record.relativePath))
        case let .engine(engine):
            return try await engine.fileData(at: record.relativePath)
        }
    }

    // MARK: - Records

    public func update(_ record: ReceiptRecord) async throws {
        var updated = record
        updated.updatedAt = Date()
        try await write(updated)
    }

    public func allRecords() async -> [ReceiptRecord] {
        let urls: [URL]
        switch backend {
        case let .local(root):
            urls = Self.sidecarURLs(under: root)
        case let .engine(engine):
            urls = Array(await engine.localFiles(withSuffix: ".json").values)
        }

        var records: [ReceiptRecord] = []
        for url in urls {
            if let data = try? Data(contentsOf: url),
               let record = try? Self.decoder.decode(ReceiptRecord.self, from: data) {
                records.append(record)
            }
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    /// Synchronous helper: FileManager enumeration is unavailable directly in
    /// async contexts under strict concurrency.
    private static func sidecarURLs(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator
            where url.pathExtension == "json" && url.lastPathComponent != "state.json" {
            urls.append(url)
        }
        return urls
    }

    public func record(idPrefix: String) async -> ReceiptRecord? {
        let matches = await allRecords().filter { $0.id.lowercased().hasPrefix(idPrefix.lowercased()) }
        return matches.count == 1 ? matches.first : nil
    }

    /// All identifiers already ingested (email dedupe): Graph IDs and RFC
    /// Message-IDs both count, so records survive Graph ID format changes.
    public func knownMessageIds() async -> Set<String> {
        var ids = Set<String>()
        for record in await allRecords() {
            if let id = record.source.messageId { ids.insert(id) }
            if let id = record.source.internetMessageId { ids.insert(id) }
        }
        return ids
    }

    /// Find an existing record for a message whose Graph ID has drifted
    /// (e.g. records created before immutable IDs): match on mailbox +
    /// subject + received time.
    public func adoptableRecord(mailbox: String, subject: String, receivedAt: Date?) async -> ReceiptRecord? {
        guard let receivedAt else { return nil }
        return await allRecords().first { record in
            record.source.mailbox == mailbox
                && record.source.subject == subject
                && abs((record.source.receivedAt?.timeIntervalSince(receivedAt)) ?? .infinity) < 2
        }
    }

    // MARK: - Private

    private func write(_ record: ReceiptRecord) async throws {
        let data = try Self.encoder.encode(record)
        try await writeFile(relativePath: record.relativePath + ".json", data: data)
    }

    private func writeFile(relativePath: String, data: Data) async throws {
        switch backend {
        case let .local(root):
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url)
        case let .engine(engine):
            try await engine.stage(relativePath: relativePath, data: data)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let mapped = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "receipt" : String(collapsed.prefix(32))
    }
}
