import SwiftUI
import BookkeeperCore

/// Form state for credentials, shared by SetupView and SettingsView.
struct CredentialsFormModel {
    var clientId = ""
    var clientSecret = ""
    var accessToken = ""
    var refreshToken = ""
    var organizationId = ""
    var region = "com"
    var anthropicApiKey = ""
    /// Category hierarchy carried through JSON import (not editable in the form).
    var categoryMapping: CategoryMappingConfig?

    // Receipts (optional). The form edits the practical single-mailbox case;
    // a JSON import with multiple mailboxes keeps only the first on save.
    var receiptTenantId = ""
    var receiptClientId = ""
    var receiptMailbox = ""
    var oneDriveFolderPath = ""
    var archiveFolderPath = ""

    var isValid: Bool {
        !clientId.isEmpty && !clientSecret.isEmpty && !accessToken.isEmpty
            && !refreshToken.isEmpty && !organizationId.isEmpty && !anthropicApiKey.isEmpty
    }

    var configuration: FullConfiguration {
        FullConfiguration(
            zoho: ZohoConfiguration(
                clientId: clientId,
                clientSecret: clientSecret,
                accessToken: accessToken,
                refreshToken: refreshToken,
                organizationId: organizationId,
                region: region
            ),
            anthropic: AnthropicConfiguration(apiKey: anthropicApiKey),
            categoryMapping: categoryMapping,
            receipts: receiptsConfig
        )
    }

    private var receiptsConfig: ReceiptsConfig? {
        guard !receiptTenantId.isEmpty, !receiptClientId.isEmpty, !receiptMailbox.isEmpty else {
            return nil
        }
        return ReceiptsConfig(
            mailboxes: [GraphMailboxConfig(
                tenantId: receiptTenantId,
                clientId: receiptClientId,
                address: receiptMailbox
            )],
            onedrive: oneDriveFolderPath.isEmpty ? nil : OneDriveConfig(folderPath: oneDriveFolderPath),
            archiveFolderPath: archiveFolderPath.isEmpty ? nil : archiveFolderPath
        )
    }

    mutating func apply(_ config: FullConfiguration) {
        clientId = config.zoho.clientId
        clientSecret = config.zoho.clientSecret
        accessToken = config.zoho.accessToken
        refreshToken = config.zoho.refreshToken
        organizationId = config.zoho.organizationId
        region = config.zoho.region
        anthropicApiKey = config.anthropic.apiKey
        categoryMapping = config.categoryMapping
        if let mailbox = config.receipts?.mailboxes.first {
            receiptTenantId = mailbox.tenantId
            receiptClientId = mailbox.clientId
            receiptMailbox = mailbox.address
        }
        oneDriveFolderPath = config.receipts?.onedrive?.folderPath ?? ""
        archiveFolderPath = config.receipts?.archiveFolderPath ?? ""
    }
}
