import Foundation

/// How many times each pending receipt has been re-checked against Zoho
/// without finding a match.
///
/// This is operational state, not audit data, so it lives in the sync store
/// (state.json on the CLI, UserDefaults in the app) rather than in the receipt
/// sidecars. Keeping it out of the archive means a budgeted retry pass never
/// rewrites — and re-uploads — hundreds of sidecar files just to note that
/// nothing happened.
public struct ReceiptRetryLedger: Sendable, Codable {
    /// Key under which the ledger is serialized in a `SyncStateStore`.
    static let stateKey = "receiptRetryAttempts"

    private var attempts: [String: Int]

    public init(attempts: [String: Int] = [:]) {
        self.attempts = attempts
    }

    public static func load(from state: any SyncStateStore) -> ReceiptRetryLedger {
        guard let raw = state.value(forKey: stateKey),
              let data = raw.data(using: .utf8),
              let attempts = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return ReceiptRetryLedger()
        }
        return ReceiptRetryLedger(attempts: attempts)
    }

    public func save(to state: any SyncStateStore) {
        guard let data = try? JSONEncoder().encode(attempts),
              let raw = String(data: data, encoding: .utf8) else { return }
        state.setValue(raw, forKey: Self.stateKey)
    }

    public func attemptCount(for id: String) -> Int { attempts[id] ?? 0 }

    public mutating func recordFailure(for id: String) {
        attempts[id, default: 0] += 1
    }

    /// Forget a receipt's history — it matched, or its budget is being reset.
    public mutating func clear(for id: String) {
        attempts[id] = nil
    }

    /// Drop every count, so the next budgeted pass reconsiders all of them.
    public mutating func reset() {
        attempts.removeAll()
    }
}
