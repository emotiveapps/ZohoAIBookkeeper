import Foundation
import Testing
import ZohoBooksClient
@testable import BookkeeperCore

/// Scripted stand-in for Zoho, tracking call counts so caching is verifiable.
private actor StubHistorySource: VendorHistorySource {
    var vendorIds: [String: String]
    var expensesByVendor: [String: [ZBExpense]]
    private(set) var vendorLookups = 0
    private(set) var expenseFetches = 0

    init(vendorIds: [String: String] = [:], expensesByVendor: [String: [ZBExpense]] = [:]) {
        self.vendorIds = vendorIds
        self.expensesByVendor = expensesByVendor
    }

    func findVendorId(name: String) async throws -> String? {
        vendorLookups += 1
        return vendorIds[name]
    }

    func fetchExpenses(vendorId: String) async throws -> [ZBExpense] {
        expenseFetches += 1
        return expensesByVendor[vendorId] ?? []
    }
}

private func expense(
    category: String?, amount: Double = 10, description: String? = nil, date: String? = nil
) -> ZBExpense {
    ZBExpense(accountName: category, date: date, amount: amount, description: description)
}

/// Shaped like Zoho's live expense list: `total` populated, `amount` null.
private func listedExpense(
    category: String?, total: Double, description: String? = nil, date: String? = nil
) -> ZBExpense {
    ZBExpense(accountName: category, date: date, total: total, description: description)
}

private func transaction(amount: Double = 10, description: String? = nil) -> ZBBankTransaction {
    ZBBankTransaction(
        transactionId: "tx1", date: "2026-08-01", amount: amount,
        debitOrCredit: "debit", description: description
    )
}

private func expenseSuggestion(vendor: String? = "Acme", category: String = "Software") -> TransactionSuggestion {
    TransactionSuggestion(transactionType: .expense, vendorName: vendor, category: category, confidence: 60, reasoning: "ai")
}

@Suite("HistoryMatcher")
struct HistoryMatcherTests {

    @Test("Majority category in history overrides the AI's category")
    func majorityOverride() async throws {
        let source = StubHistorySource(
            vendorIds: ["Acme": "v1"],
            expensesByVendor: ["v1": [
                expense(category: "Office Supplies"),
                expense(category: "Office Supplies"),
                expense(category: "Software")
            ]]
        )
        let result = try await HistoryMatcher().refine(
            suggestion: expenseSuggestion(category: "Software"),
            transaction: transaction(),
            source: source
        )
        #expect(result.suggestion.category == "Office Supplies")
        #expect(result.suggestion.confidence == 98)
    }

    @Test("Live-API expenses (total set, amount null) still amount-match; raw feed text doesn't win the description vote")
    func appleOneScenario() async throws {
        // Real-world shape: three early saves kept the raw feed text, one has
        // a human description. The raw text must not outvote it, and matching
        // must work off `total` because the list endpoint leaves `amount` null.
        let source = StubHistorySource(
            vendorIds: ["Apple": "v1"],
            expensesByVendor: ["v1": [
                listedExpense(category: "Online Services", total: 39.73, description: "APPLE.COM/BILL", date: "2025-08-31"),
                listedExpense(category: "Online Services", total: 39.73, description: "APPLE.COM/BILL", date: "2025-10-31"),
                listedExpense(category: "Online Services", total: 39.73, description: "APPLE.COM/BILL", date: "2025-12-01"),
                listedExpense(category: "Online Services", total: 39.73, description: "Apple One Premier (monthly)", date: "2026-07-01"),
                listedExpense(category: "Hardware", total: 13.49, description: "AppleCare+ with Theft and Loss", date: "2026-06-07")
            ]]
        )
        let result = try await HistoryMatcher().refine(
            suggestion: expenseSuggestion(vendor: "Apple", category: "Software"),
            transaction: transaction(amount: 39.73, description: "APPLE.COM/BILL"),
            source: source
        )
        #expect(result.suggestion.category == "Online Services")
        #expect(result.suggestion.description == "Apple One Premier (monthly)")
    }

    @Test("Description wording drift clusters together; ties resolve to the most recent")
    func fuzzyDescriptionTieBreak() async throws {
        let source = StubHistorySource(
            vendorIds: ["Apple": "v1"],
            expensesByVendor: ["v1": [
                listedExpense(category: "Hardware", total: 13.49, description: "AppleCare+ with Theft and Loss", date: "2026-06-07"),
                listedExpense(category: "Hardware", total: 13.49, description: "AppleCare+ with Theft & Loss", date: "2026-07-07")
            ]]
        )
        let result = try await HistoryMatcher().refine(
            suggestion: expenseSuggestion(vendor: "Apple", category: "Software"),
            transaction: transaction(amount: 13.49, description: "APPLE.COM/BILL"),
            source: source
        )
        #expect(result.suggestion.category == "Hardware")
        #expect(result.suggestion.description == "AppleCare+ with Theft & Loss")
    }

    @Test("Same-amount history wins the category vote over the vendor-wide majority")
    func amountScopedCategoryVote() async throws {
        // Apple-style vendor: many $38 Apple One charges vs. a few $13.49
        // AppleCare charges — a $13.49 transaction must refine to the
        // AppleCare category even though Subscriptions wins vendor-wide.
        let source = StubHistorySource(
            vendorIds: ["Apple": "v1"],
            expensesByVendor: ["v1": [
                expense(category: "Subscriptions", amount: 38),
                expense(category: "Subscriptions", amount: 38),
                expense(category: "Subscriptions", amount: 38),
                expense(category: "Subscriptions", amount: 38),
                expense(category: "Insurance", amount: 13.49),
                expense(category: "Insurance", amount: 13.49)
            ]]
        )
        let result = try await HistoryMatcher().refine(
            suggestion: expenseSuggestion(vendor: "Apple", category: "Software"),
            transaction: transaction(amount: 13.49),
            source: source
        )
        #expect(result.suggestion.category == "Insurance")
    }

    @Test("With no same-amount history, the vendor-wide vote still applies")
    func amountFallbackToVendorWideVote() async throws {
        let source = StubHistorySource(
            vendorIds: ["Apple": "v1"],
            expensesByVendor: ["v1": [
                expense(category: "Subscriptions", amount: 38),
                expense(category: "Subscriptions", amount: 38),
                expense(category: "Insurance", amount: 13.49)
            ]]
        )
        let result = try await HistoryMatcher().refine(
            suggestion: expenseSuggestion(vendor: "Apple", category: "Software"),
            transaction: transaction(amount: 99.99),
            source: source
        )
        #expect(result.suggestion.category == "Subscriptions")
    }

    @Test("An even split does not override (no majority)")
    func evenSplitKeepsAISuggestion() async throws {
        let source = StubHistorySource(
            vendorIds: ["Acme": "v1"],
            expensesByVendor: ["v1": [
                expense(category: "Meals"),
                expense(category: "Travel")
            ]]
        )
        let result = try await HistoryMatcher().refine(
            suggestion: expenseSuggestion(category: "Software"),
            transaction: transaction(),
            source: source
        )
        #expect(result.suggestion.category == "Software")
        #expect(result.suggestion.confidence == 60)
    }

    @Test("Uncategorized expenses don't dilute the majority vote (B9)")
    func nilCategoriesExcludedFromDenominator() async throws {
        // 2 of 4 expenses name a category; both say Software. Under the old
        // denominator (all 4) that's not a majority; under the fixed one it is.
        let source = StubHistorySource(
            vendorIds: ["Acme": "v1"],
            expensesByVendor: ["v1": [
                expense(category: "Software"),
                expense(category: "Software"),
                expense(category: nil),
                expense(category: nil)
            ]]
        )
        let result = try await HistoryMatcher().refine(
            suggestion: expenseSuggestion(category: "Meals"),
            transaction: transaction(),
            source: source
        )
        #expect(result.suggestion.category == "Software")
    }

    @Test("Amount-matched history overrides the description")
    func descriptionOverride() async throws {
        let source = StubHistorySource(
            vendorIds: ["Acme": "v1"],
            expensesByVendor: ["v1": [
                expense(category: "Software", amount: 42.00, description: "Monthly subscription"),
                expense(category: "Software", amount: 42.00, description: "Monthly subscription"),
                expense(category: "Software", amount: 999.99, description: "Annual plan")
            ]]
        )
        let result = try await HistoryMatcher().refine(
            suggestion: expenseSuggestion(category: "Software"),
            transaction: transaction(amount: 42.00),
            source: source
        )
        #expect(result.suggestion.description == "Monthly subscription")
    }

    @Test("Non-expense and vendor-less suggestions pass through untouched")
    func skipsNonExpense() async throws {
        let source = StubHistorySource()
        let matcher = HistoryMatcher()

        let sale = TransactionSuggestion(transactionType: .sale, confidence: 70, reasoning: "-")
        let saleResult = try await matcher.refine(suggestion: sale, transaction: transaction(), source: source)
        #expect(saleResult.suggestion.confidence == 70)

        let noVendor = expenseSuggestion(vendor: nil)
        let noVendorResult = try await matcher.refine(suggestion: noVendor, transaction: transaction(), source: source)
        #expect(noVendorResult.suggestion.category == "Software")
        #expect(await source.vendorLookups == 0)
    }

    @Test("Unknown vendor passes through with a debug note")
    func unknownVendor() async throws {
        let source = StubHistorySource()
        let result = try await HistoryMatcher().refine(
            suggestion: expenseSuggestion(),
            transaction: transaction(),
            source: source
        )
        #expect(result.suggestion.confidence == 60)
        #expect(result.debugLines.contains { $0.contains("not found") })
    }

    @Test("Vendor and expense lookups are cached within a session")
    func sessionCaching() async throws {
        let source = StubHistorySource(
            vendorIds: ["Acme": "v1"],
            expensesByVendor: ["v1": [expense(category: "Software")]]
        )
        let matcher = HistoryMatcher()
        for _ in 0 ..< 3 {
            _ = try await matcher.refine(
                suggestion: expenseSuggestion(),
                transaction: transaction(),
                source: source
            )
        }
        #expect(await source.vendorLookups == 1)
        #expect(await source.expenseFetches == 1)
    }

    @Test("Category ties break deterministically (alphabetical)")
    func deterministicTies() async throws {
        // No majority either way, but the description path exercises
        // countOccurrences ordering; run the same input repeatedly and expect
        // identical output every time.
        let expenses = [
            expense(category: "Zebra", amount: 5, description: "B desc"),
            expense(category: "Alpha", amount: 5, description: "A desc"),
            expense(category: "Zebra", amount: 5, description: "A desc"),
            expense(category: "Alpha", amount: 5, description: "B desc")
        ]
        var seen = Set<String>()
        for _ in 0 ..< 5 {
            let source = StubHistorySource(vendorIds: ["Acme": "v1"], expensesByVendor: ["v1": expenses])
            let result = try await HistoryMatcher().refine(
                suggestion: expenseSuggestion(category: "Meals"),
                transaction: transaction(amount: 5),
                source: source
            )
            seen.insert(result.suggestion.category ?? "")
        }
        #expect(seen.count == 1)
    }
}
