import SwiftUI
import WatchConnectivity
import WidgetKit
import BookkeeperCore


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

