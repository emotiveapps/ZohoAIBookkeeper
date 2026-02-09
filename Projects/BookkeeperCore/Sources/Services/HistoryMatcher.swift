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
/// Caches vendor lookups and expense history within a session for performance.
public actor HistoryMatcher {

    /// Cache: vendor name (lowercased) -> vendor ID (nil means not found)
    private var vendorIdCache: [String: String?] = [:]

    /// Cache: vendor ID -> expenses
    private var expenseCache: [String: [ZBExpense]] = [:]

    public init() {}

    /// Refine a suggestion by checking Zoho expense history for the same vendor.
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

        // Resolve vendor name to ID (cached)
        let cacheKey = vendorName.lowercased()
        let vendorId: String?
        if let cached = vendorIdCache[cacheKey] {
            vendorId = cached
        } else {
            let vendor = try await client.searchContactByName(vendorName, contactType: "vendor")
            vendorId = vendor?.contactId
            vendorIdCache[cacheKey] = vendorId
        }

        guard let vendorId else {
            debugLines.append("History: vendor '\(vendorName)' not found in Zoho")
            return HistoryMatchResult(suggestion: suggestion, debugLines: debugLines)
        }

        // Fetch expenses for this vendor (cached)
        let expenses: [ZBExpense]
        if let cached = expenseCache[vendorId] {
            expenses = cached
        } else {
            expenses = try await client.fetchExpenses(vendorId: vendorId)
            expenseCache[vendorId] = expenses
        }

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
