import Foundation


/// A OneDrive folder that acts as a second receipts inbox. Files are read via
/// Microsoft Graph using the sign-in of a configured mailbox (delegated
/// `Files.ReadWrite` on the signed-in user's own OneDrive), so processing is
/// independent of any machine's OneDrive sync client. Processed files are
/// moved into state subfolders, never deleted.
public struct OneDriveConfig: Codable, Sendable, Hashable {
    /// Folder path within the signed-in user's OneDrive, e.g. "03_Finance/Receipts".
    public let folderPath: String
    /// Picks which mailbox sign-in to reuse when mailboxes span tenants
    /// (defaults to the first configured mailbox).
    public let tenantId: String?

    public init(folderPath: String, tenantId: String? = nil) {
        self.folderPath = folderPath
        self.tenantId = tenantId
    }
}

