import Foundation


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

