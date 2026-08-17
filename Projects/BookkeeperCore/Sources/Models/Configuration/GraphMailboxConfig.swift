import Foundation

/// One Microsoft 365 mailbox polled for receipts, with the Entra app that
/// grants access to it (device-code flow; no client secret).
public struct GraphMailboxConfig: Codable, Sendable, Hashable {
    public let tenantId: String
    public let clientId: String
    /// Mailbox to poll (may be a shared mailbox the signed-in user has Full Access to).
    public let address: String

    public init(tenantId: String, clientId: String, address: String) {
        self.tenantId = tenantId
        self.clientId = clientId
        self.address = address
    }
}
