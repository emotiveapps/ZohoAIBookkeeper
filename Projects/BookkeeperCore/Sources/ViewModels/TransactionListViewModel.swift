import Foundation
import ZohoBooksClient

/// ViewModel for managing a list of transactions
@MainActor
public final class TransactionListViewModel: ObservableObject {
    @Published public var transactions: [ZBBankTransaction] = []
    @Published public var categorizedTransactions: [CategorizedTransaction] = []
    @Published public var isLoading = false
    @Published public var errorMessage: String?

    private let cacheService: CacheService

    public init(cacheService: CacheService) {
        self.cacheService = cacheService
    }

    /// Load uncategorized transactions from Zoho
    public func loadTransactions(
        client: ZohoBooksClient<ZohoOAuth>,
        accountId: String,
        year: Int? = nil
    ) async {
        isLoading = true
        errorMessage = nil

        do {
            let allTransactions = try await client.fetchUncategorizedTransactions(
                accountId: accountId,
                year: year
            )

            // Filter out already processed/skipped transactions
            var unprocessed: [ZBBankTransaction] = []
            for tx in allTransactions {
                let isProcessed = await cacheService.isProcessed(tx.transactionId)
                let isSkipped = await cacheService.isSkipped(tx.transactionId)
                if !isProcessed && !isSkipped {
                    unprocessed.append(tx)
                }
            }

            transactions = unprocessed
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Get pending transaction count
    public var pendingCount: Int {
        transactions.count
    }

    /// Mark a transaction as processed
    public func markProcessed(_ transactionId: String) async {
        await cacheService.markProcessed(transactionId)
        transactions.removeAll { $0.transactionId == transactionId }
    }

    /// Mark a transaction as skipped
    public func markSkipped(_ transactionId: String) async {
        await cacheService.markSkipped(transactionId)
        transactions.removeAll { $0.transactionId == transactionId }
    }
}
