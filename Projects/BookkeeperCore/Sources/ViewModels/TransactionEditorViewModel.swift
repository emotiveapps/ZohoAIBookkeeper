import Foundation
import ZohoBooksClient

/// ViewModel for editing a single transaction
@MainActor
public final class TransactionEditorViewModel: ObservableObject {
    @Published public var categorizedTransaction: CategorizedTransaction
    @Published public var isLoadingSuggestion = false
    @Published public var isSaving = false
    @Published public var errorMessage: String?

    public let availableCategories: [String]
    public let availableVendors: [String]
    public let bankAccounts: [ZBBankAccount]

    private let claudeService: ClaudeService?

    public init(
        transaction: ZBBankTransaction,
        suggestion: TransactionSuggestion? = nil,
        categories: [String],
        vendors: [String],
        bankAccounts: [ZBBankAccount],
        claudeService: ClaudeService? = nil
    ) {
        let initialSuggestion = suggestion ?? TransactionSuggestion()
        self.categorizedTransaction = CategorizedTransaction(
            transaction: transaction,
            suggestion: initialSuggestion
        )
        self.availableCategories = categories
        self.availableVendors = vendors
        self.bankAccounts = bankAccounts
        self.claudeService = claudeService
    }

    /// Available transaction types based on debit/credit
    public var availableTransactionTypes: [TransactionType] {
        categorizedTransaction.transaction.isDebit
            ? TransactionType.debitTypes
            : TransactionType.creditTypes
    }

    /// Request AI suggestion for the transaction
    public func requestAISuggestion() async {
        guard let service = claudeService else {
            errorMessage = "AI service not configured"
            return
        }

        isLoadingSuggestion = true
        errorMessage = nil

        do {
            let suggestion = try await service.suggestCategorization(
                transaction: categorizedTransaction.transaction,
                bankAccounts: bankAccounts,
                existingVendors: availableVendors
            )

            categorizedTransaction.suggestion = suggestion
            categorizedTransaction.selectedType = suggestion.transactionType
            categorizedTransaction.vendorName = suggestion.vendorName ?? ""
            categorizedTransaction.category = suggestion.category ?? "Uncategorized"
            categorizedTransaction.description = suggestion.description ?? categorizedTransaction.transaction.description ?? ""
        } catch {
            errorMessage = "AI suggestion failed: \(error.localizedDescription)"
        }

        isLoadingSuggestion = false
    }

    /// Save the categorized transaction to Zoho
    public func save(
        client: ZohoBooksClient<ZohoOAuth>,
        cacheService: CacheService
    ) async -> Bool {
        isSaving = true
        errorMessage = nil

        do {
            try await categorizeTransaction(client: client, cacheService: cacheService)
            isSaving = false
            return true
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            isSaving = false
            return false
        }
    }

    private func categorizeTransaction(
        client: ZohoBooksClient<ZohoOAuth>,
        cacheService: CacheService
    ) async throws {
        let tx = categorizedTransaction.transaction

        switch categorizedTransaction.selectedType {
        case .expense:
            // Get or create vendor if specified
            var vendorId: String?
            if !categorizedTransaction.vendorName.isEmpty {
                let vendor = try await client.getOrCreateVendor(name: categorizedTransaction.vendorName)
                vendorId = vendor.contactId
                await cacheService.addVendor(categorizedTransaction.vendorName)
            }

            // Find category account
            let categoryAccount = try await client.searchAccountByName(categorizedTransaction.category)

            let request = ZBCategorizeExpenseRequest(
                accountId: categoryAccount?.accountId ?? "",
                vendorId: vendorId,
                description: categorizedTransaction.description
            )

            try await client.categorizeAsExpense(transactionId: tx.transactionId, request: request)

        case .transfer:
            let request = ZBCategorizeTransferRequest(
                toAccountId: categorizedTransaction.transferToAccountId,
                amount: tx.amount,
                description: categorizedTransaction.description
            )

            try await client.categorizeAsTransfer(transactionId: tx.transactionId, request: request)

        case .ownerContribution:
            let equityAccount = try await client.searchAccountByName("Owner's Equity")

            let request = ZBCategorizeOwnerContributionRequest(
                accountId: equityAccount?.accountId ?? "",
                description: categorizedTransaction.description
            )

            try await client.categorizeAsOwnerContribution(transactionId: tx.transactionId, request: request)

        case .sale:
            let salesAccount = try await client.searchAccountByName("Sales")

            let request = ZBCategorizeSaleRequest(
                accountId: salesAccount?.accountId ?? "",
                description: categorizedTransaction.description
            )

            try await client.categorizeAsSale(transactionId: tx.transactionId, request: request)

        case .refund, .skip:
            // Skip - don't categorize
            break
        }

        await cacheService.markProcessed(tx.transactionId)
    }
}
