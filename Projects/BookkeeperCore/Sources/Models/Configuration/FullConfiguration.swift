import Foundation


public struct FullConfiguration: Codable, Sendable {
    public let zoho: ZohoConfiguration
    public let anthropic: AnthropicConfiguration
    public let categoryMapping: CategoryMappingConfig?
    /// Receipt-ingestion mailboxes (Microsoft 365 via Graph). Optional so older
    /// configs keep decoding.
    public let receipts: ReceiptsConfig?

    public init(
        zoho: ZohoConfiguration,
        anthropic: AnthropicConfiguration,
        categoryMapping: CategoryMappingConfig? = nil,
        receipts: ReceiptsConfig? = nil
    ) {
        self.zoho = zoho
        self.anthropic = anthropic
        self.categoryMapping = categoryMapping
        self.receipts = receipts
    }

    /// URL of a transaction in the Zoho Books web UI (used by "view on web" affordances).
    public func transactionURL(bankAccountId: String, transactionId: String, isDebit: Bool) -> URL? {
        // Zoho Books is an SPA: the query string lives inside the URL fragment.
        let txnGroup = isDebit ? "money_out" : "money_in"
        let fragment = "/banking/transactions/details"
            + "?account_id=\(bankAccountId)"
            + "&bankaccount_id=\(bankAccountId)"
            + "&transaction_id=\(transactionId)"
            + "&filter_by=Status.Uncategorized"
            + "&txn_group=\(txnGroup)"
            + "&txn_status=uncategorized"
        return URL(string: "https://books.zoho.com/app/\(zoho.organizationId)#\(fragment)")
    }
}

