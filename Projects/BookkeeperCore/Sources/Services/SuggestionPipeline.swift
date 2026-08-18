import Foundation
import ZohoBooksClient

/// Runs the full suggestion flow for one transaction: Claude proposal, then
/// history-based refinement. One call site for the CLI and the app.
public actor SuggestionPipeline {
    private let claudeService: ClaudeService
    private let historyMatcher: HistoryMatcher

    public init(claudeService: ClaudeService, historyMatcher: HistoryMatcher = HistoryMatcher()) {
        self.claudeService = claudeService
        self.historyMatcher = historyMatcher
    }

    public func suggestion(
        for transaction: ZBBankTransaction,
        client: ZohoBooksClient<ZohoOAuth>,
        bankAccounts: [ZBBankAccount],
        existingVendors: [String],
        accountType: String,
        vendorMemory: (@Sendable (String) async -> String?)? = nil
    ) async throws -> HistoryMatchResult {
        var suggestion = try await claudeService.suggestCategorization(
            transaction: transaction,
            bankAccounts: bankAccounts,
            existingVendors: existingVendors,
            accountType: accountType
        )

        // What the user actually saved for a matching feed description beats
        // the AI's guess — and running this *before* history refinement means
        // the corrected vendor's category history gets applied too.
        if suggestion.transactionType == .expense || suggestion.transactionType == .refund,
           let raw = transaction.description,
           let remembered = await vendorMemory?(raw),
           remembered != suggestion.vendorName {
            suggestion = TransactionSuggestion(
                transactionType: suggestion.transactionType,
                vendorName: remembered,
                category: suggestion.category,
                description: suggestion.description,
                transferToAccount: suggestion.transferToAccount,
                confidence: max(suggestion.confidence, 90),
                reasoning: suggestion.reasoning
                    + " [Vendor from your history: you previously saved a matching description as \"\(remembered)\"]"
            )
        }

        return try await historyMatcher.refine(
            suggestion: suggestion,
            transaction: transaction,
            source: ZohoVendorHistorySource(client: client)
        )
    }
}
