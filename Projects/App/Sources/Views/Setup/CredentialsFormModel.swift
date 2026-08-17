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
            categoryMapping: categoryMapping
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
    }
}

