import Foundation
import ZohoBooksClient

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

    /// Refine a suggestion by checking expense history for the same vendor.
    public func refine(
        suggestion: TransactionSuggestion,
        transaction: ZBBankTransaction,
        source: any VendorHistorySource
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
            vendorId = try await source.findVendorId(name: vendorName)
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
            expenses = try await source.fetchExpenses(vendorId: vendorId)
            expenseCache[vendorId] = expenses
        }

        debugLines.append("History: \(expenses.count) prior expense(s) for '\(vendorName)'")

        guard !expenses.isEmpty else {
            return HistoryMatchResult(suggestion: suggestion, debugLines: debugLines)
        }

        // Same-amount charges are the strongest signal: one vendor's recurring
        // subscriptions (Apple One vs. AppleCare) differ by amount, not name.
        let amountMatched = expenses.filter { expense in
            guard let expenseAmount = expense.amount else { return false }
            return abs(expenseAmount - transaction.amount) < 0.01
        }

        // Category vote: same-amount expenses when any of them are categorized,
        // otherwise the vendor's whole history. Expenses with no account name
        // never dilute the vote.
        var categorized = amountMatched.compactMap { $0.accountName }
        if categorized.isEmpty {
            categorized = expenses.compactMap { $0.accountName }
        } else {
            debugLines.append("  voting on \(amountMatched.count) same-amount expense(s)")
        }
        let categoryCounts = countOccurrences(categorized)
        for (category, count) in categoryCounts {
            debugLines.append("  \(category): \(count)x")
        }

        // Override category if a majority of the voting pool share one.
        var overrideCategory = suggestion.category
        if let (topCategory, count) = categoryCounts.first, count > categorized.count / 2 {
            overrideCategory = topCategory
        }

        // For description, use amount-matched expenses for more relevant matches
        var overrideDescription = suggestion.description
        if !amountMatched.isEmpty {
            let described = amountMatched.compactMap { $0.description }
            let descCounts = countOccurrences(described)
            if let (topDesc, count) = descCounts.first, count > described.count / 2 {
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
    /// Ties break alphabetically so results are stable across runs
    /// (dictionary ordering is otherwise nondeterministic).
    private func countOccurrences(_ values: [String]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for value in values {
            counts[value, default: 0] += 1
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
    }
}
