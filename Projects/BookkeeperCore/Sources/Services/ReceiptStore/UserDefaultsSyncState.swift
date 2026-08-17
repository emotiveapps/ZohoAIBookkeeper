import Foundation

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
