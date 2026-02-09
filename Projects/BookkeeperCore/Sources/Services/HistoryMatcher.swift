import Foundation
import ZohoBooksClient

/// Result of history matching, including debug info for display
public struct HistoryMatchResult: Sendable {
    public let suggestion: TransactionSuggestion
    public let debugLines: [String]
}

/// Refines Claude's transaction suggestions using historical expense data from Zoho Books.
/// When a vendor has been categorized before, overrides Claude's category (and description)
/// with the historically most-used values.
public struct HistoryMatcher: Sendable {

    public init() {}

    /// Refine a suggestion by checking Zoho expense history for the same vendor.
    /// - Parameters:
    ///   - suggestion: Claude's initial suggestion
    ///   - transaction: The bank transaction being categorized
    ///   - client: Zoho Books API client
    ///   - bankAccountId: The bank account ID (for debug context only)
    /// - Returns: A result containing the refined suggestion and debug lines
    public func refine(
        suggestion: TransactionSuggestion,
        transaction: ZBBankTransaction,
        client: ZohoBooksClient<ZohoOAuth>,
        bankAccountId: String
    ) async throws -> HistoryMatchResult {
        var debugLines: [String] = []

        // Only applies to expense suggestions with a vendor
        guard suggestion.transactionType == .expense,
              let vendorName = suggestion.vendorName,
              !vendorName.isEmpty else {
            debugLines.append("History: skipped (not an expense or no vendor)")
            return HistoryMatchResult(suggestion: suggestion, debugLines: debugLines)
        }

        // Resolve vendor name to ID
        guard let vendor = try await client.searchContactByName(vendorName, contactType: "vendor"),
              let vendorId = vendor.contactId else {
            debugLines.append("History: vendor '\(vendorName)' not found in Zoho")
            return HistoryMatchResult(suggestion: suggestion, debugLines: debugLines)
        }

        // Fetch ALL historical expenses for this vendor (no bank account filter)
        let expenses = try await client.fetchExpenses(vendorId: vendorId)
        debugLines.append("History: \(expenses.count) prior expense(s) for '\(vendorName)'")

        guard !expenses.isEmpty else {
            return HistoryMatchResult(suggestion: suggestion, debugLines: debugLines)
        }

        // Show category breakdown
        let categoryCounts = countOccurrences(expenses.compactMap { $0.accountName })
        for (category, count) in categoryCounts {
            debugLines.append("  \(category): \(count)x")
        }

        // Override category if a majority share the same one
        var overrideCategory = suggestion.category
        if let (topCategory, count) = categoryCounts.first, count > expenses.count / 2 {
            overrideCategory = topCategory
        }

        // For description, use amount-matched expenses for more relevant matches
        var overrideDescription = suggestion.description
        let amountMatched = expenses.filter { expense in
            guard let expenseAmount = expense.amount else { return false }
            return abs(expenseAmount - transaction.amount) < 0.01
        }
        if !amountMatched.isEmpty {
            let descCounts = countOccurrences(amountMatched.compactMap { $0.description })
            if let (topDesc, count) = descCounts.first, count > amountMatched.count / 2 {
                overrideDescription = topDesc
            }
        }

        // If nothing changed, return original
        if overrideCategory == suggestion.category && overrideDescription == suggestion.description {
            return HistoryMatchResult(suggestion: suggestion, debugLines: debugLines)
        }

        let refined = TransactionSuggestion(
            transactionType: suggestion.transactionType,
            vendorName: suggestion.vendorName,
            category: overrideCategory,
            description: overrideDescription,
            transferToAccount: suggestion.transferToAccount,
            confidence: 98,
            reasoning: suggestion.reasoning + " [Refined by history: \(expenses.count) prior expense(s)]"
        )
        return HistoryMatchResult(suggestion: refined, debugLines: debugLines)
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
