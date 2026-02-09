import Foundation
import ZohoBooksClient

/// Refines Claude's transaction suggestions using historical expense data from Zoho Books.
/// When a vendor+amount combination has been categorized before, overrides Claude's category
/// and description with the historically most-used values.
public struct HistoryMatcher: Sendable {

    public init() {}

    /// Refine a suggestion by checking Zoho expense history for the same vendor and amount.
    /// - Parameters:
    ///   - suggestion: Claude's initial suggestion
    ///   - transaction: The bank transaction being categorized
    ///   - client: Zoho Books API client
    ///   - bankAccountId: The bank account ID (used as paid_through_account_id filter)
    /// - Returns: A refined suggestion with history-based overrides, or the original if no match
    public func refine(
        suggestion: TransactionSuggestion,
        transaction: ZBBankTransaction,
        client: ZohoBooksClient<ZohoOAuth>,
        bankAccountId: String
    ) async throws -> TransactionSuggestion {
        // Only applies to expense suggestions with a vendor
        guard suggestion.transactionType == .expense,
              let vendorName = suggestion.vendorName,
              !vendorName.isEmpty else {
            return suggestion
        }

        // Resolve vendor name to ID
        guard let vendor = try await client.searchContactByName(vendorName, contactType: "vendor"),
              let vendorId = vendor.contactId else {
            return suggestion
        }

        // Fetch historical expenses for this vendor on the same bank account
        let expenses = try await client.fetchExpenses(
            vendorId: vendorId,
            paidThroughAccountId: bankAccountId
        )

        // Filter to matching amount (within $0.01 tolerance)
        let matchingExpenses = expenses.filter { expense in
            guard let expenseAmount = expense.amount else { return false }
            return abs(expenseAmount - transaction.amount) < 0.01
        }

        guard !matchingExpenses.isEmpty else {
            return suggestion
        }

        // Find most common category (accountName) among matches
        var overrideCategory = suggestion.category
        let categoryCounts = countOccurrences(matchingExpenses.compactMap { $0.accountName })
        if let (topCategory, count) = categoryCounts.first, count > matchingExpenses.count / 2 {
            overrideCategory = topCategory
        }

        // Find most common description among matches
        var overrideDescription = suggestion.description
        let descCounts = countOccurrences(matchingExpenses.compactMap { $0.description })
        if let (topDesc, count) = descCounts.first, count > matchingExpenses.count / 2 {
            overrideDescription = topDesc
        }

        // If nothing changed, return original
        if overrideCategory == suggestion.category && overrideDescription == suggestion.description {
            return suggestion
        }

        return TransactionSuggestion(
            transactionType: suggestion.transactionType,
            vendorName: suggestion.vendorName,
            category: overrideCategory,
            description: overrideDescription,
            transferToAccount: suggestion.transferToAccount,
            confidence: 98,
            reasoning: suggestion.reasoning + " [Refined by history match: \(matchingExpenses.count) prior expense(s)]"
        )
    }

    /// Count occurrences of each value, sorted descending by count.
    private func countOccurrences(_ values: [String]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for value in values {
            counts[value, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }
}
