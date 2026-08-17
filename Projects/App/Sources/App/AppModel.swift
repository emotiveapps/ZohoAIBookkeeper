import Foundation
import Observation
import ZohoBooksClient
import BookkeeperCore

/// App lifecycle: credential loading, connection, and the active workspace.
@MainActor
@Observable
public final class AppModel {
    public enum Phase {
        case loading
        case needsSetup
        case ready(Workspace)
    }

    public private(set) var phase: Phase = .loading

    private let credentialsStore: any CredentialsStore

    public init(credentialsStore: any CredentialsStore = KeychainCredentialsStore()) {
        self.credentialsStore = credentialsStore
    }

    public var workspace: Workspace? {
        if case let .ready(workspace) = phase { return workspace }
        return nil
    }

    /// Called once at launch: restore credentials from the Keychain and connect.
    public func bootstrap() async {
        guard case .loading = phase else { return }

        let configuration: FullConfiguration?
        do {
            configuration = try credentialsStore.load()
        } catch {
            logger.error("Failed to read credentials: \(error)")
            configuration = nil
        }

        guard let configuration else {
            phase = .needsSetup
            return
        }

        // Enter the app immediately with saved credentials; data loads in the background
        // and any connection problem surfaces inside the workspace UI.
        let workspace = await Workspace.connect(configuration: configuration)
        phase = .ready(workspace)
        await workspace.refresh()
    }

    /// Validate new credentials by connecting; persist and switch phases only on success.
    /// - Returns: an error message to display, or nil on success.
    public func submitCredentials(_ configuration: FullConfiguration) async -> String? {
        let workspace = await Workspace.connect(configuration: configuration)
        await workspace.refresh()

        if workspace.bankAccounts.isEmpty, let error = workspace.lastError {
            return error
        }

        do {
            try credentialsStore.save(configuration)
        } catch {
            return "Connected, but saving to the Keychain failed: \(error.localizedDescription)"
        }

        phase = .ready(workspace)
        return nil
    }

    /// Forget credentials and return to setup. Local caches are left intact.
    public func signOut() {
        do {
            try credentialsStore.clear()
        } catch {
            logger.error("Failed to clear credentials: \(error)")
        }
        phase = .needsSetup
    }
}
