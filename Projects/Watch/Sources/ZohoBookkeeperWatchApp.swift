import SwiftUI
import WatchConnectivity
import WidgetKit
import BookkeeperCore

@main
struct ZohoBookkeeperWatchApp: App {
    @StateObject private var watchState = WatchState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(watchState)
        }
    }
}

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

/// WCSession receiver. Stateless except for the update callback; delegate
/// callbacks arrive on arbitrary queues.
final class PhoneSyncReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
    var onUpdate: (@Sendable (Int, Date) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // The phone may have pushed context while we weren't running.
        guard activationState == .activated else { return }
        apply(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        apply(context)
    }

    private func apply(_ context: [String: Any]) {
        guard let count = context["totalPending"] as? Int else { return }
        let updatedAt = (context["updatedAt"] as? TimeInterval)
            .map(Date.init(timeIntervalSince1970:)) ?? Date()

        PendingCountStorage.write(count: count, updatedAt: updatedAt)
        WidgetCenter.shared.reloadAllTimelines()
        onUpdate?(count, updatedAt)
    }
}
