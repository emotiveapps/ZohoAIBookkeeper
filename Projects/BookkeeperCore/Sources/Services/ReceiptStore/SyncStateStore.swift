import Foundation

/// Where receipt-sync bookkeeping (last-sync timestamps) lives — deliberately
/// separate from the receipt archive, which holds only audit data.
public protocol SyncStateStore: Sendable {
    func lastSync(mailbox: String) -> Date?
    func setLastSync(mailbox: String, date: Date)
    /// Generic string state (e.g. Graph delta tokens), keyed by caller.
    func value(forKey key: String) -> String?
    func setValue(_ value: String?, forKey key: String)
}
