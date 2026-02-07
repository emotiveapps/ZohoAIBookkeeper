import Foundation
import SwiftUI
import ZohoBooksClient
import BookkeeperCore

/// App-wide state management
@MainActor
public final class AppState: ObservableObject {
    // MARK: - Configuration State
    @Published public var isConfigured = false
    @Published public var zohoConfig: ZohoConfiguration?
    @Published public var anthropicConfig: AnthropicConfiguration?
    @Published public var categoryMapping: CategoryMappingConfig?

    // MARK: - Connection State
    @Published public var isConnected = false
    @Published public var connectionError: String?

    // MARK: - Services
    public var zohoClient: ZohoBooksClient<ZohoOAuth>?
    public var claudeService: ClaudeService?
    public var cacheService: CacheService?

    // MARK: - Data
    @Published public var bankAccounts: [ZBBankAccount] = []
    @Published public var categories: [String] = []
    @Published public var vendors: [String] = []

    public init() {
        // Try to initialize cache service
        do {
            cacheService = try CacheService()
        } catch {
            print("Failed to initialize cache service: \(error)")
        }

        // Load saved configuration from Keychain/UserDefaults
        loadSavedConfiguration()
    }

    // MARK: - Configuration

    public func configure(
        zoho: ZohoConfiguration,
        anthropic: AnthropicConfiguration,
        categories: CategoryMappingConfig? = nil
    ) async {
        zohoConfig = zoho
        anthropicConfig = anthropic
        categoryMapping = categories

        // Initialize Zoho client
        let config = ZohoConfig(
            clientId: zoho.clientId,
            clientSecret: zoho.clientSecret,
            accessToken: zoho.accessToken,
            refreshToken: zoho.refreshToken,
            organizationId: zoho.organizationId,
            region: ZohoRegion(rawValue: zoho.region) ?? .com
        )

        zohoClient = ZohoBooksClient(config: config, verbose: false)
        await zohoClient?.configure()

        // Initialize Claude service with categories
        let categoryList = categories?.allCategoryNames ?? []
        claudeService = ClaudeService(
            apiKey: anthropic.apiKey,
            categories: categoryList,
            verbose: false
        )

        isConfigured = true
        saveConfiguration()
    }

    public func connect() async {
        guard let client = zohoClient else {
            connectionError = "Client not configured"
            return
        }

        connectionError = nil

        do {
            // Test connection by fetching accounts
            bankAccounts = try await client.fetchBankAccounts()

            // Fetch categories if not already set
            if categories.isEmpty {
                let accounts = try await client.fetchAccounts()
                categories = accounts
                    .filter { ($0.accountType ?? "").lowercased() == "expense" }
                    .compactMap { $0.accountName }
                    .sorted()
            }

            // Fetch vendors
            let contacts = try await client.fetchContacts(contactType: "vendor")
            vendors = contacts.compactMap { $0.contactName }

            isConnected = true
        } catch {
            connectionError = error.localizedDescription
            isConnected = false
        }
    }

    public func disconnect() {
        isConnected = false
        bankAccounts = []
    }

    // MARK: - Persistence

    private func loadSavedConfiguration() {
        // TODO: Load from Keychain for secure credential storage
        // For now, check if we have saved config
    }

    private func saveConfiguration() {
        // TODO: Save to Keychain for secure credential storage
    }

    public func clearConfiguration() {
        zohoConfig = nil
        anthropicConfig = nil
        categoryMapping = nil
        isConfigured = false
        isConnected = false
        zohoClient = nil
        claudeService = nil
        // TODO: Clear from Keychain
    }
}
