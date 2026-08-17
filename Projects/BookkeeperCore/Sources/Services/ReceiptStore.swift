import Foundation

// MARK: - Sync state

/// Where receipt-sync bookkeeping (last-sync timestamps) lives — deliberately
/// separate from the receipt archive, which holds only audit data.
public protocol SyncStateStore: Sendable {
    func lastSync(mailbox: String) -> Date?
    func setLastSync(mailbox: String, date: Date)
}

/// iPhone/iPad: UserDefaults behind a predefined, namespaced key set. All keys
/// live in one place so the app's defaults surface stays auditable.
public struct UserDefaultsSyncState: SyncStateStore {
    /// Every UserDefaults key this wrapper may touch.
    private enum Key {
        static let lastSyncPrefix = "receipts.lastSync."

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
}

/// CLI: a small JSON file kept next to config.json in the repo (gitignored) —
/// operational state lives with the machine's working copy, never in the
/// audit archive and never in a hidden home folder.
public struct FileSyncState: SyncStateStore {
    private struct State: Codable {
        var lastSyncByMailbox: [String: Date] = [:]
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
    private let root: URL

    /// The archive location is always explicit on macOS — it's IRS-retention
    /// audit data and belongs in a visible, backed-up folder chosen by the
    /// owner (`receipts.archive_path` in config), never a hidden default.
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    #if !os(macOS)
    /// iOS/watchOS: the app's Documents container (included in device backups).
    public init() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try self.init(root: documents.appendingPathComponent("Receipts"))
    }
    #endif

    public nonisolated var rootURL: URL { root }

    // MARK: - Ingest

    /// Store a receipt file and its sidecar. `year` and file name come from the
    /// parsed date when available, else the source received date, else today.
    public func ingest(
        fileData: Data,
        fileExtension: String,
        source: ReceiptRecord.Source,
        parsed: ParsedReceipt?
    ) throws -> ReceiptRecord {
        let id = UUID().uuidString
        let dateString = parsed?.date
            ?? source.receivedAt.map(Self.dayFormatter.string(from:))
            ?? Self.dayFormatter.string(from: Date())
        let year = String(dateString.prefix(4))
        let slug = Self.slug(parsed?.vendor ?? source.subject ?? "receipt")
        let fileName = "\(dateString)-\(slug)-\(id.prefix(8)).\(fileExtension)"
        let relativePath = "\(year)/\(fileName)"

        let directory = root.appendingPathComponent(year)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileData.write(to: directory.appendingPathComponent(fileName))

        let record = ReceiptRecord(
            id: id,
            relativePath: relativePath,
            source: source,
            parsed: parsed
        )
        try write(record)
        return record
    }

    public func fileData(for record: ReceiptRecord) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(record.relativePath))
    }

    // MARK: - Records

    public func update(_ record: ReceiptRecord) throws {
        var updated = record
        updated.updatedAt = Date()
        try write(updated)
    }

    public func allRecords() -> [ReceiptRecord] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var records: [ReceiptRecord] = []
        for case let url as URL in enumerator where url.pathExtension == "json" && url.lastPathComponent != "state.json" {
            if let data = try? Data(contentsOf: url),
               let record = try? Self.decoder.decode(ReceiptRecord.self, from: data) {
                records.append(record)
            }
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    public func record(idPrefix: String) -> ReceiptRecord? {
        let matches = allRecords().filter { $0.id.lowercased().hasPrefix(idPrefix.lowercased()) }
        return matches.count == 1 ? matches.first : nil
    }

    /// All identifiers already ingested (email dedupe): Graph IDs and RFC
    /// Message-IDs both count, so records survive Graph ID format changes.
    public func knownMessageIds() -> Set<String> {
        var ids = Set<String>()
        for record in allRecords() {
            if let id = record.source.messageId { ids.insert(id) }
            if let id = record.source.internetMessageId { ids.insert(id) }
        }
        return ids
    }

    /// Find an existing record for a message whose Graph ID has drifted
    /// (e.g. records created before immutable IDs): match on mailbox +
    /// subject + received time.
    public func adoptableRecord(mailbox: String, subject: String, receivedAt: Date?) -> ReceiptRecord? {
        guard let receivedAt else { return nil }
        return allRecords().first { record in
            record.source.mailbox == mailbox
                && record.source.subject == subject
                && abs((record.source.receivedAt?.timeIntervalSince(receivedAt)) ?? .infinity) < 2
        }
    }

    // MARK: - Private

    private func write(_ record: ReceiptRecord) throws {
        let sidecarURL = root.appendingPathComponent(record.relativePath + ".json")
        let data = try Self.encoder.encode(record)
        try data.write(to: sidecarURL)
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
