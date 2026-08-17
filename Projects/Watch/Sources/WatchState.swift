import SwiftUI
import WatchConnectivity
import WidgetKit
import BookkeeperCore


/// Watch-side state: pending count received from the iPhone app via
/// Watch Connectivity, persisted for the complication.
@MainActor
final class WatchState: ObservableObject {
    @Published var pendingCount: Int = 0
    @Published var lastUpdated: Date?
    @Published var isPhoneReachable = true

    private let receiver = PhoneSyncReceiver()

    init() {
        // Show the last known values immediately, then live-update.
        let stored = PendingCountStorage.read()
        pendingCount = stored.count
        lastUpdated = stored.updatedAt

        receiver.onUpdate = { [weak self] count, updatedAt in
            Task { @MainActor in
                self?.pendingCount = count
                self?.lastUpdated = updatedAt
            }
        }
        receiver.activate()
    }

    func refresh() {
        let stored = PendingCountStorage.read()
        pendingCount = stored.count
        lastUpdated = stored.updatedAt
        isPhoneReachable = WCSession.isSupported() && WCSession.default.isReachable
    }
}

