import Foundation
import ZohoBooksClient


/// Production source backed by the Zoho Books API.
public struct ZohoVendorHistorySource: VendorHistorySource {
    private let client: ZohoBooksClient<ZohoOAuth>

    public init(client: ZohoBooksClient<ZohoOAuth>) {
        self.client = client
    }

    public func findVendorId(name: String) async throws -> String? {
        try await client.searchContactByName(name, contactType: "vendor")?.contactId
    }

    public func fetchExpenses(vendorId: String) async throws -> [ZBExpense] {
        try await client.fetchExpenses(vendorId: vendorId)
    }
}

