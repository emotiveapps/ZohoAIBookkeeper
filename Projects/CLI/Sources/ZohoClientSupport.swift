import ArgumentParser
import Foundation
import ZohoBooksClient
import BookkeeperCore

func createZohoClient(config: FullConfiguration, verbose: Bool) async throws -> ZohoBooksClient<ZohoOAuth> {
    let zohoConfig = ZohoConfig(
        clientId: config.zoho.clientId,
        clientSecret: config.zoho.clientSecret,
        accessToken: config.zoho.accessToken,
        refreshToken: config.zoho.refreshToken,
        organizationId: config.zoho.organizationId,
        region: ZohoRegion(rawValue: config.zoho.region) ?? .com
    )

    let client = ZohoBooksClient(config: zohoConfig, verbose: verbose)
    await client.configure()
    return client
}

func fetchExpenseCategories(client: ZohoBooksClient<ZohoOAuth>) async throws -> [String] {
    let accounts = try await client.fetchAccounts()
    // Includes inventory/COGS accounts so LEGO resale purchases can be routed
    // to Inventory Asset instead of a period expense.
    return CategoryFilter.spendingCategories(from: accounts)
}
