import Foundation

/// Persists the pending count where both the watch app and the complication
/// timeline provider can read it. The provider runs in the widget extension —
/// a separate process — so this must be an App Group container, not standard
/// defaults. This file is compiled into both targets.
enum PendingCountStorage {
    static let appGroupID = "group.com.emotiveapps.ZohoBookkeeperApp"
    static let countKey = "pendingCount"
    static let updatedAtKey = "pendingUpdatedAt"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static func read() -> (count: Int, updatedAt: Date?) {
        let defaults = Self.defaults
        let count = defaults.integer(forKey: countKey)
        let timestamp = defaults.double(forKey: updatedAtKey)
        let updatedAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        return (count, updatedAt)
    }

    static func write(count: Int, updatedAt: Date) {
        let defaults = Self.defaults
        defaults.set(count, forKey: countKey)
        defaults.set(updatedAt.timeIntervalSince1970, forKey: updatedAtKey)
    }
}
