import SwiftUI
import WatchConnectivity
import WidgetKit
import BookkeeperCore


/// Persists the pending count where both the watch app and the complication
/// timeline provider can read it.
enum PendingCountStorage {
    static let countKey = "pendingCount"
    static let updatedAtKey = "pendingUpdatedAt"

    static func read() -> (count: Int, updatedAt: Date?) {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: countKey)
        let timestamp = defaults.double(forKey: updatedAtKey)
        let updatedAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        return (count, updatedAt)
    }

    static func write(count: Int, updatedAt: Date) {
        let defaults = UserDefaults.standard
        defaults.set(count, forKey: countKey)
        defaults.set(updatedAt.timeIntervalSince1970, forKey: updatedAtKey)
    }
}

