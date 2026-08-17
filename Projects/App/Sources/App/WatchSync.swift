import Foundation
import WatchConnectivity

/// Pushes the total pending-transaction count to the paired Apple Watch so the
/// watch app and complication show real numbers instead of placeholders.
/// Stateless after init; safe to touch from any executor.
final class WatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSync()

    override private init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Best-effort: silently a no-op when no watch is paired or the session
    /// hasn't finished activating yet (the next refresh will catch it up).
    func send(totalPending: Int) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        try? session.updateApplicationContext([
            "totalPending": totalPending,
            "updatedAt": Date().timeIntervalSince1970
        ])
    }

    // MARK: - WCSessionDelegate

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
