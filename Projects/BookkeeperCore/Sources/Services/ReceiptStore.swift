import Foundation

/// The local receipt filing cabinet: original files plus JSON sidecars under
/// `<root>/<year>/`. This archive is the durable audit trail (IRS retention),
/// independent of what's attached in Zoho.
public actor ReceiptStore {
    private let root: URL

    public init(root: URL? = nil) throws {
        if let root {
            self.root = root
        } else {
            #if os(macOS)
            self.root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".zoho-ai-bookkeeper/receipts")
            #else
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.root = documents.appendingPathComponent("Receipts")
            #endif
        }
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

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

    // MARK: - Sync state

    public func lastSync(mailbox: String) -> Date? {
        loadState().lastSyncByMailbox[mailbox]
    }

    public func setLastSync(mailbox: String, date: Date) {
        var state = loadState()
        state.lastSyncByMailbox[mailbox] = date
        saveState(state)
    }

    // MARK: - Private

    private struct State: Codable {
        var lastSyncByMailbox: [String: Date] = [:]
    }

    private var stateURL: URL { root.appendingPathComponent("state.json") }

    private func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? Self.decoder.decode(State.self, from: data) else {
            return State()
        }
        return state
    }

    private func saveState(_ state: State) {
        if let data = try? Self.encoder.encode(state) {
            try? data.write(to: stateURL)
        }
    }

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
