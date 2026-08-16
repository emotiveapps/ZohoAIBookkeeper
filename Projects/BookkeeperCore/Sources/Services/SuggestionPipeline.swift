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
        accountType: String
    ) async throws -> HistoryMatchResult {
        let suggestion = try await claudeService.suggestCategorization(
            transaction: transaction,
            bankAccounts: bankAccounts,
            existingVendors: existingVendors,
            accountType: accountType
        )
        return try await historyMatcher.refine(
            suggestion: suggestion,
            transaction: transaction,
            source: ZohoVendorHistorySource(client: client)
        )
    }
}
