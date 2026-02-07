import Foundation
import ZohoBooksClient

/// ViewModel for the dashboard showing stats and pending counts
@MainActor
public final class DashboardViewModel: ObservableObject {
    @Published public var bankAccounts: [ZBBankAccount] = []
    @Published public var pendingCounts: [String: Int] = [:]  // accountId -> count
    @Published public var totalPendingCount: Int = 0
    @Published public var isLoading = false
    @Published public var errorMessage: String?

    private let cacheService: CacheService

    public init(cacheService: CacheService) {
        self.cacheService = cacheService
    }

    /// Load all bank accounts and their pending transaction counts
    public func loadDashboard(client: ZohoBooksClient<ZohoOAuth>) async {
        isLoading = true
        errorMessage = nil

        do {
            // Fetch bank accounts
            bankAccounts = try await client.fetchBankAccounts()

            // Get pending counts for each account
            var counts: [String: Int] = [:]
            var total = 0

            for account in bankAccounts {
                let transactions = try await client.fetchUncategorizedTransactions(
                    accountId: account.accountId,
                    year: nil
                )

                // Filter out processed/skipped
                var pending = 0
                for tx in transactions {
                    let isProcessed = await cacheService.isProcessed(tx.transactionId)
                    let isSkipped = await cacheService.isSkipped(tx.transactionId)
                    if !isProcessed && !isSkipped {
                        pending += 1
                    }
                }

                counts[account.accountId] = pending
                total += pending
            }

            pendingCounts = counts
            totalPendingCount = total

        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Get cache statistics
    public func getCacheStats() async -> (processed: Int, skipped: Int, vendors: Int) {
        await cacheService.getStats()
    }

    /// Refresh pending counts (lighter weight than full dashboard load)
    public func refreshPendingCounts(client: ZohoBooksClient<ZohoOAuth>) async {
        // Re-run the same logic as loadDashboard
        await loadDashboard(client: client)
    }
}
