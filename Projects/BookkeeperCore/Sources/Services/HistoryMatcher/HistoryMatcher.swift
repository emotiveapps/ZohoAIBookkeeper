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
        // Zoho's expense list populates `total` but leaves `amount` null, so
        // compare against whichever is present.
        let amountMatched = expenses.filter { expense in
            guard let expenseAmount = expense.total ?? expense.amount else { return false }
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

        // Description: reuse what a same-amount expense was called before.
        // Past saves that kept the raw feed text carry no information (they're
        // exactly the string being improved), so they don't get a vote. The
        // rest are grouped fuzzily so wording drift like "Theft and Loss" vs
        // "Theft & Loss" still clusters, with recency breaking ties.
        var overrideDescription = suggestion.description
        let rawKey = transaction.description.flatMap { DescriptionNormalizer.key($0) }
        let informative = amountMatched.compactMap { expense -> (key: String, date: String, text: String)? in
            guard let text = expense.description,
                  let key = DescriptionNormalizer.key(text),
                  key != rawKey else { return nil }
            return (key: key, date: expense.date ?? "", text: text)
        }
        if !informative.isEmpty {
            let groups = Dictionary(grouping: informative, by: \.key)
            let winner = groups.values.max { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count < rhs.count }
                return (lhs.map(\.date).max() ?? "") < (rhs.map(\.date).max() ?? "")
            }
            if let latest = winner?.max(by: { $0.date < $1.date }) {
                overrideDescription = latest.text
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
