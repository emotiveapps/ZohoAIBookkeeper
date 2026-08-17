import Foundation


public struct ReceiptsConfig: Codable, Sendable {
    public let mailboxes: [GraphMailboxConfig]
    /// Optional OneDrive folder swept for receipt files alongside the mailboxes.
    public let onedrive: OneDriveConfig?
    /// OneDrive folder (drive-root-relative) holding the canonical receipt
    /// archive, synced via `GraphDriveSyncEngine` (cloud-canonical, local
    /// cache + staging). Must NOT sit inside the swept `onedrive.folderPath`
    /// (the sweep would reprocess it).
    public let archiveFolderPath: String?

    public var resolvedArchiveFolderPath: String {
        archiveFolderPath ?? "03_Finance/ZohoAIBookkeeper/Receipts Archive"
    }

    public init(
        mailboxes: [GraphMailboxConfig],
        onedrive: OneDriveConfig? = nil,
        archiveFolderPath: String? = nil
    ) {
        self.mailboxes = mailboxes
        self.onedrive = onedrive
        self.archiveFolderPath = archiveFolderPath
    }
}

